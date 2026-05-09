/*
 * test_eq.c — unit tests for pure functions in eq.c
 *
 * Tests the two functions that have no hardware dependency:
 *   1. generate_sine_lut  — Q1.23 sine table generation
 *   2. sign_extend_24     — 24-bit two's-complement sign extension
 *
 * Compile:  clang -Wall -lm -o test_eq test_eq.c
 * Run:      ./test_eq
 */

#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include <stdlib.h>

#include "eq.h"

/* ── test harness ───────────────────────────────────────────── */

static int tests_run    = 0;
static int tests_passed = 0;

#define CHECK(cond, name) do {                                      \
    tests_run++;                                                    \
    if (cond) {                                                     \
        tests_passed++;                                             \
        printf("  PASS  %s\n", name);                              \
    } else {                                                        \
        printf("  FAIL  %s  (line %d)\n", name, __LINE__);         \
    }                                                               \
} while (0)

/* ── generate_sine_lut tests ────────────────────────────────── */

static void test_sine_lut_endpoints(void)
{
    printf("sine LUT endpoints\n");
    int32_t lut[N_LUT];
    generate_sine_lut(lut, N_LUT);

    /* lut[0] = sin(0) = 0 */
    CHECK(lut[0] == 0, "lut[0] = 0 (sin 0°)");

    /* lut[255] = sin(255 * π/512) ≈ 0.9999882 → 8388440
     * Accept ±1 for rounding */
    int32_t expected_255 = (int32_t)round(sin(255.0 * M_PI / 512.0) * (1 << 23));
    CHECK(abs(lut[255] - expected_255) <= 1, "lut[255] ≈ sin(89.65°) in Q1.23");

    /* All values must be non-negative (one quadrant: 0 → π/2) */
    int all_positive = 1;
    for (int i = 0; i < N_LUT; i++)
        if (lut[i] < 0) { all_positive = 0; break; }
    CHECK(all_positive, "all entries ≥ 0 (first quadrant only)");
}

static void test_sine_lut_monotonic(void)
{
    printf("sine LUT monotonically increasing\n");
    int32_t lut[N_LUT];
    generate_sine_lut(lut, N_LUT);

    int monotonic = 1;
    for (int i = 1; i < N_LUT; i++) {
        if (lut[i] < lut[i-1]) { monotonic = 0; break; }
    }
    CHECK(monotonic, "lut[i] >= lut[i-1] for all i");
}

static void test_sine_lut_q1_23_range(void)
{
    printf("sine LUT Q1.23 range\n");
    int32_t lut[N_LUT];
    generate_sine_lut(lut, N_LUT);

    int32_t q123_max =  (1 << 23) - 1;   /*  8388607 */
    int32_t q123_min = -(1 << 23);        /* -8388608 */

    int in_range = 1;
    for (int i = 0; i < N_LUT; i++) {
        if (lut[i] > q123_max || lut[i] < q123_min) { in_range = 0; break; }
    }
    CHECK(in_range, "all entries fit in Q1.23 signed range");
}

static void test_sine_lut_spot_values(void)
{
    printf("sine LUT spot-check values\n");
    int32_t lut[N_LUT];
    generate_sine_lut(lut, N_LUT);

    /*
     * angle = i * π / (2 * N_LUT) = i * π / 512
     *   i=32  → 32π/512  = π/16    = 11.25°
     *   i=64  → 64π/512  = π/8     = 22.5°
     *   i=128 → 128π/512 = π/4     = 45.0°
     *   i=192 → 192π/512 = 3π/8    = 67.5°
     *   i=255 → 255π/512           = 89.65°
     */
    struct { int idx; double expected_deg; } cases[] = {
        {  32, 11.25 },
        {  64, 22.50 },
        { 128, 45.00 },
        { 192, 67.50 },
    };

    for (int c = 0; c < 4; c++) {
        int i = cases[c].idx;
        int32_t ref = (int32_t)round(sin(cases[c].expected_deg * M_PI / 180.0) * (1 << 23));
        char name[64];
        snprintf(name, sizeof(name), "lut[%d] ≈ sin(%.2f°)", i, cases[c].expected_deg);
        CHECK(abs(lut[i] - ref) <= 1, name);
    }
}

/* ── sign_extend_24 tests ───────────────────────────────────── */

static void test_sign_extend_24(void)
{
    printf("sign_extend_24\n");

    /* Positive value: bit 23 = 0, no sign extension needed */
    CHECK(sign_extend_24(0x000001) == 1,          "positive 1");
    CHECK(sign_extend_24(0x7FFFFF) == 8388607,    "max positive (2^23 - 1)");
    CHECK(sign_extend_24(0x000000) == 0,          "zero");

    /* Negative value: bit 23 = 1, must extend with 0xFF to 32 bits */
    CHECK(sign_extend_24(0xFFFFFF) == -1,         "all ones → -1");
    CHECK(sign_extend_24(0x800000) == -8388608,   "min negative (-2^23)");
    CHECK(sign_extend_24(0xFFFFFE) == -2,         "0xFFFFFE → -2");

    /* Note: bits 31-24 are always 0 after the driver's & 0xFFFFFF mask,
     * so no test needed for non-zero upper bytes. */
}

/* ── main ───────────────────────────────────────────────────── */

int main(void)
{
    printf("=== eq.c unit tests ===\n\n");

    test_sine_lut_endpoints();   printf("\n");
    test_sine_lut_monotonic();   printf("\n");
    test_sine_lut_q1_23_range(); printf("\n");
    test_sine_lut_spot_values(); printf("\n");
    test_sign_extend_24();       printf("\n");

    printf("%d/%d passed\n", tests_passed, tests_run);
    return (tests_passed == tests_run) ? 0 : 1;
}
