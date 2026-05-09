/*
 * test_fir.c — unit tests for fir_design.c sub-functions
 *
 * Compile:  clang -Wall -lm -Isrc/software -o test_fir \
 *               test/software/test_fir.c \
 *               src/software/room_eq/FIR/fir_design.c
 * Run:      ./test_fir
 */

#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>

#include "room_eq/FIR/fir_internal.h"

/* ── test harness ───────────────────────────────────────────── */

static int tests_run    = 0;
static int tests_passed = 0;

#define CHECK(cond, name) do {                                      \
    tests_run++;                                                    \
    if (cond) { tests_passed++; printf("  PASS  %s\n", name); }   \
    else       { printf("  FAIL  %s  (line %d)\n", name, __LINE__); } \
} while (0)

#define CHECK_NEAR(a, b, tol, name) \
    CHECK(fabs((a) - (b)) < (tol), name)

/* ── compute_magnitudes tests ───────────────────────────────── */

static void test_mag_zero(void)
{
    printf("compute_magnitudes: zero input\n");
    int32_t r[4] = {0}, im[4] = {0};
    double  out[4];
    compute_magnitudes(r, im, 4, out);
    CHECK(out[0] == 0.0, "zero complex → zero magnitude");
}

static void test_mag_real_only(void)
{
    printf("compute_magnitudes: real-only input\n");
    /* Q1.23: (1<<22) / 2^23 = 0.5 */
    int32_t r[1]  = { 1 << 22 };
    int32_t im[1] = { 0 };
    double  out[1];
    compute_magnitudes(r, im, 1, out);
    CHECK_NEAR(out[0], 0.5, 1e-9, "real=0.5, imag=0 → mag=0.5");
}

static void test_mag_imag_only(void)
{
    printf("compute_magnitudes: imag-only input\n");
    int32_t r[1]  = { 0 };
    int32_t im[1] = { 1 << 22 };
    double  out[1];
    compute_magnitudes(r, im, 1, out);
    CHECK_NEAR(out[0], 0.5, 1e-9, "real=0, imag=0.5 → mag=0.5");
}

static void test_mag_pythagorean(void)
{
    printf("compute_magnitudes: Pythagorean triple\n");
    /*
     * Use a 3-4-5 triple scaled to Q1.23 units:
     *   real = 3 * 2^20,  imag = 4 * 2^20
     *   → r = 3/8,  i = 4/8 = 0.5
     *   → mag = 5/8 = 0.625
     */
    int32_t r[1]  = { 3 * (1 << 20) };
    int32_t im[1] = { 4 * (1 << 20) };
    double  out[1];
    compute_magnitudes(r, im, 1, out);
    CHECK_NEAR(out[0], 0.625, 1e-9, "3-4-5 triple → mag=0.625");
}

static void test_mag_negative_real(void)
{
    printf("compute_magnitudes: sign does not affect magnitude\n");
    int32_t r_pos[1]  = {  1 << 22 };
    int32_t r_neg[1]  = { -(1 << 22) };
    int32_t im[1]     = { 1 << 21 };
    double  out_pos[1], out_neg[1];
    compute_magnitudes(r_pos, im, 1, out_pos);
    compute_magnitudes(r_neg, im, 1, out_neg);
    CHECK_NEAR(out_pos[0], out_neg[0], 1e-12,
               "mag(+r, i) == mag(-r, i)");
}

static void test_mag_all_non_negative(void)
{
    printf("compute_magnitudes: output always non-negative\n");
    int32_t r[4]  = { -(1<<22),  (1<<22), -(1<<21),  0 };
    int32_t im[4] = {  (1<<21), -(1<<22),  (1<<22), -(1<<22) };
    double  out[4];
    compute_magnitudes(r, im, 4, out);
    int ok = 1;
    for (int k = 0; k < 4; k++) if (out[k] < 0.0) ok = 0;
    CHECK(ok, "all magnitudes ≥ 0");
}

/* ── octave_smooth tests ────────────────────────────────────── */

