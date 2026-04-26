// The Following code was inspired by: https://github.com/samiyaalizaidi/Direct-Digital-Synthesizer/blob/main/phase_accumulator.v
// ==================== MODULE INTERFACE ====================
// Inputs:
// - clock:     48kHz sample tick (Divided From 12.288MHz PLL Clock)
// - reset:     Active High
// - increment: 32-bit phase increment, set externally by sweep_controller.
//              Determines instantaneous output frequency:
//              increment = (2^32 * frequency) / sample_rate
//
// Outputs:
// - phase: 32-bit phase accumulator value. Wraps naturally on overflow.
//
// ===========================================================

module phase_accumulator(
    clock,     // 48kHz sample tick (Divided From 12.288MHz PLL Clock)
    reset,     // Active high reset
    increment, // Input: phase increment controlled by sweep_controller
    phase      // Output: current phase accumulator value
    );

    // Inputs and Outputs:
    input        clock;
    input        reset;
    input [31:0] increment; // driven by sweep_controller each sample
    output reg [31:0] phase;

    always @ (posedge clock or posedge reset) begin
        if (reset) begin
            phase <= 32'd0;
        end else begin
            phase <= phase + increment; // 32-bit register wraps naturally on overflow
        end
    end

endmodule
