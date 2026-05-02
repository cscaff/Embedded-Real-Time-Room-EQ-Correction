// ==================== MODULE INTERFACE ====================
// Top-level I2S transmitter.  Accepts stereo 24-bit parallel
// samples and serializes them to the WM8731 codec using standard
// Philips I2S format (1-bit delay, MSB-first, 24 data + 8 pad).
//
// Runs entirely in the 12.288 MHz clock domain.  BCLK and LRCK
// are data signals, not clock nets.
//
// Inputs:
//   clock        – 12.288 MHz master clock (from PLL)
//   reset        – active-high synchronous reset
//   left_sample  – 24-bit signed left channel audio
//   right_sample – 24-bit signed right channel audio
//
// Outputs:
//   bclk         – 3.072 MHz bit clock → codec AUD_BCLK
//   lrck         – 48 kHz frame clock  → codec AUD_DACLRCK
//   dacdat       – serial data         → codec AUD_DACDAT
// ===========================================================

module i2s_tx (
    input  logic        clock,
    input  logic        reset,
    input  logic [23:0] left_sample,
    input  logic [23:0] right_sample,
    output logic        bclk,
    output logic        lrck,
    output logic        dacdat
);

    // ── Internal wires ──────────────────────────────────────
    logic        bclk_fall;
    logic [5:0]  bit_cnt;

    // ── Clock generator ─────────────────────────────────────
    i2s_clock_gen clock_gen_inst (
        .clock     (clock),
        .reset     (reset),
        .bclk      (bclk),
        .lrck      (lrck),
        .bclk_fall (bclk_fall),
        .bit_cnt   (bit_cnt)
    );

    // ── Sample holding registers ────────────────────────────
    // Latch both channels at bit_cnt == 62, two BCLK cycles
    // before the left channel load at bit_cnt == 63.
    logic [23:0] left_hold, right_hold;

    always_ff @(posedge clock) begin
        if (reset) begin
            left_hold  <= 24'd0;
            right_hold <= 24'd0;
        end else if (bclk_fall && bit_cnt == 6'd62) begin
            left_hold  <= left_sample;
            right_hold <= right_sample;
        end
    end

    // ── Shift register control ──────────────────────────────
    // The I2S 1-bit delay is handled by:
    //   - LOADing at bit_cnt 63 (left) and 31 (right), which is
    //     1 BCLK cycle BEFORE the LRCK transition.  The MSB
    //     appears on serial_out immediately after load.
    //   - Doing NOTHING at bit_cnt 0 and 32 (the delay slots).
    //     The MSB stays on the output for two BCLK cycles: the
    //     delay slot and the first data slot.
    //   - SHIFTing on all other bit_cnt values.

    wire load_left  = bclk_fall && (bit_cnt == 6'd63);
    wire load_right = bclk_fall && (bit_cnt == 6'd31);
    wire do_load    = load_left || load_right;
    wire do_shift   = bclk_fall && !do_load
                      && (bit_cnt != 6'd0)
                      && (bit_cnt != 6'd32);

    wire [23:0] shift_data = load_left ? left_hold : right_hold;

    // ── Shift register ──────────────────────────────────────
    i2s_shift_register shift_reg_inst (
        .clock      (clock),
        .reset      (reset),
        .data_in    (shift_data),
        .load       (do_load),
        .shift      (do_shift),
        .serial_out (dacdat)
    );

endmodule
