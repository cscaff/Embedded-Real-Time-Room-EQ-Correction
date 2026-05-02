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
    input  logic [2:0]  address,      // register address (word offset)

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

    // ── Register read ───────────────────────────────────────
    always_comb begin
        readdata = 32'd0;
        if (chipselect && read)
            case (address)
                3'd0: readdata = {30'd0, sweep_running, 1'b0};
                3'd1: readdata = 32'd0;            // STATUS: reserved
                3'd2: readdata = sweep_len;
                3'd3: readdata = 32'h0001_0000;    // VERSION
                default: readdata = 32'd0;
            endcase
    end

    // ── Register write ──────────────────────────────────────
    always_ff @(posedge clk) begin
        if (reset) begin
            sweep_start <= 1'b0;
            sweep_len   <= 32'd480_000;  // default: 10 seconds at 48 kHz
        end else if (chipselect && write) begin
            case (address)
                3'd0: sweep_start <= writedata[0];
                3'd2: sweep_len   <= writedata;
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

    // LUT init state machine
    logic [8:0]  lut_init_cnt;  // 0-256 (256 = done)

    // Precomputed quarter-wave sine values (256 entries)
    // sin(i * pi / 512) * 8388607 for i = 0..255
    // We compute this combinationally from the counter.
    // NOTE: For synthesis, we use a ROM-style init.
    // iverilog supports $sin but Quartus doesn't in synthesis.
    // For now, we use a simple linear approximation init that
    // will be replaced with a proper ROM or init from HPS.
    //
    // Actually, the cleanest approach: have the HPS write the
    // LUT values through registers after boot. This avoids
    // needing $sin in synthesis. For the initial hardware test,
    // we'll init the LUT from a generate block with hard-coded values.

    // For initial bring-up: use a MIF file or HPS init.
    // For now, flag as not done and let the sweep run with
    // whatever is in BRAM (zeros until HPS writes it).
    //
    // TODO: Add registers for HPS to write LUT values, or
    //       use a .mif file for BRAM initialization.

    // Temporary: simple init from a counter-based approach
    // that produces a rough sine. Will be replaced.
    always_ff @(posedge clk) begin
        if (reset) begin
            lut_init_cnt  <= 9'd0;
            lut_init_done <= 1'b0;
            we_lut        <= 1'b0;
        end else if (!lut_init_done) begin
            if (lut_init_cnt < 9'd256) begin
                we_lut   <= 1'b1;
                addr_lut <= lut_init_cnt[7:0];
                // Approximate quarter-wave sine using a parabolic
                // approximation: sin(x) ≈ x*(256-x)*2/256^2 * MAX
                // where x = lut_init_cnt, MAX = 8388607
                // This gives a reasonable sine shape for bring-up.
                din_lut <= (lut_init_cnt[7:0] * (8'd255 - lut_init_cnt[7:0])) << 7;
                lut_init_cnt <= lut_init_cnt + 9'd1;
            end else begin
                we_lut        <= 1'b0;
                lut_init_done <= 1'b1;
            end
        end else begin
            we_lut <= 1'b0;
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
        .addr_lut (addr_lut),
        .din_lut  (din_lut)
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
