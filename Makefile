IVERILOG = iverilog
VVP      = vvp
FLAGS    = -g2012

SRC_DIR  = src/hardware
TEST_DIR = test/hardware
OUT_DIR  = sim_out

# ── Targets ─────────────────────────────────────────────────────────────────

.PHONY: all sim_phase_acc sim_sine_lut sim_sine_lookup sim_sweep sim_i2s_clk sim_i2s_shift sim_i2s_tx clean

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

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

clean:
	rm -rf $(OUT_DIR)
