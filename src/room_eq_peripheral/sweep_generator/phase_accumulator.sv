// The Following code was inspired by: https://github.com/samiyaalizaidi/Direct-Digital-Synthesizer/blob/main/phase_accumulator.v

module phase_accumulator(
    clock, // This will be our 12.288MHz clock from the PLL
    reset, // Let's say active high reset for now.
    phase, // Output: Phase Accumulator value
    );

    // Constant Params:

    // Increment determines our output frequency.
    // Formula: phase_inc = (2 * pi * frequency) / sample_rate
    // Our codec sample rate is 48kHz, so for a 20Hz tone,
    // (2 * pi * 20) / 48000 = 0.00261799387
    // We represent our 2 * pi as a 32-bit fixed point integer that wraps.
    // (2^32 * 20) / 48000 = 0.1789569.70667
    parameter increment = 32'd1789569; 

    // Inputs and Outputs:
    input clock;
    input reset;

    output reg [31:0] phase; // 32-bit phase accumulator which is our equivalent of 2 * pi in fixed point i.e. total phase.

    always @ (posedge clock or posedge reset) begin
        if (reset) begin
            phase <= 32'd0; // Reset phase to 0 on reset.
        end else begin
            phase <= phase + increment; // Increment phase by our defined increment, 32-bit register will auto wrap on overflow.
        end
    end


endmodule