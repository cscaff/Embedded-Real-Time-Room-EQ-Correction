/*
 * Avalon memory-mapped peripheral for Real-Time Room EQ Correction
 *
 * CSEE W4840 — Embedded Systems
 * Jacob Boxerman, Roland List, Christian Scaff
 *
 * Register map (32-bit words):
 *
 * Offset   Bits      Access   Meaning
 *   0      [0]       W        CTRL: bit 0 = sweep_start (self-clears)
 *          [1]       R/W      CTRL: bit 1 = fifo_hps_mode (1=HPS drains FIFO, 0=FFT drains)
 *   1      [3:0]     R        STATUS: FSM state — 0=IDLE, 1=SWEEP, 2=DONE
 *          [4]       R        STATUS: fft_done (FFT frame complete, result RAM valid)
 *          [5]       R        STATUS: fifo_empty
 *   2      —         —        (reserved)
 *   3      [31:0]    R        VERSION: 32'h0001_0000
 *   4      [9:0]     W        LUT_ADDR: address for LUT initialization (1024 entries)
 *   5      [23:0]    W        LUT_DATA: data for LUT initialization (fires we_lut)
 *   6      [12:0]    R/W      FFT_ADDR: read address for FFT result RAM
 *   7      [23:0]    R        FFT_RDATA: real part of FFT result at FFT_ADDR
 *   8      [23:0]    R        FFT_IDATA: imaginary part of FFT result at FFT_ADDR
 *   9      [23:0]    R        ADC_LEFT: latest left-channel sample from I2S RX
 *  10      [23:0]    R        FIFO_RDATA: pop-on-read from DCFIFO (showahead)
 *
 * Audio conduit signals connect to the WM8731 codec on the DE1-SoC.
 * The PLL-generated 12.288 MHz audio clock is received from Platform Designer.
 *
 * Staged testing:
 *   Stage 1: Set fifo_hps_mode=1, start sweep, read FIFO_RDATA to verify ADC→DCFIFO→HPS.
 *   Stage 2: Set fifo_hps_mode=0, start sweep, poll fft_done, read FFT bins.
 *   Stage 3: Continuous FFT — loop reading FFT frames during sweep.
 */

