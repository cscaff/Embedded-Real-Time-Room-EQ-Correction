/*
 * test_fir_e2e.c — end-to-end integration test for the chunked calibration path
 *
 * Simulates the full calibration pipeline as it would run on hardware:
 *   1. Synthesise a realistic room magnitude response (4097 bins)
 *   2. Simulate chunked capture: for each of 29 chunks, compute which bins
 *      are active based on the sweep frequency, and populate only those
 *   3. Fill unfilled bins with 1.0 (unity — no correction)
 *   4. Run fir_design_from_spectrum() to produce 128 Q1.23 taps
 *
 * Writes two text files for Python plotting:
 *   fir_e2e_room.txt  — N_HALF magnitude values (one per line)
 *   fir_e2e_taps.txt  — N_TAPS Q1.23 tap values (one per line)
 *
 * Compile (from project root):
 *   gcc -Wall -lm -Isrc/software -o test_out/test_fir_e2e \
 *       test/software/FIR/test_fir_e2e.c \
 *       src/software/room_eq/FIR/fir_design.c
 *
 * Run:   ./test_out/test_fir_e2e
 * Plot:  python3 test/software/plot_eq.py
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

#include "eq.h"                      /* N_FFT, N_HALF, FS, sweep constants */
#include "room_eq/FIR/fir_design.h"  /* N_TAPS, fir_design_from_spectrum() */

/* ── Synthetic room response model ──────────────────────────────────────────
 *
 * Returns the room's gain at frequency f (Hz) in decibels.
 * The model captures several characteristics of a typical small room:
 *
 *   1. Low-frequency rolloff  — rooms have limited bass extension below ~50 Hz
 *   2. Bass mode at 80 Hz     — +8 dB resonance, 1-octave wide (room mode)
 *   3. Upper-bass buildup     — +4 dB around 250 Hz (reverberant field)
 *   4. Midrange null at 1.2 kHz — −7 dB (reflection comb null)
 *   5. HF absorption          — −4 dB/octave above 8 kHz
 *
 * Each resonance/dip uses a Gaussian in log-frequency:
 *   G(f) = A * exp(−0.5 * (log2(f/f0) / (bw/2))^2)
 * This matches the shape of acoustic resonances on a log-frequency axis.
 */
static double synthetic_room_db(double f)
{
    if (f < 1.0) return 0.0;

    double db = 0.0;
    double x;

    /* 1. Low-frequency rolloff: −12 dB/octave below 50 Hz */
    if (f < 50.0)
        db -= 12.0 * log2(50.0 / f);

    /* 2. Room mode at 80 Hz: +8 dB, 1-octave width */
    x = log2(f / 80.0) / 0.5;
    db += 8.0 * exp(-0.5 * x * x);

    /* 3. Upper-bass buildup at 250 Hz: +4 dB, 1.5-octave width */
    x = log2(f / 250.0) / 0.75;
    db += 4.0 * exp(-0.5 * x * x);

    /* 4. Midrange null at 1.2 kHz: −7 dB, 0.4-octave width */
    x = log2(f / 1200.0) / 0.2;
    db -= 7.0 * exp(-0.5 * x * x);

    /* 5. HF rolloff: −4 dB/octave above 8 kHz */
    if (f > 8000.0)
        db -= 4.0 * log2(f / 8000.0);

    return db;
}

/* ── Sweep frequency helpers (same as eq.c) ─────────────────────────────── */

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
    if (*k_lo < 1)        *k_lo = 1;
    if (*k_hi >= N_HALF)  *k_hi = N_HALF - 1;
}

/* ── main ───────────────────────────────────────────────────────────────── */

