IVERILOG = iverilog
VVP      = vvp
FLAGS    = -g2012

SRC_DIR  = src
TEST_DIR = test
OUT_DIR  = sim_out

# ── Targets ─────────────────────────────────────────────────────────────────

.PHONY: all sim_phase_acc sim_sine_lut sim_sine_lookup clean

all: sim_phase_acc sim_sine_lut sim_sine_lookup

sim_phase_acc: $(OUT_DIR)/tb_phase_accumulator.vvp
	$(VVP) $<

$(OUT_DIR)/tb_phase_accumulator.vvp: \
		$(SRC_DIR)/room_eq_peripheral/sweep_generator/phase_accumulator.sv \
		$(TEST_DIR)/sweep_generator/tb_phase_accumulator.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

sim_sine_lut: $(OUT_DIR)/tb_sine_lut.vvp
	$(VVP) $<

$(OUT_DIR)/tb_sine_lut.vvp: \
		$(SRC_DIR)/room_eq_peripheral/sweep_generator/sine_lut.sv \
		$(TEST_DIR)/sweep_generator/sine_lut.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

sim_sine_lookup: $(OUT_DIR)/tb_sine_lookup.vvp
	$(VVP) $<
	python3 $(TEST_DIR)/sweep_generator/scripts/plot_sine.py

$(OUT_DIR)/tb_sine_lookup.vvp: \
		$(SRC_DIR)/room_eq_peripheral/sweep_generator/sine_lut.sv \
		$(SRC_DIR)/room_eq_peripheral/sine_lookup.sv \
		$(TEST_DIR)/sweep_generator/sine_lookup.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

clean:
	rm -rf $(OUT_DIR)