static void test_smooth_flat_spectrum(void)
{
    printf("octave_smooth: flat input stays flat\n");
    int n = 4097;
    double *in  = malloc(n * sizeof(double));
    double *out = malloc(n * sizeof(double));
    for (int k = 0; k < n; k++) in[k] = 1.0;

    octave_smooth(in, n, 1.0/3.0, out);

    int ok = 1;
    for (int k = 0; k < n; k++)
        if (fabs(out[k] - 1.0) > 1e-12) { ok = 0; break; }
    CHECK(ok, "flat 1.0 input → flat 1.0 output");

    free(in); free(out);
}

static void test_smooth_dc_passthrough(void)
{
    printf("octave_smooth: DC bin passes through unchanged\n");
    int n = 64;
    double in[64], out[64];
    for (int k = 0; k < n; k++) in[k] = 1.0;
    in[0] = 99.0;   /* distinctive DC value */

    octave_smooth(in, n, 1.0/3.0, out);
    CHECK_NEAR(out[0], 99.0, 1e-12, "DC (bin 0) unchanged");
}

static void test_smooth_window_widens(void)
{
    /*
     * For a spike at bin k, the smoothed output is nonzero over the window
     * [k*lo, k*hi].  A higher bin has a wider window.  Verify by injecting
     * a spike at k=40 vs k=200 and checking how many output bins are nonzero.
     */
    printf("octave_smooth: window widens with frequency\n");
    int n = 4097;
    double *in  = malloc(n * sizeof(double));
    double *out = malloc(n * sizeof(double));

    /* Spike at k=40 */
    memset(in, 0, n * sizeof(double));
    in[40] = 1.0;
    octave_smooth(in, n, 1.0/3.0, out);
    int width_40 = 0;
    for (int k = 1; k < n; k++) if (out[k] > 0.0) width_40++;

    /* Spike at k=200 */
    memset(in, 0, n * sizeof(double));
    in[200] = 1.0;
    octave_smooth(in, n, 1.0/3.0, out);
    int width_200 = 0;
    for (int k = 1; k < n; k++) if (out[k] > 0.0) width_200++;

    CHECK(width_200 > width_40, "spike at k=200 spreads wider than spike at k=40");

    free(in); free(out);
}

static void test_smooth_output_non_negative(void)
{
    printf("octave_smooth: non-negative input → non-negative output\n");
    int n = 4097;
    double *in  = malloc(n * sizeof(double));
    double *out = malloc(n * sizeof(double));
    for (int k = 0; k < n; k++) in[k] = (double)k * 0.001;

    octave_smooth(in, n, 1.0/3.0, out);

    int ok = 1;
    for (int k = 0; k < n; k++) if (out[k] < 0.0) { ok = 0; break; }
    CHECK(ok, "all smoothed values ≥ 0");

    free(in); free(out);
}

static void test_smooth_reduces_variance(void)
{
    /*
     * Build a noisy spectrum: alternating 0.0 and 1.0.  After smoothing
     * the variance across all bins should be lower.
     */
    printf("octave_smooth: reduces variance of noisy spectrum\n");
    int n = 4097;
    double *in  = malloc(n * sizeof(double));
    double *out = malloc(n * sizeof(double));
    for (int k = 0; k < n; k++) in[k] = (k % 2) ? 1.0 : 0.0;

    octave_smooth(in, n, 1.0/3.0, out);

    /* compute variance of input and output */
    double var_in = 0.0, var_out = 0.0, mean_in = 0.5, mean_out = 0.0;
    for (int k = 1; k < n; k++) mean_out += out[k];
    mean_out /= (n - 1);
    for (int k = 1; k < n; k++) {
        var_in  += (in[k]  - mean_in)  * (in[k]  - mean_in);
        var_out += (out[k] - mean_out) * (out[k] - mean_out);
    }
    CHECK(var_out < var_in, "variance decreases after smoothing");

    free(in); free(out);
}

