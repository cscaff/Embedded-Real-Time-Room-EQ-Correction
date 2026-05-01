// ==================== MODULE INTERFACE ====================
// Inputs:
// - sysclk: 50 MHz system clock.
// - reset_n: Active low reset signal.
// - sink_real: 24-bit real part of the input sample to the FFT.
// - sink_valid: Indicates when the input sample is valid and can be consumed by the FFT.
// - TODO: FSM Control/Status Signals. 
//
// Outputs:
// - source_real: 24-bit real part of the FFT output.
// - source_imag: 24-bit imaginary part of the FFT output.
// - source_valid: Indicates when the FFT output is valid and can be consumed by downstream logic.
// - source_eop: End of Packet signal for the FFT output, indicating the last sample of the current FFT frame.
// - source_sop: Start of Packet signal for the FFT output, indicating the first sample of the current FFT frame.//
// - sink_ready: Backpressure signal from the FFT indicating it is ready to consume the input sample.
//
// ===========================================================
module sample_fft (
    sysclk, // System Clock (50 MHz)
    reset_n, // Active low reset
    sink_real, // Real part of input sample
    sink_valid, // Input sample valid signal
    sink_ready, // FFT Ready Signal (Backpressure)
    source_real, // Real part of FFT output
    source_imag, // Imaginary part of FFT output
    source_valid, // FFT output valid signal
    source_eop, // End of Packet for FFT output
    source_sop // Start of Packet for FFT output
    );


    // ==================== Wiring ====================

    // Clocks and Reset
    input sysclk;
    input reset_n;

    // Data and Control
    input [23:0] sink_real; // Real part of input sample
    input sink_valid; // Input sample valid signal
    output sink_ready; // FFT Ready Signal (Backpressure)
    output [23:0] source_real; // Real part of FFT output
    output [23:0] source_imag; // Imaginary part of FFT output
    output source_valid; // FFT output valid signal
    output source_eop; // End of Packet for FFT output
    output source_sop; // Start of Packet for FFT output

    // Internal Signals
    wire [12:0] fftpts_in = 13'd8192; // 8192 point FFT (13 bits: 8192 = 2^13).
    wire inverse = 1'b0; // Set inverse to False. Only use Forward.
    wire source_ready = 1'b1; // BRAM never applies backpressure.
    wire [1:0] sink_error = 2'b00; // No error messages as of now.
    wire [23:0] sink_imag = 24'b0; // We do not use the inverse FFT, so we only need sink_real.

    // Unused Wires
    wire [1:0] source_error_unused; // TODO - Connect to FSM for Error Handling.
    wire [12:0] fftpts_out_unused;

    // ==================== SOP and EOP Signal Logic ====================
    reg [12:0] sample_count; // 13 Bit counter from 0 to 8191 (2^13 = 8192) to track 
                             // number of samples sent to FFT. (Variable Streaming)

    // Notes on Logic:
    // sink_valid asserts when data is ready from the FIFO.
    // sink_ready asserts when the FFT is ready to consume.
    // When both assert, handshake occurs and sample is consumed i.e. start of packet (SOP).
    // Notes on reset:
    // !reset_n because reset is active low, thus reset occurs when reset_n is 0.

    always @(posedge sysclk or negedge reset_n) begin
        if (!reset_n) begin
            sample_count <= 13'd0; // Count resets.
        end else if (sink_valid && sink_ready) begin
            if (sample_count == 13'd8191) // EOP
                sample_count <= 13'd0;  // wrap for next packet
            else
                sample_count <= sample_count + 1'b1;
        end
    end

    wire sink_sop = (sample_count == 13'd0);
    wire sink_eop = (sample_count == 13'd8191);

    // ==================== Quartus Generated Bi-Directional FFT Instantiation ====================
    // Core Notes and Assumptions:
    // - The FFT is bi-directional (FFT + IFFT). We will likely only use forward direction.
    // -- This was solely done to allow us to use variable streaming and fixed point precision (Quartus forced bi-directional for this setting).
    // -- Our design.md cals for BFP, but Quaruts does not support that for variable streaming (SOP/EOP).
    // -- I don't want to overcomplicate with non-variable streaming.
    // -- Our disadvatage of fixed point is having to determine a precision and deal with scaling.
    // -- We can always change this.
    
    capture_fft u0 (
    .clk          (sysclk),          //    clk.clk
    .reset_n      (reset_n),      //    rst.reset_n
    .sink_valid   (sink_valid),   //   sink.sink_valid
    .sink_ready   (sink_ready),   //       .sink_ready
    .sink_error   (sink_error),   //       .sink_error
    .sink_sop     (sink_sop),     //       .sink_sop
    .sink_eop     (sink_eop),     //       .sink_eop
    .sink_real    (sink_real),    //       .sink_real
    .sink_imag    (sink_imag),    //       .sink_imag
    .fftpts_in    (fftpts_in),    //       .fftpts_in
    .inverse      (inverse),      //       .inverse
    .source_valid (source_valid), // source.source_valid
    .source_ready (source_ready), //       .source_ready
    .source_error (source_error_unused), //       .source_error
    .source_sop   (source_sop),   //       .source_sop
    .source_eop   (source_eop),   //       .source_eop
    .source_real  (source_real),  //       .source_real
    .source_imag  (source_imag),  //       .source_imag
    .fftpts_out   (fftpts_out_unused)    //       .fftpts_out
	);

endmodule