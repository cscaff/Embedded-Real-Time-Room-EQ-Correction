/*
 * eq.h — public interface for pure (hardware-free) functions in eq.c
 *
 * Exposed here so test_eq.c can test them without a device.
 */

#ifndef EQ_H
#define EQ_H

#include <stdint.h>

#define N_FFT   8192
#define N_HALF  (N_FFT / 2 + 1)   /* 4097 unique bins for a real-input FFT */
#define N_LUT   256                /* one quadrant of sine, 256 entries     */

/*
 * generate_sine_lut — fill lut[0..n-1] with Q1.23 sine values for one quadrant.
 *
 * lut[i] = round(sin(i * π / (2*n)) * 2^23)
 *
 * The sweep generator mirrors and negates these 256 values to reconstruct a
 * full sine cycle (see sine_lookup.sv quadrant logic).
 */
void generate_sine_lut(int32_t *lut, int n);

/*
 * sign_extend_24 — interpret a 24-bit two's-complement value (stored in the
 * lower 24 bits of a uint32_t) as a signed 32-bit integer.
 *
 * This is needed after reading FFT bins: the driver masks to 24 bits with
 * & 0xFFFFFF, but the MSB (bit 23) is the sign bit.
 */
static inline int32_t sign_extend_24(uint32_t v)
{
    return (int32_t)(v << 8) >> 8;   /* shift into sign position, then arithmetic shift back */
}

#endif
