/*
 * Avalon memory-mapped peripheral for Real-Time Room EQ Correction
 *
 * CSEE W4840 — Embedded Systems
 * Jacob Boxerman, Roland List, Christian Scaff
 *
 * Register map (32-bit words):
 *
 * Offset   Bits      Access   Meaning
 *   0      [0]       W        CTRL: bit 0 = sweep_start (write 1 to trigger, self-clears next cycle)
 *   1      [3:0]     R        STATUS: FSM state — 0=IDLE, 1=CALIBRATING, 3=DONE
 *   2      [7:0]     R        CHUNK_COUNT: completed FFT chunks (increments on each fft_done rising edge)
 *   3      [31:0]    R        VERSION: 32'h0002_0000
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
    output logic        AUD_DACDAT,   // I2S serial data to DAC
    output logic        AUD_DACLRCK,  // I2S DAC frame clock (L/R)
    input  logic        AUD_ADCDAT,   // I2S serial data from ADC
    output logic        AUD_ADCLRCK   // I2S ADC frame clock (= DACLRCK)
);

    // ── Forward the master clock to the codec ───────────────
    assign AUD_XCK = audio_clk;

    // ── Share DAC frame clock with ADC ──────────────────────
    assign AUD_ADCLRCK = AUD_DACLRCK;

    // ── All internal signal declarations ────────────────────
    // (Grouped here to avoid forward-reference errors in Questa.)

    // Register file
    logic        sweep_start;
    logic [7:0]  lut_addr;
    logic [23:0] lut_data;
    logic [12:0] fft_rd_addr;
    logic [23:0] fft_rd_real;
    logic [23:0] fft_rd_imag;

    // Internal control
    logic        we_lut;          // LUT write enable (self-clearing pulse)
    logic        calibrate_start; // One-cycle pulse to start calibration engine
    logic        fft_done;        // Calibration engine FFT complete
    logic        sweep_done;      // Latches high in audio domain when sweep reaches 20 kHz
    logic        sweep_reset;     // Active-high reset for sweep_generator and i2s_tx (audio domain)
    logic [23:0] amplitude;       // Sweep generator output

    // I2S RX outputs
    logic [23:0] i2s_rx_left;
    logic [23:0] i2s_rx_right;
    logic        i2s_rx_valid;

    // Toggle synchronizer (50 MHz → 12.288 MHz)
    logic        sweep_start_toggle;
    logic        tog_sync1, tog_sync2, tog_sync3;

    // done_sync: sweep_done (audio domain) → system clock domain
    logic        done_sync1, done_sync2;

    // rst_sync: async reset → synchronized release in audio domain
    logic        rst_sync1, rst_sync2;

    // Chunk counter
    logic        fft_done_prev;
    logic [7:0]  chunk_count;

    // FSM
    typedef enum logic [3:0] {
        IDLE        = 4'd0,
        CALIBRATING = 4'd1,
        DONE        = 4'd3
    } state_t;
    state_t state;

    // ── Register read ───────────────────────────────────────
    always_comb begin
        readdata = 32'd0;
        if (chipselect && read)
            case (address)
                4'd0: readdata = 32'd0;                    // CTRL is write-only
                4'd1: readdata = {28'd0, state};           // STATUS: FSM state
                4'd2: readdata = {24'd0, chunk_count};     // CHUNK_COUNT
                4'd3: readdata = 32'h0002_0000;            // VERSION
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
            lut_addr    <= 8'd0;
            we_lut      <= 1'b0;
            fft_rd_addr <= 13'd0;
        end else if (chipselect && write) begin
            we_lut <= 1'b0; // default off — only address 5 overrides this
            case (address)
                4'd0: sweep_start <= writedata[0];
                4'd4: lut_addr    <= writedata[7:0];
                4'd5: begin
                    we_lut   <= 1'b1;
                    lut_data <= writedata[23:0];
                end
                4'd6: fft_rd_addr <= writedata[12:0];
                default: ;
            endcase
        end else begin
            we_lut      <= 1'b0;  // self-clear LUT write enable
            sweep_start <= 1'b0;  // self-clear
        end
    end

    // ── Synchronization ───────────────────────────────────────
    // Toggle synchronizer: converts the one-cycle sweep_start pulse (50 MHz) into
    // a safe crossing to the 12.288 MHz audio domain, then reconstructs a clean
    // one-cycle pulse via XOR edge detection.
    always_ff @(posedge clk) begin
        if (reset)            sweep_start_toggle <= 1'b0;
        else if (sweep_start) sweep_start_toggle <= ~sweep_start_toggle;
    end

    always_ff @(posedge audio_clk) begin
        tog_sync1 <= sweep_start_toggle;
        tog_sync2 <= tog_sync1;
        tog_sync3 <= tog_sync2;
    end

    wire sweep_start_audio = tog_sync2 ^ tog_sync3; // one-cycle pulse in audio domain

    // Synchronize sweep_done from the audio clock domain back to the system clock domain
    always_ff @(posedge clk) begin
        done_sync1 <= sweep_done;
        done_sync2 <= done_sync1;
    end

    // Asynchronous reset synchronizer for audio domain:
    // rst_sync2 asserts immediately on reset (async preset), deasserts after 2 audio clocks.
    always_ff @(posedge audio_clk or posedge reset) begin
        if (reset) begin
            rst_sync1 <= 1'b1;
            rst_sync2 <= 1'b1;
        end else begin
            rst_sync1 <= 1'b0;
            rst_sync2 <= rst_sync1;
        end
    end

    assign sweep_reset = rst_sync2; // sweep_generator and i2s_tx share the audio-domain reset

    // ── Chunk counter ────────────────────────────────────────
    // Increments on each rising edge of fft_done (one per completed FFT frame).
    // Resets when FSM returns to IDLE (on new calibration trigger).
    always_ff @(posedge clk) begin
        if (reset) begin
            fft_done_prev <= 1'b0;
            chunk_count   <= 8'd0;
        end else begin
            fft_done_prev <= fft_done;
            if (state == IDLE)
                chunk_count <= 8'd0;
            else if (fft_done && !fft_done_prev)  // rising edge
                chunk_count <= chunk_count + 8'd1;
        end
    end

    // ── FSM ─────────────────────────────────────
    // Sweep and capture run simultaneously.  The calibration engine's
    // FFT cycles continuously (one 8192-point FFT per ~170 ms).
    // The HPS reads each chunk's results via FFT_ADDR/FFT_RDATA/FFT_IDATA,
    // using CHUNK_COUNT to know when a new result is available.
    always_ff @(posedge clk) begin
        if (reset) begin
            state           <= IDLE;
            calibrate_start <= 1'b0;
        end else begin
            calibrate_start <= 1'b0; // default: one-cycle pulse
            case (state)
                IDLE: begin
                    if (sweep_start) begin
                        state           <= CALIBRATING;
                        calibrate_start <= 1'b1; // arm capture engine NOW
                    end
                end
                CALIBRATING: begin
                    // Sweep and capture run together.  FFTs cycle automatically.
                    // fft_done toggles once per chunk; chunk_count tracks them.
                    if (done_sync2)              // sweep finished
                        state <= DONE;
                end
                DONE: begin
                    // Sticky.  HPS reads final chunk, then can re-trigger.
                    if (sweep_start)
                        state <= IDLE;
                end
            endcase
        end
    end

    // ── Sweep generator ─────────────────────────────────────
    sweep_generator sweep_inst (
        .clock    (audio_clk),
        .reset    (sweep_reset),
        .amplitude(amplitude),
        .clk_sys  (clk),
        .we_lut   (we_lut),
        .addr_lut (lut_addr),
        .din_lut  (lut_data),
        .start    (sweep_start_audio),
        .done     (sweep_done)
    );

    // ── Calibration engine ────────────────────────────────────
    calibration_engine calib_inst (
        .sysclk  (clk),
        .bclk    (AUD_BCLK),
        .lrclk   (AUD_DACLRCK),
        .aclr    (rst_sync2),
        .left_chan(i2s_rx_left),
        .rd_addr (fft_rd_addr),
        .rd_real (fft_rd_real),
        .rd_imag (fft_rd_imag),
        .start   (calibrate_start),
        .fft_done(fft_done)
    );

    // ── I2S transmitter ─────────────────────────────────────
    i2s_tx i2s_inst (
        .clock        (audio_clk),
        .reset        (sweep_reset),
        .left_sample  (amplitude),
        .right_sample (amplitude),
        .bclk         (AUD_BCLK),
        .lrck         (AUD_DACLRCK),
        .dacdat       (AUD_DACDAT)
    );

    // ── I2S receiver ─────────────────────────────────────────
    i2s_rx i2s_rx_inst (
        .clock       (audio_clk),
        .reset       (sweep_reset),
        .bclk        (AUD_BCLK),
        .lrck        (AUD_DACLRCK),
        .adcdat      (AUD_ADCDAT),
        .left_sample (i2s_rx_left),
        .right_sample(i2s_rx_right),
        .sample_valid(i2s_rx_valid)
    );

endmodule
