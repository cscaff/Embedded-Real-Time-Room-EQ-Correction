IVERILOG = iverilog
VVP      = vvp
FLAGS    = -g2012

SRC_DIR  = src/hardware
TEST_DIR = test/hardware
OUT_DIR  = sim_out

# ── Targets ─────────────────────────────────────────────────────────────────

.PHONY: all sim_phase_acc sim_sine_lut sim_sine_lookup sim_sweep sim_i2s_clk sim_i2s_shift sim_i2s_tx sim_sweep_i2s sim_sweep_i2s_long sim_sweep_i2s_full sim_sweep_i2s_10s sim_fft_result_ram sim_sample_fifo sim_sample_fft sim_calibration_engine sim_room_eq clean

all: sim_phase_acc sim_sine_lut sim_sine_lookup sim_sweep sim_i2s_clk sim_i2s_shift sim_i2s_tx

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

sim_i2s_clk: $(OUT_DIR)/tb_i2s_clock_gen.vvp
	$(VVP) $<

$(OUT_DIR)/tb_i2s_clock_gen.vvp: \
		$(SRC_DIR)/room_eq_peripheral/i2s_tx/i2s_clock_gen.sv \
		$(TEST_DIR)/room_eq_peripheral/i2s_tx/tb_i2s_clock_gen.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

sim_i2s_shift: $(OUT_DIR)/tb_i2s_shift_register.vvp
	$(VVP) $<

$(OUT_DIR)/tb_i2s_shift_register.vvp: \
		$(SRC_DIR)/room_eq_peripheral/i2s_tx/i2s_shift_register.sv \
		$(TEST_DIR)/room_eq_peripheral/i2s_tx/tb_i2s_shift_register.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

sim_i2s_tx: $(OUT_DIR)/tb_i2s_tx.vvp
	$(VVP) $<

$(OUT_DIR)/tb_i2s_tx.vvp: \
		$(SRC_DIR)/room_eq_peripheral/i2s_tx/i2s_clock_gen.sv \
		$(SRC_DIR)/room_eq_peripheral/i2s_tx/i2s_shift_register.sv \
		$(SRC_DIR)/room_eq_peripheral/i2s_tx/i2s_tx.sv \
		$(TEST_DIR)/room_eq_peripheral/i2s_tx/tb_i2s_tx.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

# Sweep sources shared by both integration targets
SWEEP_SRCS = \
	$(SRC_DIR)/memory/sine_lut.sv \
	$(SRC_DIR)/room_eq_peripheral/sweep_generator/phase_accumulator.sv \
	$(SRC_DIR)/room_eq_peripheral/sweep_generator/sine_lookup.sv \
	$(SRC_DIR)/room_eq_peripheral/sweep_generator/sweep_generator.sv

I2S_SRCS = \
	$(SRC_DIR)/room_eq_peripheral/i2s_tx/i2s_clock_gen.sv \
	$(SRC_DIR)/room_eq_peripheral/i2s_tx/i2s_shift_register.sv \
	$(SRC_DIR)/room_eq_peripheral/i2s_tx/i2s_tx.sv

sim_sweep_i2s: $(OUT_DIR)/tb_sweep_i2s.vvp
	$(VVP) $<
	python3 $(TEST_DIR)/room_eq_peripheral/i2s_tx/scripts/play_sweep.py

sim_sweep_i2s_long: $(OUT_DIR)/tb_sweep_i2s_long.vvp
	$(VVP) $<
	python3 $(TEST_DIR)/room_eq_peripheral/i2s_tx/scripts/play_sweep.py

$(OUT_DIR)/tb_sweep_i2s.vvp: \
		$(SWEEP_SRCS) $(I2S_SRCS) \
		$(TEST_DIR)/room_eq_peripheral/i2s_tx/tb_sweep_i2s.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

$(OUT_DIR)/tb_sweep_i2s_long.vvp: \
		$(SWEEP_SRCS) $(I2S_SRCS) \
		$(TEST_DIR)/room_eq_peripheral/i2s_tx/tb_sweep_i2s.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -DN_SAMPLES=120000 -o $@ $^