static void test_smooth_less_fraction_less_smoothing(void)
{
    /*
     * Larger fraction → wider window → output deviates more from input.
     * Verify: for a noisy spectrum, summing squared deviations from the
     * input is smaller for fraction=1/12 than for fraction=1/3.
     */
    printf("octave_smooth: smaller fraction → less deviation from input\n");
    int n = 4097;
    double *in      = malloc(n * sizeof(double));
    double *out_narrow = malloc(n * sizeof(double));
    double *out_wide   = malloc(n * sizeof(double));
    /*
     * Use in[k] = k (linear ramp).  The smoothing window is asymmetric in
     * bin-index space (lo_factor < 1, hi_factor > 1, but hi > 1-lo so the
     * centroid is slightly above k), so the smoothed value overshoots k by
     * an amount proportional to the window width.  A wider fraction always
     * deviates more from the linear input.
     */
    for (int k = 0; k < n; k++) in[k] = (double)k;

    octave_smooth(in, n, 1.0/12.0, out_narrow);
    octave_smooth(in, n, 1.0/3.0,  out_wide);

    double dev_narrow = 0.0, dev_wide = 0.0;
    for (int k = 1; k < n; k++) {
        dev_narrow += fabs(out_narrow[k] - in[k]);
        dev_wide   += fabs(out_wide[k]   - in[k]);
    }
    CHECK(dev_narrow < dev_wide, "1/12-octave deviates less from input than 1/3-octave");

    free(in); free(out_narrow); free(out_wide);
}

/* ── compute_inverse tests ──────────────────────────────────── */

static void test_inv_flat_response(void)
{
    /*
     * Flat room response (all 1.0) with target 1.0:
     *   eps = 1e-3 * 1.0 = 0.001
     *   C = 1.0 / (1.0 + 0.001) = 1/1.001 ≈ 0.999001
     * All bins should be approximately 1.0 (within eps of 1).
     */
    printf("compute_inverse: flat input → near-flat output\n");
    int n = 16;
    double h[16], c[16];
    for (int k = 0; k < n; k++) h[k] = 1.0;

    compute_inverse(h, n, 1.0, c);

    double expected = 1.0 / 1.001;
    int ok = 1;
    for (int k = 0; k < n; k++)
        if (fabs(c[k] - expected) > 1e-9) { ok = 0; break; }
    CHECK(ok, "flat H_mag=1 → C_mag ≈ 1/(1+eps)");
}

static void test_inv_high_response_attenuated(void)
{
    printf("compute_inverse: high room response → correction < 1\n");
    /* h[0]=2.0 (6 dB peak in the room), target=1.0 → C < 1 */
    double h[1] = { 2.0 };
    double c[1];
    compute_inverse(h, 1, 1.0, c);
    CHECK(c[0] < 1.0, "room peak → correction attenuates");
}

static void test_inv_low_response_boosted(void)
{
    printf("compute_inverse: low room response → correction > 1\n");
    /* Room null at 0.3 (near full spectrum peak of 1.0) → correction > 1 */
    double h[2] = { 1.0, 0.3 };
    double c[2];
    compute_inverse(h, 2, 1.0, c);
    CHECK(c[1] > 1.0, "room dip → correction boosts");
}

static void test_inv_clamp_max(void)
{
    printf("compute_inverse: very low response → clamped to +12 dB\n");
    /*
     * h_max = 1.0, eps = 0.001
     * h[k] = 0.0 → C = 1.0 / 0.001 = 1000 >> 3.981 → must clamp
     */
    double h[2] = { 1.0, 0.0 };
    double c[2];
    compute_inverse(h, 2, 1.0, c);
    double c_max = pow(10.0, 12.0 / 20.0);
    CHECK_NEAR(c[1], c_max, 1e-9, "zero bin clamped to +12 dB (3.981)");
}

static void test_inv_clamp_min(void)
{
    printf("compute_inverse: very high response → clamped to -12 dB\n");
    /*
     * h_max = 1000.0, eps = 1.0
     * h[0] = 1000.0 → C = 1.0/1001 ≈ 0.001 < 0.251 → must clamp
     */
    double h[2] = { 1000.0, 0.5 };
    double c[2];
    compute_inverse(h, 2, 1.0, c);
    double c_min = pow(10.0, -12.0 / 20.0);
    CHECK_NEAR(c[0], c_min, 1e-9, "large bin clamped to -12 dB (0.251)");
}

