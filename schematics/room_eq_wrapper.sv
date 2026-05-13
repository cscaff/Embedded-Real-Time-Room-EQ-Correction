module room_eq_wrapper(
    input  logic        clk,
    input  logic        reset,
    input  logic [31:0] writedata,
    output logic [31:0] readdata,
    input  logic        write,
    input  logic        read,
    input  logic        chipselect,
    input  logic [3:0]  address,
    input  logic        audio_clk,
    output logic        AUD_XCK,
    output logic        AUD_BCLK,
    output logic        AUD_DACDAT,
    output logic        AUD_DACLRCK,
    output logic        AUD_ADCLRCK,
    input  logic        AUD_ADCDAT
);
    room_eq_peripheral u0 (
        .clk         (clk),
        .reset       (reset),
        .writedata   (writedata),
        .readdata    (readdata),
        .write       (write),
        .read        (read),
        .chipselect  (chipselect),
        .address     (address),
        .audio_clk   (audio_clk),
        .AUD_XCK     (AUD_XCK),
        .AUD_BCLK    (AUD_BCLK),
        .AUD_DACDAT  (AUD_DACDAT),
        .AUD_DACLRCK (AUD_DACLRCK),
        .AUD_ADCLRCK (AUD_ADCLRCK),
        .AUD_ADCDAT  (AUD_ADCDAT)
    );
endmodule
