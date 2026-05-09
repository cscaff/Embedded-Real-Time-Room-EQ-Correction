/*
 * eq.c — HPS entry point for room EQ calibration and FIR tap generation
 *
 * Sequence:
 *   1. generate_sine_lut()  — compute 256 Q1.23 sine values for one quadrant
 *   2. load_lut()           — write them to the peripheral via ROOM_EQ_WRITE_LUT
 *   3. trigger_sweep()      — assert sweep_start via ROOM_EQ_WRITE_CTRL
 *   4. chunked read loop    — poll CHUNK_COUNT, read active FFT bins per chunk
 *   5. fir_design_from_spectrum() — compute 128 correction taps from assembled spectrum
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
#define POLL_INTERVAL_US  1000     /* 1 ms between chunk polls             */
#define POLL_TIMEOUT_S    30       /* give up after 30 s (sweep is ~5 s)   */

/* FSM state values from room_eq_peripheral.sv */
#define STATE_IDLE        0u
#define STATE_CALIBRATING 1u
#define STATE_DONE        3u

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

/* ── Sweep frequency mapping ─────────────────────────────────────────────
 *
 * The sweep generator (phase_accumulator.sv) produces an exponential sweep
 * from F_START to F_END over SWEEP_SAMPS samples:
 *   f(n) = F_START * (F_END/F_START)^(n/SWEEP_SAMPS)
 *
 * For each 8192-sample chunk, we compute which FFT bins correspond to
 * the sweep's frequency range during that chunk.
 */
static double sweep_freq(int sample_n)
{
    return F_START * pow(F_END / F_START, (double)sample_n / SWEEP_SAMPS);
}

static void chunk_bin_range(int chunk, int *k_lo, int *k_hi)
{
    double f_lo = sweep_freq(chunk * N_FFT);
    double f_hi = sweep_freq((chunk + 1) * N_FFT - 1);
    *k_lo = (int)floor(f_lo / BIN_WIDTH);
    *k_hi = (int)ceil(f_hi / BIN_WIDTH);
    if (*k_lo < 1)        *k_lo = 1;          /* skip DC */
    if (*k_hi >= N_HALF)  *k_hi = N_HALF - 1;
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

    /* 2. Trigger sweep */
    if (trigger_sweep(fd) < 0) { ret = 1; goto done; }

    /* 3. Chunked spectrum assembly */
    double *spectrum = calloc(N_HALF, sizeof(double));
    int    *filled   = calloc(N_HALF, sizeof(int));
    if (!spectrum || !filled) {
        perror("eq: calloc");
        free(spectrum); free(filled);
        ret = 1; goto done;
    }

    int last_chunk = -1;
    int running = 1;
    int max_polls = (POLL_TIMEOUT_S * 1000000) / POLL_INTERVAL_US;
    int poll_count = 0;

    while (running && poll_count < max_polls) {
        room_eq_status_t status;
        ioctl(fd, ROOM_EQ_READ_STATUS, &status);

        room_eq_chunk_count_t cc;
        ioctl(fd, ROOM_EQ_READ_CHUNK_COUNT, &cc);
        int current_chunk = (int)cc.count;

        /* Process all new chunks since last poll */
        while (last_chunk + 1 < current_chunk && last_chunk + 1 < N_CHUNKS) {
            int c = last_chunk + 1;
            int k_lo, k_hi;
            chunk_bin_range(c, &k_lo, &k_hi);

            for (int k = k_lo; k <= k_hi; k++) {
                room_eq_fft_addr_t addr = { .addr = (unsigned short)k };
                ioctl(fd, ROOM_EQ_WRITE_FFT_ADDR, &addr);

                room_eq_fft_data_t data;
                ioctl(fd, ROOM_EQ_READ_FFT_DATA, &data);

                int32_t re = sign_extend_24(data.rdata);
                int32_t im = sign_extend_24(data.idata);
                double r = re / (double)(1 << 23);
                double i = im / (double)(1 << 23);
                spectrum[k] = sqrt(r * r + i * i);
                filled[k] = 1;
            }

            printf("eq: chunk %2d  bins %4d-%4d  (%.0f-%.0f Hz)\n",
                   c, k_lo, k_hi,
                   k_lo * BIN_WIDTH, k_hi * BIN_WIDTH);
            last_chunk = c;
        }

        if (status.state == STATE_DONE)
            running = 0;
        else
            usleep(POLL_INTERVAL_US);

        poll_count++;
    }

    if (poll_count >= max_polls) {
        fprintf(stderr, "eq: timeout waiting for calibration after %d s\n",
                POLL_TIMEOUT_S);
        free(spectrum); free(filled);
        ret = 1; goto done;
    }

    /* Fill unfilled bins with 1.0 (no correction needed) */
    int n_filled = 0;
    for (int k = 0; k < N_HALF; k++) {
        if (filled[k]) n_filled++;
        else spectrum[k] = 1.0;
    }
    printf("eq: %d of %d bins filled across %d chunks\n",
           n_filled, N_HALF, last_chunk + 1);

    /* 4. Design correction filter */
    int32_t taps[N_TAPS];
    if (fir_design_from_spectrum(spectrum, N_HALF, taps) < 0) {
        fprintf(stderr, "eq: fir_design failed\n");
        free(spectrum); free(filled);
        ret = 1; goto done;
    }

    /* 5. Write taps to file */
    FILE *f = fopen("fir_taps.bin", "wb");
    if (f) {
        fwrite(taps, sizeof(int32_t), N_TAPS, f);
        fclose(f);
        printf("eq: %d Q1.23 taps written to fir_taps.bin\n", N_TAPS);
    } else {
        perror("eq: fopen fir_taps.bin");
    }

    /* 6. Write spectrum to file (for plotting) */
    FILE *sf = fopen("room_spectrum.txt", "w");
    if (sf) {
        for (int k = 0; k < N_HALF; k++)
            fprintf(sf, "%.10f\n", spectrum[k]);
        fclose(sf);
        printf("eq: spectrum written to room_spectrum.txt\n");
    }

    free(spectrum);
    free(filled);

done:
    close(fd);
    return ret;
}

#endif /* EQ_TEST_BUILD */
