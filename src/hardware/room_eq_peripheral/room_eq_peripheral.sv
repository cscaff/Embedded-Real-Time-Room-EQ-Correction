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
 *   1      [3:0]     R        STATUS: FSM state — 0=IDLE, 1=SWEEP, 2=CAPTURE, 3=DONE
 *   2      [31:0]    R/W      SWEEP_LEN: sweep length in samples (default 480000 = 10s) TODO: I would remove. I think our sweep length is hardcoded.
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
    logic [7:0]  lut_addr;
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
                4'd1: readdata = {28'd0, state};   // STATUS: FSM state
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
            we_lut      <= 1'b0;
            fft_rd_addr <= 13'd0;
        end else if (chipselect && write) begin
            case (address)
                4'd0: sweep_start <= writedata[0];
                4'd2: sweep_len   <= writedata;
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

    // Internal Signals
    logic        we_lut; // LUT write enable (self-clearing pulse - Pulses when address 5 is written to.)
    logic        calibrate_start; // Signal to start the calibration engine (synchronized to System Clock)
    logic        fft_done; // Signal from calibration engine indicating FFT processing is complete. RAM can be read.


    // ── Synchronization ───────────────────────────────────────
    // Synchronize sweep_start into the audio clock domain
    logic sweep_start_sync1, sweep_start_sync2;
    always_ff @(posedge audio_clk) begin
        sweep_start_sync1 <= sweep_start;
        sweep_start_sync2 <= sweep_start_sync1;
    end

    // Synchronize sweep_done from the audio clock domain back to the system clock domain
    logic done_sync1, done_sync2;
    always_ff @(posedge clk) begin
        done_sync1 <= sweep_done; 
        done_sync2 <= done_sync1;
    end

    // Asycnhronous reset for calibration engine
    logic rst_sync1, rst_sync2;
    always_ff @(posedge audio_clk or posedge reset) begin
        if (reset) begin
            rst_sync1 <= 1'b1; // Reset goes high right on reset assertion (Async)
            rst_sync2 <= 1'b1;
        end else begin
            rst_sync1 <= 1'b0; // Reset deasserts after two audio clock cycles (Synchronized to audio clock domain) to avoid metastability.
            rst_sync2 <= rst_sync1;
        end
    end
  
  
    // ── FSM ─────────────────────────────────────
    typedef enum logic [3:0] {
        IDLE,
        SWEEP,
        CAPTURE,
        DONE
    } state_t;

    state_t state;

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE; // Start in IDLE State
            calibrate_start <= 1'b0; // Calibration engine is not started until we enter the CAPTURE state
        end else begin
            // Default Values
            calibrate_start <= 1'b0;
            case (state)
                IDLE: begin
                    if (sweep_start) begin
                        state <= SWEEP;
                    end
                end
                SWEEP: begin 
                    //  Wait until the sweep is done (Sweep programmed to run for 5 seconds from 20 Hz to 20 kHz.)
                    if (done_sync2) begin
                        state <= CAPTURE;
                        calibrate_start <= 1'b1;
                    end
                end
                CAPTURE: begin
                    if (fft_done) begin
                        state <= DONE;
                    end
                end
                DONE: begin
                    // Return to Idle
                    state <= IDLE;
                end
            endcase
        end
    end


    // ── Sweep generator ─────────────────────────────────────
    logic [23:0] amplitude;

    sweep_generator sweep_inst (
        .clock    (audio_clk),
        .reset    (sweep_reset),
        .amplitude(amplitude),
        .clk_sys  (clk),
        .we_lut   (we_lut),
        .addr_lut (lut_addr),
        .din_lut  (lut_data),
        .start    (sweep_start_sync2), // Start signal synchronized to audio clock domain
        .done     (sweep_done) // Unconnected for now, will connect to FSM when done signal is
    );

    // ── Calibration engine ────────────────────────────────────
    calibration_engine calib_inst (
        .sysclk(sysclk),
        .bclk(AUD_BCLK),
        .lrclk(AUD_DACLRCK),
        .aclr(rst_sync2),
        .left_chan(amplitude), // feed the sweep output into the calibration engine
        .rd_addr(fft_rd_addr),
        .rd_real(fft_rd_real), 
        .rd_imag(fft_rd_imag),
        .start(calibrate_start), // Start signal for calibration engine. Exists in clock domain. No need to synchronize.
        .fft_done(fft_done)
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

    // ── TODO: I2S reciever ─────────────────────────────────────

endmodule
