/*
 * codec_init.c — Initialize the WM8731 codec via the FPGA I2C master
 *                and run Room EQ calibration.
 *
 * The Avalon I2C master IP is at offset 0x00 from the lightweight bridge.
 * The room_eq_peripheral is at offset 0x2000.
 *
 * Register map (word offsets from room_eq_peripheral base):
 *   0: CTRL       — [0] sweep_start (W, self-clears), [1] fifo_hps_mode (R/W)
 *   1: STATUS     — [3:0] FSM state, [4] fft_done, [5] fifo_empty
 *   3: VERSION    — 0x0001_0000
 *   4: LUT_ADDR   — 10-bit write address for sine LUT
 *   5: LUT_DATA   — 24-bit write data for sine LUT (fires we_lut)
 *   6: FFT_ADDR   — 13-bit read address for FFT results
 *   7: FFT_RDATA  — 24-bit real part at FFT_ADDR
 *   8: FFT_IDATA  — 24-bit imaginary part at FFT_ADDR
 *   9: ADC_LEFT   — 24-bit latest left ADC sample
 *  10: FIFO_RDATA — 24-bit pop-on-read from DCFIFO
 *
 * Usage:
 *   ./codec_init       — init codec + load LUT + start sweep
 *   ./codec_init m     — mic test (continuous ADC readback via reg 9)
 *   ./codec_init f     — FIFO test (Stage 1: read raw samples through DCFIFO)
 *   ./codec_init c     — full calibration (continuous FFT during sweep)
 */

#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>
#include <math.h>
#include <time.h>

/* ── Memory map ──────────────────────────────────────────── */

#define LW_BRIDGE_BASE   0xFF200000 // Lightweight HPS - FPGA Bridge
#define LW_BRIDGE_SPAN   0x00200000 // Width in Bytes 

#define I2C_BASE_OFFSET  0x0000 // I2C Base Address in bridge
#define ROOM_EQ_OFFSET   0x2000 // Room EQ Peripheral Base Address in bridge

/* ── Avalon I2C Master registers (byte offsets) ──────────── */

#define I2C_TFR_CMD      0x00 // main transmit command register
#define I2C_RX_DATA      0x04 // data received from the I2C bus
#define I2C_CTRL         0x08 // data received from the I2C bus
#define I2C_ISER         0x0C // Interrupt enable register
#define I2C_ISR          0x10 // Interrupt enable register
#define I2C_STATUS       0x14 // General controller state register
#define I2C_SCL_LOW      0x20 // SCL low period in clock cycles (for 100 kHz, at 50 MHz: 250 cycles)
#define I2C_SCL_HIGH     0x24 // SCL high period in clock cycles (for 100 kHz, at 50 MHz: 250 cycles)
#define I2C_SDA_HOLD     0x28 // Controls SDA hold timing.  (data remain stable briefly after clock edges)

#define TFR_CMD_STA      (1 << 9) // Start condition
#define TFR_CMD_STO      (1 << 8) // Stop condition
#define STATUS_CORE_STATUS  (1 << 0) // 0 indicates: I2C core is busy performing a transaction
#define CTRL_EN          (1 << 0) // Enable I2C master

/* ── WM8731 ──────────────────────────────────────────────── */

#define WM8731_ADDR      0x1A // Address of WM8731 on I2C bus

/* Analog path control (reg 0x04) options:
 *   0x010 = line-in, no boost, DAC selected
 *   0x012 = line-in, muted (bad)
 *   0x014 = mic input, no boost, DAC selected
 *   0x015 = mic input, +20dB boost, DAC selected
 */
static int use_line_in = 0;    /* 0=mic (default), 1=line-in */
static int mic_boost = 1;      /* 0=no boost, 1=+20dB boost */

/* ── Room EQ register offsets (word offsets) ──────────────── */

#define CTRL_REG        0
#define STATUS_REG      1
#define VERSION_REG     3
#define LUT_ADDR_REG    4
#define LUT_DATA_REG    5
#define FFT_ADDR_REG    6
#define FFT_RDATA_REG   7
#define FFT_IDATA_REG   8
#define ADC_LEFT_REG    9
#define FIFO_RDATA_REG  10

/* CTRL bits */
#define CTRL_SWEEP_START   (1 << 0) // Write 1 to start sweep.
#define CTRL_FIFO_HPS_MODE (1 << 1) // Diagnostic - Routes FIFO samples to HPS.

