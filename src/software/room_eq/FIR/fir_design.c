/*
 * fir_design.c — inverse-target FIR design (stub)
 *
 * This file will be filled in step by step. Each algorithmic stage
 * (octave smoothing, inverse design, Hermitian extension, IFFT,
 * windowing, Q1.23 scaling) will be added and unit-tested individually.
 */

#include <string.h>
#include "fir_design.h"

int fir_design(const int32_t *fft_real, const int32_t *fft_imag,
               int n_bins, int32_t *taps_out)
{
    (void)fft_real;
    (void)fft_imag;
    (void)n_bins;

    /* Stub: identity filter (delta at center tap) */
    memset(taps_out, 0, N_TAPS * sizeof(int32_t));
    taps_out[N_TAPS / 2] = 1 << 23;   /* Q1.23 representation of 1.0 */
    return 0;
}
