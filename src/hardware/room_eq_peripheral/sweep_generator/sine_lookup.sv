// ==================== MODULE INTERFACE ====================
// Sine lookup with linear interpolation between adjacent LUT entries.
// Eliminates staircase aliasing at high frequencies.
//
// Pipeline (5 stages after sample_en, plenty of time in 256-clock frame):
//   Stage 0: present index0 to BRAM
//   Stage 1: BRAM latency — wait for lut_out to settle
//   Stage 2: latch val0, present index1 to BRAM
//   Stage 3: BRAM latency — wait for lut_out to settle
//   Stage 4: latch val1, interpolate, apply quadrant, output
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
    wire [9:0]  frac_bits = phase[19:10];  // 10-bit fraction between LUT entries

    // Quarter-wave mirror: in Q2/Q4 read backwards
    // Clamp index1 to prevent wrap-around at boundaries
    wire [9:0]  index0 = (quadrant[0]) ? ~raw_index : raw_index;
    wire [9:0]  next_fwd = (raw_index == 10'd1023) ? 10'd1023 : (raw_index + 10'd1);
    wire [9:0]  next_rev = (raw_index == 10'd0)    ? 10'd1023 : (~raw_index - 10'd1);
    wire [9:0]  index1 = (quadrant[0]) ? next_rev : next_fwd;

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
    reg [2:0] pipe_state;
    reg [23:0] val0;
    reg [1:0]  quad_saved;
    reg [9:0]  frac_saved;
    reg [9:0]  index1_saved;

    // Interpolation math (combinational, used in stage 4)
    wire signed [24:0] w_val0 = {1'b0, val0};
    wire signed [24:0] w_val1 = {1'b0, lut_out};
    wire signed [24:0] w_diff = w_val1 - w_val0;
    wire signed [34:0] w_product = w_diff * {1'b0, frac_saved};
    wire signed [24:0] w_interp = w_val0 + (w_product >>> 10);
    wire [23:0] interp_clamp = w_interp[24] ? 24'd0 : w_interp[23:0];

    always @(posedge clock or posedge reset) begin
        if (reset) begin
            pipe_state   <= 3'd0;
            bram_addr    <= 10'd0;
            val0         <= 24'd0;
            quad_saved   <= 2'b00;
            frac_saved   <= 10'd0;
            index1_saved <= 10'd0;
            amplitude    <= 24'd0;
        end else begin
            case (pipe_state)
                3'd0: begin
                    if (sample_en) begin
                        bram_addr    <= index0;
                        index1_saved <= index1;
                        quad_saved   <= quadrant;
                        frac_saved   <= frac_bits;
                        pipe_state   <= 3'd1;
                    end
                end
                3'd1: begin
                    // Wait: BRAM is reading index0
                    pipe_state <= 3'd2;
                end
                3'd2: begin
                    // lut_out now has val at index0
                    val0      <= lut_out;
                    bram_addr <= index1_saved;
                    pipe_state <= 3'd3;
                end
                3'd3: begin
                    // Wait: BRAM is reading index1
                    pipe_state <= 3'd4;
                end
                3'd4: begin
                    // lut_out now has val at index1, interpolate
                    case (quad_saved)
                        2'b00: amplitude <=  interp_clamp;
                        2'b01: amplitude <=  interp_clamp;
                        2'b10: amplitude <= -interp_clamp;
                        2'b11: amplitude <= -interp_clamp;
                    endcase
                    pipe_state <= 3'd0;
                end
                default: pipe_state <= 3'd0;
            endcase
        end
    end

endmodule
