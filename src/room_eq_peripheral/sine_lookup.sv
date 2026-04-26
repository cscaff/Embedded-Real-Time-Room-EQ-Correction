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
    output [23:0] amplitude; // 24-bit amplitude control for the CODEC
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

    // Initialize BRAM (LUT w/ 256 entries of 24-bit signed values)
    // Motivation for 256 entries: Maps tp 8 bits of phase accumulator.
    // I think the idea is that is sufficient resolution for our sine wave. We can always adjust.
    reg [23:0] sine_lut [255:0];

    // Delayed Output Registers to align with BRAM read latency. (I am assuming 1 cycle).
    reg [23:0] lut_out;
    reg [1:0] quadrant_d;

    // On clock edge, read from the LUT and store the output and quadrant for use in the next cycle.
    always @ (posedge clock or posedge reset) begin
        if (reset) begin
            lut_out <= 24'd0; // Reset LUT output to 0 on reset.
            quadrant_d <= 2'b00; // Reset delayed quadrant to 0 on reset.
        end else begin
            lut_out <= sine_lut[lut_index]; // Read from LUT using the calculated index
            quadrant_d <= quadrant; // Store the current quadrant for use in the next cycle
        end
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