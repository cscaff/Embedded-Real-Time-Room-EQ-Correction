/*
 * room_analyze.c — Room EQ analysis and correction filter computation
 *
 * Runs on the DE1-SoC HPS. Performs a calibration sweep, captures FFT
 * frames from the FPGA, extracts the room response H(f), computes a
 * correction FIR filter, and prints a room analysis report with a
 * terminal frequency response graph.
 *
 * Usage:
 *   ./room_analyze [options]
 *     -L          Use line-in instead of mic
 *     -B          No mic boost
 *     -f FILE     Read sweep data from CSV file instead of running sweep
 *     -o FILE     Write correction taps to file (default: correction_taps.csv)
 *     -e FREQ     Analysis end frequency in Hz (default: 20000)
 *     -s STRENGTH Correction strength 0.0-1.0 (default: 0.5)
 *     -d DB       Max correction dB (default: 12)
 *     -t TAPS     Number of FIR taps (default: 511)
 *     -w FILE     Write captured sweep data to CSV (default: none)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>
#include <math.h>

#include <fftw3.h>

/* ── Memory map (same as codec_init.c) ───────────────────── */

#define LW_BRIDGE_BASE   0xFF200000
#define LW_BRIDGE_SPAN   0x00200000
#define I2C_BASE_OFFSET  0x0000
#define ROOM_EQ_OFFSET   0x2000

#define I2C_TFR_CMD      0x00
#define I2C_CTRL         0x08
#define I2C_ISR          0x10
#define I2C_STATUS       0x14
#define I2C_SCL_LOW      0x20
#define I2C_SCL_HIGH     0x24
#define I2C_SDA_HOLD     0x28

#define TFR_CMD_STA      (1 << 9)
#define TFR_CMD_STO      (1 << 8)
#define STATUS_CORE_STATUS  (1 << 0)

#define WM8731_ADDR      0x1A

#define CTRL_REG        0
#define STATUS_REG      1
#define LUT_ADDR_REG    4
#define LUT_DATA_REG    5
#define FFT_ADDR_REG    6
#define FFT_RDATA_REG   7
#define FFT_IDATA_REG   8

#define CTRL_SWEEP_START   (1 << 0)
#define STATUS_STATE_MASK  0xF
#define STATUS_FFT_DONE    (1 << 4)
#define STATE_DONE         2

#define FFT_SIZE       8192
#define LUT_SIZE       1024
#define MAX_FRAMES     64
#define BINS_PER_FRAME (FFT_SIZE / 2 + 1)

static volatile uint32_t *i2c_base;
static volatile uint32_t *room_eq_base;
static int use_line_in = 0;
static int mic_boost = 1;

/* ── I2C / codec helpers (same as codec_init.c) ──────────── */

static inline void i2c_write_reg(int reg, uint32_t val)
{ *(volatile uint32_t *)((uint8_t *)i2c_base + reg) = val; }

static inline uint32_t i2c_read_reg(int reg)
{ return *(volatile uint32_t *)((uint8_t *)i2c_base + reg); }

static void i2c_wait_idle(void)
{
    int timeout = 100000;
    while ((i2c_read_reg(I2C_STATUS) & STATUS_CORE_STATUS) && --timeout > 0)
        usleep(1);
}

static void i2c_init(void)
{
    i2c_write_reg(I2C_CTRL, 0);
    i2c_write_reg(I2C_SCL_LOW, 250);
    i2c_write_reg(I2C_SCL_HIGH, 250);
    i2c_write_reg(I2C_SDA_HOLD, 30);
    i2c_write_reg(I2C_CTRL, 1);
    usleep(1000);
}

static int wm8731_write(uint8_t reg, uint16_t data)
{
    uint8_t b1 = (reg << 1) | ((data >> 8) & 1);
    uint8_t b2 = data & 0xFF;
    i2c_wait_idle();
    i2c_write_reg(I2C_TFR_CMD, TFR_CMD_STA | (WM8731_ADDR << 1));
    i2c_write_reg(I2C_TFR_CMD, b1);
    i2c_write_reg(I2C_TFR_CMD, TFR_CMD_STO | b2);
    i2c_wait_idle();
    uint32_t isr = i2c_read_reg(I2C_ISR);
    if (isr & (1 << 2)) { i2c_write_reg(I2C_ISR, isr); return -1; }
    return 0;
}