static void test_inv_all_positive(void)
{
    printf("compute_inverse: all outputs positive\n");
    int n = 4097;
    double *h = malloc(n * sizeof(double));
    double *c = malloc(n * sizeof(double));
    for (int k = 0; k < n; k++) h[k] = (double)k * 0.0001;   /* ramp inc. zero */

    compute_inverse(h, n, 1.0, c);

    int ok = 1;
    for (int k = 0; k < n; k++) if (c[k] <= 0.0) { ok = 0; break; }
    CHECK(ok, "all C_mag > 0");

    free(h); free(c);
}

static void test_inv_all_zero_input(void)
{
    printf("compute_inverse: all-zero H_mag does not crash\n");
    double h[4] = { 0.0, 0.0, 0.0, 0.0 };
    double c[4];
    compute_inverse(h, 4, 1.0, c);   /* must not divide by zero */
    double c_max = pow(10.0, 12.0 / 20.0);
    int ok = 1;
    for (int k = 0; k < 4; k++)
        if (fabs(c[k] - c_max) > 1e-6) { ok = 0; break; }
    CHECK(ok, "all-zero input → all clamped to +12 dB");
}

/* ── hermitian_extend tests ─────────────────────────────────── */

static void test_herm_dc_and_nyquist_copied(void)
{
    printf("hermitian_extend: DC and Nyquist copied directly\n");
    /* n_half=5, n_full=8 → bins 0,1,2,3,4 map to full[0..7] */
    double c_mag[5]  = { 1.0, 2.0, 3.0, 4.0, 5.0 };
    double c_full[8] = { 0 };
    hermitian_extend(c_mag, 5, 8, c_full);

    CHECK_NEAR(c_full[0], 1.0, 1e-12, "DC (k=0) copied to full[0]");
    CHECK_NEAR(c_full[4], 5.0, 1e-12, "Nyquist (k=4) copied to full[4]");
}

static void test_herm_positive_freqs_match_input(void)
{
    printf("hermitian_extend: positive frequencies match c_mag\n");
    double c_mag[5]  = { 1.0, 2.0, 3.0, 4.0, 5.0 };
    double c_full[8] = { 0 };
    hermitian_extend(c_mag, 5, 8, c_full);

    int ok = 1;
    for (int k = 0; k < 5; k++)
        if (fabs(c_full[k] - c_mag[k]) > 1e-12) { ok = 0; break; }
    CHECK(ok, "c_full[0..4] == c_mag[0..4]");
}

static void test_herm_mirror_symmetry(void)
{
    /*
     * For k=1..n_full/2-1, c_full[k] must equal c_full[n_full-k].
     * DC and Nyquist have no mirror counterpart.
     */
    printf("hermitian_extend: mirror symmetry c_full[k] == c_full[N-k]\n");
    double c_mag[5]  = { 1.0, 2.0, 3.0, 4.0, 5.0 };
    double c_full[8] = { 0 };
    hermitian_extend(c_mag, 5, 8, c_full);

    /* k=1: full[1]=2.0, full[7]=2.0 */
    /* k=2: full[2]=3.0, full[6]=3.0 */
    /* k=3: full[3]=4.0, full[5]=4.0 */
    int ok = 1;
    for (int k = 1; k <= 3; k++)
        if (fabs(c_full[k] - c_full[8 - k]) > 1e-12) { ok = 0; break; }
    CHECK(ok, "c_full[k] == c_full[N-k] for k=1..N/2-1");
}

static void test_herm_full_size(void)
{
    printf("hermitian_extend: output length = n_full\n");
    /* Use full project sizes: n_half=4097, n_full=8192 */
    int n_half = 4097, n_full = 8192;
    double *c_mag  = malloc(n_half * sizeof(double));
    double *c_full = malloc(n_full * sizeof(double));
    for (int k = 0; k < n_half; k++) c_mag[k] = 1.0;
    memset(c_full, 0, n_full * sizeof(double));

    hermitian_extend(c_mag, n_half, n_full, c_full);

    /* Every element should have been written (no zeros remain for a flat input) */
    int ok = 1;
    for (int k = 0; k < n_full; k++)
        if (c_full[k] == 0.0) { ok = 0; break; }
    CHECK(ok, "all 8192 elements written for flat input");

    free(c_mag); free(c_full);
}

