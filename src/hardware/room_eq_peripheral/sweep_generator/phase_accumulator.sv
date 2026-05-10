// The Following code was inspired by: https://github.com/samiyaalizaidi/Direct-Digital-Synthesizer/blob/main/phase_accumulator.v
// ==================== MODULE INTERFACE ====================
// Inputs:
// - clock:     12.288MHz PLL Generated Clock
// - reset:     Active High
// - sample_en: Fires every 48 kHz tick (Divided From 12.288MHz PLL Clock)
//
// Outputs:
// - phase: 32-bit phase accumulator value. Wraps naturally on overflow.
// - done:  Asserts and latches when increment reaches 20 kHz threshold.
//
// ===========================================================

module phase_accumulator(
    clock,     // 12.288MHz PLL Generated Clock
    reset,     // Active high reset
    sample_en, // Fires every 48 kHz tick (Divided From 12.288MHz PLL Clock)
    phase,     // Output: current phase accumulator value
    done       // Output: latches high when sweep reaches 20 kHz
    );

    // Inputs and Outputs:
    input        clock;
    input        reset;
    input        sample_en;
    output reg [31:0] phase;
    output reg        done;

    // Parameters
    parameter [31:0] INCREMENT_START = 32'd1_789_570;   // Initial Phase Increment to get 20 Hz Output.
    parameter [31:0] K_FRAC          = 32'd30_904;      // (K-1)*2^32 where K=exp(ln(1000)/(48000*20)), 16s to 5kHz
    parameter [31:0] INC_STOP        = 32'd447_392_426;   // increment[63:32] threshold for 5 kHz: (5000/48000)*2^32

    // Internal Registers
    reg [63:0] increment; // Phase increment w/ Q.32.32 (Recommended By Claude. Need to verify if this quantization makes sense.)

    // Multiply Step
    wire [63:0] delta = increment[63:32] * K_FRAC; // Computes growth factor in this cycle (Multiplying integer part of inc and K frac.)
    // Explanation for later when I forget and Stephen Edwards asks me what this means:
    // inc_fixed[63:32] is the integer part of the increment — call it r.
    // K_FRAC = (K-1) × 2^32
    // Product = r × (K-1) × 2^32 = delta
    // delta / 2^32 = r × (K-1)
    // r → r × K (Growth factor applied to increment in next cycle)

    // Accumulate Step
    always @ (posedge clock or posedge reset) begin
        if (reset) begin
            phase     <= 32'd0;
            increment <= {INCREMENT_START, 32'd0};
            done      <= 1'b0;
        end else if (sample_en) begin // Sample Enable Gate
            increment <= increment + delta; // Updates increment for next cycle.
            phase     <= phase + increment[63:32]; // 32-bit register wraps naturally on overflow.
            if (increment[63:32] >= INC_STOP)
                done <= 1'b1;
        end
    end

endmodule
