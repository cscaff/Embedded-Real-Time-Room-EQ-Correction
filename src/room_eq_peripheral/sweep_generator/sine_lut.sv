// Simple single-port BRAM — 256 entries x 24-bit wide.
// Sized to match sine_lookup.sv: 8-bit address, 24-bit signed amplitude.
// Synchronous write, synchronous read with 1-cycle registered output.
// Both Xilinx and Intel tools infer a true BRAM from this pattern.

// ==================== MODULE INTERFACE ====================
// Inputs:
// - clk: ...
// - phase: 32-bit phase accumulator (Tells us where we are in the waveform cycle.)
//
// Outputs:
// - amplitude: 24-bit signed output for the CODEC, representing the sine wave value
//
// ===========================================================

module sine_lut (
    input  logic        clk,
    input  logic        we,        // write enable (active high)
    input  logic [7:0]  addr,      // address: 0–255
    input  logic [23:0] din,       // data in  (write path)
    output logic [23:0] dout       // data out (1-cycle read latency)
);

    logic [23:0] mem [255:0];

    always_ff @(posedge clk) begin
        if (we)
            mem[addr] <= din;
        dout <= mem[addr];   // read-first: dout reflects mem before write on same cycle
    end

endmodule
