// ==================== MODULE INTERFACE ====================
// Inputs:
// - sysclk: 50 MHz system clock.
// - bclk: I2S Bit Clock
// - lrclk: I2S Left-Right Clock
// - aclr: Active High Async Reset (Because we have dual clock domains)
// - left_chan: 24 bit I2S Serial Data (I am assuming this is just the left channel?)
// - rd_addr: 13-bit read address for RAM (0 to 8191).
//
// Outputs:
// - rd_real: 24-bit real part of the RAM output at rd_addr.
// - rd_imag: 24-bit imaginary part of the RAM output at rd_addr.
// - fft_done: Signal indicating FFT processing is complete. RAM can be read.
//
// ===========================================================

module calibration_engine(
    sysclk, // System Clock (50 MHz)
    bclk, // I2S Bit Clock
    lrclk, // I2S Left-Right Clock
    aclr, // Active High Async Reset (Because we have dual clock domains)
    left_chan, // 24 bit I2S Serial Data (I am assuming this is just the left channel?)
    rd_addr,  // Read address for RAM
    rd_real, // Real part of RAM output
    rd_imag, // Imaginary part of RAM output
    fft_done // Signal indicating FFT processing is complete. RAM can be read.
    );

    // ==================== Wiring ====================
    // Clocks and Reset
    input sysclk; // System Clock (50 MHz)
    input bclk; // I2S Bit Clock
    input lrclk; // I2S Left-Right Clock
    input aclr; // Active High Async Reset (Because we have dual clock domains)

    // Input Data
    input [23:0] left_chan; // 24 bit I2S Serial Data (I am assuming this is just the left channel?)

    // RAM Read Interface
    input [12:0] rd_addr; // Read address for RAM (13 bits for 8192 entries)
    output [23:0] rd_real; // Real part of RAM output
    output [23:0] rd_imag; // Imaginary part of RAM output
    output fft_done; // Signal indicating FFT processing is complete. RAM can be read.

    // ==================== Internal Signals ====================

    // sample_fifo -> sample_fft
    wire [23:0] fifo_to_fft_data;
    wire        fifo_to_fft_valid;
    wire        fft_to_fifo_ready;  // backpressure

    // sample_fft -> fft_result_ram
    wire [23:0] fft_to_ram_real;
    wire [23:0] fft_to_ram_imag;
    wire        fft_to_ram_valid;
    wire        fft_to_ram_sop;
    wire        fft_to_ram_eop;

    // ==================== Reset Derivations ====================
    // We introduce a 2-FF Synchronizer to ensure stable reset signals.
    reg reset_n_ff1, reset_n_ff2;

    always @(posedge sysclk or posedge aclr) begin
        if (aclr) begin
            reset_n_ff1 <= 0;
            reset_n_ff2 <= 0;
        end else begin
            reset_n_ff1 <= 1;
            reset_n_ff2 <= reset_n_ff1;
        end
    end

    wire reset_n = reset_n_ff2;

    // ==================== Submodules ====================
    sample_fifo u_sample_fifo (
        .bclk(bclk),
        .lrclk(lrclk),
        .left_chan(left_chan),
        .sysclk(sysclk),
        .aclr(aclr),
        .data_out(fifo_to_fft_data),
        .data_valid(fifo_to_fft_valid),
        .fft_ready(fft_to_fifo_ready)
    );

    sample_fft u_sample_fft (
        .sysclk(sysclk), // System Clock (50 MHz)
        .reset_n(reset_n), // Active low reset
        .sink_real(fifo_to_fft_data), // Real part of input sample
        .sink_valid(fifo_to_fft_valid), // Input sample valid signal
        .sink_ready(fft_to_fifo_ready), // FFT Ready Signal (Backpressure)
        .source_real(fft_to_ram_real), // Real part of FFT output
        .source_imag(fft_to_ram_imag), // Imaginary part of FFT output
        .source_valid(fft_to_ram_valid), // FFT output valid signal
        .source_eop(fft_to_ram_eop), // End of Packet for FFT output
        .source_sop(fft_to_ram_sop) // Start of Packet for FFT output
    );

    fft_result_ram u_fft_result_ram (
        .sysclk(sysclk), // System Clock (50 MHz)
        .reset_n(reset_n), // Active low reset
        .fft_real(fft_to_ram_real), // Real part of FFT output
        .fft_imag(fft_to_ram_imag), // Imaginary part of FFT output
        .fft_valid(fft_to_ram_valid), // FFT output valid signal
        .data_eop(fft_to_ram_eop), // End of Packet for FFT output
        .data_sop(fft_to_ram_sop), // Start of Packet for FFT output
        .rd_addr(rd_addr),  // Read address for RAM
        .rd_real(rd_real), // Real part of RAM output
        .rd_imag(rd_imag), // Imaginary part of RAM output
        .fft_done(fft_done) // Signal indicating FFT processing is complete. RAM can be read.
    );

endmodule