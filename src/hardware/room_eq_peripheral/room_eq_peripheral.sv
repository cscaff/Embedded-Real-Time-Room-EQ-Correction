/*
 * Avalon memory-mapped peripheral for Real-Time Room EQ Correction
 *
 * CSEE W4840 — Embedded Systems
 * Jacob Boxerman, Roland List, Christian Scaff
 *
 * Register map (32-bit words):
 *
 * Offset      Bits      Access   Meaning
 *   0         [0]       R/W      CTRL: bit 0 = sweep_start (write 1 to trigger,
 *                                             self-clears after one cycle)
 *                                      bit 1 = sweep_running (read-only)
 *   1         [31:0]    R        STATUS: reserved
 *   2         [31:0]    R/W      SWEEP_LEN: sweep length in samples (default 480000 = 10s)
 *   3         [31:0]    R        VERSION: 32'h0001_0000
 *   4..259    [23:0]    W        SINE_LUT: quarter-wave sine BRAM (256 × 24-bit)
 *                                Write offset (LUT_BASE + i) with sin(i×π/512)×8388607
 *                                (LUT_BASE must match localparam below and codec_init.c)
 *
 * Audio conduit signals connect to the WM8731 codec on the DE1-SoC.
 * The PLL-generated 12.288 MHz audio clock is received from Platform Designer.
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
    input  logic [10:0] address,      // register/LUT word offset (0..1027)

    // Audio clock from PLL
    input  logic        audio_clk,    // 12.288 MHz from audio PLL

    // Audio conduit — directly to codec pins
    output logic        AUD_XCK,      // master clock to codec (12.288 MHz)
    output logic        AUD_BCLK,     // I2S bit clock
    output logic        AUD_DACDAT,   // I2S serial data
    output logic        AUD_DACLRCK  // I2S frame clock (L/R)
);

    // ── Address map ──────────────────────────────────────────
    //   Offsets 0..3   : control registers
    //   Offsets 4..259 : sine LUT (256 quarter-wave entries)
    localparam [10:0] LUT_BASE = 11'd4;
    localparam [10:0] LUT_SIZE = 11'd1024;

    // ── Forward master clock to codec ────────────────────────
    assign AUD_XCK = audio_clk;

    // ── Control registers ────────────────────────────────────
    logic        sweep_start;   // one-cycle pulse: HPS writes 1 to CTRL[0]
    logic        sweep_running; // read-only status
    logic [31:0] sweep_len;     // sweep length in samples

    // ── Sine LUT write signals (to sweep_generator) ──────────
    logic        we_lut;
    logic  [9:0] addr_lut;
    logic [23:0] din_lut;

    // ── Register read ────────────────────────────────────────
    always_comb begin
        readdata = 32'd0;
        if (chipselect && read)
            case (address)
                11'd0:    readdata = {30'd0, sweep_running, 1'b0};
                11'd1:    readdata = 32'd0;           // STATUS: reserved
                11'd2:    readdata = sweep_len;
                11'd3:    readdata = 32'h0001_0000;   // VERSION
                default: readdata = 32'd0;           // LUT not readable
            endcase
    end

    // ── Register / LUT write ─────────────────────────────────
    always_ff @(posedge clk) begin
        if (reset) begin
            sweep_start <= 1'b0;
            sweep_len   <= 32'd480_000;  // default: 10 s at 48 kHz
            we_lut      <= 1'b0;
            addr_lut    <= 8'd0;
            din_lut     <= 24'd0;
        end else begin
            // Self-clearing defaults
            sweep_start <= 1'b0;
            we_lut      <= 1'b0;

            if (chipselect && write) begin
                if (address < LUT_BASE) begin
                    // ── Control registers ─────────────────
                    case (address)
                        11'd0: sweep_start <= writedata[0];
                        11'd2: sweep_len   <= writedata;
                        default: ;
                    endcase
                end else if (address < LUT_BASE + LUT_SIZE) begin
                    // ── Sine LUT write ────────────────────
                    // address[7:0] - LUT_BASE[7:0] gives the BRAM index
                    // (modular 10-bit arithmetic is correct for all 1024 entries)
                    addr_lut <= address[9:0] - LUT_BASE[9:0];
                    din_lut  <= writedata[23:0];
                    we_lut   <= 1'b1;
                end
            end
        end
    end

    // ── Sweep control ─────────────────────────────────────────

    // Sample counter in audio clock domain.
    // Counts 48 kHz ticks (audio_clk / 256); stops sweep at sweep_len.
    // sweep_len is quasi-static: written by HPS before sweep starts,
    // stable for the entire sweep duration — safe to read cross-domain.
    logic        sweep_active;
    logic        sweep_done_audio;  // asserted in audio clock domain when done

    // Sync sweep_done_audio → sys clock domain (2-FF)
    logic sweep_done_sync1, sweep_done_sync2;
    always_ff @(posedge clk) begin
        sweep_done_sync1 <= sweep_done_audio;
        sweep_done_sync2 <= sweep_done_sync1;
    end

    always_ff @(posedge clk) begin
        if (reset)
            sweep_active <= 1'b0;
        else if (sweep_start)
            sweep_active <= 1'b1;
        else if (sweep_done_sync2)
            sweep_active <= 1'b0;
    end

    assign sweep_running = sweep_active;

    // Synchronise sweep_active into the audio clock domain (2-FF)
    logic sweep_active_sync1, sweep_active_sync2;
    always_ff @(posedge audio_clk) begin
        sweep_active_sync1 <= sweep_active;
        sweep_active_sync2 <= sweep_active_sync1;
    end

    logic sweep_reset;
    assign sweep_reset = ~sweep_active_sync2;

    // 48 kHz tick divider + sample counter (audio clock domain)
    logic [7:0]  smpl_div;
    logic        smpl_en;
    logic [31:0] sample_cnt;

    always_ff @(posedge audio_clk) begin
        if (sweep_reset) begin
            smpl_div      <= 8'd0;
            smpl_en       <= 1'b0;
            sample_cnt    <= 32'd0;
            sweep_done_audio <= 1'b0;
        end else begin
            smpl_en  <= (smpl_div == 8'd255);
            smpl_div <= smpl_div + 8'd1;

            if (smpl_en && !sweep_done_audio) begin
                if (sample_cnt == sweep_len - 1)
                    sweep_done_audio <= 1'b1;
                else
                    sample_cnt <= sample_cnt + 32'd1;
            end
        end
    end

    // ── Sweep generator ───────────────────────────────────────
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

    // ── I2S transmitter ───────────────────────────────────────
    // Mono: same sample on both channels
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
