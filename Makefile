IVERILOG = iverilog
VVP      = vvp
FLAGS    = -g2012

SRC_DIR  = src
TEST_DIR = test
OUT_DIR  = sim_out

# ── Targets ─────────────────────────────────────────────────────────────────

.PHONY: all sim_phase_acc clean

all: sim_phase_acc

sim_phase_acc: $(OUT_DIR)/tb_phase_accumulator.vvp
	$(VVP) $<

$(OUT_DIR)/tb_phase_accumulator.vvp: \
		$(SRC_DIR)/room_eq_peripheral/sweep_generator/phase_accumulator.sv \
		$(TEST_DIR)/sweep_generator/tb_phase_accumulator.sv \
		| $(OUT_DIR)
	$(IVERILOG) $(FLAGS) -o $@ $^

$(OUT_DIR):
	mkdir -p $(OUT_DIR)

clean:
	rm -rf $(OUT_DIR)