/* STATUS bits */
#define STATUS_STATE_MASK  0xF // FSM States + FFT FLAGS
#define STATUS_FFT_DONE    (1 << 4)
#define STATUS_FIFO_EMPTY  (1 << 5)

/* FSM states */
#define STATE_IDLE     0
#define STATE_SWEEP    1
#define STATE_DONE     2

#define LUT_SIZE       1024
#define FFT_SIZE       8192

static volatile uint32_t *i2c_base;
static volatile uint32_t *room_eq_base;

static inline void i2c_write_reg(int reg, uint32_t val)
{
    *(volatile uint32_t *)((uint8_t *)i2c_base + reg) = val;
}

static inline uint32_t i2c_read_reg(int reg)
{
    return *(volatile uint32_t *)((uint8_t *)i2c_base + reg);
}

// Wait until i2c is idle.
static void i2c_wait_idle(void)
{
    int timeout = 100000;
    while ((i2c_read_reg(I2C_STATUS) & STATUS_CORE_STATUS) && --timeout > 0)
        usleep(1);
    if (timeout == 0)
        fprintf(stderr, "Warning: I2C timeout waiting for idle\n");
}

// Initialize I2C master with 100 kHz clock and enable it.
static void i2c_init(void)
{
    i2c_write_reg(I2C_CTRL, 0);
    i2c_write_reg(I2C_SCL_LOW, 250);
    i2c_write_reg(I2C_SCL_HIGH, 250);
    i2c_write_reg(I2C_SDA_HOLD, 30);
    i2c_write_reg(I2C_CTRL, CTRL_EN);
    usleep(1000);
}

// 
static int wm8731_write(uint8_t reg, uint16_t data)
{
    uint8_t byte1 = (reg << 1) | ((data >> 8) & 0x01);
    uint8_t byte2 = data & 0xFF;
    // byte1 = [reg bits][data bit 8]
    // byte2 = [data bits 7:0]

    i2c_wait_idle();
    // Send start + Address
    i2c_write_reg(I2C_TFR_CMD, TFR_CMD_STA | (WM8731_ADDR << 1) | 0);
    // Sends [register bits + top data bit]
    i2c_write_reg(I2C_TFR_CMD, byte1);
    // Sends second byte and stop condition
    i2c_write_reg(I2C_TFR_CMD, TFR_CMD_STO | byte2);
    i2c_wait_idle();

    uint32_t isr = i2c_read_reg(I2C_ISR); // Check for NACK
    if (isr & (1 << 2)) {
        i2c_write_reg(I2C_ISR, isr);
        fprintf(stderr, "NACK on reg 0x%02x\n", reg);
        return -1;
    }
    return 0;
}

static int codec_init(void)
{
    fprintf(stderr, "Initializing I2C master...\n");
    i2c_init();

    fprintf(stderr, "Configuring WM8731 codec...\n");
    int err = 0;

    // Reset codec
    err |= wm8731_write(0x0F, 0x000);
    usleep(10000);

    // configure left/right headphone or line outputs
    // digital audio interface format
    // sample rate and clocking behavior
    err |= wm8731_write(0x00, 0x017);
    err |= wm8731_write(0x01, 0x017);
    err |= wm8731_write(0x02, 0x079);
    err |= wm8731_write(0x03, 0x079);
    {
        uint16_t reg04 = 0x010;          /* base: line-in, DAC selected */
        if (!use_line_in) reg04 |= 0x004; /* select mic instead of line-in */
        if (!use_line_in && mic_boost) reg04 |= 0x001; /* +20dB mic boost */
        fprintf(stderr, "Analog path: %s%s (reg04=0x%03x)\n",
               use_line_in ? "LINE-IN" : "MIC",
               (!use_line_in && mic_boost) ? " +20dB" : "", reg04);
        err |= wm8731_write(0x04, reg04); // analog path control
    }
    err |= wm8731_write(0x05, 0x000); 
    err |= wm8731_write(0x06, 0x000); 
    err |= wm8731_write(0x07, 0x00A); // digital audio interface: I2S, 24-bit, slave mode
    err |= wm8731_write(0x08, 0x000); 
    err |= wm8731_write(0x09, 0x001); // activate digital interface

    if (err)
        fprintf(stderr, "Some codec writes failed (NACKs)\n");
    else
        fprintf(stderr, "Codec initialized: I2S slave, 24-bit, 48 kHz\n");

    return err;
}