static void test_herm_real_signal_property(void)
{
    /*
     * IFFT of a Hermitian spectrum produces a real signal.
     * We can verify the property directly: for any k in 1..N/2-1,
     * c_full[k] must equal c_full[N-k].  (Already checked in symmetry
     * test, but confirm at full project scale.)
     */
    printf("hermitian_extend: full-scale symmetry (N=8192)\n");
    int n_half = 4097, n_full = 8192;
    double *c_mag  = malloc(n_half * sizeof(double));
    double *c_full = malloc(n_full * sizeof(double));
    for (int k = 0; k < n_half; k++) c_mag[k] = (double)(k + 1);

    hermitian_extend(c_mag, n_half, n_full, c_full);

    int ok = 1;
    for (int k = 1; k < n_half - 1; k++)
        if (fabs(c_full[k] - c_full[n_full - k]) > 1e-12) { ok = 0; break; }
    CHECK(ok, "c_full[k] == c_full[8192-k] for all k=1..4095");

    free(c_mag); free(c_full);
}

/* ── real_ifft tests ────────────────────────────────────────── */

static void test_ifft_all_zero(void)
{
    printf("real_ifft: all-zero spectrum → all-zero output\n");
    int n = 8;
    double in[8]  = { 0 };
    double out[8] = { 0 };
    real_ifft(in, n, out);
    int ok = 1;
    for (int k = 0; k < n; k++) if (fabs(out[k]) > 1e-12) { ok = 0; break; }
    CHECK(ok, "IFFT(0) = 0");
}

