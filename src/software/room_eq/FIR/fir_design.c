/*
 * fir_design.c — inverse-target FIR design pipeline
 *
 * Each function below is one stage. They are built and tested incrementally.
 * The public entry point (fir_design) calls them in order.
 *
 * Completed stages:
 *   1. compute_magnitudes  — Q1.23 complex bins → double magnitudes
 *   2. octave_smooth       — 1/3-octave log-frequency averaging
 *
 * Remaining (stubs):
 *   3. inverse design, Hermitian extension, IFFT, windowing, Q1.23 output
 */

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "fir_design.h"
#include "fir_internal.h"

/* ── Stage 1: Q1.23 complex bins → double magnitudes ───────────────────────
 *
 * Each FFT bin arrives as a pair of Q1.23 signed 32-bit integers.
 * Dividing by 2^23 converts to the double in [-1.0, 1.0).
 * sqrt(r² + i²) gives the complex magnitude for that bin.
 */
void compute_magnitudes(const int32_t *real, const int32_t *imag,
                        int n_bins, double *mag_out)
{
    const double scale = 1.0 / (double)(1 << 23);
    for (int k = 0; k < n_bins; k++) {
        double r = real[k] * scale;
        double i = imag[k] * scale;
        mag_out[k] = sqrt(r * r + i * i);
    }
}

/* ── Stage 2: 1/3-octave log-frequency smoothing ───────────────────────────
 *
 * For each bin k the smoothed output is the arithmetic mean of all input bins
 * whose indices fall in the window [k * 2^(-fraction/2), k * 2^(+fraction/2)].
 *
 * Working directly in bin-index space is exact: since f[k] = k * fs/N, the
 * frequency factor cancels and the window bounds reduce to k * lo/hi_factor.
 *
 * fraction = 1/3 gives 1/3-octave smoothing (lo_factor≈0.891, hi≈1.122).
 *
 * Why: room modal resonances create narrow peaks/notches that a 128-tap FIR
 * cannot correct anyway. Smoothing prevents the inverse design from chasing
 * them and producing huge, ineffective boosts.
 *
 * Bin 0 (DC, f=0) is passed through unchanged — a log window around f=0
 * is undefined and DC energy is irrelevant for audio correction.
 */
void octave_smooth(const double *mag_in, int n_bins,
                   double fraction, double *mag_out)
{
    double lo_factor = pow(2.0, -fraction / 2.0);
    double hi_factor = pow(2.0,  fraction / 2.0);

    mag_out[0] = mag_in[0];   /* DC: pass through */

    for (int k = 1; k < n_bins; k++) {
        int k_lo = (int)floor(k * lo_factor);
        int k_hi = (int)ceil(k * hi_factor);

        if (k_lo < 0)         k_lo = 0;
        if (k_hi >= n_bins)   k_hi = n_bins - 1;

        double sum = 0.0;
        for (int j = k_lo; j <= k_hi; j++)
            sum += mag_in[j];

        mag_out[k] = sum / (double)(k_hi - k_lo + 1);
    }
}

/* ── Stage 3: inverse correction magnitude ──────────────────────────────────
 *
 * TARGET = 1.0 (flat) — we want the corrected room response to be flat.
 *
 * eps prevents division by zero at deep room nulls (frequencies where the
 * room nearly cancels the signal due to reflections).  Setting eps relative
 * to the spectrum peak means it has no effect on strong bins but regularises
 * weak ones consistently regardless of the overall signal level.
 *
 * The ±12 dB clamp (linear: 0.251 to 3.981) stops the filter from applying
 * corrections larger than the hardware can cleanly reproduce and prevents
 * runaway boosts at measurement noise floors.
 */
void compute_inverse(const double *h_mag, int n_bins,
                     double target, double *c_mag_out)
{
    /* find spectrum peak for eps scaling */
    double h_max = 0.0;
    for (int k = 0; k < n_bins; k++)
        if (h_mag[k] > h_max) h_max = h_mag[k];

    double eps   = 1e-3 * h_max;
    if (eps == 0.0) eps = 1e-10;   /* all-zero input guard */

    double c_max = pow(10.0,  12.0 / 20.0);   /* +12 dB in linear = 3.981 */
    double c_min = pow(10.0, -12.0 / 20.0);   /* -12 dB in linear = 0.251 */

    for (int k = 0; k < n_bins; k++) {
        double c = target / (h_mag[k] + eps);
        if (c > c_max) c = c_max;
        if (c < c_min) c = c_min;
        c_mag_out[k] = c;
    }
}