/* ── Sine LUT ─────────────────────────────────────────────── */

static void load_sine_lut(void)
{
    fprintf(stderr, "Loading sine LUT (%d entries)...\n", LUT_SIZE);
    for (int i = 0; i < LUT_SIZE; i++) {
        double  angle = i * M_PI / (2.0 * LUT_SIZE);
        int32_t val   = (int32_t)(sin(angle) * 8388607.0);
        room_eq_base[LUT_ADDR_REG] = i;
        room_eq_base[LUT_DATA_REG] = (uint32_t)(val & 0x00FFFFFF);
    }
    fprintf(stderr, "Sine LUT loaded.\n");
}

/* ── Sign-extend 24-bit to 32-bit ─────────────────────────── */

static int32_t sign_extend_24(uint32_t val)
{
    return (val & 0x800000) ? (int32_t)(val | 0xFF000000) : (int32_t)val;
}

/* ── Sweep ────────────────────────────────────────────────── */

static int start_sweep(void)
{
    /* Start sweep with FFT mode (fifo_hps_mode=0) */
    room_eq_base[CTRL_REG] = CTRL_SWEEP_START;
    fprintf(stderr, "Sweep started.\n");

    usleep(1000);

    uint32_t status = room_eq_base[STATUS_REG];
    fprintf(stderr, "STATUS: 0x%08x (state=%d, fft_done=%d)\n",
           status, status & STATUS_STATE_MASK,
           (status >> 4) & 1);

    return 0;
}

/* ── Mic test ─────────────────────────────────────────────── */

static void mic_test(void)
{
    load_sine_lut();
    room_eq_base[CTRL_REG] = CTRL_SWEEP_START;
    usleep(50000);

    printf("\nMic test — make noise! (Ctrl-C to stop)\n");
    uint32_t prev = 0xDEADBEEF;
    while (1) {
        uint32_t raw = room_eq_base[ADC_LEFT_REG] & 0x00FFFFFF;  // 24 bit mask
        if (raw != prev) { // Only prints changing samples.
            int32_t sample = sign_extend_24(raw);
            printf("ADC left: 0x%06x  (%d)\n", raw, sample);
            fflush(stdout);
            prev = raw;
        }
        usleep(10000);
    }
}

/* ── FIFO test (Stage 1) ──────────────────────────────────── */

static void fifo_test(void)
{
    load_sine_lut();

    /* Set fifo_hps_mode=1, then start sweep */
    room_eq_base[CTRL_REG] = CTRL_FIFO_HPS_MODE;
    usleep(1000);
    room_eq_base[CTRL_REG] = CTRL_FIFO_HPS_MODE | CTRL_SWEEP_START;
    usleep(50000);  /* let BCLK/LRCK stabilize */

    printf("\nFIFO test — reading raw ADC samples through DCFIFO (Ctrl-C to stop)\n");
    printf("sample_num,value\n");

    int count = 0;
    while (count < 2000) {
        uint32_t status = room_eq_base[STATUS_REG];
        if (!(status & STATUS_FIFO_EMPTY)) { // Read while not empty. Pops on read.
            uint32_t raw = room_eq_base[FIFO_RDATA_REG] & 0x00FFFFFF;
            int32_t sample = sign_extend_24(raw);
            printf("%d,%d\n", count, sample);
            count++;
        } else {
            usleep(100);  /* wait for FIFO to fill */
        }
    }

    fprintf(stderr, "Read %d samples from FIFO.\n", count);
}

/* ── Full calibration (Stage 2+3) ─────────────────────────── */

// We capture 46 FFT frames
#define MAX_FRAMES   64
#define BINS_PER_FRAME (FFT_SIZE / 2 + 1)  /* 4097 */

/* Store real+imag per bin, per frame. ~2 MB for 64 frames. */
static int32_t frame_real[MAX_FRAMES][BINS_PER_FRAME];
static int32_t frame_imag[MAX_FRAMES][BINS_PER_FRAME];

