#!/usr/bin/env bash
# Generates a netlistsvg SVG schematic for every hardware module.
# Each schematic shows the module's own RTL with submodules as black boxes.

set -e

BASE="$(cd "$(dirname "$0")/.." && pwd)"
HW="$BASE/src/hardware"
LAB="$BASE/lab3-hw"
OUT="$BASE/schematics"

# gen <top_module> <top_sv_file> [stub_file ...]
#   top_sv_file  — the module under scrutiny (elaborated fully)
#   stub_files   — read with -lib so they become black boxes
gen() {
    local top="$1"; local top_file="$2"; shift 2
    local script="read_verilog -sv $top_file;"
    for stub in "$@"; do
        script+=" read_verilog -sv -lib $stub;"
    done
    script+=" hierarchy -top $top; proc; opt; write_json $OUT/${top}.json"
    echo "  yosys: $top"
    yosys -p "$script" -q 2>/dev/null
    echo "  netlistsvg: $top"
    netlistsvg "$OUT/${top}.json" -o "$OUT/${top}.svg"
}

# gen_mem — same as gen but uses memory -nomap instead of opt
# Use for modules with large RAM arrays to avoid unrolling them into registers.
gen_mem() {
    local top="$1"; local top_file="$2"; shift 2
    local script="read_verilog -sv $top_file;"
    for stub in "$@"; do
        script+=" read_verilog -sv -lib $stub;"
    done
    script+=" hierarchy -top $top; proc; memory -nomap; write_json $OUT/${top}.json"
    echo "  yosys: $top"
    yosys -p "$script" -q 2>/dev/null
    echo "  netlistsvg: $top"
    netlistsvg "$OUT/${top}.json" -o "$OUT/${top}.svg"
}

echo "=== Generating schematics ==="

# ── Leaf modules (no submodule instantiations) ──────────────────────────────
gen phase_accumulator \
    "$HW/room_eq_peripheral/sweep_generator/phase_accumulator.sv"

gen_mem sine_lut \
    "$HW/memory/sine_lut.sv"

gen i2s_clock_gen \
    "$HW/room_eq_peripheral/i2s_tx/i2s_clock_gen.sv"

gen i2s_shift_register \
    "$HW/room_eq_peripheral/i2s_tx/i2s_shift_register.sv"

gen i2s_rx \
    "$HW/room_eq_peripheral/i2s_rx/i2s_rx.sv"

gen_mem fft_result_ram \
    "$HW/memory/fft_results_ram.sv"

# ── Modules with .sv submodules (children become black boxes) ─────────────
gen sine_lookup \
    "$HW/room_eq_peripheral/sweep_generator/sine_lookup.sv" \
    "$HW/memory/sine_lut.sv"

gen sweep_generator \
    "$HW/room_eq_peripheral/sweep_generator/sweep_generator.sv" \
    "$HW/room_eq_peripheral/sweep_generator/phase_accumulator.sv" \
    "$HW/room_eq_peripheral/sweep_generator/sine_lookup.sv" \
    "$HW/memory/sine_lut.sv"

gen i2s_tx \
    "$HW/room_eq_peripheral/i2s_tx/i2s_tx.sv" \
    "$HW/room_eq_peripheral/i2s_tx/i2s_clock_gen.sv" \
    "$HW/room_eq_peripheral/i2s_tx/i2s_shift_register.sv"

# ── Modules with Quartus IP submodules ────────────────────────────────────
gen sample_fifo \
    "$HW/room_eq_peripheral/calibration_engine/sample_fifo.sv" \
    "$LAB/capture_fifo.v"

gen sample_fft \
    "$HW/room_eq_peripheral/calibration_engine/sample_fft.sv" \
    "$LAB/capture_fft.v"

gen calibration_engine \
    "$HW/room_eq_peripheral/calibration_engine/calibration_engine.sv" \
    "$HW/room_eq_peripheral/calibration_engine/sample_fifo.sv" \
    "$HW/room_eq_peripheral/calibration_engine/sample_fft.sv" \
    "$HW/memory/fft_results_ram.sv" \
    "$LAB/capture_fifo.v" \
    "$LAB/capture_fft.v"  # stubs already have correct module names

gen room_eq_peripheral \
    "$HW/room_eq_peripheral/room_eq_peripheral.sv" \
    "$HW/room_eq_peripheral/sweep_generator/sweep_generator.sv" \
    "$HW/room_eq_peripheral/sweep_generator/phase_accumulator.sv" \
    "$HW/room_eq_peripheral/sweep_generator/sine_lookup.sv" \
    "$HW/memory/sine_lut.sv" \
    "$HW/room_eq_peripheral/i2s_tx/i2s_tx.sv" \
    "$HW/room_eq_peripheral/i2s_tx/i2s_clock_gen.sv" \
    "$HW/room_eq_peripheral/i2s_tx/i2s_shift_register.sv" \
    "$HW/room_eq_peripheral/i2s_rx/i2s_rx.sv" \
    "$HW/room_eq_peripheral/calibration_engine/calibration_engine.sv" \
    "$HW/room_eq_peripheral/calibration_engine/sample_fifo.sv" \
    "$HW/room_eq_peripheral/calibration_engine/sample_fft.sv" \
    "$HW/memory/fft_results_ram.sv" \
    "$LAB/capture_fifo.v" \
    "$LAB/capture_fft.v"

echo "=== Done. SVGs written to $OUT/ ==="
