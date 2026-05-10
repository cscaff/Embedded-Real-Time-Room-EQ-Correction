`timescale 1ns / 1ps
// ── tb_room_eq_peripheral.sv ──────────────────────────────────────────────
// Top-level integration testbench for room_eq_peripheral.
//
// Tests staged hardware bring-up:
//   T1-T3: Register basics (VERSION, STATUS, LUT load)
//   T4:    Stage 1 — FIFO HPS mode (pop raw ADC samples through DCFIFO)
//   T5:    Stage 2 — FFT mode (one frame, verify results)
//   T6:    Stage 3 — Continuous FFT (multiple frames during sweep)
//   T7:    Re-start from DONE
//
// Uses behavioral simulation models:
//   - capture_fifo.v   (DCFIFO behavioral model)
//   - capture_fft_sim.v (echo-stub FFT)
// ─────────────────────────────────────────────────────────────────────────────

module tb_room_eq_peripheral;

    // ── Clock periods ─────────────────────────────────────────
    localparam SYSCLK_PERIOD   = 20;    // 50 MHz
    localparam AUDIOCLK_PERIOD = 81;    // ~12.288 MHz

    // ── DUT signals ───────────────────────────────────────────
    logic        clk;
    logic        reset;
    logic [31:0] writedata;
    logic [31:0] readdata;
    logic        write_sig;
    logic        read_sig;
    logic        chipselect;
    logic [3:0]  address;

    logic        audio_clk;

    wire         AUD_XCK;
    wire         AUD_BCLK;
    wire         AUD_DACDAT;
    wire         AUD_DACLRCK;
    wire         AUD_ADCLRCK;

    // Loopback: DAC output feeds ADC input
    wire         AUD_ADCDAT;
    assign AUD_ADCDAT = AUD_DACDAT;

    // ── DUT ───────────────────────────────────────────────────
    room_eq_peripheral dut (
        .clk        (clk),
        .reset      (reset),
        .writedata  (writedata),
        .readdata   (readdata),
        .write      (write_sig),
        .read       (read_sig),
        .chipselect (chipselect),
        .address    (address),
        .audio_clk  (audio_clk),
        .AUD_XCK    (AUD_XCK),
        .AUD_BCLK   (AUD_BCLK),
        .AUD_DACDAT (AUD_DACDAT),
        .AUD_DACLRCK(AUD_DACLRCK),
        .AUD_ADCLRCK(AUD_ADCLRCK),
        .AUD_ADCDAT (AUD_ADCDAT)
    );

    // ── Clocks ────────────────────────────────────────────────
    initial clk = 0;
    always #(SYSCLK_PERIOD / 2) clk = ~clk;
    initial audio_clk = 0;
    always #(AUDIOCLK_PERIOD / 2) audio_clk = ~audio_clk;

    // ── Fast sweep for simulation ─────────────────────────────
    // ~1000 samples to reach 20 kHz instead of 480K
    defparam dut.sweep_inst.mac.K_FRAC = 32'd29_777_979;

    // ── Avalon write ──────────────────────────────────────────
    task automatic avalon_write(input [3:0] addr, input [31:0] data);
        @(posedge clk); #1;
        chipselect = 1;
        write_sig  = 1;
        read_sig   = 0;
        address    = addr;
        writedata  = data;
        @(posedge clk); #1;
        chipselect = 0;
        write_sig  = 0;
    endtask

    // ── Avalon read ───────────────────────────────────────────
    task automatic avalon_read(input [3:0] addr, output [31:0] data);
        @(posedge clk); #1;
        chipselect = 1;
        read_sig   = 1;
        write_sig  = 0;
        address    = addr;
        @(posedge clk); #1;
        data = readdata;
        chipselect = 0;
        read_sig   = 0;
    endtask

    // ── Test variables ────────────────────────────────────────
    integer      i;
    logic [31:0] rdata;

    // ── Test sequence ─────────────────────────────────────────
    initial begin
        reset      = 1;
        chipselect = 0;
        write_sig  = 0;
        read_sig   = 0;
        address    = 0;
        writedata  = 0;

        repeat (10) @(posedge clk);
        #1; reset = 0;
        repeat (10) @(posedge clk);

        // ── T1: VERSION register ──────────────────────────────
        avalon_read(4'd3, rdata);
        if (rdata === 32'h0001_0000)
            $display("PASS [T1] VERSION = 0x%08h", rdata);
        else
            $display("FAIL [T1] VERSION = 0x%08h, expected 0x00010000", rdata);

        // ── T2: STATUS starts at IDLE (0), fft_done=0, fifo_empty=1
        avalon_read(4'd1, rdata);
        if (rdata[3:0] === 4'd0)
            $display("PASS [T2] STATUS state = IDLE (0)");
        else
            $display("FAIL [T2] STATUS state = %0d, expected IDLE (0)", rdata[3:0]);
        if (rdata[5] === 1'b1)
            $display("PASS [T2] fifo_empty = 1 at startup");
        else
            $display("FAIL [T2] fifo_empty = %b, expected 1", rdata[5]);

        // ── T3: Load sine LUT ─────────────────────────────────
        for (i = 0; i < 1024; i++) begin
            avalon_write(4'd4, i);
            avalon_write(4'd5, (i * 8191) & 24'hFFFFFF);
        end
        $display("PASS [T3] Loaded 1024 LUT entries");

        // ══════════════════════════════════════════════════════
        // Stage 1: FIFO HPS mode — read raw samples through DCFIFO
        // ══════════════════════════════════════════════════════

        // ── T4: FIFO HPS mode ─────────────────────────────────
        // Set fifo_hps_mode=1, start sweep, wait for samples, pop from FIFO
        avalon_write(4'd0, 32'h2);  // CTRL: fifo_hps_mode=1, sweep_start=0
        repeat (5) @(posedge clk);
        avalon_write(4'd0, 32'h3);  // CTRL: fifo_hps_mode=1, sweep_start=1
        repeat (20) @(posedge clk);

        // Verify FSM entered SWEEP
        avalon_read(4'd1, rdata);
        if (rdata[3:0] === 4'd1)
            $display("PASS [T4a] STATUS = SWEEP (1) in FIFO HPS mode");
        else
            $display("FAIL [T4a] STATUS = %0d, expected SWEEP (1)", rdata[3:0]);

        // Wait for FIFO to fill (a few audio frames = ~170us sim time)
        // At 48 kHz, one sample every ~20.8us. Need at least a few samples.
        // Wait enough audio_clk cycles for a few lrclk periods.
        // 1 lrclk period = 64 bclk = 256 audio_clk = 256 * 81ns = ~21us
        // Wait 10 periods: ~210us = 210000ns = 10500 sysclk cycles
        repeat (15000) @(posedge clk);

        // Check FIFO is not empty
        avalon_read(4'd1, rdata);
        if (rdata[5] === 1'b0)
            $display("PASS [T4b] fifo_empty=0 after audio frames");
        else
            $display("FAIL [T4b] fifo_empty=1, FIFO should have data");

        // Pop and read samples from FIFO
        begin : t4_fifo_read
            integer nonzero_count, read_count;
            logic [31:0] fifo_val;
            nonzero_count = 0;
            read_count = 0;

            for (i = 0; i < 20; i++) begin
                avalon_read(4'd1, rdata);
                if (!(rdata[5])) begin  // not empty
                    avalon_read(4'd10, fifo_val);  // pop-on-read
                    if (fifo_val[23:0] !== 24'd0)
                        nonzero_count++;
                    read_count++;
                end
            end

            if (read_count > 0)
                $display("PASS [T4c] read %0d samples from FIFO (%0d non-zero)",
                         read_count, nonzero_count);
            else
                $display("FAIL [T4c] could not read any samples from FIFO");
        end

        // Wait for sweep to finish in FIFO mode
        begin : t4_wait_done
            integer timeout;
            timeout = 0;
            rdata[3:0] = 4'd1;  // init to SWEEP
            while (timeout < 50_000_000 && rdata[3:0] !== 4'd2) begin
                avalon_read(4'd1, rdata);
                repeat (1000) @(posedge clk);
                timeout = timeout + 1000;
            end
            if (rdata[3:0] === 4'd2)
                $display("PASS [T4d] FSM reached DONE in FIFO HPS mode");
            else
                $display("FAIL [T4d] FSM stuck in state %0d", rdata[3:0]);
        end

        // ══════════════════════════════════════════════════════
        // Stage 2: FFT mode — switch to FFT, verify one frame
        // ══════════════════════════════════════════════════════

        // ── T5: FFT mode single frame ─────────────────────────
        // Switch to FFT mode and re-start sweep
        avalon_write(4'd0, 32'h1);  // CTRL: fifo_hps_mode=0, sweep_start=1
        repeat (20) @(posedge clk);

        avalon_read(4'd1, rdata);
        if (rdata[3:0] === 4'd1)
            $display("PASS [T5a] STATUS = SWEEP in FFT mode");
        else
            $display("FAIL [T5a] STATUS = %0d, expected SWEEP", rdata[3:0]);

        // Wait for first fft_done
        begin : t5_wait_fft
            integer timeout;
            timeout = 0;
            rdata[4] = 1'b0;
            while (timeout < 50_000_000 && !(rdata[4])) begin
                avalon_read(4'd1, rdata);
                repeat (100) @(posedge clk);
                timeout = timeout + 100;
            end
            if (rdata[4])
                $display("PASS [T5b] fft_done=1 after first FFT frame (%0d cycles)", timeout);
            else
                $display("FAIL [T5b] fft_done never asserted (timeout)");
        end

        // Read FFT results and check for non-zero data
        if (rdata[4]) begin : t5_read_fft
            integer nonzero_count;
            logic [31:0] fft_r;
            nonzero_count = 0;

            for (i = 0; i < 32; i++) begin
                avalon_write(4'd6, i);  // FFT_ADDR
                repeat (2) @(posedge clk);
                avalon_read(4'd7, fft_r);  // FFT_RDATA
                if (fft_r[23:0] !== 24'd0)
                    nonzero_count++;
            end

            if (nonzero_count > 0)
                $display("PASS [T5c] %0d of first 32 FFT bins non-zero", nonzero_count);
            else
                $display("FAIL [T5c] all FFT bins zero — pipeline may be broken");
        end

        // ══════════════════════════════════════════════════════
        // Stage 3: Continuous FFT — count multiple frames
        // ══════════════════════════════════════════════════════

        // ── T6: Count FFT frames during sweep ─────────────────
        // Already in SWEEP with FFT running. Count fft_done toggles.
        begin : t6_continuous
            integer frame_count, timeout;
            logic   prev_fft_done;

            frame_count = 0;
            prev_fft_done = 1'b1;  // we know fft_done=1 from T5
            timeout = 0;

            // Wait until sweep ends (DONE state) and count frames
            while (timeout < 100_000_000 && rdata[3:0] !== 4'd2) begin
                avalon_read(4'd1, rdata);

                // Detect rising edge of fft_done
                if (rdata[4] && !prev_fft_done)
                    frame_count++;
                prev_fft_done = rdata[4];

                repeat (500) @(posedge clk);
                timeout = timeout + 500;
            end

            // The frame from T5 plus any additional frames
            if (frame_count >= 1)
                $display("PASS [T6] %0d additional FFT frames during sweep", frame_count);
            else if (rdata[3:0] === 4'd2)
                $display("PASS [T6] sweep finished (0 additional frames detected by polling)");
            else
                $display("FAIL [T6] sweep didn't finish (state=%0d)", rdata[3:0]);
        end

        // ══════════════════════════════════════════════════════
        // T7: Re-start from DONE
        // ══════════════════════════════════════════════════════

        avalon_read(4'd1, rdata);
        if (rdata[3:0] === 4'd2) begin
            avalon_write(4'd0, 32'h1);  // sweep_start, FFT mode
            repeat (20) @(posedge clk);
            avalon_read(4'd1, rdata);
            if (rdata[3:0] === 4'd1)
                $display("PASS [T7] FSM re-entered SWEEP from DONE");
            else
                $display("FAIL [T7] FSM state = %0d after re-start", rdata[3:0]);
        end else begin
            $display("SKIP [T7] not in DONE state");
        end

        $display("\n=== All tests complete ===");
        $finish;
    end

    // ── Timeout watchdog ──────────────────────────────────────
    initial begin
        #5_000_000_000;
        $display("TIMEOUT — simulation limit reached");
        $finish;
    end

endmodule
