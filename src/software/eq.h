/*
 * eq.h — public interface for hardware-independent functions in eq.c
 *
 * We expose them here so test_eq.c can test these functions that don't require hardware.
 * 
 */

#ifndef EQ_H
#define EQ_H

#include <stdint.h>

#define N_FFT   8192 // FFT Sample Size (Matches room_eq_peripheral.sv's FFT)
#define N_HALF  (N_FFT / 2 + 1)   /* 4097 unique bins for a real-input FFT */
#define N_LUT   256                /* one quadrant of sine, 256 entries for now. May change to 1024? */

/*
 * generate_sine_lut — fill lut[0..n-1] with Q1.23 sine values for one quadrant.
 *
 * lut[i] = round(sin(i * pi / (2*n)) * 2^23)
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
    // Example:
    //  0xFF0000 = 16711680 interpreted as unsigned 32 bit int.
    // We need to interpret it as a 24 bit two's complement.
    // 11111111 00000000 00000000
    // ^ Sign Bit
    // As 32 bit signed int: 00000000 11111111 00000000 00000000
    // We shift left by 8:   11111111 00000000 00000000 00000000
    // ">> 8" yields arithmetic shift. Since MSB is 1, we fill with 1s: 11111111 11111111 00000000 00000000 "Sign Extension"
}

#endif
