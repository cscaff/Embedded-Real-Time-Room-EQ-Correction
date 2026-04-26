// ==================== MODULE INTERFACE ====================
// Inputs:
// - clock:    48kHz sample clock (Divided from 12.288MHz PLL)
// - reset:    Active high
// - phase:    32-bit phase accumulator value
//
// LUT Initialization Inputs (Port A — 50 MHz system clock):
// - clk_sys:  50 MHz system clock, drives BRAM write port
// - we_lut:   Write enable (active high). Assert to write a sine value.
// - addr_lut: 8-bit write address (0-255)
// - din_lut:  24-bit signed sine value to store
//
// Outputs:
// - amplitude: 24-bit signed sine output for the CODEC.
//              Valid 2 clock cycles after phase is presented (2-cycle pipeline).
//
// ===========================================================

module sine_lookup(
    clock,
    reset,
    phase,
    amplitude,
    clk_sys,
    we_lut,
    addr_lut,
    din_lut
    );

    // Inputs and Outputs:
    input        clock;
    input        reset;
    input [31:0] phase;
    output reg [23:0] amplitude;

    // Port A — LUT initialization (driven by top-level init controller)
    input        clk_sys;
    input        we_lut;
    input  [7:0] addr_lut;
    input [23:0] din_lut;

    // Determining the quadrant and LUT index from the phase accumulator:
    // Q1 (00): output = lut_out               forward, positive
    // Q2 (01): output = lut_out read backwards, positive
    // Q3 (10): output = lut_out               forward, negative
    // Q4 (11): output = lut_out read backwards, negative

    wire [1:0] quadrant  = phase[31:30];
    wire [7:0] lut_index = (quadrant[0]) ? ~phase[29:22] : phase[29:22];

    // BRAM output wire — 1-cycle read latency handled inside sine_lut.
    wire [23:0] lut_out;

    // Instantiate sine_lut BRAM.
    // Port A driven from outside via clk_sys/we_lut/addr_lut/din_lut.
    // Port B driven by the 48 kHz sample clock and lut_index.
    sine_lut lut (
        .clk_a  (clk_sys),
        .we_a   (we_lut),
        .addr_a (addr_lut),
        .din_a  (din_lut),
        .clk_b  (clock),
        .addr_b (lut_index),
        .dout_b (lut_out)
    );

    // Register quadrant in sync with the BRAM's 1-cycle read pipeline.
    reg [1:0] quadrant_d;

    always @ (posedge clock or posedge reset) begin
        if (reset)
            quadrant_d <= 2'b00;
        else
            quadrant_d <= quadrant;
    end

    // Output logic based on quadrant (cycle 2 of pipeline).
    always @ (posedge clock or posedge reset) begin
        if (reset) begin
            amplitude <= 24'd0;
        end else begin
            case (quadrant_d)
                2'b00: amplitude <=  lut_out;  // Q1: forward,  positive
                2'b01: amplitude <=  lut_out;  // Q2: backward, positive
                2'b10: amplitude <= -lut_out;  // Q3: forward,  negative
                2'b11: amplitude <= -lut_out;  // Q4: backward, negative
            endcase
        end
    end

endmodule