module room_eq_peripheral(
    // Avalon slave interface
    input  logic        clk,          // 50 MHz system clock from Platform Designer
    input  logic        reset,        // system reset (active high)
    input  logic [31:0] writedata,    // data from HPS
    output logic [31:0] readdata,     // data to HPS
    input  logic        write,        // write strobe
    input  logic        read,         // read strobe
    input  logic        chipselect,   // peripheral selected
    input  logic [3:0]  address,      // register address (word offset, 0-15)

    // Audio clock from PLL
    input  logic        audio_clk,    // 12.288 MHz from audio PLL

    // Audio conduit — directly to codec pins
    output logic        AUD_XCK,      // master clock to codec (12.288 MHz)
    output logic        AUD_BCLK,     // I2S bit clock
    output logic        AUD_DACDAT,   // I2S DAC serial data (FPGA → codec)
    output logic        AUD_DACLRCK,  // I2S DAC frame clock (L/R)
    output logic        AUD_ADCLRCK,  // I2S ADC frame clock (tied to DACLRCK)
    input  logic        AUD_ADCDAT    // I2S ADC serial data (codec → FPGA)
);

    // ── Forward master clock to codec ────────────────────────
    assign AUD_XCK = audio_clk;

    // ── Internal BCLK/LRCK wires (shared by TX and RX) ───────
    logic bclk_int, lrck_int;
    assign AUD_BCLK    = bclk_int;
    assign AUD_DACLRCK = lrck_int;
    assign AUD_ADCLRCK = lrck_int;  // ADC and DAC share the same frame clock

    // ── Register file ────────────────────────────────────────
    logic        sweep_start;     // one-cycle pulse from HPS
    logic        fifo_hps_mode;   // 1 = HPS drains FIFO, 0 = FFT drains
    logic [9:0]  lut_addr;        // 10-bit for 1024-entry LUT
    logic [23:0] lut_data;
    logic [12:0] fft_rd_addr;

    // ── Internal control ─────────────────────────────────────
    logic        we_lut;          // LUT write enable (self-clearing pulse)
    logic        calibrate_start; // One-cycle pulse to arm calibration engine
    logic        fft_done;        // Calibration engine FFT frame complete
    logic        sweep_done;      // Latches high in audio domain when sweep reaches 20 kHz
    logic        sweep_reset;     // Active-high reset for audio-domain modules
    logic [23:0] amplitude;       // Sweep generator output

    // ── Calibration engine FIFO access ──────────────────────
    logic [23:0] fft_rd_real, fft_rd_imag;
    logic [23:0] fifo_data_out;
    logic        fifo_data_valid;
    logic        fifo_empty;
    wire         fifo_hps_pop = chipselect && read && (address == 4'd10);

    // ── I2S RX ────────────────────────────────────────────────
    logic [23:0] rx_left, rx_right;

    i2s_rx rx_inst (
        .clock       (audio_clk),
        .reset       (sweep_reset),
        .bclk        (bclk_int),
        .lrck        (lrck_int),
        .adcdat      (AUD_ADCDAT),
        .left_sample (rx_left),
        .right_sample(rx_right)
    );

    // ── Toggle synchronizer (50 MHz → 12.288 MHz) ───────────
    logic        sweep_start_toggle;
    logic        tog_sync1, tog_sync2, tog_sync3;

    always_ff @(posedge clk) begin
        if (reset)            sweep_start_toggle <= 1'b0;
        else if (sweep_start) sweep_start_toggle <= ~sweep_start_toggle;
    end

    always_ff @(posedge audio_clk) begin
        tog_sync1 <= sweep_start_toggle;
        tog_sync2 <= tog_sync1;
        tog_sync3 <= tog_sync2;
    end

    wire sweep_start_audio = tog_sync2 ^ tog_sync3;

    // ── Synchronize sweep_done: audio → system ───────────────
    logic done_sync1, done_sync2;
    always_ff @(posedge clk) begin
        done_sync1 <= sweep_done;
        done_sync2 <= done_sync1;
    end

    // ── Async reset synchronizer for audio domain ────────────
    logic rst_sync1, rst_sync2;
    always_ff @(posedge audio_clk or posedge reset) begin
        if (reset) begin
            rst_sync1 <= 1'b1;
            rst_sync2 <= 1'b1;
        end else begin
            rst_sync1 <= 1'b0;
            rst_sync2 <= rst_sync1;
        end
    end

    assign sweep_reset = rst_sync2;

    // ── FSM ──────────────────────────────────────────────────
    typedef enum logic [3:0] {
        IDLE  = 4'd0,
        SWEEP = 4'd1,
        DONE  = 4'd2
    } state_t;
    state_t state;

    // Rising-edge detector for done_sync2: prevent stale high from
    // previous sweep from immediately triggering SWEEP→DONE.
    logic done_sync2_prev;
    wire  done_rising = done_sync2 && !done_sync2_prev;

    always_ff @(posedge clk) begin
        if (reset) begin
            state           <= IDLE;
            calibrate_start <= 1'b0;
            done_sync2_prev <= 1'b0;
        end else begin
            calibrate_start <= 1'b0;
            done_sync2_prev <= done_sync2;
            case (state)
                IDLE: begin
                    if (sweep_start) begin
                        state           <= SWEEP;
                        calibrate_start <= 1'b1;  // arm FFT at sweep start
                    end
                end
                SWEEP: begin
                    if (done_rising)
                        state <= DONE;
                end
                DONE: begin
                    if (sweep_start) begin
                        state           <= SWEEP;
                        calibrate_start <= 1'b1;
                    end
                end
            endcase
        end
    end

    // ── Register read ────────────────────────────────────────
    always_comb begin
        readdata = 32'd0;
        if (chipselect && read)
            case (address)
                4'd0:    readdata = {30'd0, fifo_hps_mode, 1'b0};
                4'd1:    readdata = {26'd0, fifo_empty, fft_done, state};
                4'd3:    readdata = 32'h0001_0000;           // VERSION
                4'd6:    readdata = {19'd0, fft_rd_addr};
                4'd7:    readdata = {8'd0, fft_rd_real};
                4'd8:    readdata = {8'd0, fft_rd_imag};
                4'd9:    readdata = {8'd0, rx_left};          // ADC_LEFT
                4'd10:   readdata = {8'd0, fifo_data_out};    // FIFO_RDATA (pop-on-read)
                default: readdata = 32'd0;
            endcase
    end

    // ── Register write ───────────────────────────────────────
    always_ff @(posedge clk) begin
        if (reset) begin
            sweep_start   <= 1'b0;
            fifo_hps_mode <= 1'b0;
            lut_addr      <= 10'd0;
            we_lut        <= 1'b0;
            fft_rd_addr   <= 13'd0;
        end else if (chipselect && write) begin
            we_lut <= 1'b0;
            case (address)
                4'd0: begin
                    sweep_start   <= writedata[0];
                    fifo_hps_mode <= writedata[1];
                end
                4'd4: lut_addr    <= writedata[9:0];
                4'd5: begin
                    we_lut   <= 1'b1;
                    lut_data <= writedata[23:0];
                end
                4'd6: fft_rd_addr <= writedata[12:0];
                default: ;
            endcase
        end else begin
            we_lut      <= 1'b0;
            sweep_start <= 1'b0;
        end
    end

    // ── Sweep generator ──────────────────────────────────────
    sweep_generator sweep_inst (
        .clock    (audio_clk),
        .reset    (sweep_reset),
        .amplitude(amplitude),
        .clk_sys  (clk),
        .we_lut   (we_lut),
        .addr_lut (lut_addr),
        .din_lut  (lut_data),
        .start    (sweep_start_audio),
        .done     (sweep_done),
        .lrck     (lrck_int)
    );

    // ── I2S transmitter ──────────────────────────────────────
    i2s_tx i2s_inst (
        .clock        (audio_clk),
        .reset        (sweep_reset),
        .left_sample  (amplitude),
        .right_sample (amplitude),
        .bclk         (bclk_int),
        .lrck         (lrck_int),
        .dacdat       (AUD_DACDAT)
    );

    // ── Calibration engine ───────────────────────────────────
    calibration_engine calib_inst (
        .sysclk        (clk),
        .bclk          (bclk_int),
        .lrclk         (lrck_int),
        .aclr          (rst_sync2),
        .start         (calibrate_start),
        .left_chan      (rx_left),
        .rd_addr       (fft_rd_addr),
        .rd_real       (fft_rd_real),
        .rd_imag       (fft_rd_imag),
        .fft_done      (fft_done),
        .fifo_hps_mode (fifo_hps_mode),
        .fifo_hps_pop  (fifo_hps_pop),
        .fifo_data_out (fifo_data_out),
        .fifo_data_valid(fifo_data_valid),
        .fifo_empty    (fifo_empty)
    );

endmodule
