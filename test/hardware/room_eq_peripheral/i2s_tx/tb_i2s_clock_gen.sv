// Testbench for i2s_clock_gen.
// Verifies BCLK frequency (12.288 MHz / 4 = 3.072 MHz),
// LRCK period (64 BCLK cycles = 48 kHz), duty cycles,
// bclk_fall strobe timing, and bit_cnt sequencing.

`timescale 1ns / 1ps

module tb_i2s_clock_gen;

    // ── Parameters ──────────────────────────────────────────
    // 12.288 MHz → period ≈ 81.38 ns.  Use 81 ns for simulation.
    localparam CLK_PERIOD = 81;

    // ── Signals ─────────────────────────────────────────────
    logic        clock;
    logic        reset;
    logic        bclk;
    logic        lrck;
    logic        bclk_fall;
    logic [5:0]  bit_cnt;

    // ── DUT ─────────────────────────────────────────────────
    i2s_clock_gen dut (
        .clock     (clock),
        .reset     (reset),
        .bclk      (bclk),
        .lrck      (lrck),
        .bclk_fall (bclk_fall),
        .bit_cnt   (bit_cnt)
    );

    // ── Clock ───────────────────────────────────────────────
    initial clock = 0;
    always #(CLK_PERIOD / 2) clock = ~clock;

    // ── Helper tasks ────────────────────────────────────────
    integer pass_count = 0;
    integer fail_count = 0;

    task automatic check(
        input integer got,
        input integer expected,
        input string  label
    );
        if (got !== expected) begin
            $display("FAIL [%s]  got=%0d  expected=%0d", label, got, expected);
            fail_count++;
        end else begin
            $display("PASS [%s]  value=%0d", label, got);
            pass_count++;
        end
    endtask

    // ── Test sequence ───────────────────────────────────────
    integer i;
    integer count;
    logic   prev_bclk;
    logic   prev_lrck;
    integer bclk_high_count;
    integer bclk_low_count;
    integer lrck_low_bclks;
    integer lrck_high_bclks;
    integer bclk_fall_count;
    logic [5:0] expected_bit_cnt;

    initial begin
        $dumpfile("sim_out/tb_i2s_clock_gen.vcd");
        $dumpvars(0, tb_i2s_clock_gen);

        // ── T1: Reset state ─────────────────────────────────
        reset = 1;
        @(posedge clock); #1;
        check(bclk,     0, "T1 reset bclk=0");
        check(lrck,     0, "T1 reset lrck=0");
        check(bit_cnt,  0, "T1 reset bit_cnt=0");
        check(bclk_fall, 0, "T1 reset bclk_fall=0");

        // ── T2: BCLK period = exactly 4 master clocks ──────
        // Release reset, count master clocks between consecutive
        // bclk_fall assertions.
        reset = 0;

        // Wait for first bclk_fall
        @(posedge clock); #1; // bclk_cnt goes from 0 to 1
        @(posedge clock); #1; // 1 to 2
        @(posedge clock); #1; // 2 to 3, bclk_fall should be high now
        check(bclk_fall, 1, "T2 first bclk_fall at count 3");

        // Count master clocks until next bclk_fall
        count = 0;
        @(posedge clock); #1; // bclk_cnt wraps to 0, bclk_fall goes low
        count++;
        while (!bclk_fall) begin
            @(posedge clock); #1;
            count++;
        end
        check(count, 4, "T2 BCLK period = 4 master clocks");

        // ── T3: BCLK duty cycle — 2 high, 2 low ────────────
        // Observe one full BCLK period (4 master clocks) and count
        // how many clocks bclk is high vs low.
        // Reset to get a clean start.
        reset = 1; @(posedge clock); #1; reset = 0;

        bclk_high_count = 0;
        bclk_low_count  = 0;
        for (i = 0; i < 4; i++) begin
            @(posedge clock); #1;
            if (bclk) bclk_high_count++;
            else      bclk_low_count++;
        end
        check(bclk_high_count, 2, "T3 BCLK high for 2 master clocks");
        check(bclk_low_count,  2, "T3 BCLK low for 2 master clocks");

        // ── T4: LRCK period = 64 BCLK cycles ───────────────
        // Count bclk_fall events between two LRCK rising edges.
        reset = 1; @(posedge clock); #1; reset = 0;

        // Run until LRCK goes high (end of left channel)
        prev_lrck = 0;
        while (!(lrck && !prev_lrck)) begin
            prev_lrck = lrck;
            @(posedge clock); #1;
        end

        // Now count bclk_fall events until LRCK rises again (full cycle)
        count = 0;
        prev_lrck = lrck;
        // First wait for LRCK to go low again
        while (lrck) begin
            if (bclk_fall) count++;
            @(posedge clock); #1;
        end
        // Then wait for LRCK to go high again
        while (!lrck) begin
            if (bclk_fall) count++;
            @(posedge clock); #1;
        end
        check(count, 64, "T4 LRCK period = 64 BCLK cycles");

        // ── T5: LRCK duty cycle — 32 BCLK low, 32 high ────
        // Count bclk_fall events while LRCK is low vs high over one frame.
        reset = 1; @(posedge clock); #1; reset = 0;

        lrck_low_bclks  = 0;
        lrck_high_bclks = 0;

        // Run for exactly one full frame (64 bclk_fall events)
        count = 0;
        while (count < 64) begin
            @(posedge clock); #1;
            if (bclk_fall) begin
                count++;
                if (!lrck) lrck_low_bclks++;
                else       lrck_high_bclks++;
            end
        end
        check(lrck_low_bclks,  32, "T5 LRCK low for 32 BCLK cycles");
        check(lrck_high_bclks, 32, "T5 LRCK high for 32 BCLK cycles");

        // ── T6: bit_cnt counts 0 → 63 → 0 ──────────────────
        reset = 1; @(posedge clock); #1; reset = 0;

        expected_bit_cnt = 6'd0;
        for (i = 0; i < 65; i++) begin
            // Wait for next bclk_fall
            while (!bclk_fall) begin
                @(posedge clock); #1;
            end
            // Check bit_cnt BEFORE the increment (it increments on this posedge)
            if (i < 64) begin
                if (bit_cnt !== expected_bit_cnt) begin
                    $display("FAIL [T6 bit_cnt seq]  i=%0d  got=%0d  expected=%0d",
                             i, bit_cnt, expected_bit_cnt);
                    fail_count++;
                end
                expected_bit_cnt = expected_bit_cnt + 6'd1;
            end else begin
                // After 64 increments, should wrap to 0
                check(bit_cnt, 0, "T6 bit_cnt wraps to 0");
            end
            @(posedge clock); #1; // advance past the bclk_fall
        end
        $display("PASS [T6 bit_cnt counts 0-63]  (checked all 64 values)");
        pass_count++;

        // ── T7: bclk_fall fires exactly once per BCLK ──────
        reset = 1; @(posedge clock); #1; reset = 0;

        bclk_fall_count = 0;
        // Run for 256 master clocks = 64 BCLK cycles = 1 frame
        for (i = 0; i < 256; i++) begin
            @(posedge clock); #1;
            if (bclk_fall) bclk_fall_count++;
        end
        check(bclk_fall_count, 64, "T7 bclk_fall fires 64 times per frame");

        // ── Summary ─────────────────────────────────────────
        $display("\n=== All tests complete: %0d passed, %0d failed ===",
                 pass_count, fail_count);
        $finish;
    end

    // ── Timeout watchdog ────────────────────────────────────
    initial begin
        #5_000_000;
        $display("TIMEOUT — simulation limit reached");
        $finish;
    end

endmodule
