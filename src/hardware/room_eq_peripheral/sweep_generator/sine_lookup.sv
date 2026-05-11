// ==================== MODULE INTERFACE ====================
// Sine lookup with linear interpolation using dual BRAMs.
//
// Two copies of the sine LUT read index0 and index1 simultaneously,
// eliminating any pipeline timing issues. The interpolation is purely
// combinational between two registered BRAM outputs.
//
// Pipeline (2 cycles, same as original):
//   Cycle 0 (sample_en): addr_b updates for both BRAMs
//   Cycle 1: BRAM outputs settle (1-cycle read latency)
//   Next sample_en: latch interpolated result
//
// Uses 2x BRAM (48 Kbits out of 4M available = 1.2%).
// ===========================================================

module sine_lookup(
    clock, // 12.288 MHz PLL Generated Clock
    reset,
    sample_en, // Fires every 48 kHz tick
    phase,
    amplitude,
    clk_sys, // System Clock - 50 MHz for LUT initialization
    we_lut, // LUT Write Enable
    addr_lut, // LUT Write Address
    din_lut // LUT Write Data
    );

    input        clock;
    input        reset;
    input        sample_en;
    input [31:0] phase;
    output reg [23:0] amplitude;

    input        clk_sys;
    input        we_lut;
    input  [9:0] addr_lut;
    input [23:0] din_lut;

    // ── Phase decomposition ─────────────────────────────────
    wire [1:0]  quadrant  = phase[31:30];
    wire [9:0]  raw_index = phase[29:20];
    wire [9:0]  frac_bits = phase[19:10];  // 10-bit fraction between entries

    // Quarter-wave mirror with clamped next index
    wire [9:0]  index0 = (quadrant[0]) ? ~raw_index : raw_index;
    wire [9:0]  next_fwd = (raw_index == 10'd1023) ? 10'd1023 : (raw_index + 10'd1);
    wire [9:0]  next_rev = (raw_index == 10'd0)    ? 10'd1023 : (~raw_index - 10'd1);
    wire [9:0]  index1 = (quadrant[0]) ? next_rev : next_fwd;

    // ── Dual BRAMs — both written identically, read different addresses ──
    wire [23:0] lut_out0;  // value at index0
    wire [23:0] lut_out1;  // value at index1

    sine_lut lut0 (
        .clk_a  (clk_sys),
        .we_a   (we_lut),
        .addr_a (addr_lut),
        .din_a  (din_lut),
        .clk_b  (clock),
        .addr_b (index0),
        .dout_b (lut_out0)
    );

    sine_lut lut1 (
        .clk_a  (clk_sys),
        .we_a   (we_lut),
        .addr_a (addr_lut),
        .din_a  (din_lut),
        .clk_b  (clock),
        .addr_b (index1),
        .dout_b (lut_out1)
    );

    // ── Interpolation (combinational from registered BRAM outputs) ──
    // Both lut_out0 and lut_out1 are unsigned quarter-wave values (0..8388607).
    // diff can be negative, so use signed arithmetic.
    wire signed [24:0] s_val0 = {1'b0, lut_out0};
    wire signed [24:0] s_val1 = {1'b0, lut_out1};
    wire signed [24:0] s_diff = s_val1 - s_val0;
    wire signed [34:0] s_product = s_diff * {1'b0, frac_bits};
    wire signed [24:0] s_interp = s_val0 + (s_product >>> 10);
    wire [23:0] interp_val = s_interp[24] ? 24'd0 : s_interp[23:0];

    // ── Output with quadrant and pipeline delay ─────────────
    // Register quadrant in sync with BRAM's 1-cycle read latency.
    reg [1:0] quadrant_d;

    always @(posedge clock or posedge reset) begin
        if (reset)
            quadrant_d <= 2'b00;
        else if (sample_en)
            quadrant_d <= quadrant;
    end

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            amplitude <= 24'd0;
        end else if (sample_en) begin
            case (quadrant_d)
                2'b00: amplitude <=  interp_val;
                2'b01: amplitude <=  interp_val;
                2'b10: amplitude <= -interp_val;
                2'b11: amplitude <= -interp_val;
            endcase
        end
    end

endmodule
