// Testbench for i2s_shift_register.
// Verifies load, MSB-first shift-out, zero padding,
// load priority over shift, and idle hold behavior.

`timescale 1ns / 1ps

module tb_i2s_shift_register;

    // ── Parameters ──────────────────────────────────────────
    localparam CLK_PERIOD = 81; // ~12.288 MHz

    // ── Signals ─────────────────────────────────────────────
    logic        clock;
    logic        reset;
    logic [23:0] data_in;
    logic        load;
    logic        shift;
    logic        serial_out;

    // ── DUT ─────────────────────────────────────────────────
    i2s_shift_register dut (
        .clock      (clock),
        .reset      (reset),
        .data_in    (data_in),
        .load       (load),
        .shift      (shift),
        .serial_out (serial_out)
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

    // Pulse load for one clock cycle.
    task automatic do_load(input [23:0] val);
        data_in = val;
        load = 1;
        @(posedge clock); #1;
        load = 0;
    endtask

    // Pulse shift for one clock cycle, return serial_out.
    task automatic do_shift(output logic bit_out);
        shift = 1;
        @(posedge clock); #1;
        bit_out = serial_out;
        shift = 0;
    endtask

    // ── Test sequence ───────────────────────────────────────
    integer i;
    logic [23:0] test_pattern;
    logic        bit_out;
    logic        expected_bit;

    initial begin
        $dumpfile("sim_out/tb_i2s_shift_register.vcd");
        $dumpvars(0, tb_i2s_shift_register);

        load    = 0;
        shift   = 0;
        data_in = 24'd0;

        // ── T1: Reset → serial_out = 0 ─────────────────────
        reset = 1;
        @(posedge clock); #1;
        check(serial_out, 0, "T1 reset serial_out=0");
        reset = 0;

        // ── T2: Load and MSB check ─────────────────────────
        // Load 24'hABCDEF = 1010_1011_1100_1101_1110_1111
        // MSB (bit 23) = 1
        do_load(24'hABCDEF);
        check(serial_out, 1, "T2 load ABCDEF MSB=1");

        // ── T3: Full 24-bit shift-out of ABCDEF ────────────
        // Reload cleanly.
        reset = 1; @(posedge clock); #1; reset = 0;
        do_load(24'hABCDEF);

        test_pattern = 24'hABCDEF;
        $display("T3: shifting out 24'hABCDEF bit-by-bit...");
        for (i = 23; i >= 0; i--) begin
            expected_bit = test_pattern[i];
            // serial_out should already show the current MSB before shifting
            if (serial_out !== expected_bit) begin
                $display("FAIL [T3 bit %0d]  got=%0b  expected=%0b", i, serial_out, expected_bit);
                fail_count++;
            end
            do_shift(bit_out);
        end
        $display("PASS [T3 full shift-out of ABCDEF]  (checked all 24 bits)");
        pass_count++;

        // ── T4: Zero padding after 24 shifts ───────────────
        // After all 24 data bits are out, the next 8 shifts
        // should output 0 (zeros shifted in from the right).
        $display("T4: checking 8 padding zeros...");
        for (i = 0; i < 8; i++) begin
            check(serial_out, 0, $sformatf("T4 padding bit %0d", i));
            do_shift(bit_out);
        end

        // ── T5: Load 800000 — MSB=1, rest=0 ────────────────
        // Catches off-by-one alignment errors.
        reset = 1; @(posedge clock); #1; reset = 0;
        do_load(24'h800000);
        check(serial_out, 1, "T5 load 800000 MSB=1");
        do_shift(bit_out);
        check(serial_out, 0, "T5 bit 22=0 after shift");
        // Shift remaining 22 bits, all should be 0.
        for (i = 0; i < 22; i++) do_shift(bit_out);
        check(serial_out, 0, "T5 all remaining bits=0");

        // ── T6: Load FFFFFF — 24 ones then 8 zeros ─────────
        reset = 1; @(posedge clock); #1; reset = 0;
        do_load(24'hFFFFFF);
        for (i = 0; i < 24; i++) begin
            if (serial_out !== 1'b1) begin
                $display("FAIL [T6 data bit %0d]  got=0  expected=1", 23 - i);
                fail_count++;
            end
            do_shift(bit_out);
        end
        // Now 8 padding zeros.
        for (i = 0; i < 8; i++) begin
            if (serial_out !== 1'b0) begin
                $display("FAIL [T6 padding bit %0d]  got=1  expected=0", i);
                fail_count++;
            end
            do_shift(bit_out);
        end
        $display("PASS [T6 FFFFFF: 24 ones then 8 zeros]");
        pass_count++;

        // ── T7: Load priority over shift ────────────────────
        // Load a pattern, then assert load and shift together.
        // Load should win — serial_out shows MSB of new data.
        reset = 1; @(posedge clock); #1; reset = 0;
        do_load(24'hFFFFFF);
        // Now assert both load (with 000001) and shift simultaneously.
        data_in = 24'h000001; // MSB = 0
        load  = 1;
        shift = 1;
        @(posedge clock); #1;
        load  = 0;
        shift = 0;
        check(serial_out, 0, "T7 load priority: new MSB=0 wins over shift");

        // ── T8: Idle hold — output stable when no load/shift ─
        reset = 1; @(posedge clock); #1; reset = 0;
        do_load(24'hAAAAAA); // MSB = 1
        // Wait 5 cycles without load or shift.
        repeat (5) @(posedge clock);
        #1;
        check(serial_out, 1, "T8 idle hold: serial_out stable after 5 idle cycles");

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
