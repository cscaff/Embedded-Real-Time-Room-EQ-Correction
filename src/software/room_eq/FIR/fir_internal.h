/*
 * fir_internal.h — internal sub-functions of the FIR design pipeline
 *
 * Not part of the public API (fir_design.h).  Exposed here so that
 * test/software/test_fir.c can call each step individually.
 *
 * Each function corresponds to one stage of the algorithm:
 *   Step 1: compute_magnitudes  — Q1.23 complex bins → double magnitudes
 *   Step 2: octave_smooth       — 1/3-octave log-frequency averaging
 *   Step 3: compute_inverse     — TARGET / (H_mag + eps), clamped ±12 dB
 *   Step 4: hermitian_extend    — mirror half-spectrum to full N-point array
 *   Step 5: real_ifft           — Cooley-Tukey IFFT → real impulse response
 *   (Steps 6-7: windowing, Q1.23 output — added in fir_design)
 */

#ifndef FIR_INTERNAL_H
#define FIR_INTERNAL_H

#include <stdint.h>

/*
 * compute_magnitudes — convert N_HALF Q1.23 complex bins to double magnitudes.
 *
 * real, imag: signed Q1.23 integers from the FFT result RAM
 * n_bins:     number of bins (N_HALF = 4097)
 * mag_out:    output array, each entry in [0.0, ~1.0]
 *
 * Conversion: Q1.23 integer v → double v / 2^23
 * Magnitude:  sqrt(r² + i²)  in double precision
 */
void compute_magnitudes(const int32_t *real, const int32_t *imag,
                        int n_bins, double *mag_out);

/*
 * octave_smooth — smooth mag_in over a log-frequency window and write mag_out.
 *
 * fraction: width in octaves (e.g. 1.0/3.0 for 1/3-octave)
 * n_bins:   length of both arrays
 * Bin 0 (DC) is passed through unchanged.
 */
void octave_smooth(const double *mag_in, int n_bins,
                   double fraction, double *mag_out);

/*
 * compute_inverse — design the correction magnitude spectrum.
 *
 * For each bin k:
 *   eps      = 1e-3 * max(h_mag)          regularise against room nulls
 *   c_mag[k] = target / (h_mag[k] + eps)  invert the room response
 *   c_mag[k] = clamp(c_mag[k], 10^(-12/20), 10^(+12/20))   ±12 dB safety
 *
 * target: desired flat magnitude (use 1.0 for flat correction)
 * All outputs are positive linear-scale magnitudes.
 */
void compute_inverse(const double *h_mag, int n_bins,
                     double target, double *c_mag_out);

/*
 * hermitian_extend — build a full n_full-point real spectrum from the
 * one-sided (half) magnitude spectrum.
 *
 * c_mag:   n_half = n_full/2+1 real magnitudes (k = 0 .. n_full/2)
 * n_half:  number of input values (4097 for N=8192)
 * n_full:  full FFT size (8192); must equal 2*(n_half-1)
 * c_full:  output array of length n_full, Hermitian-symmetric:
 *            c_full[k]        = c_mag[k]   for k = 0 .. n_full/2
 *            c_full[n_full-k] = c_mag[k]   for k = 1 .. n_full/2-1
 *
 * Since all c_mag values are real and non-negative (zero phase), the
 * mirrored negative-frequency bins are identical to their positive-
 * frequency counterparts (conjugate of a real number is itself).
 */
void hermitian_extend(const double *c_mag, int n_half,
                      int n_full, double *c_full);

/*
 * window_taps — extract and window the center n_taps of the IFFT output.
 *
 * h:        full IFFT result, length n_full; peak is at h[0] (zero-phase)
 * n_full:   length of h (must be a power of 2; 8192 for this project)
 * n_taps:   number of FIR taps to extract (128); must be even and ≤ n_full
 * taps_out: output array of length n_taps
 *
 * The n_taps samples are extracted circularly, centred on h[0]:
 *   src[i] = h[(i - n_taps/2 + n_full) % n_full]   for i = 0 .. n_taps-1
 * Each sample is then multiplied by a Hann window:
 *   w[i] = 0.5 * (1 − cos(2π·i / (n_taps−1)))
 * so the endpoints taper to zero and sidelobes are suppressed.
 */
void window_taps(const double *h, int n_full, int n_taps, double *taps_out);

/*
 * quantise_taps — convert double taps to Q1.23 signed integers.
 *
 * taps:     floating-point FIR taps (after windowing)
 * n_taps:   number of taps (128)
 * taps_q23: output Q1.23 array of length n_taps
 *
 * Normalises so the largest |tap| maps to full-scale Q1.23 (2^23 − 1),
 * then rounds each value.  If all taps are zero the output is all zero.
 * Values are clamped to [−2^23, 2^23−1] before assignment.
 */
void quantise_taps(const double *taps, int n_taps, int32_t *taps_q23);

/*
 * real_ifft — Cooley-Tukey radix-2 IFFT of a real, Hermitian-symmetric spectrum.
 *
 * c_full: n real-valued magnitudes (Hermitian-extended, zero phase), length n
 * n:      FFT size (must be a power of 2; 8192 for this project)
 * h_out:  output real impulse response, length n
 *
 * Internally allocates complex work arrays re[n] and im[n].
 * Sets re = c_full, im = 0 (zero-phase assumption), performs inverse FFT
 * (twiddle angle +2π/len, normalise by 1/n), then copies the real part to h_out.
 * The imaginary part is discarded; for a truly Hermitian input it is ≈ 0.
 */
void real_ifft(const double *c_full, int n, double *h_out);

#endif