static void calibrate(void)
{
    load_sine_lut();

    /* FFT mode (fifo_hps_mode=0), start sweep */
    fprintf(stderr, "Starting calibration sweep (continuous FFT)...\n");
    room_eq_base[CTRL_REG] = CTRL_SWEEP_START;

    int frame_num = 0;

    /* Capture loop: read FFT frames into memory, no printing */
    while (1) {
        uint32_t status = room_eq_base[STATUS_REG];
        uint32_t fsm_state = status & STATUS_STATE_MASK;

        /* Check if FFT frame is ready */
        if ((status & STATUS_FFT_DONE) && frame_num < MAX_FRAMES) {
            /* Read all bins into buffer */
            for (int i = 0; i < BINS_PER_FRAME; i++) {
                room_eq_base[FFT_ADDR_REG] = i;
                /* No usleep — register read latency is 1 cycle at 50 MHz */
                uint32_t re = room_eq_base[FFT_RDATA_REG] & 0xFFFFFF;
                uint32_t im = room_eq_base[FFT_IDATA_REG] & 0xFFFFFF;
                frame_real[frame_num][i] = sign_extend_24(re);
                frame_imag[frame_num][i] = sign_extend_24(im);
            }
            frame_num++;

            /* Wait for fft_done to clear (next frame SOP) before polling again */
            while (room_eq_base[STATUS_REG] & STATUS_FFT_DONE)
                ;  /* busy-wait, no usleep — speed matters */
        }

        /* Check if sweep is done */
        if (fsm_state == STATE_DONE) {
            /* Capture final frame if available */
            status = room_eq_base[STATUS_REG];
            if ((status & STATUS_FFT_DONE) && frame_num < MAX_FRAMES) {
                for (int i = 0; i < BINS_PER_FRAME; i++) {
                    room_eq_base[FFT_ADDR_REG] = i;
                    uint32_t re = room_eq_base[FFT_RDATA_REG] & 0xFFFFFF;
                    uint32_t im = room_eq_base[FFT_IDATA_REG] & 0xFFFFFF;
                    frame_real[frame_num][i] = sign_extend_24(re);
                    frame_imag[frame_num][i] = sign_extend_24(im);
                }
                frame_num++;
            }
            break;
        }
    }

    fprintf(stderr, "Calibration complete. %d FFT frames captured.\n", frame_num);

    /* Now dump all buffered data */
    printf("frame,bin,real,imag\n");
    for (int f = 0; f < frame_num; f++) {
        for (int i = 0; i < BINS_PER_FRAME; i++) {
            printf("%d,%d,%d,%d\n", f, i, frame_real[f][i], frame_imag[f][i]);
        }
    }
}

/* ── Live spectrum (continuous FFT display) ───────────────── */

/* Compute log-spaced band edges at runtime.
 * NUM_BANDS bands from 20 Hz to 20 kHz. */
#define NUM_BANDS 48
static int band_edges[NUM_BANDS + 1];

