// capture_fft.v — Passthrough stub for synthesis
// Replaces the real FFT II IP until it's generated.
// Buffers one 8192-sample frame and echoes it back:
//   source_real = sink_real (passthrough), source_imag = 0

module capture_fft (
    input         clk,
    input         reset_n,
    input         sink_valid,
    output        sink_ready,
    input  [1:0]  sink_error,
    input         sink_sop,
    input         sink_eop,
    input  [23:0] sink_real,
    input  [23:0] sink_imag,
    input  [13:0] fftpts_in,
    input         inverse,
    output        source_valid,
    input         source_ready,
    output [1:0]  source_error,
    output        source_sop,
    output        source_eop,
    output [23:0] source_real,
    output [23:0] source_imag,
    output [13:0] fftpts_out
);

    localparam N = 8192;

    reg [23:0] buf_mem [0:N-1];
    reg [12:0] wr_ptr;
    reg [12:0] rd_ptr;
    reg        capturing;
    reg        outputting;
    reg        frame_ready;

    assign sink_ready    = capturing & ~frame_ready;
    assign source_valid  = outputting;
    assign source_real   = outputting ? buf_mem[rd_ptr] : 24'd0;
    assign source_imag   = 24'd0;
    assign source_sop    = outputting & (rd_ptr == 13'd0);
    assign source_eop    = outputting & (rd_ptr == N - 1);
    assign source_error  = 2'b00;
    assign fftpts_out    = fftpts_in;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wr_ptr      <= 0;
            rd_ptr      <= 0;
            capturing   <= 1;
            outputting  <= 0;
            frame_ready <= 0;
        end else begin
            if (capturing && sink_valid && sink_ready) begin
                buf_mem[wr_ptr] <= sink_real;
                if (wr_ptr == N - 1) begin
                    wr_ptr      <= 0;
                    capturing   <= 0;
                    frame_ready <= 1;
                end else begin
                    wr_ptr <= wr_ptr + 1;
                end
            end

            if (frame_ready && !outputting) begin
                outputting  <= 1;
                frame_ready <= 0;
                rd_ptr      <= 0;
            end

            if (outputting && source_ready) begin
                if (rd_ptr == N - 1) begin
                    outputting <= 0;
                    capturing  <= 1;
                    rd_ptr     <= 0;
                end else begin
                    rd_ptr <= rd_ptr + 1;
                end
            end
        end
    end

endmodule
