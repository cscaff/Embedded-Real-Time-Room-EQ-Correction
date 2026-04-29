// ==================== MODULE INTERFACE ====================
// Inputs:
// - bclk: I2S Bit Clock (3.072 MHz)
// - lrclk: I2S Left-Right Clock (48 kHz)
// - sdata: I2S Serial Data (assumed to be the left channel)
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
module capture_fifo (
    bclk, // I2S Bit Clock
    lrclk, // I2S Left-Right Clock 
    sdata, // I2s Serial Data (I am assuming this is just the left channel?)
    sysclk, // System Clock (50 MHz)
    aclr, // Active High Async Reset (Because we have dual clock domains)
    data_out, // Output: 24-bit audio sample from FIFO
    data_valid, // Output: High when data_out is valid
    fft_ready  // Input: FFT Backpressure Signal.
    );

endmodule