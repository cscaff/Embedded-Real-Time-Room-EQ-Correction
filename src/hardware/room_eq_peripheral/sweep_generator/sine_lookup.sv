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

    // ── Interpolation (registered pipeline) ────────────────
    // Stage 1: register BRAM outputs and diff (on any clock, always running)
    // Stage 2: register product
    // Stage 3: register final interp result
    // These registers break the long combinational path (multiply + add)
    // so it meets timing at 12.288 MHz.

    reg signed [24:0] r_val0;
    reg signed [24:0] r_diff;
    reg [9:0]  r_frac;
    reg [1:0]  r_quad1;  // quadrant delayed 1 cycle
    reg [1:0]  r_quad2;  // quadrant delayed 2 cycles
    reg [1:0]  r_quad3;  // quadrant delayed 3 cycles

    // Stage 1: capture BRAM outputs, compute diff
    always @(posedge clock or posedge reset) begin
        if (reset) begin
            r_val0  <= 0;
            r_diff  <= 0;
            r_frac  <= 0;
            r_quad1 <= 0;
        end else begin
            r_val0  <= {1'b0, lut_out0};
            r_diff  <= {1'b0, lut_out1} - {1'b0, lut_out0};
            r_frac  <= frac_bits;
            r_quad1 <= quadrant;
        end
    end

    // Stage 2: multiply
    reg signed [34:0] r_product;
    reg signed [24:0] r_val0_d;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            r_product <= 0;
            r_val0_d  <= 0;
            r_quad2   <= 0;
        end else begin
            r_product <= r_diff * {1'b0, r_frac};
            r_val0_d  <= r_val0;
            r_quad2   <= r_quad1;
        end
    end

    // Stage 3: add and clamp
    reg [23:0] r_interp;

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            r_interp <= 0;
            r_quad3  <= 0;
        end else begin
            reg signed [24:0] sum;
            sum = r_val0_d + (r_product >>> 10);
            r_interp <= sum[24] ? 24'd0 : sum[23:0];
            r_quad3  <= r_quad2;
        end
    end

    // ── Output: apply quadrant sign ─────────────────────────
    // r_interp and r_quad3 are stable and registered.
    // Update amplitude on sample_en (once per 256 clocks).
    // The 3-stage interpolation pipeline runs continuously and
    // settles well before the next sample_en.

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            amplitude <= 24'd0;
        end else if (sample_en) begin
            case (r_quad3)
                2'b00: amplitude <=  r_interp;
                2'b01: amplitude <=  r_interp;
                2'b10: amplitude <= -r_interp;
                2'b11: amplitude <= -r_interp;
            endcase
        end
    end

endmodule
