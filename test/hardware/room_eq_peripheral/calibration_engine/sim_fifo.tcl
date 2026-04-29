# ── sim_fifo.tcl ──────────────────────────────────────────────────────────────
# Questa FSE simulation for tb_sample_fifo.
#
# HOW TO RUN (from this script's directory):
#   C:\altera_lite\25.1std\questa_fse\win64\vsim.exe -c -do sim_fifo.tcl
#
# The -c flag runs in batch (console) mode so $finish exits cleanly.
# Drop -c to open the Questa GUI instead.
# ──────────────────────────────────────────────────────────────────────────────

set QUESTA_HOME "C:/altera_lite/25.1std/questa_fse"
set SCRIPT_DIR  [file normalize [file dirname [info script]]]
set PROJ_ROOT   [file normalize "$SCRIPT_DIR/../../../../"]

# ── Clean previous artifacts ──────────────────────────────────────────────────
if {[file exists work]} { vdel -all -lib work }

# ── Create work library ───────────────────────────────────────────────────────
vlib work

# ── Map pre-compiled Altera simulation libraries ──────────────────────────────
vmap altera_mf_ver   "$QUESTA_HOME/intel/verilog/altera_mf"
vmap altera_lnsim_ver "$QUESTA_HOME/intel/verilog/altera_lnsim"
vmap cyclonev_ver    "$QUESTA_HOME/intel/verilog/cyclonev"
vmap altera_ver      "$QUESTA_HOME/intel/verilog/altera"

# ── Compile design files ──────────────────────────────────────────────────────
vlog "$PROJ_ROOT/quartus/ip/room_eq_peripheral/capture_fifo/capture_fifo.v"
vlog -sv "$PROJ_ROOT/src/hardware/room_eq_peripheral/calibration_engine/sample_fifo.sv"
vlog -sv "$SCRIPT_DIR/tb_sample_fifo.sv"

# ── Elaborate and run ─────────────────────────────────────────────────────────
vsim -t 1ps \
    -L altera_mf_ver \
    -L altera_lnsim_ver \
    -L cyclonev_ver \
    -L altera_ver \
    tb_sample_fifo

run -all
quit
