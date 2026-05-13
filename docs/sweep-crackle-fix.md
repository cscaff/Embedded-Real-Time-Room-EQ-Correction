# Fixing the Sine Sweep Crackling

## The Problem

The sine sweep had a periodic clicking/crackling artifact introduced by the linear interpolation added to `sine_lookup.sv`. Without interpolation, the sweep had no clicks but suffered from aliasing at high frequencies. Every interpolation attempt either kept the clicking or made things worse.

## Root Cause: Three Bugs

The crackling was caused by three independent bugs that were never all fixed at the same time. Previous attempts fixed one or two but introduced or missed the others.

### Bug 1: Stale BRAM Read (the original click)

The 3-stage interpolation pipeline read `val0 <= lut_out` one cycle too early. The BRAM has 1-cycle read latency — `dout_b` is only valid on the clock edge *after* the address is presented. The pipeline set `bram_addr = index0` in state 0 and immediately read `lut_out` in state 1, but at that posedge the BRAM is still registering the output. Due to non-blocking assignment semantics, `val0` captured the *previous* BRAM output (from the last sample's `index1`).

This mostly worked because adjacent samples have similar indices — except at **quadrant boundaries** where index mirroring flips direction. There, the stale value came from a completely different part of the LUT, producing a large discontinuity.

**Fix:** 5-stage pipeline with explicit BRAM wait states:
```
State 0: set bram_addr = index0, save quadrant/frac/index1
State 1: wait (BRAM registering)
State 2: val0 = lut_out (now correct), set bram_addr = index1
State 3: wait (BRAM registering)
State 4: interpolate using val0 and lut_out (both correct)
```

### Bug 2: Unsigned Multiply (why the 5-stage attempt failed)

The earlier 5-stage pipeline attempt (commit `fa9bc8f`) correctly fixed the BRAM timing but had:

```verilog
// BROKEN — unsigned multiply
wire signed [34:0] w_product = w_diff * {1'b0, frac_saved};
```

In SystemVerilog, `signed * unsigned = unsigned`. The signed `w_diff` was silently reinterpreted as unsigned when negative (half the time), producing garbage. This is why the 5-stage attempt sounded like a "jet engine."

**Fix:** Cast the fraction to signed:
```verilog
wire signed [34:0] w_product = w_diff * $signed({1'b0, frac_saved});
```

### Bug 3: Wrong Boundary Clamp (the remaining crackle)

The `next_rev` index (used in Q1/Q3 where the LUT is read backward) had its overflow clamp on the wrong boundary:

```verilog
// BROKEN — clamps at raw_index=0, which never wraps (~0-1 = 1022, fine)
wire [9:0] next_rev = (raw_index == 10'd0) ? 10'd1023 : (~raw_index - 10'd1);
```

The actual wrap happens at `raw_index == 1023`: `~1023 = 0`, and `0 - 1 = 1023` in unsigned arithmetic. This made the interpolation read LUT[1023] (the peak, ~8.4M) at the zero crossing where it should read LUT[0] (~0), producing a massive spike once per cycle at the Q1→Q2 and Q3→Q0 transitions.

**Fix:**
```verilog
wire [9:0] next_rev = (raw_index == 10'd1023) ? 10'd0 : (~raw_index - 10'd1);
```

## Why Simulation Didn't Catch It

1. **`tb_sine_lookup.sv`** held `sample_en = 1` every clock cycle. This masked Bug 1 because the BRAM address changed every cycle, so the "stale" read was only 1 cycle old (nearly correct) instead of 256 cycles old (wildly wrong).
2. **`tb_sweep_quality.sv`** referenced a `.lrck` port that didn't exist on `sweep_generator` — it wouldn't compile.
3. No test checked for sample-to-sample discontinuities or quadrant boundary behavior.

## Why Previous Fix Attempts Failed

| Attempt | What it fixed | What it broke/missed |
|---------|--------------|---------------------|
| 3-stage pipeline (original) | — | Bug 1: stale BRAM read |
| Index clamping | Bug 3 partially | Bug 1 still present, wrong clamp for `next_rev` |
| 5-stage pipeline | Bug 1 | Bug 2: dropped `$signed()` cast |
| Dual-BRAM | Bug 1 | Bug 2: same unsigned multiply issue |
| Revert to no interpolation | No clicks | Aliasing returns |
| Combinational wires | Cleaner code | Bug 1 and Bug 3 still present |

No single attempt fixed all three bugs simultaneously.

## Files Changed

- **`src/hardware/room_eq_peripheral/sweep_generator/sine_lookup.sv`** — 5-stage pipeline, `$signed()` multiply, corrected `next_rev` clamp
- **`test/hardware/room_eq_peripheral/sweep_generator/tb_sine_lookup.sv`** — realistic `sample_en` timing (1 pulse per 256 clocks), discontinuity sweep test (T6), quadrant boundary stress test (T7)

## Verification

The new testbench catches all three bugs on the old code:
- **T6 (discontinuity sweep):** Detects clicks with delta of 7.7M vs threshold of 440K
- **T7 (quadrant boundaries):** Detects large jumps at all four transitions

And passes cleanly on the fixed code:
- **T6:** Max delta 219K across 2000 samples (8 full cycles), zero clicks
- **T7:** All quadrant transitions smooth (max delta 12K)

## Timing Note

Quartus reports timing violations (-2.3 ns setup, -3.1 ns recovery) on cross-domain paths between `clock_50_1` (50 MHz) and the audio PLL (12.288 MHz). These are on HPS register readback paths (`rx_left` → Avalon bus) and synchronizer chains (`sweep_start_toggle` → `tog_sync1`), **not** on the audio DAC path which has +68 ns of positive slack. These violations exist in all builds and don't affect audio output quality.
