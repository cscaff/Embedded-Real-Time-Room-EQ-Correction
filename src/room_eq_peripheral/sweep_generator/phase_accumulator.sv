// The Following code was inspired by: https://github.com/samiyaalizaidi/Direct-Digital-Synthesizer/blob/main/phase_accumulator.v
// ==================== MODULE INTERFACE ====================
// Inputs:
// - clock:     48kHz sample tick (Divided From 12.288MHz PLL Clock)
// - reset:     Active High
//
// Outputs:
// - phase: 32-bit phase accumulator value. Wraps naturally on overflow.
//
// ===========================================================

module phase_accumulator(
    clock,     // 48kHz sample tick (Divided From 12.288MHz PLL Clock)
    reset,     // Active high reset
    phase      // Output: current phase accumulator value
    );

    // Inputs and Outputs:
    input        clock;
    input        reset;
    output reg [31:0] phase;

    // Parameters
    parameter [31:0] INCREMENT_START = 32'd1_789_570; // Initial Phase Increment to get 20 Hz Output.
    parameter [31:0] K_FRAC          = 32'd123_621;   // (K-1)*2^32 where K=exp(ln(1000)/(48000*5))

    // Internal Registers
    reg [31:0] increment = 32'd1789569; // Phase increment

    // Multiply Step


    // Accumulate Step
    always @ (posedge clock or posedge reset) begin
        if (reset) begin
            phase <= 32'd0;
        end else begin
            phase <= phase + increment; // 32-bit register wraps naturally on overflow
        end
    end

endmodule
