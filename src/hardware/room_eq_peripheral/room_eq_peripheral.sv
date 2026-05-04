/*
 * Avalon memory-mapped peripheral for Real-Time Room EQ Correction
 *
 * CSEE W4840 — Embedded Systems
 * Jacob Boxerman, Roland List, Christian Scaff
 *
 * Register map (32-bit words):
 *
 * Offset   Bits      Access   Meaning
 *   0      [0]       R/W      CTRL: bit 0 = sweep_start (write 1 to trigger,
 *                                          self-clears when sweep begins)
 *                              bit 1 = sweep_running (read-only, 1 while sweep active)
 *   1      [31:0]    R        STATUS: reserved for future use
 *   2      [31:0]    R/W      SWEEP_LEN: sweep length in samples (default 480000 = 10s)
 *   3      [31:0]    R        VERSION: 32'h0001_0000
 *   4      [7:0]     W        LUT_ADDR: address for LUT initialization
 *   5      [23:0]    W        LUT_DATA: data for LUT initialization
 *   6      [12:0]    R/W      FFT_ADDR: read address for calibration engine results
 *   7      [23:0]    R        FFT_RDATA: read data for calibration engine results (Real Part)
 *   8      [23:0]    R        FFT_IDATA: read data for calibration engine results (Imaginary Part)
 * 
 * Audio conduit signals connect to the WM8731 codec on the DE1-SoC.
 * The PLL-generated 12.288 MHz audio clock is received from Platform Designer.
 */

module room_eq_peripheral(
    // Avalon slave interface (active)
    input  logic        clk,          // 50 MHz system clock from Platform Designer
    input  logic        reset,        // system reset (active high)
    input  logic [31:0] writedata,    // data from HPS
    output logic [31:0] readdata,     // data to HPS
    input  logic        write,        // write strobe
    input  logic        read,         // read strobe
    input  logic        chipselect,   // peripheral selected
    input  logic [3:0]  address,      // register address (word offset)

    // Audio clock from PLL (active)
    input  logic        audio_clk,    // 12.288 MHz from audio PLL

    // Audio conduit — directly to codec pins
    output logic        AUD_XCK,      // master clock to codec (12.288 MHz)
    output logic        AUD_BCLK,     // I2S bit clock
    output logic        AUD_DACDAT,   // I2S serial data
    output logic        AUD_DACLRCK   // I2S frame clock (L/R)
);

    // ── Forward the master clock to the codec ───────────────
    assign AUD_XCK = audio_clk;

    // ── Registers ───────────────────────────────────────────
    logic        sweep_start;     // pulse from HPS to start sweep
    logic        sweep_running;   // 1 while sweep is active
    logic [31:0] sweep_len;       // sweep length in samples
    
    // Lut Init
    logic [7:0] lut_addr;
    logic [23:0] lut_data;

    // Resulting FFT Values
    logic [12:0] fft_rd_addr;
    logic [23:0] fft_rd_real;
    logic [23:0] fft_rd_imag;

    // ── Register read ───────────────────────────────────────
    always_comb begin
        readdata = 32'd0;
        if (chipselect && read)
            case (address)
                4'd0: readdata = {30'd0, sweep_running, 1'b0};
                4'd1: readdata = 32'd0;            // STATUS: reserved
                4'd2: readdata = sweep_len;
                4'd3: readdata = 32'h0001_0000;    // VERSION
                4'd6: readdata = {19'd0, fft_rd_addr};
                4'd7: readdata = {8'd0, fft_rd_real};
                4'd8: readdata = {8'd0, fft_rd_imag};
                default: readdata = 32'd0;
            endcase
    end

    // ── Register write ──────────────────────────────────────
    always_ff @(posedge clk) begin
        if (reset) begin
            sweep_start <= 1'b0;
            sweep_len   <= 32'd480_000;  // default: 10 seconds at 48 kHz
            lut_addr    <= 8'd0;
            fft_rd_addr <= 13'd0;
        end else if (chipselect && write) begin
            case (address)
                4'd0: sweep_start <= writedata[0];
                4'd2: sweep_len   <= writedata;
                4'd4: lut_addr    <= writedata[7:0];
                4'd5: lut_data    <= writedata[23:0];
                4'd6: fft_rd_addr <= writedata[12:0];
                default: ;
            endcase
        end else begin
            sweep_start <= 1'b0;  // self-clear
        end
    end

    // ── Sweep control ───────────────────────────────────────
    // For now: sweep runs continuously after start, resets on
    // reset.  The sweep_running signal will eventually gate
    // the sweep_generator and count samples.
    //
    // Simple approach: reset the sweep generator when not running.
    logic sweep_reset;
    logic sweep_active;

    always_ff @(posedge clk) begin
        if (reset) begin
            sweep_active <= 1'b0;
        end else if (sweep_start) begin
            sweep_active <= 1'b1;
        end
    end

    assign sweep_running = sweep_active;

    // Synchronize sweep_active into the audio clock domain
    logic sweep_active_sync1, sweep_active_sync2;
    always_ff @(posedge audio_clk) begin
        sweep_active_sync1 <= sweep_active;
        sweep_active_sync2 <= sweep_active_sync1;
    end

    assign sweep_reset = !sweep_active_sync2;

    // ── Sine LUT initialization ─────────────────────────────
    // Load the quarter-wave sine table at startup from the
    // 50 MHz clock domain.
    logic        lut_init_done;
    logic        we_lut;
    logic  [7:0] addr_lut;
    logic [23:0] din_lut;


    // ── Sweep generator ─────────────────────────────────────
    logic [23:0] amplitude;

    sweep_generator sweep_inst (
        .clock    (audio_clk),
        .reset    (sweep_reset),
        .amplitude(amplitude),
        .clk_sys  (clk),
        .we_lut   (we_lut),
        .addr_lut (addr_lut),
        .din_lut  (din_lut)
    );

    // ── Calibration engine ────────────────────────────────────
    calibration_engine calib_inst (
        .sysclk(sysclk),
        .bclk(AUD_BCLK),
        .lrclk(AUD_DACLRCK),
        .aclr(/*RESET*/),
        .left_chan(amplitude), // feed the sweep output into the calibration engine
        .rd_addr(13'd0), // For now, hardcode read address (will be used by HPS to read results)
        .rd_real(), // Unconnected for now
        .rd_imag(), // Unconnected for now
        .fft_done() // Unconnected for now
    );


    // ── I2S transmitter ─────────────────────────────────────
    // Mono output: same sample on both channels.
    i2s_tx i2s_inst (
        .clock        (audio_clk),
        .reset        (sweep_reset),
        .left_sample  (amplitude),
        .right_sample (amplitude),
        .bclk         (AUD_BCLK),
        .lrck         (AUD_DACLRCK),
        .dacdat       (AUD_DACDAT)
    );

endmodule