static void hw_codec_init(void)
{
    i2c_init();
    wm8731_write(0x0F, 0x000); usleep(10000);
    wm8731_write(0x00, 0x017);
    wm8731_write(0x01, 0x017);
    wm8731_write(0x02, 0x079);
    wm8731_write(0x03, 0x079);
    uint16_t reg04 = 0x010;
    if (!use_line_in) reg04 |= 0x004;
    if (!use_line_in && mic_boost) reg04 |= 0x001;
    wm8731_write(0x04, reg04);
    wm8731_write(0x05, 0x000);
    wm8731_write(0x06, 0x000);
    wm8731_write(0x07, 0x00A);
    wm8731_write(0x08, 0x000);
    wm8731_write(0x09, 0x001);
    fprintf(stderr, "Codec init: %s%s\n",
            use_line_in ? "LINE-IN" : "MIC",
            (!use_line_in && mic_boost) ? " +20dB" : "");
}

static void load_sine_lut(void)
{
    for (int i = 0; i < LUT_SIZE; i++) {
        double angle = i * M_PI / (2.0 * LUT_SIZE);
        int32_t val = (int32_t)(sin(angle) * 8388607.0);
        room_eq_base[LUT_ADDR_REG] = i;
        room_eq_base[LUT_DATA_REG] = (uint32_t)(val & 0x00FFFFFF);
    }
}

static int32_t sign_extend_24(uint32_t val)
{
    return (val & 0x800000) ? (int32_t)(val | 0xFF000000) : (int32_t)val;
}

/* ── Sweep capture ───────────────────────────────────────── */

static int32_t frame_real[MAX_FRAMES][BINS_PER_FRAME];
static int32_t frame_imag[MAX_FRAMES][BINS_PER_FRAME];

static int capture_sweep(void)
{
    load_sine_lut();
    fprintf(stderr, "Running sweep...\n");
    room_eq_base[CTRL_REG] = CTRL_SWEEP_START;

    int n = 0;
    while (1) {
        uint32_t status = room_eq_base[STATUS_REG];
        if ((status & STATUS_FFT_DONE) && n < MAX_FRAMES) {
            for (int i = 0; i < BINS_PER_FRAME; i++) {
                room_eq_base[FFT_ADDR_REG] = i;
                frame_real[n][i] = sign_extend_24(room_eq_base[FFT_RDATA_REG] & 0xFFFFFF);
                frame_imag[n][i] = sign_extend_24(room_eq_base[FFT_IDATA_REG] & 0xFFFFFF);
            }
            n++;
            while (room_eq_base[STATUS_REG] & STATUS_FFT_DONE) ;
        }
        if ((status & STATUS_STATE_MASK) == STATE_DONE) {
            status = room_eq_base[STATUS_REG];
            if ((status & STATUS_FFT_DONE) && n < MAX_FRAMES) {
                for (int i = 0; i < BINS_PER_FRAME; i++) {
                    room_eq_base[FFT_ADDR_REG] = i;
                    frame_real[n][i] = sign_extend_24(room_eq_base[FFT_RDATA_REG] & 0xFFFFFF);
                    frame_imag[n][i] = sign_extend_24(room_eq_base[FFT_IDATA_REG] & 0xFFFFFF);
                }
                n++;
            }
            break;
        }
    }
    fprintf(stderr, "Captured %d FFT frames.\n", n);
    return n;
}

static void save_sweep_csv(const char *fname, int n_frames)
{
    FILE *f = fopen(fname, "w");
    if (!f) { perror(fname); return; }
    fprintf(f, "frame,bin,real,imag\n");
    for (int fr = 0; fr < n_frames; fr++)
        for (int b = 0; b < BINS_PER_FRAME; b++)
            fprintf(f, "%d,%d,%d,%d\n", fr, b, frame_real[fr][b], frame_imag[fr][b]);
    fclose(f);
    fprintf(stderr, "Sweep data saved to %s\n", fname);
}