static void test_ifft_dc_only(void)
{
    /*
     * X[0] = N, all other bins 0 → IFFT gives h[n] = 1 for all n.
     * (IFFT normalises by 1/N, so h[n] = (1/N) * N * e^{j*2π*0*n/N} = 1)
     */
    printf("real_ifft: DC-only spectrum → constant output\n");
    int n = 8;
    double in[8]  = { 8.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    double out[8];
    real_ifft(in, n, out);
    int ok = 1;
    for (int k = 0; k < n; k++)
        if (fabs(out[k] - 1.0) > 1e-12) { ok = 0; break; }
    CHECK(ok, "IFFT(DC=N) → constant 1.0");
}

static void test_ifft_flat_spectrum_delta(void)
{
    /*
     * Flat spectrum (all 1.0) → delta at n=0.
     * IFFT of all-ones: h[0] = (1/N)*sum_{k=0}^{N-1} 1 = 1, h[n≠0] = 0.
     *
     * But our input is real magnitudes (not the complex spectrum of a delta).
     * A flat magnitude spectrum with zero phase is X[k]=1 for all k, which
     * gives IFFT h[0]=1, h[n≠0]=(1/N)*sum e^{j2πkn/N} ≈ 0.
     */
    printf("real_ifft: flat spectrum (all 1.0) → near-delta at n=0\n");
    int n = 16;
    double in[16], out[16];
    for (int k = 0; k < n; k++) in[k] = 1.0;
    real_ifft(in, n, out);

    CHECK_NEAR(out[0], 1.0, 1e-12, "h[0] = 1.0 for flat spectrum");
    int rest_zero = 1;
    for (int k = 1; k < n; k++) if (fabs(out[k]) > 1e-12) { rest_zero = 0; break; }
    CHECK(rest_zero, "h[n>0] ≈ 0 for flat spectrum");
}

static void test_ifft_hermitian_real_output(void)
{
    /*
     * Hermitian-symmetric input (X[k] = X[N-k]) → real output (imaginary
     * part ≈ 0).  We verify by checking that h[n] ≈ h[N-n] (even symmetry),
     * which is the time-domain consequence of a zero-phase magnitude spectrum.
     */
    printf("real_ifft: Hermitian input → even-symmetric output\n");
    int n = 16;
    /* Build a flat Hermitian spectrum (all real, positive) */
    double in[16], out[16];
    for (int k = 0; k < n; k++) in[k] = 1.0;
    real_ifft(in, n, out);

    int ok = 1;
    for (int k = 1; k < n / 2; k++)
        if (fabs(out[k] - out[n - k]) > 1e-12) { ok = 0; break; }
    CHECK(ok, "h[n] == h[N-n] (even symmetry from zero-phase input)");
}

static void test_ifft_cosine_pair(void)
{
    /*
     * Place equal real values A at bins k0 and N-k0 (Hermitian cosine pair).
     * IFFT result:  h[n] = (2A/N) * cos(2π k0 n / N)
     *
     * Use N=16, k0=2, A=8 → h[n] = 1.0 * cos(2π*2*n/16) = cos(πn/4)
     */
    printf("real_ifft: Hermitian cosine pair → cosine output\n");
    int n = 16, k0 = 2;
    double A = 8.0;
    double in[16] = { 0 };
    double out[16];
    in[k0]     = A;
    in[n - k0] = A;
    real_ifft(in, n, out);

    int ok = 1;
    for (int j = 0; j < n; j++) {
        double expected = (2.0 * A / n) * cos(2.0 * M_PI * k0 * j / n);
        if (fabs(out[j] - expected) > 1e-12) { ok = 0; break; }
    }
    CHECK(ok, "Hermitian cosine pair → cosine waveform");
}

static void test_ifft_full_size(void)
{
    /*
     * Smoke test at full project size (n=8192).
     * Flat spectrum of 1.0 should produce h[0]=1, rest ≈ 0.
     */
    printf("real_ifft: full project size N=8192\n");
    int n = 8192;
    double *in  = malloc(n * sizeof(double));
    double *out = malloc(n * sizeof(double));
    for (int k = 0; k < n; k++) in[k] = 1.0;

    real_ifft(in, n, out);

    CHECK_NEAR(out[0], 1.0, 1e-9, "h[0] ≈ 1.0 for N=8192 flat spectrum");

    double max_rest = 0.0;
    for (int k = 1; k < n; k++) {
        double v = fabs(out[k]);
        if (v > max_rest) max_rest = v;
    }
    CHECK(max_rest < 1e-9, "h[n>0] < 1e-9 for N=8192 flat spectrum");

    free(in); free(out);
}

/* ── window_taps tests ──────────────────────────────────────── */

static void test_win_delta_peak(void)
{
    /*
     * h[0]=1, rest=0 → only the center tap (i=n_taps/2) is non-zero.
     * w[64] = 0.5*(1 - cos(2π*64/127)) ≈ 1.0, so taps_out[64] ≈ 1.0.
     */
    printf("window_taps: delta at h[0] → single centre tap\n");
    int n_full = 128, n_taps = 8;   /* small sizes for clarity */
    double h[128];
    double out[8];
    memset(h, 0, sizeof(h));
    h[0] = 1.0;

    window_taps(h, n_full, n_taps, out);

    /* Centre tap i=4 → src=(4-4+128)%128=0 → h[0]=1, w[4]=0.5*(1-cos(2π*4/7)) */
    double w_center = 0.5 * (1.0 - cos(2.0 * M_PI * (n_taps/2) / (n_taps - 1)));
    CHECK_NEAR(out[n_taps/2], w_center, 1e-12, "centre tap = h[0] * w_centre");

    /* All other taps should be 0 (h[src]=0) */
    int rest_zero = 1;
    for (int i = 0; i < n_taps; i++)
        if (i != n_taps/2 && fabs(out[i]) > 1e-12) { rest_zero = 0; break; }
    CHECK(rest_zero, "non-centre taps = 0 for delta input");
}

static void test_win_endpoints_zero(void)
{
    /*
     * Hann window is 0 at i=0 and i=n_taps-1, so the output endpoints
     * are always 0 regardless of the input.
     */
    printf("window_taps: endpoints always zero (Hann property)\n");
    int n_full = 8192, n_taps = 128;
    double *h   = malloc(n_full * sizeof(double));
    double *out = malloc(n_taps * sizeof(double));
    for (int k = 0; k < n_full; k++) h[k] = 1.0;

    window_taps(h, n_full, n_taps, out);

    CHECK_NEAR(out[0],         0.0, 1e-12, "taps_out[0] = 0 (Hann endpoint)");
    CHECK_NEAR(out[n_taps-1],  0.0, 1e-12, "taps_out[127] = 0 (Hann endpoint)");

    free(h); free(out);
}

static void test_win_circular_addressing(void)
{
    /*
     * Verify the circular extraction directly.
     *
     * For n_taps=128, half=64, the formula is: src[i] = (i-64+N) % N.
     *   i=64  → src=0   (centre picks h[0])
     *   i=65  → src=1   (one to the right of peak)
     *   i=63  → src=N-1 (one to the left of peak, wraps around)
     *   i=0   → src=N-64 (leftmost tap)
     *   i=127 → src=63  (rightmost tap)
     *
     * Build h with unique values h[k]=k+1 so we can identify which
     * element was picked.
     */
    printf("window_taps: circular extraction picks correct h elements\n");
    int n_full = 8192, n_taps = 128, half = n_taps / 2;
    double *h   = malloc(n_full * sizeof(double));
    double *out = malloc(n_taps * sizeof(double));
    for (int k = 0; k < n_full; k++) h[k] = (double)(k + 1);

    window_taps(h, n_full, n_taps, out);

    /* Reconstruct expected values manually */
    int ok = 1;
    for (int i = 0; i < n_taps; i++) {
        int src = (i - half + n_full) % n_full;
        double w = 0.5 * (1.0 - cos(2.0 * M_PI * i / (n_taps - 1)));
        double expected = h[src] * w;
        if (fabs(out[i] - expected) > 1e-9) { ok = 0; break; }
    }
    CHECK(ok, "every output tap matches h[src]*w[i] for all i");

    /* Spot-check centre and neighbours */
    double w_c  = 0.5 * (1.0 - cos(2.0 * M_PI * half / (n_taps - 1)));
    double w_r  = 0.5 * (1.0 - cos(2.0 * M_PI * (half+1) / (n_taps - 1)));
    double w_l  = 0.5 * (1.0 - cos(2.0 * M_PI * (half-1) / (n_taps - 1)));
    CHECK_NEAR(out[half],   h[0]        * w_c, 1e-9, "centre tap → h[0]");
    CHECK_NEAR(out[half+1], h[1]        * w_r, 1e-9, "right of centre → h[1]");
    CHECK_NEAR(out[half-1], h[n_full-1] * w_l, 1e-9, "left of centre → h[N-1] (wrap)");

    free(h); free(out);
}

static void test_win_length(void)
{
    printf("window_taps: output has exactly n_taps values\n");
    int n_full = 8192, n_taps = 128;
    double *h   = malloc(n_full * sizeof(double));
    double *out = malloc(n_taps * sizeof(double));
    for (int k = 0; k < n_full; k++) h[k] = 1.0;

    /* Fill sentinel values beyond the expected output */
    for (int i = 0; i < n_taps; i++) out[i] = -999.0;
    window_taps(h, n_full, n_taps, out);

    int ok = 1;
    for (int i = 0; i < n_taps; i++)
        if (out[i] == -999.0) { ok = 0; break; }
    CHECK(ok, "all 128 output slots written");

    free(h); free(out);
}

/* ── quantise_taps tests ────────────────────────────────────── */

static void test_quant_all_zero(void)
{
    printf("quantise_taps: all-zero input → all-zero output\n");
    double   in[8]  = { 0 };
    int32_t  out[8];
    quantise_taps(in, 8, out);
    int ok = 1;
    for (int i = 0; i < 8; i++) if (out[i] != 0) { ok = 0; break; }
    CHECK(ok, "zero taps → zero Q1.23");
}

static void test_quant_peak_maps_to_max(void)
{
    /*
     * Single positive tap: after peak-normalise it becomes (2^23 - 1).
     */
    printf("quantise_taps: peak tap → 2^23-1 (max Q1.23)\n");
    double  in[1]  = { 2.5 };   /* arbitrary positive value */
    int32_t out[1];
    quantise_taps(in, 1, out);
    CHECK(out[0] == (1 << 23) - 1, "single positive tap → Q1.23 max");
}

static void test_quant_negative_peak(void)
{
    /*
     * Single negative tap normalises to −(2^23 − 1).
     * (We map |peak| → 2^23−1, so −peak → −(2^23−1), not q23_min.)
     */
    printf("quantise_taps: negative peak → -(2^23-1)\n");
    double  in[1]  = { -3.0 };
    int32_t out[1];
    quantise_taps(in, 1, out);
    CHECK(out[0] == -((1 << 23) - 1), "single negative tap → -(2^23-1)");
}

static void test_quant_relative_shape(void)
{
    /*
     * Input {2.0, 1.0, -1.0}: after normalise by 2.0:
     *   {1.0, 0.5, -0.5} → Q1.23: {8388607, 4194304, -4194304} (approx)
     * The ratio out[0] : out[1] should be ≈ 2:1.
     */
    printf("quantise_taps: relative shape preserved after normalisation\n");
    double  in[3]  = { 2.0, 1.0, -1.0 };
    int32_t out[3];
    quantise_taps(in, 3, out);
    CHECK(out[0] == (1 << 23) - 1, "peak tap is max Q1.23");
    CHECK(out[1] > 0 && out[1] < out[0], "half-peak tap is positive and smaller");
    CHECK(out[2] < 0 && out[2] == -out[1], "minus-half tap mirrors positive");
}

static void test_quant_q1_23_range(void)
{
    printf("quantise_taps: all outputs in Q1.23 signed range\n");
    int n = 128;
    double  *in  = malloc(n * sizeof(double));
    int32_t *out = malloc(n * sizeof(int32_t));
    for (int i = 0; i < n; i++) in[i] = (i % 2) ? 1.0 : -1.0;

    quantise_taps(in, n, out);

    int32_t q23_max =  (1 << 23) - 1;
    int32_t q23_min = -(1 << 23);
    int ok = 1;
    for (int i = 0; i < n; i++)
        if (out[i] > q23_max || out[i] < q23_min) { ok = 0; break; }
    CHECK(ok, "all taps within Q1.23 range");

    free(in); free(out);
}

/* ── main ───────────────────────────────────────────────────── */

int main(void)
{
    printf("=== fir_design pipeline tests ===\n\n");

    test_mag_zero();            printf("\n");
    test_mag_real_only();       printf("\n");
    test_mag_imag_only();       printf("\n");
    test_mag_pythagorean();     printf("\n");
    test_mag_negative_real();   printf("\n");
    test_mag_all_non_negative(); printf("\n");

    test_smooth_flat_spectrum();    printf("\n");
    test_smooth_dc_passthrough();   printf("\n");
    test_smooth_window_widens();    printf("\n");
    test_smooth_output_non_negative(); printf("\n");
    test_smooth_reduces_variance(); printf("\n");
    test_smooth_less_fraction_less_smoothing(); printf("\n");

    test_inv_flat_response();        printf("\n");
    test_inv_high_response_attenuated(); printf("\n");
    test_inv_low_response_boosted(); printf("\n");
    test_inv_clamp_max();            printf("\n");
    test_inv_clamp_min();            printf("\n");
    test_inv_all_positive();         printf("\n");
    test_inv_all_zero_input();       printf("\n");

    test_herm_dc_and_nyquist_copied();       printf("\n");
    test_herm_positive_freqs_match_input();  printf("\n");
    test_herm_mirror_symmetry();             printf("\n");
    test_herm_full_size();                   printf("\n");
    test_herm_real_signal_property();        printf("\n");

    test_ifft_all_zero();            printf("\n");
    test_ifft_dc_only();             printf("\n");
    test_ifft_flat_spectrum_delta(); printf("\n");
    test_ifft_hermitian_real_output(); printf("\n");
    test_ifft_cosine_pair();         printf("\n");
    test_ifft_full_size();           printf("\n");

    test_win_delta_peak();           printf("\n");
    test_win_endpoints_zero();       printf("\n");
    test_win_circular_addressing();  printf("\n");
    test_win_length();               printf("\n");

    test_quant_all_zero();         printf("\n");
    test_quant_peak_maps_to_max(); printf("\n");
    test_quant_negative_peak();    printf("\n");
    test_quant_relative_shape();   printf("\n");
    test_quant_q1_23_range();      printf("\n");

    printf("%d/%d passed\n", tests_passed, tests_run);
    return (tests_passed == tests_run) ? 0 : 1;
}
