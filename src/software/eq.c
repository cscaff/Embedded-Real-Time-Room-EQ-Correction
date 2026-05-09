/*
 * eq.c — HPS entry point for room EQ calibration and FIR tap generation
 *
 * Sequence:
 *   1. generate_sine_lut()  — compute 256 Q1.23 sine values for one quadrant
 *   2. load_lut()           — write them to the peripheral via ROOM_EQ_WRITE_LUT
 *   3. trigger_sweep()      — assert sweep_start via ROOM_EQ_WRITE_CTRL
 *   4. poll_done()          — poll ROOM_EQ_READ_STATUS until state == DONE
 *   5. read_fft_bins()      — read 4097 complex bins via ROOM_EQ_READ_FFT_DATA
 *   6. fir_design()         — compute 128 correction taps (see room_eq/FIR/)
 *
 * Build (on DE1-SoC):
 *   arm-linux-gnueabihf-gcc -O2 -Wall -lm \
 *       eq.c room_eq/FIR/fir_design.c \
 *       -Iroom_eq/device_drivers -o eq
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

#include "eq.h"

/* Hardware-dependent headers are excluded when building for unit tests on macOS */
#ifndef EQ_TEST_BUILD
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <errno.h>
#include "room_eq/device_drivers/room_eq.h"
#include "room_eq/FIR/fir_design.h"
#endif

#define DEVICE_PATH       "/dev/room_eq"
#define POLL_INTERVAL_US  100000   /* 100 ms between status polls          */
#define POLL_TIMEOUT_S    30       /* give up after 30 s (sweep is ~5 s)   */

/* FSM state values from room_eq_peripheral.sv */
#define STATE_IDLE    0u
#define STATE_SWEEP   1u
#define STATE_CAPTURE 2u
#define STATE_DONE    3u

/* ── Step 1: sine LUT generation ────────────────────────────────────────────
 *
 * The sweep generator (sine_lookup.sv) reconstructs a full sine wave from
 * 256 values that cover one quadrant (0 to just below π/2).  Port A of the
 * sine_lut BRAM must be loaded with these values before the sweep starts.
 *
 * Formula:  lut[i] = round(sin(i × π / 512) × 2²³)
 *
 * The factor π/512 = π / (2 × 256) steps uniformly through one quadrant.
 * The ×2²³ converts to Q1.23 signed integer (1 sign bit + 23 fractional bits).
 */
void generate_sine_lut(int32_t *lut, int n)  /* non-static: callable from test_eq.c */
{
    for (int i = 0; i < n; i++) {
        double angle = (double)i * M_PI / (2.0 * n);
        lut[i] = (int32_t)round(sin(angle) * (double)(1 << 23));
    }
}

#ifndef EQ_TEST_BUILD

/* ── Step 2: LUT loading ─────────────────────────────────────────────────── */

static int load_lut(int fd, const int32_t *lut, int n)
{
    for (int i = 0; i < n; i++) {
        room_eq_lut_t entry = {
            .addr = (unsigned char)i,
            .data = (unsigned int)(lut[i] & 0xFFFFFF)
        };
        if (ioctl(fd, ROOM_EQ_WRITE_LUT, &entry) < 0) {
            fprintf(stderr, "eq: LUT write failed at addr %d: %s\n",
                    i, strerror(errno));
            return -1;
        }
    }
    printf("eq: sine LUT loaded (%d entries)\n", n);
    return 0;
}

/* ── Step 3: sweep trigger ───────────────────────────────────────────────── */

static int trigger_sweep(int fd)
{
    room_eq_ctrl_t ctrl = { .sweep_start = 1 };
    if (ioctl(fd, ROOM_EQ_WRITE_CTRL, &ctrl) < 0) {
        perror("eq: ROOM_EQ_WRITE_CTRL");
        return -1;
    }
    printf("eq: sweep triggered\n");
    return 0;
}

/* ── Step 4: status polling ──────────────────────────────────────────────── */

static const char *state_name(unsigned int s)
{
    switch (s) {
    case STATE_IDLE:    return "IDLE";
    case STATE_SWEEP:   return "SWEEP";
    case STATE_CAPTURE: return "CAPTURE";
    case STATE_DONE:    return "DONE";
    default:            return "UNKNOWN";
    }
}