static int load_sweep_csv(const char *fname)
{
    FILE *f = fopen(fname, "r");
    if (!f) { perror(fname); return 0; }

    char line[256];
    /* Skip to CSV header */
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "frame,bin,real,imag", 19) == 0) break;
    }

    int max_frame = -1;
    int fr, bn, re, im;
    while (fscanf(f, "%d,%d,%d,%d", &fr, &bn, &re, &im) == 4) {
        if (fr < MAX_FRAMES && bn < BINS_PER_FRAME) {
            frame_real[fr][bn] = re;
            frame_imag[fr][bn] = im;
            if (fr > max_frame) max_frame = fr;
        }
    }
    fclose(f);
    int n = max_frame + 1;
    fprintf(stderr, "Loaded %d frames from %s\n", n, fname);
    return n;
}

/* ── Room analysis + correction ──────────────────────────── */

static double H_mag[BINS_PER_FRAME];  /* room response magnitude */
static double H_smooth[BINS_PER_FRAME];
static double correction[BINS_PER_FRAME];

/* 1/3-octave smoothing — matches compute_correction.py third_octave_smooth().
 * Each bin is averaged with neighbors spanning 1/3 octave around it:
 * window from freq / 2^(1/6) to freq * 2^(1/6). */
static void third_octave_smooth(double *out, const double *in, int len,
                                 double hz_per_bin)
{
    static const double SIXTH_ROOT_2 = 1.12246204831; /* 2^(1/6) */
    for (int i = 0; i < len; i++) {
        double freq = i * hz_per_bin;
        if (freq < 20) { out[i] = in[i]; continue; }
        int lo = (int)(freq / SIXTH_ROOT_2 / hz_per_bin);
        int hi = (int)(freq * SIXTH_ROOT_2 / hz_per_bin) + 1;
        if (lo < 1) lo = 1;
        if (hi > len) hi = len;
        double sum = 0;
        for (int j = lo; j < hi; j++) sum += in[j];
        out[i] = sum / (hi - lo);
    }
}

static void compute_room_response(int n_frames)
{
    double hz_per_bin = 48000.0 / FFT_SIZE;

    /* Peak magnitude per bin across all frames */
    for (int b = 0; b < BINS_PER_FRAME; b++) {
        double best = 0;
        for (int f = 0; f < n_frames; f++) {
            double re = frame_real[f][b];
            double im = frame_imag[f][b];
            double m = sqrt(re*re + im*im);
            if (m > best) best = m;
        }
        H_mag[b] = best;
    }

    /* Compensate for log sweep energy (1/f) */
    for (int b = 1; b < BINS_PER_FRAME; b++) {
        double freq_hz = b * hz_per_bin;
        H_mag[b] *= (freq_hz / 1000.0);
    }

    /* Smooth */
    third_octave_smooth(H_smooth, H_mag, BINS_PER_FRAME, hz_per_bin);
}

static void compute_correction(int lo_hz, int hi_hz, double max_db,
                                double strength)
{
    double hz_per_bin = 48000.0 / FFT_SIZE;
    int lo_bin = (int)(lo_hz / hz_per_bin);
    int hi_bin = (int)(hi_hz / hz_per_bin);
    if (hi_bin > BINS_PER_FRAME) hi_bin = BINS_PER_FRAME;

    /* Mean level over fixed 100-3000 Hz reference band (matches Python) */
    int mean_lo_bin = (int)(100.0 / hz_per_bin);
    int mean_hi_bin = (int)(3000.0 / hz_per_bin);
    double sum = 0;
    int count = 0;
    for (int b = mean_lo_bin; b < mean_hi_bin; b++) {
        if (H_smooth[b] > 0) { sum += H_smooth[b]; count++; }
    }
    double H_mean = sum / count;
    fprintf(stderr, "Target level: %.1f dB (mean of 100-3000 Hz)\n",
            20 * log10(H_mean + 1));

    /* Compute correction per bin */
    double max_boost = pow(10, max_db / 20.0);
    double max_cut = pow(10, -max_db / 20.0);

    for (int b = 0; b < BINS_PER_FRAME; b++)
        correction[b] = 1.0;

    for (int b = lo_bin; b < hi_bin; b++) {
        double H_norm = H_smooth[b] / H_mean;
        if (H_norm > 0.001) {
            double c = 1.0 / H_norm;
            if (c > max_boost) c = max_boost;
            if (c < max_cut) c = max_cut;
            c = 1.0 + strength * (c - 1.0);
            correction[b] = c;
        }
    }
}

