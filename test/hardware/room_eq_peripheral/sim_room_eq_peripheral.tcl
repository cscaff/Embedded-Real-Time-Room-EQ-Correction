# ── sim_room_eq_peripheral.tcl ────────────────────────────────────────────────
# Questa FSE simulation for tb_room_eq_peripheral using the real Altera FFT II IP.
# Runs gen_golden_fft.py first (via Makefile) to generate sim_out/fft_*.hex.
#
# HOW TO RUN — see Makefile target sim_room_eq_peripheral, or manually:
#   set PR=C:\Users\chris\OneDrive\Desktop\CSEE4840\Embedded-Real-Time-Room-EQ-Correction
#   set TS=%PR%\test\hardware\room_eq_peripheral\sim_room_eq_peripheral.tcl
#   C:\altera_lite\25.1std\questa_fse\win64\vsim.exe -c -do "set PROJ_ROOT {%PR%}; source {%TS%}"
# ─────────────────────────────────────────────────────────────────────────────

set QUESTA_HOME "C:/altera_lite/25.1std/questa_fse"

if {![info exists PROJ_ROOT]} {
    puts "ERROR: PROJ_ROOT is not set. Run vsim with:"
    puts {  vsim -c -do "set PROJ_ROOT {<abs-path-to-repo>}; source {<this-script>}"}
    quit -f
}
set PROJ_ROOT  [file normalize $PROJ_ROOT]
set SCRIPT_DIR [file normalize "$PROJ_ROOT/test/hardware/room_eq_peripheral"]

# Paths into the qsys-generated FFT simulation tree
set FFT_SIM "$PROJ_ROOT/quartus/ip/room_eq_peripheral/capture_fft/capture_fft/simulation/simulation"
set FFT_SUB "$FFT_SIM/submodules"
set FFT_MEN "$FFT_SIM/submodules/mentor"

# ── Clean previous artifacts ──────────────────────────────────────────────────
if {[file exists work]}     { vdel -all -lib work }
if {[file exists fft_ii_0]} { vdel -all -lib fft_ii_0 }

# ── Create libraries ──────────────────────────────────────────────────────────
vlib work
vlib fft_ii_0
vmap fft_ii_0 fft_ii_0

# ── Map pre-compiled Questa FSE Altera libraries ──────────────────────────────
vmap altera_mf_ver    "$QUESTA_HOME/intel/verilog/altera_mf"
vmap altera_lnsim_ver "$QUESTA_HOME/intel/verilog/altera_lnsim"
vmap cyclonev_ver     "$QUESTA_HOME/intel/verilog/cyclonev"
vmap altera_ver       "$QUESTA_HOME/intel/verilog/altera"

# ── Copy twiddle-factor hex files to CWD so VHDL $readmemh finds them ────────
cd $PROJ_ROOT
foreach hex [glob "$FFT_SUB/*.hex"] {
    file copy -force $hex .
}

# ── Compile FFT II IP VHDL submodules into fft_ii_0 (msim_setup.tcl order) ───
foreach f {
    auk_dspip_text_pkg.vhd
    auk_dspip_math_pkg.vhd
    auk_dspip_lib_pkg.vhd
} { vcom -work fft_ii_0 "$FFT_SUB/$f" }

vcom -work fft_ii_0 "$FFT_MEN/auk_dspip_avalon_streaming_block_sink.vhd"
vcom -work fft_ii_0 "$FFT_MEN/auk_dspip_avalon_streaming_block_source.vhd"
vcom -work fft_ii_0 "$FFT_SUB/auk_dspip_roundsat.vhd"
vcom -work fft_ii_0 "$FFT_MEN/apn_fft_mult_can.vhd"
vlog -work fft_ii_0 "$FFT_MEN/apn_fft_mult_cpx_1825.v"
vcom -work fft_ii_0 "$FFT_MEN/apn_fft_mult_cpx.vhd"
vcom -work fft_ii_0 "$FFT_MEN/hyper_opt_OFF_pkg.vhd"
vcom -work fft_ii_0 "$FFT_MEN/altera_fft_dual_port_ram.vhd"
vcom -work fft_ii_0 "$FFT_MEN/altera_fft_dual_port_rom.vhd"
vcom -work fft_ii_0 "$FFT_MEN/altera_fft_mult_add.vhd"
vcom -work fft_ii_0 "$FFT_MEN/altera_fft_single_port_rom.vhd"
vcom -work fft_ii_0 "$FFT_MEN/auk_fft_pkg.vhd"
vlog -work fft_ii_0 "$FFT_MEN/hyper_pipeline_interface.v"
vlog -sv  -work fft_ii_0 "$FFT_MEN/counter_module.sv"

