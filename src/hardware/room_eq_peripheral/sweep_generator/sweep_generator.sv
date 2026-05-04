// ==================== MODULE INTERFACE ====================
// Inputs:
// - clock:    12.288 MHz PLL Generated Clock
// - reset:    Active high
// - clk_sys: 50 MHz system clock, drives BRAM write port
// - we_lut: Write enable (active high). Assert to write a sine value.
// - addr_lut: 8-bit write address (0-255)
// - din_lut: 24-bit signed sine value to store
// - start: Trigger to start the sweep. (Likely needs a 2-FF outside as it derives from a different clock domain)
//
// LUT Initialization Inputs (Port A — 50 MHz system clock):
// Outputs:
// - amplitude: 24-bit signed sine output for the CODEC.
// - done:      Asserts and latches when sweep reaches 20 kHz.
//
// ===========================================================


module sweep_generator(
    clock, // 12.288 MHz PLL Generated Clock
    reset, // Active High Reset
    amplitude, // 24-bit Signed Output Amplitude
    clk_sys, // 50 Mhz System Clock
    we_lut, // LUT Write Enable
    addr_lut, // LUT Write Address
    din_lut, // LUT Write Data
    start, // Start Trigger
    done  // Sweep complete (latches high at 20 kHz)
    );

    // Inputs and outputs:
    input          clock;
    input          reset;
    output  [23:0] amplitude;
    input          clk_sys;
    input          we_lut;
    input    [7:0] addr_lut;
    input   [23:0] din_lut;
    input          start;
    output         done; 

    // Clock Division for Sweep Generation (Convert 12.288 MHz to 48 kHz)
    logic [7:0] clk_div; // 8-bit Counter to divide 12.288 by 256 = 48 kHz
    logic       sample_en; // Sample Enable goes high every wrap around.

    // Register to hold the current state of the sweep generator
    logic sweep_active;

    always_ff @(posedge clock) begin
        if (reset) begin
            clk_div   <= '0;
            sample_en <= 1'b0;
            sweep_active <= 1'b0; // Sweep is not active on reset.
        end else if (start) begin
            sweep_active <= 1'b1; // Sweep becomes active when start signal is asserted.
        end else begin
            sample_en <= (clk_div == 8'd255) & sweep_active & !done; // Assert sample_en when counter wraps. (Sweep must be active and not done).
            clk_div   <= clk_div + 1'b1; // Increment clock divider 
        end
    end

    wire [31:0] phase;

    phase_accumulator mac (
        .clock     (clock),
        .reset     (reset),
        .sample_en (sample_en),
        .phase     (phase)
    );

    sine_lookup lookup (
        .clock     (clock),
        .reset     (reset),
        .sample_en (sample_en),
        .phase     (phase),
        .amplitude(amplitude),
        .clk_sys  (clk_sys),
        .we_lut   (we_lut),
        .addr_lut (addr_lut),
        .din_lut  (din_lut)
    );

endmodule

// Notes:
// Design Choice Explanation Worth Explaining:
// I used a clock divider to generate the 48 kHz sample enable signal
// instead of directly using the 12.288 MHz clock for the phase accumulator and sine lookup. 
// So instead of sending in a 48 KHz clock, we send in the PLL one and a enable signal.
// LLM said that adding a clock conversion would be more complex for static timing analysis?
// We can always change.