int main(void)
{
    printf("=== fir_design_from_spectrum end-to-end test ===\n\n");

    /* 1. Generate the full "true" room response (for reference / plotting) */
    double *H_room = malloc(N_HALF * sizeof(double));
    if (!H_room) { perror("malloc"); return 1; }

    for (int k = 0; k < N_HALF; k++) {
        double f = (double)k * (double)FS / N_FFT;
        H_room[k] = pow(10.0, synthetic_room_db(f) / 20.0);
    }

    /* 2. Simulate chunked capture: only fill bins that would be read
     *    from each chunk's FFT during a real sweep.  This mirrors
     *    exactly what eq.c does on hardware. */
    double *spectrum = calloc(N_HALF, sizeof(double));
    int    *filled   = calloc(N_HALF, sizeof(int));
    if (!spectrum || !filled) { perror("calloc"); return 1; }

    int total_bins_read = 0;
    printf("Simulating %d-chunk sweep capture:\n", N_CHUNKS);

    for (int c = 0; c < N_CHUNKS; c++) {
        int k_lo, k_hi;
        chunk_bin_range(c, &k_lo, &k_hi);

        for (int k = k_lo; k <= k_hi; k++) {
            /* In hardware, this magnitude comes from the FFT of the mic
             * recording during this chunk.  We approximate it as the true
             * room magnitude at this frequency (no noise, no spectral
             * leakage — ideal case). */
            spectrum[k] = H_room[k];
            filled[k] = 1;
        }

        int n = k_hi - k_lo + 1;
        total_bins_read += n;

        if (c < 5 || c >= N_CHUNKS - 3 || c == N_CHUNKS / 2)
            printf("  chunk %2d  bins %4d-%4d  (%4d bins)  %.0f-%.0f Hz\n",
                   c, k_lo, k_hi, n,
                   k_lo * BIN_WIDTH, k_hi * BIN_WIDTH);
        else if (c == 5)
            printf("  ...\n");
    }

    /* 3. Fill unfilled bins with 1.0 (same as eq.c) */
    int n_filled = 0;
    for (int k = 0; k < N_HALF; k++) {
        if (filled[k]) n_filled++;
        else spectrum[k] = 1.0;
    }

    printf("\nBins filled: %d / %d (%.1f%%)\n",
           n_filled, N_HALF, 100.0 * n_filled / N_HALF);
    printf("Total bin reads across all chunks: %d (includes overlaps)\n\n",
           total_bins_read);

    /* 4. Run the FIR design pipeline (same as eq.c) */
    int32_t taps[N_TAPS];
    int ret = fir_design_from_spectrum(spectrum, N_HALF, taps);
    printf("fir_design_from_spectrum returned: %d  (%s)\n",
           ret, ret == 0 ? "OK" : "FAILED");

    /* 5. Sanity checks */
    int32_t peak_tap = 0;
    int nonzero = 0;
    for (int i = 0; i < N_TAPS; i++) {
        int32_t av = taps[i] < 0 ? -taps[i] : taps[i];
        if (av > peak_tap) peak_tap = av;
        if (taps[i] != 0) nonzero++;
    }
    printf("Peak tap magnitude : %d  (expect %d)\n", peak_tap, (1 << 23) - 1);
    printf("Non-zero taps      : %d / %d\n", nonzero, N_TAPS);

    int ok = (ret == 0) &&
             (peak_tap == (1 << 23) - 1) &&
             (nonzero > N_TAPS / 2);
    printf("\n%s\n\n", ok ? "PASS" : "FAIL");

    /* 6. Write room response for Python (use the chunked spectrum, not H_room,
     *    so the plot shows exactly what the FIR design pipeline saw) */
    FILE *f_room = fopen("fir_e2e_room.txt", "w");
    if (!f_room) { perror("fopen fir_e2e_room.txt"); return 1; }
    for (int k = 0; k < N_HALF; k++)
        fprintf(f_room, "%.10f\n", spectrum[k]);
    fclose(f_room);
    printf("Written fir_e2e_room.txt  (%d bins)\n", N_HALF);

    /* 7. Write taps for Python */
    FILE *f_taps = fopen("fir_e2e_taps.txt", "w");
    if (!f_taps) { perror("fopen fir_e2e_taps.txt"); return 1; }
    for (int i = 0; i < N_TAPS; i++)
        fprintf(f_taps, "%d\n", (int)taps[i]);
    fclose(f_taps);
    printf("Written fir_e2e_taps.txt  (%d taps)\n\n", N_TAPS);

    printf("Run:  python3 test/software/plot_eq.py\n");

    free(H_room); free(spectrum); free(filled);
    return ok ? 0 : 1;
}
