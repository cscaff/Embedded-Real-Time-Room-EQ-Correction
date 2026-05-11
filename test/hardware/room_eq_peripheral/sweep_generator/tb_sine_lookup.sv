`timescale 1ns / 1ps

module tb_sine_lookup;

    // ── Clock parameters ─────────────────────────────────────
    localparam CLK_SYS_PERIOD  = 20;   // 50 MHz
    localparam CLK_SAMP_PERIOD = 81;   // ~12.288 MHz (matches real PLL)
    localparam CLKS_PER_SAMPLE = 256;  // 12.288 MHz / 48 kHz

    // ── Signals ──────────────────────────────────────────────
    logic        clock, clk_sys;
    logic        reset;
    logic        sample_en;
    logic [31:0] phase;
    logic [23:0] amplitude;

    // Port A — LUT init
    logic        we_lut;
    logic [9:0]  addr_lut;
    logic [23:0] din_lut;

    // ── DUT ─────────────────────────────────────────────────
    sine_lookup dut (
        .clock     (clock),
        .reset     (reset),
        .sample_en (sample_en),
        .phase     (phase),
        .amplitude (amplitude),
        .clk_sys   (clk_sys),
        .we_lut    (we_lut),
        .addr_lut  (addr_lut),
        .din_lut   (din_lut)
    );

    // ── Clock generators ──────────────────────────────────────
    initial clk_sys = 0;
    always #(CLK_SYS_PERIOD / 2)  clk_sys = ~clk_sys;

    initial clock = 0;
    always #(CLK_SAMP_PERIOD / 2) clock = ~clock;

    // ── Realistic sample_en: one pulse every 256 audio clocks ─
    logic [7:0] clk_div;
    always_ff @(posedge clock) begin
        if (reset) begin
            clk_div   <= 8'd0;
            sample_en <= 1'b0;
        end else begin
            clk_div   <= clk_div + 1'b1;
            sample_en <= (clk_div == 8'd254); // fires when counter hits 255
        end
    end

    // ── LUT write task (Port A) ───────────────────────────────
    task automatic write_lut(input [9:0] a, input [23:0] d);
        @(posedge clk_sys); #1;
        addr_lut = a;
        din_lut  = d;
        we_lut   = 1;
        @(posedge clk_sys); #1;
        we_lut   = 0;
    endtask

    // ── Wait for next sample output ──────────────────────────
    // Waits until the pipeline completes after the next sample_en.
    // With the 5-stage pipeline, amplitude updates 5 clocks after sample_en.
    task automatic wait_for_sample;
        @(posedge sample_en);
        repeat (6) @(posedge clock); // 5 pipeline stages + margin
    endtask

    // ── Variables ─────────────────────────────────────────────
    integer      i;
    real         sine_val;
    logic [23:0] amp;
    integer      csv_fd;

    localparam real MAX_AMP = 8388607.0;  // 2^23 - 1
    localparam real PI      = 3.14159265358979;

    // Discontinuity detection
    integer      fail_count;
    logic signed [23:0] prev_amp;
    logic signed [23:0] curr_amp;
    integer signed      delta;
    integer signed      max_delta;
    integer              max_delta_sample;

    initial begin
        // ── Default state ─────────────────────────────────────
        reset     = 1;
        phase     = 0;
        we_lut    = 0;
        addr_lut  = 0;
        din_lut   = 0;

        // ── Load 1024-entry sine LUT via Port A ──────────────
        for (i = 0; i < 1024; i++) begin
            sine_val = $sin(i * PI / 2048.0) * MAX_AMP;
            write_lut(i[9:0], $rtoi(sine_val));
        end

        repeat (4) @(posedge clk_sys);

        // ── Release reset ─────────────────────────────────────
        @(posedge clock); #1;
        reset = 0;

        // Wait for a few sample periods to flush
        repeat (4) wait_for_sample();

        // ── T1: Phase=0 should give ~0 ───────────────────────
        phase = 32'h00000000;
        wait_for_sample();
        $display("T1 phase=0: amplitude=%0d (expect ~0)", $signed(amplitude));

        // ── T2: Phase=90deg should give ~+max ────────────────
        phase = 32'h40000000;
        wait_for_sample();
        $display("T2 phase=90: amplitude=%0d (expect ~%0d)", $signed(amplitude), $rtoi(MAX_AMP));

        // ── T3: Phase=180deg should give ~0 ──────────────────
        phase = 32'h80000000;
        wait_for_sample();
        $display("T3 phase=180: amplitude=%0d (expect ~0)", $signed(amplitude));

        // ── T4: Phase=270deg should give ~-max ───────────────
        phase = 32'hC0000000;
        wait_for_sample();
        $display("T4 phase=270: amplitude=%0d (expect ~%0d)", $signed(amplitude), -$rtoi(MAX_AMP));

        // ── T5: Quadrant sign checks ─────────────────────────
        phase = 32'h10000000; wait_for_sample();
        if ($signed(amplitude) > 0) $display("PASS [T5 Q0 positive]");
        else $display("FAIL [T5 Q0 positive] amplitude=%0d", $signed(amplitude));

        phase = 32'h50000000; wait_for_sample();
        if ($signed(amplitude) > 0) $display("PASS [T5 Q1 positive]");
        else $display("FAIL [T5 Q1 positive] amplitude=%0d", $signed(amplitude));

        phase = 32'h90000000; wait_for_sample();
        if ($signed(amplitude) < 0) $display("PASS [T5 Q2 negative]");
        else $display("FAIL [T5 Q2 negative] amplitude=%0d", $signed(amplitude));

        phase = 32'hD0000000; wait_for_sample();
        if ($signed(amplitude) < 0) $display("PASS [T5 Q3 negative]");
        else $display("FAIL [T5 Q3 negative] amplitude=%0d", $signed(amplitude));

        // ══════════════════════════════════════════════════════
        // T6: DISCONTINUITY TEST — sweep phase linearly and
        // check that sample-to-sample jumps stay bounded.
        //
        // A clean sine at any frequency should have bounded
        // sample-to-sample deltas. A click/pop shows up as a
        // delta much larger than expected.
        //
        // We use a phase increment that sweeps ~200 Hz (fast
        // enough to cross quadrant boundaries in a few hundred
        // samples).
        // ══════════════════════════════════════════════════════
        $display("\n--- T6: Discontinuity sweep test ---");
        begin
            localparam [31:0] PHASE_INC = 32'd17895698; // ~200 Hz: (200/48000)*2^32
            localparam integer NUM_SAMPLES = 2000;
            // At 200 Hz, one full cycle = 240 samples. 2000 samples = ~8 cycles.
            // Max expected delta for a 200 Hz sine at 48 kHz:
            //   d/dt[sin(2*pi*200*t)] at sample rate = 2*pi*200/48000 * MAX_AMP ≈ 219k
            // Allow 2x margin for interpolation imprecision.
            localparam integer MAX_ALLOWED_DELTA = 440000;

            fail_count = 0;
            max_delta = 0;
            max_delta_sample = 0;

            phase = 32'd0;
            wait_for_sample();
            prev_amp = $signed(amplitude);

            csv_fd = $fopen("sim_out/discontinuity_test.csv", "w");
            $fwrite(csv_fd, "sample,amplitude,delta\n");
            $fwrite(csv_fd, "0,%0d,0\n", prev_amp);

            for (i = 1; i < NUM_SAMPLES; i++) begin
                phase = phase + PHASE_INC;
                wait_for_sample();
                curr_amp = $signed(amplitude);
                delta = curr_amp - prev_amp;
                if (delta < 0) delta = -delta;

                $fwrite(csv_fd, "%0d,%0d,%0d\n", i, curr_amp, delta);

                if (delta > MAX_ALLOWED_DELTA) begin
                    if (fail_count < 10) // only print first 10
                        $display("  CLICK at sample %0d: amplitude=%0d, prev=%0d, delta=%0d",
                                 i, curr_amp, prev_amp, delta);
                    fail_count++;
                end
                if (delta > max_delta) begin
                    max_delta = delta;
                    max_delta_sample = i;
                end
                prev_amp = curr_amp;
            end

            $fclose(csv_fd);
            $display("  Max delta: %0d at sample %0d", max_delta, max_delta_sample);
            if (fail_count == 0)
                $display("PASS [T6] No discontinuities in %0d samples", NUM_SAMPLES);
            else
                $display("FAIL [T6] %0d discontinuities detected (threshold=%0d)", fail_count, MAX_ALLOWED_DELTA);
        end

        // ══════════════════════════════════════════════════════
        // T7: Quadrant boundary stress test — phase values
        // that land exactly at and near quadrant transitions.
        // ══════════════════════════════════════════════════════
        $display("\n--- T7: Quadrant boundary test ---");
        begin
            logic signed [23:0] amp_before, amp_at, amp_after;
            integer signed d1, d2;

            // Q0→Q1 boundary: phase[31:30] transitions from 00 to 01
            phase = 32'h3FF00000; wait_for_sample(); amp_before = $signed(amplitude);
            phase = 32'h40000000; wait_for_sample(); amp_at     = $signed(amplitude);
            phase = 32'h40100000; wait_for_sample(); amp_after  = $signed(amplitude);

            d1 = amp_at - amp_before; if (d1 < 0) d1 = -d1;
            d2 = amp_after - amp_at;  if (d2 < 0) d2 = -d2;
            $display("  Q0->Q1: before=%0d, at=%0d, after=%0d (deltas: %0d, %0d)",
                     amp_before, amp_at, amp_after, d1, d2);
            if (d1 > 500000 || d2 > 500000)
                $display("FAIL [T7 Q0->Q1] large jump at boundary");
            else
                $display("PASS [T7 Q0->Q1]");

            // Q1→Q2 boundary
            phase = 32'h7FF00000; wait_for_sample(); amp_before = $signed(amplitude);
            phase = 32'h80000000; wait_for_sample(); amp_at     = $signed(amplitude);
            phase = 32'h80100000; wait_for_sample(); amp_after  = $signed(amplitude);

            d1 = amp_at - amp_before; if (d1 < 0) d1 = -d1;
            d2 = amp_after - amp_at;  if (d2 < 0) d2 = -d2;
            $display("  Q1->Q2: before=%0d, at=%0d, after=%0d (deltas: %0d, %0d)",
                     amp_before, amp_at, amp_after, d1, d2);
            if (d1 > 500000 || d2 > 500000)
                $display("FAIL [T7 Q1->Q2] large jump at boundary");
            else
                $display("PASS [T7 Q1->Q2]");

            // Q2→Q3 boundary
            phase = 32'hBFF00000; wait_for_sample(); amp_before = $signed(amplitude);
            phase = 32'hC0000000; wait_for_sample(); amp_at     = $signed(amplitude);
            phase = 32'hC0100000; wait_for_sample(); amp_after  = $signed(amplitude);

            d1 = amp_at - amp_before; if (d1 < 0) d1 = -d1;
            d2 = amp_after - amp_at;  if (d2 < 0) d2 = -d2;
            $display("  Q2->Q3: before=%0d, at=%0d, after=%0d (deltas: %0d, %0d)",
                     amp_before, amp_at, amp_after, d1, d2);
            if (d1 > 500000 || d2 > 500000)
                $display("FAIL [T7 Q2->Q3] large jump at boundary");
            else
                $display("PASS [T7 Q2->Q3]");

            // Q3→Q0 boundary (wrap)
            phase = 32'hFFF00000; wait_for_sample(); amp_before = $signed(amplitude);
            phase = 32'h00000000; wait_for_sample(); amp_at     = $signed(amplitude);
            phase = 32'h00100000; wait_for_sample(); amp_after  = $signed(amplitude);

            d1 = amp_at - amp_before; if (d1 < 0) d1 = -d1;
            d2 = amp_after - amp_at;  if (d2 < 0) d2 = -d2;
            $display("  Q3->Q0: before=%0d, at=%0d, after=%0d (deltas: %0d, %0d)",
                     amp_before, amp_at, amp_after, d1, d2);
            if (d1 > 500000 || d2 > 500000)
                $display("FAIL [T7 Q3->Q0] large jump at boundary");
            else
                $display("PASS [T7 Q3->Q0]");
        end

        // ══════════════════════════════════════════════════════
        // T8: Full-cycle CSV dump for visual inspection
        // ══════════════════════════════════════════════════════
        csv_fd = $fopen("sim_out/sine_wave.csv", "w");
        $fdisplay(csv_fd, "phase_index,amplitude");
        for (i = 0; i < 1024; i++) begin
            phase = 32'(i * (65536 * 64));
            wait_for_sample();
            $fdisplay(csv_fd, "%0d,%0d", i, $signed(amplitude));
        end
        $fclose(csv_fd);
        $display("\nT8 CSV written to sim_out/sine_wave.csv");

        $display("\n=== All tests complete ===");
        $finish;
    end

    // ── Timeout watchdog ──────────────────────────────────────
    initial begin
        #2_000_000_000; // 2 seconds sim time
        $display("TIMEOUT — simulation limit reached");
        $finish;
    end

endmodule