/* ── Stage 4: Hermitian extension ───────────────────────────────────────────
 *
 * c_mag[0..n_half-1] contains real, non-negative magnitudes for bins
 * 0 (DC) through n_full/2 (Nyquist).  To IFFT back to a real time-domain
 * signal we need all n_full bins with conjugate symmetry.
 *
 * Because our magnitudes have zero phase, conjugate symmetry reduces to
 * ordinary mirror symmetry: C_full[N-k] = C_full[k].
 *
 * DC (k=0) and Nyquist (k=n_full/2) appear only once — they are real and
 * have no mirror counterpart.
 */
void hermitian_extend(const double *c_mag, int n_half,
                      int n_full, double *c_full)
{
    /* positive frequencies: DC through Nyquist */
    for (int k = 0; k < n_half; k++)
        c_full[k] = c_mag[k];

    /* negative frequencies: mirror of bins 1 .. Nyquist-1 */
    for (int k = 1; k < n_half - 1; k++)
        c_full[n_full - k] = c_mag[k];
}

/* ── Stage 5: IFFT ──────────────────────────────────────────────────────────
 *
 * Iterative Cooley-Tukey radix-2 FFT/IFFT (Gentleman-Sande decimation-in-time).
 * Works in-place on the complex arrays re[] and im[], both length n.
 *
 * inverse=0: forward DFT  (twiddle angle −2π/len, no normalisation)
 * inverse=1: inverse DFT  (twiddle angle +2π/len, divide by n at the end)
 *
 * n must be a power of 2.
 */
static void fft_inplace(double *re, double *im, int n, int inverse)
{
    /* Bit-reversal permutation */
    for (int i = 1, j = 0; i < n; i++) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1)
            j ^= bit;
        j ^= bit;
        if (i < j) {
            double tmp;
            tmp = re[i]; re[i] = re[j]; re[j] = tmp;
            tmp = im[i]; im[i] = im[j]; im[j] = tmp;
        }
    }

    /* Butterfly stages */
    double sign = inverse ? 1.0 : -1.0;
    for (int len = 2; len <= n; len <<= 1) {
        double ang = sign * 2.0 * M_PI / len;
        double wr0 = cos(ang), wi0 = sin(ang);
        for (int i = 0; i < n; i += len) {
            double wr = 1.0, wi = 0.0;
            for (int j = 0; j < len / 2; j++) {
                double ur = re[i + j],         ui = im[i + j];
                double vr = re[i + j + len/2], vi = im[i + j + len/2];
                double tr = wr * vr - wi * vi;
                double ti = wr * vi + wi * vr;
                re[i + j]         = ur + tr;
                im[i + j]         = ui + ti;
                re[i + j + len/2] = ur - tr;
                im[i + j + len/2] = ui - ti;
                double wr_next = wr * wr0 - wi * wi0;
                wi = wr * wi0 + wi * wr0;
                wr = wr_next;
            }
        }
    }

    if (inverse) {
        double inv_n = 1.0 / n;
        for (int i = 0; i < n; i++) {
            re[i] *= inv_n;
            im[i] *= inv_n;
        }
    }
}

/*
 * real_ifft — zero-phase Hermitian spectrum → real impulse response.
 *
 * c_full has zero imaginary part (all magnitudes, no phase shift), so we
 * set im=0, run the inverse FFT, and discard the near-zero imaginary result.
 */
void real_ifft(const double *c_full, int n, double *h_out)
{
    double *re = malloc(n * sizeof(double));
    double *im = calloc(n, sizeof(double));   /* imaginary part = 0 */
    if (!re || !im) { free(re); free(im); return; }

    for (int k = 0; k < n; k++)
        re[k] = c_full[k];

    fft_inplace(re, im, n, 1);

    for (int k = 0; k < n; k++)
        h_out[k] = re[k];

    free(re); free(im);
}

/* ── Stage 6: Hann-windowed tap extraction ──────────────────────────────────
 *
 * The IFFT output h[] is a circular, even-symmetric impulse response with its
 * peak at h[0].  We extract n_taps samples centred there using circular
 * addressing, then apply a Hann window to suppress spectral sidelobes.
 *
 * Circular extraction:  src[i] = h[(i − n_taps/2 + n_full) % n_full]
 *   i=0        → h[n_full − n_taps/2]   (left tail)
 *   i=n_taps/2 → h[0]                   (peak, Hann = 1.0)
 *   i=n_taps−1 → h[n_taps/2 − 1]       (right tail)
 *
 * Hann window: w[i] = 0.5 * (1 − cos(2π·i/(n_taps−1)))
 *   endpoints → 0, centre → 1.
 */