sim_sweep_i2s_full: $(OUT_DIR)/tb_sweep_i2s_full.vvp
	$(VVP) $<
	python3 $(TEST_DIR)/room_eq_peripheral/i2s_tx/scripts/play_sweep.py

$(OUT_DIR)/tb_sweep_i2s_full.vvp: \
		$(SWEEP_SRCS) $(I2S_SRCS) \
		$(TEST_DIR)/room_eq_peripheral/i2s_tx/tb_sweep_i2s.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -DN_SAMPLES=240000 -o $@ $^

sim_sweep_i2s_10s: $(OUT_DIR)/tb_sweep_i2s_10s.vvp
	$(VVP) $<
	python3 $(TEST_DIR)/room_eq_peripheral/i2s_tx/scripts/play_sweep.py

$(OUT_DIR)/tb_sweep_i2s_10s.vvp: \
		$(SWEEP_SRCS) $(I2S_SRCS) \
		$(TEST_DIR)/room_eq_peripheral/i2s_tx/tb_sweep_i2s.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -DN_SAMPLES=480000 -o $@ $^

# ── Calibration engine unit tests ────────────────────────────────────────────

SIM_DIR = sim

CALIB_SRCS = \
	$(SRC_DIR)/room_eq_peripheral/calibration_engine/sample_fifo.sv \
	$(SRC_DIR)/room_eq_peripheral/calibration_engine/sample_fft.sv \
	$(SRC_DIR)/room_eq_peripheral/calibration_engine/calibration_engine.sv \
	$(SRC_DIR)/memory/fft_results_ram.sv

sim_fft_result_ram: $(OUT_DIR)/tb_fft_result_ram.vvp
	$(VVP) $<

$(OUT_DIR)/tb_fft_result_ram.vvp: \
		$(SRC_DIR)/memory/fft_results_ram.sv \
		$(TEST_DIR)/memory/tb_fft_result_ram.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

sim_sample_fifo: $(OUT_DIR)/tb_sample_fifo.vvp
	$(VVP) $<

$(OUT_DIR)/tb_sample_fifo.vvp: \
		$(SIM_DIR)/capture_fifo.v \
		$(SRC_DIR)/room_eq_peripheral/calibration_engine/sample_fifo.sv \
		$(TEST_DIR)/room_eq_peripheral/calibration_engine/tb_sample_fifo.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

sim_sample_fft: $(OUT_DIR)/tb_sample_fft.vvp
	$(VVP) $<

$(OUT_DIR)/tb_sample_fft.vvp: \
		$(SIM_DIR)/capture_fft_sim.v \
		$(SRC_DIR)/room_eq_peripheral/calibration_engine/sample_fft.sv \
		$(TEST_DIR)/room_eq_peripheral/calibration_engine/tb_sample_fft.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

sim_calibration_engine: $(OUT_DIR)/tb_calibration_engine.vvp
	$(VVP) $<

$(OUT_DIR)/tb_calibration_engine.vvp: \
		$(SIM_DIR)/capture_fifo.v \
		$(SIM_DIR)/capture_fft_sim.v \
		$(CALIB_SRCS) \
		$(TEST_DIR)/room_eq_peripheral/calibration_engine/tb_calibration_engine.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

# ── Top-level integration test ──────────────────────────────────────────────

sim_room_eq: $(OUT_DIR)/tb_room_eq_peripheral.vvp
	$(VVP) $<

$(OUT_DIR)/tb_room_eq_peripheral.vvp: \
		$(SIM_DIR)/capture_fifo.v \
		$(SIM_DIR)/capture_fft_sim.v \
		$(SRC_DIR)/memory/sine_lut.sv \
		$(SRC_DIR)/memory/fft_results_ram.sv \
		$(SWEEP_SRCS) $(I2S_SRCS) \
		$(SRC_DIR)/room_eq_peripheral/i2s_rx/i2s_rx.sv \
		$(CALIB_SRCS) \
		$(SRC_DIR)/room_eq_peripheral/room_eq_peripheral.sv \
		$(TEST_DIR)/room_eq_peripheral/tb_room_eq_peripheral.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

clean:
	rm -rf $(OUT_DIR)
