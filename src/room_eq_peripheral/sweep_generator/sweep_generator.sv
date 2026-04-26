module sweep_generator(
    clock,
    reset,
    start,
    amplitude,
    clk_sys,
    we_lut,
    addr_lut,
    din_lut
    );

    input          clock;
    input          reset;
    input          start;
    output  [23:0] amplitude;
    input          clk_sys;
    input          we_lut;
    input    [7:0] addr_lut;
    input   [23:0] din_lut;

    wire [31:0] phase;

    phase_accumulator mac (
        .clock (clock),
        .reset (reset),
        .phase (phase)
    );

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