static double *compute_fir_taps(int n_taps)
{
    /* Build half-complex spectrum for FFTW r2c/c2r convention:
     * bins 0..N/2 (BINS_PER_FRAME = N/2+1) */
    fftw_complex *freq_buf = fftw_alloc_complex(BINS_PER_FRAME);
    double *time_buf = fftw_alloc_real(FFT_SIZE);

    for (int b = 0; b < BINS_PER_FRAME; b++) {
        freq_buf[b][0] = correction[b];  /* real */
        freq_buf[b][1] = 0;              /* imag */
    }

    /* Inverse FFT (complex half-spectrum → real time domain) */
    fftw_plan plan = fftw_plan_dft_c2r_1d(FFT_SIZE, freq_buf, time_buf,
                                           FFTW_ESTIMATE);
    fftw_execute(plan);
    fftw_destroy_plan(plan);

    /* Extract center of impulse response and window */
    double *taps = calloc(n_taps, sizeof(double));
    int half = n_taps / 2;

    for (int i = 0; i < half; i++)
        taps[i] = time_buf[FFT_SIZE - half + i] / FFT_SIZE;
    for (int i = 0; i <= half; i++)
        taps[half + i] = time_buf[i] / FFT_SIZE;

    /* Hanning window */
    for (int i = 0; i < n_taps; i++)
        taps[i] *= 0.5 * (1.0 - cos(2.0 * M_PI * i / (n_taps - 1)));

    /* Normalize DC gain = 1 */
    double sum = 0;
    for (int i = 0; i < n_taps; i++) sum += taps[i];
    if (fabs(sum) > 1e-10)
        for (int i = 0; i < n_taps; i++) taps[i] /= sum;

    fftw_free(freq_buf);
    fftw_free(time_buf);
    return taps;
}

/* ── Terminal graph ──────────────────────────────────────── */

static void print_bar(int len, int max_width)
{
    if (len < 0) len = 0;
    if (len > max_width) len = max_width;
    for (int i = 0; i < len; i++) putchar('#');
}

static void print_response_graph(int lo_hz, int hi_hz)
{
    double hz_per_bin = 48000.0 / FFT_SIZE;
    int lo_bin = (int)(lo_hz / hz_per_bin);
    int hi_bin = (int)(hi_hz / hz_per_bin);

    /* Find min/max for scaling */
    double db_min = 999, db_max = -999;
    for (int b = lo_bin; b < hi_bin; b++) {
        if (H_smooth[b] > 0) {
            double db = 20 * log10(H_smooth[b] + 1);
            if (db < db_min) db_min = db;
            if (db > db_max) db_max = db;
        }
    }
    double db_range = db_max - db_min;
    if (db_range < 1) db_range = 1;

    /* Log-spaced bands for display */
    int n_rows = 32;
    printf("\n  Frequency Response (%d-%d Hz)\n", lo_hz, hi_hz);
    printf("  %6.0f dB %*s %6.0f dB\n", db_min, 48, "", db_max);
    printf("  |");
    for (int i = 0; i < 50; i++) putchar('-');
    printf("|\n");

    for (int r = 0; r < n_rows; r++) {
        double f_lo = lo_hz * pow((double)hi_hz / lo_hz, (double)r / n_rows);
        double f_hi = lo_hz * pow((double)hi_hz / lo_hz, (double)(r+1) / n_rows);
        int b_lo = (int)(f_lo / hz_per_bin);
        int b_hi = (int)(f_hi / hz_per_bin);
        if (b_hi <= b_lo) b_hi = b_lo + 1;

        /* Average magnitude in this band */
        double avg = 0;
        int cnt = 0;
        for (int b = b_lo; b < b_hi && b < BINS_PER_FRAME; b++) {
            if (H_smooth[b] > 0) { avg += 20*log10(H_smooth[b]+1); cnt++; }
        }
        if (cnt > 0) avg /= cnt;

        int bar = (int)((avg - db_min) / db_range * 50);
        printf("  %5.0fHz|", (f_lo + f_hi) / 2);
        print_bar(bar, 50);
        printf(" %.0f\n", avg);
    }
}