void window_taps(const double *h, int n_full, int n_taps, double *taps_out)
{
    int half = n_taps / 2;
    for (int i = 0; i < n_taps; i++) {
        int src = (i - half + n_full) % n_full;
        double w = 0.5 * (1.0 - cos(2.0 * M_PI * i / (n_taps - 1)));
        taps_out[i] = h[src] * w;
    }
}

/* ── Stage 7: Q1.23 quantisation ────────────────────────────────────────────
 *
 * Peak-normalise so the largest |tap| maps to 2^23−1, then round to the
 * nearest integer.  This preserves the filter's relative shape while
 * guaranteeing no overflow.  All-zero input produces all-zero output.
 */
void quantise_taps(const double *taps, int n_taps, int32_t *taps_q23)
{
    double peak = 0.0;
    for (int i = 0; i < n_taps; i++) {
        double v = fabs(taps[i]);
        if (v > peak) peak = v;
    }

    double scale = (peak > 0.0) ? (double)((1 << 23) - 1) / peak : 0.0;

    int32_t q23_max =  (1 << 23) - 1;   /*  8388607 */
    int32_t q23_min = -(1 << 23);        /* -8388608 */

    for (int i = 0; i < n_taps; i++) {
        double v = round(taps[i] * scale);
        if (v > q23_max) v = q23_max;
        if (v < q23_min) v = q23_min;
        taps_q23[i] = (int32_t)v;
    }
}

/* ── Public entry point ─────────────────────────────────────────────────────
 *
 * Calls completed stages in order; remaining stages are stubs.
 */
int fir_design(const int32_t *fft_real, const int32_t *fft_imag,
               int n_bins, int32_t *taps_out)
{
    int n_full = 2 * (n_bins - 1);   /* 8192 for n_bins=4097 */

    double *mag      = malloc(n_bins * sizeof(double));
    double *smoothed = malloc(n_bins * sizeof(double));
    double *c_mag    = malloc(n_bins * sizeof(double));
    double *c_full   = malloc(n_full * sizeof(double));
    double *h        = malloc(n_full * sizeof(double));
    double *taps_d   = malloc(N_TAPS * sizeof(double));
    if (!mag || !smoothed || !c_mag || !c_full || !h || !taps_d) {
        free(mag); free(smoothed); free(c_mag); free(c_full); free(h); free(taps_d);
        return -1;
    }

    compute_magnitudes(fft_real, fft_imag, n_bins, mag);
    octave_smooth(mag, n_bins, 1.0 / 3.0, smoothed);
    compute_inverse(smoothed, n_bins, 1.0, c_mag);
    hermitian_extend(c_mag, n_bins, n_full, c_full);
    real_ifft(c_full, n_full, h);
    window_taps(h, n_full, N_TAPS, taps_d);
    quantise_taps(taps_d, N_TAPS, taps_out);

    free(mag); free(smoothed); free(c_mag); free(c_full); free(h); free(taps_d);
    return 0;
}

/* ── Entry point for pre-computed magnitude spectrum ───────────────────────
 *
 * Used by the chunked calibration path: eq.c assembles magnitudes from
 * multiple FFT chunks, then calls this (skipping compute_magnitudes).
 */
int fir_design_from_spectrum(const double *mag_in, int n_bins,
                             int32_t *taps_out)
{
    int n_full = 2 * (n_bins - 1);   /* 8192 for n_bins=4097 */

    double *smoothed = malloc(n_bins * sizeof(double));
    double *c_mag    = malloc(n_bins * sizeof(double));
    double *c_full   = malloc(n_full * sizeof(double));
    double *h        = malloc(n_full * sizeof(double));
    double *taps_d   = malloc(N_TAPS * sizeof(double));
    if (!smoothed || !c_mag || !c_full || !h || !taps_d) {
        free(smoothed); free(c_mag); free(c_full); free(h); free(taps_d);
        return -1;
    }

    octave_smooth(mag_in, n_bins, 1.0 / 3.0, smoothed);
    compute_inverse(smoothed, n_bins, 1.0, c_mag);
    hermitian_extend(c_mag, n_bins, n_full, c_full);
    real_ifft(c_full, n_full, h);
    window_taps(h, n_full, N_TAPS, taps_d);
    quantise_taps(taps_d, N_TAPS, taps_out);

    free(smoothed); free(c_mag); free(c_full); free(h); free(taps_d);
    return 0;
}
