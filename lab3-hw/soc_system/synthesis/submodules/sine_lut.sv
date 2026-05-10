// ==================== MODULE INTERFACE ====================
// True Dual-Port BRAM: 1024 entries x 24-bit wide.
// Port A: 50 MHz system clock — write-only (used for startup initialization).
// Port B: 12.288 MHz PLL Generated Clock
// The FPGA BRAM primitive natively handles the two independent clock domains.
//
// CDC note: Port A writes must be fully complete before Port B begins reading.
//           For one-time startup init this is guaranteed by system design
//           (do not start the sweep until the LUT is loaded).
//
// Inputs (Port A — write, 50 MHz):
// - clk_a:  50 MHz system clock.
// - we_a:   Write enable (active high). Writes din_a into mem[addr_a].
// - addr_a: 10-bit write address selecting one of 1024 entries (0-1023).
// - din_a:  24-bit signed sine value to store.
//
// Inputs (Port B — read, 12.288 MHz):
// - clk_b:  12.288 MHz sample clock (same clock driving sine_lookup).
// - addr_b: 10-bit read address, driven by lut_index from sine_lookup.
//
// Outputs:
// - dout_b: 24-bit sine value at mem[addr_b]. Registered — valid 1 cycle after addr_b.
//
// ===========================================================

module sine_lut (
    // Port A — write (50 MHz system clock)
    input  logic        clk_a,
    input  logic        we_a,
    input  logic [9:0]  addr_a,
    input  logic [23:0] din_a,

    // Port B — read (12.288 MHz sample clock)
    input  logic        clk_b,
    input  logic [9:0]  addr_b,
    output logic [23:0] dout_b
);

    logic [23:0] mem [1023:0];

    // Port A: synchronous write
    always_ff @(posedge clk_a) begin
        if (we_a)
            mem[addr_a] <= din_a;
    end

    // Port B: synchronous read (1-cycle latency)
    always_ff @(posedge clk_b) begin
        dout_b <= mem[addr_b];
    end

endmodule
