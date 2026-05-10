// ==================== MODULE INTERFACE ====================
// Inputs:
// - clock:    12.288 MHz PLL Generated Clock
// - reset:    Active high
// - clk_sys: 50 MHz system clock, drives BRAM write port
// - we_lut: Write enable (active high). Assert to write a sine value.
// - addr_lut: 10-bit write address (0-1023)
// - din_lut: 24-bit signed sine value to store
// - start: Trigger to start the sweep (needs 2-FF outside as it crosses clock domains)
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
    input    [9:0] addr_lut;
    input   [23:0] din_lut;
    input          start;
    output         done;

    // Clock Division for Sweep Generation (Convert 12.288 MHz to 48 kHz)
    logic [7:0] clk_div; // 8-bit Counter to divide 12.288 by 256 = 48 kHz
    logic       sample_en; // Sample Enable goes high every wrap around.

    // Register to hold the current state of the sweep generator
    logic sweep_active;

    // Reset phase_accumulator on system reset OR new start pulse
    // so the sweep can be re-triggered from DONE state.
    wire sweep_reset_internal = reset | start;

    always_ff @(posedge clock) begin
        if (reset) begin
            clk_div   <= '0;
            sample_en <= 1'b0;
            sweep_active <= 1'b0;
        end else if (start) begin
            sweep_active <= 1'b1;
            clk_div   <= '0;
            sample_en <= 1'b0;
        end else begin
            sample_en <= (clk_div == 8'd255) & sweep_active & !done;
            clk_div   <= clk_div + 1'b1;
        end
    end

    wire [31:0] phase;

    // Internal Amplitude from sine lookup
    wire [23:0] amplitude_internal;
    assign amplitude = done ? 24'd0 : amplitude_internal;

    phase_accumulator mac (
        .clock     (clock),
        .reset     (sweep_reset_internal),
        .sample_en (sample_en),
        .phase     (phase),
        .done      (done)
    );

    sine_lookup lookup (
        .clock     (clock),
        .reset     (reset),
        .sample_en (sample_en),
        .phase     (phase),
        .amplitude(amplitude_internal),
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
