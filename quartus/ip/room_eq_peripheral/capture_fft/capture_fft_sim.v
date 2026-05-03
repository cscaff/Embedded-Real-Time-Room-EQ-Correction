// Behavioral simulation stub for the Altera FFT II MegaCore (capture_fft).
// Not synthesizable. Replaces the VHDL-based IP for Icarus simulation.
//
// Behavior: collects one 8192-point input frame (sink_sop..sink_eop), then
// streams it back on the output side unchanged.  No FFT math is performed;
// the stub exists only to drive the streaming handshake signals so that
// tb_sample_fft.sv can verify the wrapper control logic in sample_fft.sv.
//
// Input phase  – sink_ready held high; samples written into frame_real[].
// Output phase – begins the cycle after sink_eop is accepted; one sample
//                per clock, source_sop on the first, source_eop on the last.
//                sink_ready is deasserted while the output phase runs.
`timescale 1ns / 1ps

module capture_fft (
    clk, reset_n,
    sink_valid, sink_ready, sink_error, sink_sop, sink_eop,
    sink_real,  sink_imag,  fftpts_in, inverse,
    source_valid, source_ready, source_error,
    source_sop,   source_eop,
    source_real,  source_imag, fftpts_out
);
    input             clk;
    input             reset_n;
    input             sink_valid;
    output reg        sink_ready;
    input  [1:0]      sink_error;
    input             sink_sop;
    input             sink_eop;
    input  [23:0]     sink_real;
    input  [23:0]     sink_imag;
    input  [13:0]     fftpts_in;
    input  [0:0]      inverse;
    output reg        source_valid;
    input             source_ready;
    output [1:0]      source_error;
    output reg        source_sop;
    output reg        source_eop;
    output reg [23:0] source_real;
    output reg [23:0] source_imag;
    output [13:0]     fftpts_out;

    assign source_error = 2'b00;
    assign fftpts_out   = 14'd8192;

    localparam NPTS = 8192;

    reg [23:0] frame_real [0:NPTS-1];
    reg [12:0] wr_ptr;
    reg [12:0] rd_ptr;
    reg        frame_ready; // set when a complete input frame is buffered

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sink_ready   <= 1'b1;
            source_valid <= 1'b0;
            source_sop   <= 1'b0;
            source_eop   <= 1'b0;
            source_real  <= 24'b0;
            source_imag  <= 24'b0;
            wr_ptr       <= 13'd0;
            rd_ptr       <= 13'd0;
            frame_ready  <= 1'b0;
        end else if (!frame_ready) begin
            // ── Input phase ───────────────────────────────────────────
            source_valid <= 1'b0;
            if (sink_valid && sink_ready) begin
                frame_real[wr_ptr] <= sink_real;
                if (sink_eop) begin
                    wr_ptr      <= 13'd0;
                    frame_ready <= 1'b1;
                    sink_ready  <= 1'b0; // hold off new input while outputting
                end else begin
                    wr_ptr <= wr_ptr + 1'b1;
                end
            end
        end else begin
            // ── Output phase ──────────────────────────────────────────
            if (source_ready) begin
                source_valid <= 1'b1;
                source_real  <= frame_real[rd_ptr];
                source_imag  <= 24'b0;
                source_sop   <= (rd_ptr == 13'd0);
                source_eop   <= (rd_ptr == 13'd8191);
                if (rd_ptr == 13'd8191) begin
                    rd_ptr      <= 13'd0;
                    frame_ready <= 1'b0;
                    sink_ready  <= 1'b1; // accept next frame
                end else begin
                    rd_ptr <= rd_ptr + 1'b1;
                end
            end else begin
                source_valid <= 1'b0;
            end
        end
    end
endmodule
