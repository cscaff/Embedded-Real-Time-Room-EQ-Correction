// capture_fifo.v — Behavioral DCFIFO model for simulation
// Replaces the Altera DCFIFO IP (which targets a specific FPGA device).
// Dual-clock FIFO: write on wrclk (bclk), read on rdclk (sysclk).
// Showahead mode: q is presented as soon as rdempty deasserts.

module capture_fifo (
    input         aclr,
    input  [23:0] data,
    input         rdclk,
    input         rdreq,
    input         wrclk,
    input         wrreq,
    output [23:0] q,
    output        rdempty,
    output        wrfull
);

    // Use a simple dual-clock FIFO with a large depth for simulation
    localparam DEPTH = 8192;
    localparam ADDR_W = 13;

    reg [23:0] mem [0:DEPTH-1];
    reg [ADDR_W:0] wr_ptr = 0;  // extra bit for full/empty detection
    reg [ADDR_W:0] rd_ptr = 0;

    // Gray-code CDC for pointers (simplified for simulation —
    // real hardware uses multi-stage synchronizers)
    reg [ADDR_W:0] wr_ptr_gray_sync1, wr_ptr_gray_sync2;
    reg [ADDR_W:0] rd_ptr_gray_sync1, rd_ptr_gray_sync2;

    // Convert binary to gray
    function [ADDR_W:0] bin2gray(input [ADDR_W:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction

    // Convert gray to binary
    function [ADDR_W:0] gray2bin(input [ADDR_W:0] g);
        integer i;
        begin
            gray2bin = g;
            for (i = ADDR_W; i > 0; i = i - 1)
                gray2bin[i-1] = gray2bin[i] ^ g[i-1];
        end
    endfunction

    wire [ADDR_W:0] wr_ptr_gray = bin2gray(wr_ptr);
    wire [ADDR_W:0] rd_ptr_gray = bin2gray(rd_ptr);

    // Synchronize write pointer to read domain
    always @(posedge rdclk or posedge aclr) begin
        if (aclr) begin
            wr_ptr_gray_sync1 <= 0;
            wr_ptr_gray_sync2 <= 0;
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end

    // Synchronize read pointer to write domain
    always @(posedge wrclk or posedge aclr) begin
        if (aclr) begin
            rd_ptr_gray_sync1 <= 0;
            rd_ptr_gray_sync2 <= 0;
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end

    // Write logic
    always @(posedge wrclk or posedge aclr) begin
        if (aclr) begin
            wr_ptr <= 0;
        end else if (wrreq && !wrfull) begin
            mem[wr_ptr[ADDR_W-1:0]] <= data;
            wr_ptr <= wr_ptr + 1;
        end
    end

    // Read logic (showahead: output is always mem[rd_ptr])
    // Advance pointer when rdreq is asserted
    always @(posedge rdclk or posedge aclr) begin
        if (aclr) begin
            rd_ptr <= 0;
        end else if (rdreq && !rdempty) begin
            rd_ptr <= rd_ptr + 1;
        end
    end

    // Showahead output: q presents the current head immediately
    assign q = mem[rd_ptr[ADDR_W-1:0]];

    // Empty: synchronized write pointer == read pointer (in read domain)
    wire [ADDR_W:0] wr_ptr_in_rd = gray2bin(wr_ptr_gray_sync2);
    assign rdempty = (wr_ptr_in_rd == rd_ptr);

    // Full: write pointer has wrapped and caught up to read pointer (in write domain)
    wire [ADDR_W:0] rd_ptr_in_wr = gray2bin(rd_ptr_gray_sync2);
    assign wrfull = ((wr_ptr[ADDR_W] != rd_ptr_in_wr[ADDR_W]) &&
                     (wr_ptr[ADDR_W-1:0] == rd_ptr_in_wr[ADDR_W-1:0]));

endmodule