static void live_spectrum(void)
{
    load_sine_lut();

    /* Build log-spaced band edges: 20 Hz to 20 kHz */
    double hz_per_bin = 48000.0 / FFT_SIZE;
    for (int i = 0; i <= NUM_BANDS; i++) {
        double freq = 20.0 * pow(20000.0 / 20.0, (double)i / NUM_BANDS);
        band_edges[i] = (int)(freq / hz_per_bin);
        if (band_edges[i] < 1) band_edges[i] = 1;
        if (band_edges[i] > FFT_SIZE / 2) band_edges[i] = FFT_SIZE / 2;
        /* Ensure monotonic */
        if (i > 0 && band_edges[i] <= band_edges[i - 1])
            band_edges[i] = band_edges[i - 1] + 1;
    }

    /* Start sweep to get BCLK/LRCK running, FFT mode */
    room_eq_base[CTRL_REG] = CTRL_SWEEP_START;
    usleep(50000);

    printf("\nLive spectrum — Ctrl-C to stop\n");

    int frame = 0;
    struct timespec t_prev, t_now;
    clock_gettime(CLOCK_MONOTONIC, &t_prev);

    while (1) {
        /* Wait for fft_done */
        while (!(room_eq_base[STATUS_REG] & STATUS_FFT_DONE))
            ;

        /* Time the HPS bin readout */
        struct timespec t_read_start, t_read_end;
        clock_gettime(CLOCK_MONOTONIC, &t_read_start);

        /* Read all bands */
        int band_bar[NUM_BANDS];
        int total_bins_read = 0;
        for (int b = 0; b < NUM_BANDS; b++) {
            int lo = band_edges[b];
            int hi = band_edges[b + 1];

            int64_t total_mag = 0;
            for (int i = lo; i < hi; i++) {
                room_eq_base[FFT_ADDR_REG] = i;
                int32_t re = sign_extend_24(room_eq_base[FFT_RDATA_REG] & 0xFFFFFF);
                int32_t im = sign_extend_24(room_eq_base[FFT_IDATA_REG] & 0xFFFFFF);
                int32_t mag = (re < 0 ? -re : re) + (im < 0 ? -im : im);
                total_mag += mag;
            }
            total_bins_read += (hi - lo);
            total_mag /= (hi - lo);

            int bar_len = 0;
            if (total_mag > 0) {
                int64_t v = total_mag;
                while (v > 0) { bar_len++; v >>= 1; }
                bar_len = bar_len * 3 - 20;
                if (bar_len < 0) bar_len = 0;
                if (bar_len > 60) bar_len = 60;
            }
            band_bar[b] = bar_len;
        }

        clock_gettime(CLOCK_MONOTONIC, &t_read_end);
        clock_gettime(CLOCK_MONOTONIC, &t_now);

        double read_us = (t_read_end.tv_sec - t_read_start.tv_sec) * 1e6 +
                         (t_read_end.tv_nsec - t_read_start.tv_nsec) / 1e3;
        double frame_ms = (t_now.tv_sec - t_prev.tv_sec) * 1e3 +
                          (t_now.tv_nsec - t_prev.tv_nsec) / 1e6;
        double fps = (frame_ms > 0) ? 1000.0 / frame_ms : 0;
        t_prev = t_now;

        /* Display */
        printf("\033[2J\033[H");
        fprintf(stderr, "Room EQ Live Spectrum\n");
        printf("FPGA: 8192-pt FFT @ 50MHz | ADC: 48kHz 24-bit | Input: %s%s\n",
               use_line_in ? "LINE-IN" : "MIC",
               (!use_line_in && mic_boost) ? " +20dB" : "");
        printf("HPS:  %d bins read in %.0f us | Frame %d | %.1f fps | %.0f ms/frame\n\n",
               total_bins_read, read_us, frame, fps, frame_ms);

        for (int b = 0; b < NUM_BANDS; b++) {
            int lo = band_edges[b];
            int hi = band_edges[b + 1];
            int center_freq = ((lo + hi) / 2) * 48000 / FFT_SIZE;
            printf("%5dHz|", center_freq);
            for (int j = 0; j < band_bar[b]; j++) putchar('#');
            putchar('\n');
        }

        frame++;

        /* Wait for fft_done to clear */
        while (room_eq_base[STATUS_REG] & STATUS_FFT_DONE)
            ;
    }
}

/* ── Main ─────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    int mode = 0;  /* 0=sweep, 1=mic, 2=fifo, 3=calibrate, 4=live */
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-') {
            if (argv[i][1] == 'L') use_line_in = 1;       /* -L = line-in */
            else if (argv[i][1] == 'B') mic_boost = 0;    /* -B = no boost */
        } else {
            switch (argv[i][0]) {
            case 'm': mode = 1; break;
            case 'f': mode = 2; break;
            case 'c': mode = 3; break;
            case 'l': mode = 4; break;
            }
        }
    }

    const char *mode_names[] = {"Sweep", "Mic Test", "FIFO Test", "Calibration", "Live Spectrum"};
    fprintf(stderr, "Room EQ — Codec Init + %s\n", mode_names[mode]);

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    void *base = mmap(NULL, LW_BRIDGE_SPAN, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, LW_BRIDGE_BASE);
    if (base == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    i2c_base    = (volatile uint32_t *)((uint8_t *)base + I2C_BASE_OFFSET);
    room_eq_base = (volatile uint32_t *)((uint8_t *)base + ROOM_EQ_OFFSET);

    if (codec_init() < 0)
        fprintf(stderr, "Warning: codec init had errors\n");

    switch (mode) {
    case 0:
        load_sine_lut();
        start_sweep();
        break;
    case 1:
        mic_test();
        break;
    case 2:
        fifo_test();
        break;
    case 3:
        calibrate();
        break;
    case 4:
        live_spectrum();
        break;
    }

    munmap(base, LW_BRIDGE_SPAN);
    close(fd);
    return 0;
}
