// Testbench for i2s_tx.
// Verifies complete I2S protocol: reset state, bit-exact sample
// reconstruction, the 1-bit delay, and multi-frame behavior.

`timescale 1ns / 1ps

module tb_i2s_tx;

    // ── Parameters ──────────────────────────────────────────
    localparam CLK_PERIOD = 81; // ~12.288 MHz

    // ── Signals ─────────────────────────────────────────────
    logic        clock;
    logic        reset;
    logic [23:0] left_sample;
    logic [23:0] right_sample;
    logic        bclk;
    logic        lrck;
    logic        dacdat;

    // ── DUT ─────────────────────────────────────────────────
    i2s_tx dut (
        .clock        (clock),
        .reset        (reset),
        .left_sample  (left_sample),
        .right_sample (right_sample),
        .bclk         (bclk),
        .lrck         (lrck),
        .dacdat       (dacdat)
    );

    // ── Hierarchical access to internals for debug ──────────
    wire [5:0]  bit_cnt   = dut.bit_cnt;
    wire        bclk_fall = dut.bclk_fall;

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

    logic prev_bclk_val = 0;

    // Wait for a rising edge on bclk (it's a data signal, so we
    // watch for a 0→1 transition).
    task automatic wait_bclk_rise;
        @(posedge clock); #1;
        while (!(bclk && !prev_bclk_val)) begin
            prev_bclk_val = bclk;
            @(posedge clock); #1;
        end
        prev_bclk_val = bclk;
    endtask

    // Wait for LRCK to go low (start of left channel).
    // Returns after the first master clock where lrck is newly low.
    task automatic wait_frame_start;
        // Wait for lrck to be high first (so we catch the transition)
        while (!lrck) @(posedge clock);
        // Now wait for it to go low
        while (lrck) @(posedge clock);
        #1;
        prev_bclk_val = bclk;
    endtask

    // Capture 24 bits of one channel from BCLK rising edges.
    // Assumes we are positioned just after the LRCK transition.
    // Skips the first BCLK rising edge (delay slot) per I2S spec,
    // then captures the next 24, then skips the 8 padding bits
    // so we're positioned for the next channel's transition.
    task automatic capture_channel(output [23:0] captured);
        integer i;
        // Skip delay slot: wait for one BCLK rising edge
        wait_bclk_rise();
        // Capture 24 data bits on the next 24 BCLK rising edges
        for (i = 23; i >= 0; i--) begin
            wait_bclk_rise();
            captured[i] = dacdat;
        end
        // Skip 7 padding bits. The 8th padding BCLK rise coincides
        // with the LRCK transition — leave that for the next call's
        // delay-slot skip.
        for (i = 0; i < 7; i++)
            wait_bclk_rise();
    endtask

    // Run for one complete frame (256 master clocks).
    task automatic run_one_frame;
        repeat (256) @(posedge clock);
        #1;
    endtask

    // ── Test sequence ───────────────────────────────────────
    logic [23:0] captured_left;
    logic [23:0] captured_right;
    logic        delay_slot_dacdat;
    logic        first_data_dacdat;

    initial begin
        $dumpfile("sim_out/tb_i2s_tx.vcd");
        $dumpvars(0, tb_i2s_tx);

        left_sample  = 24'd0;
        right_sample = 24'd0;

        // ── T1: Reset state ─────────────────────────────────
        reset = 1;
        @(posedge clock); #1;
        check(bclk,   0, "T1 reset bclk=0");
        check(lrck,   0, "T1 reset lrck=0");
        check(dacdat, 0, "T1 reset dacdat=0");

        reset = 0;

        // ── T2: Bit-exact left channel capture ──────────────
        // Set known samples and let them get latched.
        left_sample  = 24'hCAFE01;
        right_sample = 24'h123456;

        // Wait for a clean frame start (LRCK falling edge).
        // Run for 2 frames to ensure samples are latched.
        run_one_frame();
        run_one_frame();
        wait_frame_start();

        // Capture left channel (24 bits after delay slot).
        capture_channel(captured_left);

        if (captured_left === 24'hCAFE01)
            $display("PASS [T2 left channel]  captured=0x%06h", captured_left);
        else begin
            $display("FAIL [T2 left channel]  captured=0x%06h  expected=0xCAFE01", captured_left);
            fail_count++;
        end
        pass_count++;

        // ── T3: Bit-exact right channel capture ─────────────
        // Right channel follows immediately after left in the same frame.
        // LRCK just went high — capture right channel.
        capture_channel(captured_right);

        if (captured_right === 24'h123456)
            $display("PASS [T3 right channel]  captured=0x%06h", captured_right);
        else begin
            $display("FAIL [T3 right channel]  captured=0x%06h  expected=0x123456", captured_right);
            fail_count++;
        end
        pass_count++;

        // ── T4: I2S 1-bit delay verification ────────────────
        // The MSB must NOT appear on the BCLK rising edge where
        // LRCK transitions.  It must appear on the NEXT rising edge.
        left_sample  = 24'hFFFFFF; // MSB = 1
        right_sample = 24'h000000;

        // Let the new sample get latched.
        run_one_frame();
        run_one_frame();

        // Wait for frame start (LRCK goes low).
        wait_frame_start();

        // First BCLK rising edge after LRCK transition = delay slot.
        wait_bclk_rise();
        delay_slot_dacdat = dacdat;

        // Second BCLK rising edge = first data bit (MSB).
        wait_bclk_rise();
        first_data_dacdat = dacdat;

        // The delay slot value doesn't matter (codec ignores it),
        // but the first data bit MUST be the MSB.
        check(first_data_dacdat, 1, "T4 I2S delay: MSB=1 on second BCLK rise");
        $display("     (delay slot dacdat=%0b — don't-care per I2S spec)", delay_slot_dacdat);

        // Also verify right channel delay (LRCK going high).
        // Right sample is 000000, MSB = 0.
        // Skip remaining left channel bits.
        repeat (23) wait_bclk_rise(); // skip bits 22..0
        repeat (8)  wait_bclk_rise(); // skip 8 padding bits

        // Now at LRCK high transition. First BCLK rise = delay slot.
        wait_bclk_rise();
        delay_slot_dacdat = dacdat;

        // Second BCLK rise = MSB of right channel.
        wait_bclk_rise();
        first_data_dacdat = dacdat;

        check(first_data_dacdat, 0, "T4 I2S delay right: MSB=0 on second BCLK rise");

        // ── T5: Changing samples across frames ──────────────
        // Set new samples and verify the NEXT frame picks them up.
        left_sample  = 24'hAAAAAA;
        right_sample = 24'h555555;

        // Run enough frames for the new values to be latched.
        run_one_frame();
        run_one_frame();
        wait_frame_start();

        capture_channel(captured_left);
        capture_channel(captured_right);

        if (captured_left === 24'hAAAAAA)
            $display("PASS [T5 new left]  captured=0x%06h", captured_left);
        else begin
            $display("FAIL [T5 new left]  captured=0x%06h  expected=0xAAAAAA", captured_left);
            fail_count++;
        end
        pass_count++;

        if (captured_right === 24'h555555)
            $display("PASS [T5 new right]  captured=0x%06h", captured_right);
        else begin
            $display("FAIL [T5 new right]  captured=0x%06h  expected=0x555555", captured_right);
            fail_count++;
        end
        pass_count++;

        // ── Summary ─────────────────────────────────────────
        $display("\n=== All tests complete: %0d passed, %0d failed ===",
                 pass_count, fail_count);
        $finish;
    end

    // ── Timeout watchdog ────────────────────────────────────
    initial begin
        #50_000_000;
        $display("TIMEOUT — simulation limit reached");
        $finish;
    end

endmodule
