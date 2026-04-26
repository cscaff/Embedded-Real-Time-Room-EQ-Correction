module sweep_generator(
    clock,
    reset,
    start
    );

    // Inputs and Outputs:
    input clock;
    input reset;
    input start;

    // Internal Signals
    wire [31:0] phase;

    // Internal Modules
    phase_accumulator mac (
        .clock (clock),
        .reset (reset),
        .phase (phase)
    )

    sine_lookup lookup (
        .clock    (clock),
        .reset    (reset),
        .phase    (phase),
        .amplitude(amplitude),
        .clk_sys  (clk_sys),
        .we_lut   (we_lut),
        .addr_lut (addr_lut),
        .din_lut  (din_lut)
    );

    
endmodule