static int poll_done(int fd)
{
    int max_polls = (POLL_TIMEOUT_S * 1000000) / POLL_INTERVAL_US;
    unsigned int last_state = 0xFF;
    room_eq_status_t status;

    for (int i = 0; i < max_polls; i++) {
        if (ioctl(fd, ROOM_EQ_READ_STATUS, &status) < 0) {
            perror("eq: ROOM_EQ_READ_STATUS");
            return -1;
        }

        /* Print a line only when the FSM state changes */
        if (status.state != last_state) {
            printf("eq: status → %s\n", state_name(status.state));
            last_state = status.state;
        }

        if (status.state == STATE_DONE)
            return 0;

        usleep(POLL_INTERVAL_US);
    }

    fprintf(stderr, "eq: timeout waiting for DONE after %d s\n", POLL_TIMEOUT_S);
    return -1;
}

/* ── Step 5: FFT bin readout ─────────────────────────────────────────────── */
/*
 * The FFT result RAM stores 8192 bins but only 0..4096 are unique for a real
 * input (Hermitian symmetry).  We read N_HALF = 4097 bins.
 *
 * Each bin is 24-bit two's-complement Q1.23.  The driver masks to 24 bits
 * with & 0xFFFFFF; sign_extend_24() restores the sign before storing.
 *
 * Latency note: write FFT_ADDR ioctl, then read FFT_DATA ioctl.  The RAM has
 * a 1-cycle synchronous read latency, but the kernel syscall boundary between
 * the two ioctls takes thousands of 50 MHz cycles — the data is always ready.
 */
static int read_fft_bins(int fd, int32_t *real_out, int32_t *imag_out, int n_bins)
{
    for (int k = 0; k < n_bins; k++) {
        room_eq_fft_addr_t addr = { .addr = (unsigned short)k };
        if (ioctl(fd, ROOM_EQ_WRITE_FFT_ADDR, &addr) < 0) {
            fprintf(stderr, "eq: FFT_ADDR write failed at bin %d: %s\n",
                    k, strerror(errno));
            return -1;
        }

        room_eq_fft_data_t data;
        if (ioctl(fd, ROOM_EQ_READ_FFT_DATA, &data) < 0) {
            fprintf(stderr, "eq: FFT_DATA read failed at bin %d: %s\n",
                    k, strerror(errno));
            return -1;
        }

        real_out[k] = sign_extend_24(data.rdata);
        imag_out[k] = sign_extend_24(data.idata);
    }

    printf("eq: read %d FFT bins\n", n_bins);
    return 0;
}

/* ── main ────────────────────────────────────────────────────────────────── */

int main(void)
{
    int ret = 0;

    int fd = open(DEVICE_PATH, O_RDWR);
    if (fd < 0) {
        perror("eq: open " DEVICE_PATH);
        return 1;
    }

    /* 1. Generate and load sine LUT */
    int32_t lut[N_LUT];
    generate_sine_lut(lut, N_LUT);
    if (load_lut(fd, lut, N_LUT) < 0) { ret = 1; goto done; }

    /* 2. Trigger sweep and wait for DONE */
    if (trigger_sweep(fd) < 0) { ret = 1; goto done; }
    if (poll_done(fd)     < 0) { ret = 1; goto done; }

    /* 3. Read the half-spectrum FFT bins */
    int32_t *fft_real = malloc(N_HALF * sizeof(int32_t));
    int32_t *fft_imag = malloc(N_HALF * sizeof(int32_t));
    if (!fft_real || !fft_imag) {
        perror("eq: malloc");
        free(fft_real);
        free(fft_imag);
        ret = 1;
        goto done;
    }

    if (read_fft_bins(fd, fft_real, fft_imag, N_HALF) < 0) {
        free(fft_real);
        free(fft_imag);
        ret = 1;
        goto done;
    }

    /* 4. Design the correction FIR filter */
    int32_t taps[N_TAPS];
    if (fir_design(fft_real, fft_imag, N_HALF, taps) < 0) {
        fprintf(stderr, "eq: fir_design failed\n");
        free(fft_real);
        free(fft_imag);
        ret = 1;
        goto done;
    }

    /* 5. Write taps to file for use downstream */
    FILE *f = fopen("fir_taps.bin", "wb");
    if (f) {
        fwrite(taps, sizeof(int32_t), N_TAPS, f);
        fclose(f);
        printf("eq: %d Q1.23 taps written to fir_taps.bin\n", N_TAPS);
    } else {
        perror("eq: fopen fir_taps.bin");
    }

    free(fft_real);
    free(fft_imag);

done:
    close(fd);
    return ret;
}

#endif /* EQ_TEST_BUILD */
