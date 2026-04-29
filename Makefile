IVERILOG      = iverilog
VVP           = vvp
FLAGS         = -g2012
ALTERA_SIM_LIB = C:/altera_lite/25.1std/quartus/eda/sim_lib

SRC_DIR   = src/hardware
TEST_DIR  = test/hardware
OUT_DIR   = sim_out

FIFO_TEST_DIR = $(TEST_DIR)/room_eq_peripheral/calibration_engine

# ── Targets ─────────────────────────────────────────────────────────────────

.PHONY: all sim_phase_acc sim_sine_lut sim_sine_lookup sim_sweep sim_sample_fifo clean

all: sim_phase_acc sim_sine_lut sim_sine_lookup sim_sweep sim_sample_fifo

sim_phase_acc: $(OUT_DIR)/tb_phase_accumulator.vvp
	$(VVP) $<

$(OUT_DIR)/tb_phase_accumulator.vvp: \
		$(SRC_DIR)/room_eq_peripheral/sweep_generator/phase_accumulator.sv \
		$(TEST_DIR)/room_eq_peripheral/sweep_generator/tb_phase_accumulator.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

sim_sine_lut: $(OUT_DIR)/tb_sine_lut.vvp
	$(VVP) $<

$(OUT_DIR)/tb_sine_lut.vvp: \
		$(SRC_DIR)/memory/sine_lut.sv \
		$(TEST_DIR)/memory/sine_lut.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

sim_sine_lookup: $(OUT_DIR)/tb_sine_lookup.vvp
	$(VVP) $<
	python3 $(TEST_DIR)/room_eq_peripheral/sweep_generator/scripts/plot_sine.py

$(OUT_DIR)/tb_sine_lookup.vvp: \
		$(SRC_DIR)/memory/sine_lut.sv \
		$(SRC_DIR)/room_eq_peripheral/sweep_generator/sine_lookup.sv \
		$(TEST_DIR)/room_eq_peripheral/sweep_generator/tb_sine_lookup.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

sim_sweep: $(OUT_DIR)/tb_sweep_generator.vvp
	$(VVP) $<
	python3 $(TEST_DIR)/room_eq_peripheral/sweep_generator/scripts/plot_sweep.py

$(OUT_DIR)/tb_sweep_generator.vvp: \
		$(SRC_DIR)/memory/sine_lut.sv \
		$(SRC_DIR)/room_eq_peripheral/sweep_generator/phase_accumulator.sv \
		$(SRC_DIR)/room_eq_peripheral/sweep_generator/sine_lookup.sv \
		$(SRC_DIR)/room_eq_peripheral/sweep_generator/sweep_generator.sv \
		$(TEST_DIR)/room_eq_peripheral/sweep_generator/tb_sweep_generator.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

sim_sample_fifo: $(OUT_DIR)/tb_sample_fifo.vvp
	$(VVP) $<

$(OUT_DIR)/tb_sample_fifo.vvp: \
		$(ALTERA_SIM_LIB)/altera_mf.v \
		quartus/ip/room_eq_peripheral/capture_fifo/capture_fifo.v \
		$(SRC_DIR)/room_eq_peripheral/calibration_engine/sample_fifo.sv \
		$(FIFO_TEST_DIR)/tb_sample_fifo.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -DALTERA_RESERVED_QIS -o $@ $^

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

clean:
	rm -rf $(OUT_DIR)
