/*
 * fir_design.h — interface for the inverse-target FIR design algorithm
 *
 * Called by eq.c after it has read all FFT bins from the hardware.
 * The actual algorithm lives in fir_design.c and will be built up step by step.
 */

#ifndef FIR_DESIGN_H
#define FIR_DESIGN_H

#include <stdint.h>

#define N_TAPS 128   /* fixed FIR length — must match FPGA FIR filter */

/*
 * fir_design — design a 128-tap correction FIR filter from measured FFT data.
 *
 * fft_real:  4097 Q1.23 signed integers — real parts of the half-spectrum
 * fft_imag:  4097 Q1.23 signed integers — imaginary parts of the half-spectrum
 * n_bins:    must be N_HALF (4097)
 * taps_out:  output buffer, receives N_TAPS Q1.23 tap coefficients
 *
 * Returns 0 on success, -1 on error.
 */
int fir_design(const int32_t *fft_real, const int32_t *fft_imag,
               int n_bins, int32_t *taps_out);

#endif