foreach f {
    auk_dspip_r22sdf_lib_pkg.vhd
    auk_dspip_bit_reverse_addr_control.vhd
    auk_dspip_bit_reverse_core.vhd
    auk_dspip_bit_reverse_reverse_carry_adder.vhd
    auk_dspip_r22sdf_adder_fp.vhd
    auk_dspip_r22sdf_addsub.vhd
    auk_dspip_r22sdf_bfi.vhd
    auk_dspip_r22sdf_bfii.vhd
    auk_dspip_r22sdf_bf_control.vhd
    auk_dspip_r22sdf_cma.vhd
    auk_dspip_r22sdf_cma_adder_fp.vhd
    auk_dspip_r22sdf_cma_bfi_fp.vhd
    auk_dspip_r22sdf_cma_fp.vhd
    auk_dspip_r22sdf_core.vhd
    auk_dspip_r22sdf_counter.vhd
    auk_dspip_r22sdf_delay.vhd
    auk_dspip_r22sdf_enable_control.vhd
    auk_dspip_r22sdf_stage.vhd
    auk_dspip_r22sdf_stg_out_pipe.vhd
    auk_dspip_r22sdf_stg_pipe.vhd
    auk_dspip_r22sdf_top.vhd
    auk_dspip_r22sdf_twrom.vhd
} { vcom -work fft_ii_0 "$FFT_MEN/$f" }

vlog -sv -work fft_ii_0 "$FFT_SUB/capture_fft_fft_ii_0.sv"
vlog     -work work      "$FFT_SIM/capture_fft.v"

# ── Altera IP: capture_fifo (DCFIFO) ─────────────────────────────────────────
vlog -work work "$PROJ_ROOT/quartus/ip/room_eq_peripheral/capture_fifo/capture_fifo.v"

# ── Design sources (bottom-up dependency order) ───────────────────────────────
# Memory
vlog -sv -work work "$PROJ_ROOT/src/hardware/memory/sine_lut.sv"
vlog -sv -work work "$PROJ_ROOT/src/hardware/memory/fft_results_ram.sv"

# Sweep generator hierarchy
vlog -sv -work work "$PROJ_ROOT/src/hardware/room_eq_peripheral/sweep_generator/phase_accumulator.sv"
vlog -sv -work work "$PROJ_ROOT/src/hardware/room_eq_peripheral/sweep_generator/sine_lookup.sv"
vlog -sv -work work "$PROJ_ROOT/src/hardware/room_eq_peripheral/sweep_generator/sweep_generator.sv"

# I2S TX hierarchy
vlog -sv -work work "$PROJ_ROOT/src/hardware/room_eq_peripheral/i2s_tx/i2s_clock_gen.sv"
vlog -sv -work work "$PROJ_ROOT/src/hardware/room_eq_peripheral/i2s_tx/i2s_shift_register.sv"
vlog -sv -work work "$PROJ_ROOT/src/hardware/room_eq_peripheral/i2s_tx/i2s_tx.sv"

# Calibration engine hierarchy
vlog -sv -work work "$PROJ_ROOT/src/hardware/room_eq_peripheral/calibration_engine/sample_fifo.sv"
vlog -sv -work work "$PROJ_ROOT/src/hardware/room_eq_peripheral/calibration_engine/sample_fft.sv"
vlog -sv -work work "$PROJ_ROOT/src/hardware/room_eq_peripheral/calibration_engine/calibration_engine.sv"

# Top-level peripheral
vlog -sv -work work "$PROJ_ROOT/src/hardware/room_eq_peripheral/room_eq_peripheral.sv"

# ── Compile testbench with QUESTA_PERIPHERAL defined ─────────────────────────
vlog -sv +define+QUESTA_PERIPHERAL -work work "$SCRIPT_DIR/tb_room_eq_peripheral.sv"

# ── Elaborate and run ─────────────────────────────────────────────────────────
vsim -t 1ps \
    -L work \
    -L fft_ii_0 \
    -L altera_mf_ver \
    -L altera_lnsim_ver \
    -L cyclonev_ver \
    -L altera_ver \
    tb_room_eq_peripheral

run -all
quit
