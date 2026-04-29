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
    input left_chan;
    output reg data_valid; // Output: High when data_out is valid
    input fft_ready;  // Input: FFT Backpressure Signal.
    output reg [23:0] data_out; // Output: 24-bit audio sample from FIFO


    // Quartus Generated DCFIFO Instatnation
    sample_fifo	sample_fifo_inst (
	.data ( left_chan ),
	.rdclk ( sysclk ),
	.rdreq ( rdreq_sig ),
	.wrclk ( bclk ),
	.wrreq ( wrreq_sig ),
	.q ( q_sig ),
	.rdempty ( rdempty_sig ),
	.wrfull ( wrfull_sig )
	);




endmodule