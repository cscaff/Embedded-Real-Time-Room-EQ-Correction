// Testbench for I2S TX → RX loopback.
// Connects i2s_tx DACDAT output directly to i2s_rx ADCDAT input.
// Both share the same clock generator (as they would in the real design).
// Verifies that samples survive the serialize → deserialize round-trip.

`timescale 1ns / 1ps

module tb_i2s_loopback;

    // ── Parameters ──────────────────────────────────────────
    localparam CLK_PERIOD = 81; // ~12.288 MHz

    // ── Signals ─────────────────────────────────────────────
    logic        clock;
    logic        reset;

    // TX inputs
    logic [23:0] tx_left;
    logic [23:0] tx_right;

    // TX outputs (directly wired to RX)
    logic        bclk;
    logic        lrck;
    logic        dacdat;

    // RX outputs
    logic [23:0] rx_left;
    logic [23:0] rx_right;
    logic        rx_valid;

    // ── TX (generates bclk, lrck, dacdat) ───────────────────
    i2s_tx tx_inst (
        .clock        (clock),
        .reset        (reset),
        .left_sample  (tx_left),
        .right_sample (tx_right),
        .bclk         (bclk),
        .lrck         (lrck),
        .dacdat       (dacdat)
    );

    // ── RX (receives dacdat, uses same bclk/lrck) ──────────
    i2s_rx rx_inst (
        .clock       (clock),
        .reset       (reset),
        .bclk        (bclk),
        .lrck        (lrck),
        .adcdat      (dacdat),   // loopback: TX output → RX input
        .left_sample (rx_left),
        .right_sample(rx_right),
        .sample_valid(rx_valid)
    );

    // ── Clock ───────────────────────────────────────────────
    initial clock = 0;
    always #(CLK_PERIOD / 2) clock = ~clock;

    // ── Helpers ─────────────────────────────────────────────
    integer pass_count = 0;
    integer fail_count = 0;

    task automatic check_hex24(
        input [23:0] got,
        input [23:0] expected,
        input string label
    );
        if (got !== expected) begin
            $display("FAIL [%s]  got=0x%06h  expected=0x%06h", label, got, expected);
            fail_count++;
        end else begin
            $display("PASS [%s]  value=0x%06h", label, got);
            pass_count++;
        end
    endtask

    task automatic run_one_frame;
        repeat (256) @(posedge clock);
        #1;
    endtask

    // Wait for rx_valid pulse with timeout.
    task automatic wait_rx_valid;
        integer timeout;
        timeout = 0;
        while (!rx_valid && timeout < 2000) begin
            @(posedge clock);
            timeout++;
        end
        if (timeout >= 2000)
            $display("WARNING: wait_rx_valid timed out");
    endtask

    // Drive samples on TX, wait for them to appear on RX, and check.
    // Takes 2-3 frames due to TX latching + RX deserialization pipeline.
    task automatic loopback_check(
        input [23:0] left_val,
        input [23:0] right_val,
        input string label
    );
        // Set TX input samples
        tx_left  = left_val;
        tx_right = right_val;

        // TX latches samples 2 BCLK cycles before frame start (bit_cnt=62).
        // We need to let the TX serialize one full frame with the new data,
        // then the RX deserializes it.  Run a few frames to be safe.
        run_one_frame();
        run_one_frame();
        run_one_frame();

        // Wait for the next rx_valid pulse
        wait_rx_valid();

        check_hex24(rx_left,  left_val,  {label, " left"});
        check_hex24(rx_right, right_val, {label, " right"});
    endtask

    // ── Test sequence ───────────────────────────────────────
    initial begin
        $dumpfile("sim_out/tb_i2s_loopback.vcd");
        $dumpvars(0, tb_i2s_loopback);

        tx_left  = 24'd0;
        tx_right = 24'd0;

        // ── Reset ───────────────────────────────────────────
        reset = 1;
        repeat (4) @(posedge clock);
        reset = 0;

        // Let clocks stabilize
        run_one_frame();
        run_one_frame();

        // ── T1: Basic round-trip ────────────────────────────
        loopback_check(24'hCAFE01, 24'h123456, "T1");

        // ── T2: Max positive ────────────────────────────────
        loopback_check(24'h7FFFFF, 24'h7FFFFF, "T2 max pos");

        // ── T3: Max negative ────────────────────────────────
        loopback_check(24'h800000, 24'h800000, "T3 max neg");

        // ── T4: Alternating bits ────────────────────────────
        loopback_check(24'hAAAAAA, 24'h555555, "T4 alt bits");

        // ── T5: All ones / all zeros ────────────────────────
        loopback_check(24'hFFFFFF, 24'h000000, "T5 ones/zeros");

        // ── T6: Single bit patterns ─────────────────────────
        loopback_check(24'h000001, 24'h800000, "T6 LSB/MSB");

        // ── T7: Sequential updates ─────────────────────────
        // Verify that changing samples frame-to-frame works.
        loopback_check(24'h111111, 24'h222222, "T7a");
        loopback_check(24'h333333, 24'h444444, "T7b");
        loopback_check(24'h555555, 24'h666666, "T7c");

        // ── Summary ─────────────────────────────────────────
        $display("\n=== Loopback tests complete: %0d passed, %0d failed ===",
                 pass_count, fail_count);
        if (fail_count > 0)
            $display("*** FAILURES DETECTED ***");
        $finish;
    end

    // ── Timeout watchdog ────────────────────────────────────
    initial begin
        #100_000_000;
        $display("TIMEOUT — simulation limit reached");
        $finish;
    end

endmodule
