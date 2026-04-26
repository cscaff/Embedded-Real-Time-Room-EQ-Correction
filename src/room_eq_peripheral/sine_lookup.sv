// ==================== MODULE INTERFACE ====================
// Inputs:
// - clock: 48kHz sample tick (Divided From 12.288MHz
// - reset: Active High
// - phase: 32-bit phase accumulator (Tells us where we are in the waveform cycle.)
//
// Outputs:
// - amplitude: 24-bit signed output for the CODEC, representing the sine wave value
//
// ===========================================================

module sine_lookup(
    clock, // 48kHz sample tick (Divided From 12.288MHz PLL Clock)
    reset, // Active High Reset
    phase, // Input: 32-bit phase accumulator
    amplitude, // Output: amplitude control (Assuming 24 bit for the CODEC)
    );

    // Inputs and Outputs:
    input clock;
    input reset;
    input [31:0] phase; // 32-bit phase accumulator
    output reg [23:0] amplitude; // 24-bit amplitude control for the CODEC
    // My understanding is that the CODEC expects a 24-bit value so that's what is supplied?

    // Determining the quadrant and LUT index from the phase accumulator:
    // Q1 (00): output = lut_out               forward, positive
    // Q2 (01): output = lut_out read backwards, positive  
    // Q3 (10): output = lut_out               forward, negative
    // Q4 (11): output = lut_out read backwards, negative

    // which quadrant are we in (Upper 2 bits of phase)
    wire [1:0]  quadrant  = phase[31:30];
    // where within that quadrant (Next 8 bits of phase, ignore the rest as noise) 
    // Assuming quadrant[0] reads LSB bit, then we read the LUT backwards for Q2 and Q4.
    wire [7:0] lut_index = (quadrant[0]) ? ~phase[29:22] : phase[29:22];

    // BRAM output wire — 1-cycle read latency is handled inside sine_lut.
    wire [23:0] lut_out;

    // Instantiate sine_lut BRAM.
    // Port A (write) is tied off here — init writes come from the top level, not sine_lookup.
    // Port B (read) is driven by the 48 kHz sample clock and lut_index.
    sine_lut lut (
        .clk_a  (clock),    // tied to sample clock; Port A unused (we_a = 0). Unsure if I need to change this a little?
        .we_a   (1'b0),
        .addr_a (8'b0),
        .din_a  (24'b0),
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

    // Output logic based on the quadrant:
    always @ (posedge clock or posedge reset) begin
        if (reset) begin
            amplitude <= 24'd0;
        end else begin
            case (quadrant_d)
                2'b00: amplitude <= lut_out; // Q1: forward, positive
                2'b01: amplitude <= lut_out; // Q2: backward, positive (LUT read backwards via index calculation)
                2'b10: amplitude <= -lut_out; // Q3: forward, negative
                2'b11: amplitude <= -lut_out; // Q4: backward, negative (LUT read backwards via index calculation)
            endcase
        end
    end
    
endmodule