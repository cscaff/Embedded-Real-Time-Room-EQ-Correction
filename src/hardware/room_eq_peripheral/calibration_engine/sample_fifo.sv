// ==================== MODULE INTERFACE ====================
// Inputs:
// - bclk: I2S Bit Clock (3.072 MHz)
// - lrclk: I2S Left-Right Clock (48 kHz)
// - left_chan: 24 bit I2S Serial Data (I am assuming this is just the left channel?)
// - sysclk: System Clock (50 MHz)
// - aclr: Active High Async Reset (Because we have dual clock domains)
// - fft_ready: Input: FFT Backpressure Signal.
// - TODO: FSM Control/Status Signals. 
//
// Outputs:
// - data_out: 24-bit audio sample from FIFO
// - data_valid: High when data_out is valid
//
// ===========================================================
module sample_fifo (
    bclk, // I2S Bit Clock
    lrclk, // I2S Left-Right Clock 
    left_chan, // 24 bit I2S Serial Data (I am assuming this is just the left channel?)
    sysclk, // System Clock (50 MHz)
    aclr, // Active High Async Reset (Because we have dual clock domains)
    data_out, // Output: 24-bit audio sample from FIFO
    data_valid, // Output: High when data_out is valid
    fft_ready  // Input: FFT Backpressure Signal.
    );

    // Inputs and Outputs:

    // Clocks and Reset
    input bclk;
    input lrclk;
    input sysclk;
    input aclr;

    // Data and Control
    input [23:0] left_chan;
    output data_valid; // Output: High when data_out is valid
    input fft_ready;  // Input: FFT Backpressure Signal.
    output [23:0] data_out; // Output: 24-bit audio sample from FIFO

    // Internal Signals
    wire wrfull;
    wire rdempty;
    wire wrreq;
    wire rdreq;
    wire lrclk_neg_edge;

    // Write Request Logic:
    // Assert write request when new sample is available (Falling edge of lrclk) and FIFO is not full.
    reg lrclk_reg;

    always @ (posedge bclk or posedge aclr) begin
        if (aclr) begin
            lrclk_reg <= 1'b0;
        end else begin
            lrclk_reg <= lrclk; // Register lrclk to detect edges
        end
    end

    assign lrclk_neg_edge = lrclk_reg & ~lrclk; // Detect falling edge of lrclk
    assign wrreq = lrclk_neg_edge & ~wrfull; // Write request on falling edge of lrclk if FIFO is not full

    // Read Request Logic:
    assign data_valid = ~rdempty;
    assign rdreq  = data_valid & fft_ready; // Read request when data is valid and FFT is ready to consume.


    // Quartus Generated DCFIFO Instatnation
    capture_fifo	capture_fifo_inst (
	.aclr ( aclr ),
	.data ( left_chan ),
	.rdclk ( sysclk ),
	.rdreq ( rdreq ),
	.wrclk ( bclk ),
	.wrreq ( wrreq ),
	.q ( data_out ),
	.rdempty ( rdempty ),
	.wrfull ( wrfull )
	);


endmodule