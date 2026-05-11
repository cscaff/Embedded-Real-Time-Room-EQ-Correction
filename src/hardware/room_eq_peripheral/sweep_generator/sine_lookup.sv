// ==================== MODULE INTERFACE ====================
// Sine lookup with linear interpolation between adjacent LUT entries.
// Eliminates staircase aliasing at high frequencies where the phase
// increment skips many LUT entries per sample.
//
// Pipeline (3 stages after sample_en):
//   Cycle 0: present addr_b = index0 to BRAM
//   Cycle 1: latch lut_out0, present addr_b = index1
//   Cycle 2: latch lut_out1, interpolate, apply quadrant, output
//
// At 12.288 MHz with 256 clocks per sample, the 3-cycle pipeline
// completes well before the next sample_en.
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
    wire [9:0]  frac_bits = phase[19:10];  // fractional part between LUT entries

    // Quarter-wave mirror: in Q2/Q4 read backwards
    wire [9:0]  index0 = (quadrant[0]) ? ~raw_index       : raw_index;
    wire [9:0]  index1 = (quadrant[0]) ? (~raw_index - 1) : (raw_index + 1);

    // ── BRAM ────────────────────────────────────────────────
    wire [23:0] lut_out;
    reg  [9:0]  bram_addr;

    sine_lut lut (
        .clk_a  (clk_sys),
        .we_a   (we_lut),
        .addr_a (addr_lut),
        .din_a  (din_lut),
        .clk_b  (clock),
        .addr_b (bram_addr),
        .dout_b (lut_out)
    );

    // ── Interpolation pipeline ──────────────────────────────
    reg [1:0] pipe_state;
    reg [23:0] val0;
    reg [1:0]  quad_saved;
    reg [9:0]  frac_saved;

    // Interpolation math as combinational wires (no reg inside always)
    wire signed [24:0] w_diff    = {1'b0, lut_out} - {1'b0, val0};
    wire signed [34:0] w_product = w_diff * $signed({1'b0, frac_saved});
    wire signed [24:0] w_interp  = {1'b0, val0} + w_product[34:10];
    wire [23:0] interp_out = w_interp[23:0];

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            pipe_state <= 2'd0;
            bram_addr  <= 10'd0;
            val0       <= 24'd0;
            quad_saved <= 2'b00;
            frac_saved <= 10'd0;
            amplitude  <= 24'd0;
        end else begin
            case (pipe_state)
                2'd0: begin
                    if (sample_en) begin
                        bram_addr  <= index0;
                        quad_saved <= quadrant;
                        frac_saved <= frac_bits;
                        pipe_state <= 2'd1;
                    end
                end
                2'd1: begin
                    val0       <= lut_out;
                    bram_addr  <= index1;
                    pipe_state <= 2'd2;
                end
                2'd2: begin
                    case (quad_saved)
                        2'b00: amplitude <=  interp_out;
                        2'b01: amplitude <=  interp_out;
                        2'b10: amplitude <= -interp_out;
                        2'b11: amplitude <= -interp_out;
                    endcase
                    pipe_state <= 2'd0;
                end
                default: pipe_state <= 2'd0;
            endcase
        end
    end

endmodule
