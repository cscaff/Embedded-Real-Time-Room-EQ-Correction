/*
 * test_fir_e2e.c — end-to-end integration test for fir_design()
 *
 * Synthesises a realistic room response (Q1.23 FFT bins), runs the full
 * fir_design() pipeline, and writes two text files for Python plotting:
 *
 *   fir_e2e_room.txt  — N_HALF linear magnitude values (one per line)
 *   fir_e2e_taps.txt  — N_TAPS Q1.23 tap values     (one per line)
 *
 * Compile (from project root):
 *   clang -Wall -lm -Isrc/software -o test_fir_e2e \
 *       test/software/test_fir_e2e.c \
 *       src/software/room_eq/FIR/fir_design.c
 *
 * Run:   ./test_fir_e2e
 * Plot:  python3 test/software/plot_eq.py
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

#include "eq.h"                      /* N_FFT, N_HALF */
#include "room_eq/FIR/fir_design.h"  /* N_TAPS, fir_design() */

#define FS  48000.0   /* sample rate assumed by the WM8731 codec */

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

/* ── main ───────────────────────────────────────────────────────────────── */

int main(void)
{
    printf("=== fir_design end-to-end test ===\n\n");

    /* 1. Synthesise room response as floating-point magnitudes */
    double *H_room = malloc(N_HALF * sizeof(double));
    if (!H_room) { perror("malloc"); return 1; }

    for (int k = 0; k < N_HALF; k++) {
        double f = (double)k * FS / N_FFT;
        H_room[k] = pow(10.0, synthetic_room_db(f) / 20.0);
    }

    /* 2. Scale to Q1.23 (pure real — imaginary part zero, zero-phase model) */
    double hmax = 0.0;
    for (int k = 0; k < N_HALF; k++)
        if (H_room[k] > hmax) hmax = H_room[k];

    int32_t *fft_real = malloc(N_HALF * sizeof(int32_t));
    int32_t *fft_imag = calloc(N_HALF, sizeof(int32_t));   /* imag = 0 */
    if (!fft_real || !fft_imag) { perror("malloc"); return 1; }

    /* Use 90 % of full scale to stay clear of the Q1.23 boundary */
    double scale = 0.9 * ((1 << 23) - 1) / hmax;
    for (int k = 0; k < N_HALF; k++)
        fft_real[k] = (int32_t)round(H_room[k] * scale);

    /* 3. Run the full FIR design pipeline */
    int32_t taps[N_TAPS];
    int ret = fir_design(fft_real, fft_imag, N_HALF, taps);
    printf("fir_design returned: %d  (%s)\n", ret, ret == 0 ? "OK" : "FAILED");

    /* 4. Basic sanity checks */
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

    /* 5. Write room response for Python */
    FILE *f_room = fopen("fir_e2e_room.txt", "w");
    if (!f_room) { perror("fopen fir_e2e_room.txt"); return 1; }
    for (int k = 0; k < N_HALF; k++)
        fprintf(f_room, "%.10f\n", H_room[k]);
    fclose(f_room);
    printf("Written fir_e2e_room.txt  (%d bins)\n", N_HALF);

    /* 6. Write taps for Python */
    FILE *f_taps = fopen("fir_e2e_taps.txt", "w");
    if (!f_taps) { perror("fopen fir_e2e_taps.txt"); return 1; }
    for (int i = 0; i < N_TAPS; i++)
        fprintf(f_taps, "%d\n", (int)taps[i]);
    fclose(f_taps);
    printf("Written fir_e2e_taps.txt  (%d taps)\n\n", N_TAPS);

    printf("Run:  python3 test/software/plot_eq.py\n");

    free(H_room); free(fft_real); free(fft_imag);
    return ok ? 0 : 1;
}