/* ── Room analysis report ────────────────────────────────── */

static void print_analysis(int lo_hz, int hi_hz)
{
    double hz_per_bin = 48000.0 / FFT_SIZE;
    int lo_bin = (int)(lo_hz / hz_per_bin);
    int hi_bin = (int)(hi_hz / hz_per_bin);

    /* Mean level */
    int mean_lo = (int)(100 / hz_per_bin);
    int mean_hi = (int)(3000 / hz_per_bin);
    double sum = 0; int cnt = 0;
    for (int b = mean_lo; b < mean_hi; b++) {
        if (H_smooth[b] > 0) { sum += 20*log10(H_smooth[b]+1); cnt++; }
    }
    double mean_db = cnt > 0 ? sum / cnt : 0;

    printf("\n============================================================\n");
    printf("ROOM ANALYSIS REPORT\n");
    printf("============================================================\n");
    printf("\nAverage level (100-3000 Hz): %.1f dB\n", mean_db);

    /* Find peaks and dips */
    double threshold = 3.0;
    int in_peak = 0, in_dip = 0;
    int peak_start = 0, dip_start = 0;
    int n_peaks = 0, n_dips = 0;

    printf("\nRoom resonances (peaks > +%.0f dB above mean):\n", threshold);
    for (int b = lo_bin; b <= hi_bin; b++) {
        double db = (H_smooth[b] > 0) ? 20*log10(H_smooth[b]+1) : 0;
        double dev = db - mean_db;
        if (dev > threshold && !in_peak) { peak_start = b; in_peak = 1; }
        if ((dev <= threshold || b == hi_bin) && in_peak) {
            /* Find max in region */
            double best_dev = 0; int best_b = peak_start;
            for (int j = peak_start; j < b; j++) {
                double d = 20*log10(H_smooth[j]+1) - mean_db;
                if (d > best_dev) { best_dev = d; best_b = j; }
            }
            double freq = best_b * hz_per_bin;
            printf("  %5.0f Hz: +%.1f dB", freq, best_dev);
            if (freq < 80) printf(" — sub-bass room mode\n");
            else if (freq < 200) printf(" — bass room mode (room dimensions)\n");
            else if (freq < 500) printf(" — low-mid buildup (boxy)\n");
            else if (freq < 2000) printf(" — midrange resonance\n");
            else printf(" — upper-mid presence peak\n");
            in_peak = 0; n_peaks++;
        }
        if (dev < -threshold && !in_dip) { dip_start = b; in_dip = 1; }
        if ((dev >= -threshold || b == hi_bin) && in_dip) {
            double worst_dev = 0; int worst_b = dip_start;
            for (int j = dip_start; j < b; j++) {
                double d = 20*log10(H_smooth[j]+1) - mean_db;
                if (d < worst_dev) { worst_dev = d; worst_b = j; }
            }
            double freq = worst_b * hz_per_bin;
            printf("  %5.0f Hz: %.1f dB", freq, worst_dev);
            if (freq < 200) printf(" — bass null (placement)\n");
            else if (freq < 500) printf(" — low-mid cancellation\n");
            else printf(" — midrange null (reflections)\n");
            in_dip = 0; n_dips++;
        }
    }
    if (n_peaks == 0) printf("  None detected.\n");

    if (n_dips == 0) printf("\nNull points: None detected.\n");

    /* Overall assessment */
    double var_sum = 0; cnt = 0;
    for (int b = lo_bin; b < hi_bin; b++) {
        if (H_smooth[b] > 0) {
            double d = 20*log10(H_smooth[b]+1) - mean_db;
            var_sum += d*d; cnt++;
        }
    }
    double stddev = cnt > 0 ? sqrt(var_sum / cnt) : 0;
    printf("\nVariation (%d-%d Hz): %.1f dB std dev\n", lo_hz, hi_hz, stddev);
    if (stddev < 3)
        printf("Assessment: Well-treated room — minimal correction needed.\n");
    else if (stddev < 6)
        printf("Assessment: Moderate room coloration — correction recommended.\n");
    else
        printf("Assessment: Significant room modes — correction will help.\n");
    printf("============================================================\n");
}

/* ── Main ────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    const char *input_file = NULL;
    const char *output_file = "correction_taps.csv";
    const char *sweep_out_file = NULL;
    int end_hz = 20000;
    double strength = 0.65;
    double max_db = 12;
    int n_taps = 511;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-L") == 0) use_line_in = 1;
        else if (strcmp(argv[i], "-B") == 0) mic_boost = 0;
        else if (strcmp(argv[i], "-f") == 0 && i+1 < argc) input_file = argv[++i];
        else if (strcmp(argv[i], "-o") == 0 && i+1 < argc) output_file = argv[++i];
        else if (strcmp(argv[i], "-e") == 0 && i+1 < argc) end_hz = atoi(argv[++i]);
        else if (strcmp(argv[i], "-s") == 0 && i+1 < argc) strength = atof(argv[++i]);
        else if (strcmp(argv[i], "-d") == 0 && i+1 < argc) max_db = atof(argv[++i]);
        else if (strcmp(argv[i], "-t") == 0 && i+1 < argc) n_taps = atoi(argv[++i]);
        else if (strcmp(argv[i], "-w") == 0 && i+1 < argc) sweep_out_file = argv[++i];
    }
    /* Ensure odd number of taps */
    if (n_taps % 2 == 0) n_taps++;

    fprintf(stderr, "Room EQ Analyzer\n");
    fprintf(stderr, "  Range: 60-%d Hz, Strength: %.0f%%, Max: +/-%.0f dB, Taps: %d\n",
            end_hz, strength * 100, max_db, n_taps);

    int n_frames;

    if (input_file) {
        /* Load from CSV file */
        n_frames = load_sweep_csv(input_file);
    } else {
        /* Run sweep on hardware */
        int fd = open("/dev/mem", O_RDWR | O_SYNC);
        if (fd < 0) { perror("open /dev/mem"); return 1; }
        void *base = mmap(NULL, LW_BRIDGE_SPAN, PROT_READ | PROT_WRITE,
                          MAP_SHARED, fd, LW_BRIDGE_BASE);
        if (base == MAP_FAILED) { perror("mmap"); close(fd); return 1; }
        i2c_base = (volatile uint32_t *)((uint8_t *)base + I2C_BASE_OFFSET);
        room_eq_base = (volatile uint32_t *)((uint8_t *)base + ROOM_EQ_OFFSET);
        hw_codec_init();
        n_frames = capture_sweep();
        if (sweep_out_file)
            save_sweep_csv(sweep_out_file, n_frames);
        munmap(base, LW_BRIDGE_SPAN);
        close(fd);
    }

    if (n_frames == 0) {
        fprintf(stderr, "No data captured.\n");
        return 1;
    }

    /* Compute room response */
    compute_room_response(n_frames);

    /* Print graph and analysis */
    print_response_graph(60, end_hz);
    print_analysis(60, end_hz);

    /* Compute correction */
    compute_correction(60, end_hz, max_db, strength);

    /* Compute FIR taps via IFFT */
    double *taps = compute_fir_taps(n_taps);

    /* Save taps */
    FILE *fout = fopen(output_file, "w");
    if (fout) {
        for (int i = 0; i < n_taps; i++)
            fprintf(fout, "%.10f\n", taps[i]);
        fclose(fout);
        fprintf(stderr, "Saved %d FIR taps to %s\n", n_taps, output_file);
    }

    free(taps);
    return 0;
}
