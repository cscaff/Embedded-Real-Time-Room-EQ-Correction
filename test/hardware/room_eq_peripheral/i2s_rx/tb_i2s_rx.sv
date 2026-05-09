// Testbench for i2s_rx.
// Verifies deserialization of I2S ADCDAT into 24-bit parallel samples.
// Tests: reset state, bit-exact capture for both channels, I2S 1-bit
// delay, full-scale values, sign bit, and multi-frame updates.

`timescale 1ns / 1ps

module tb_i2s_rx;

    // ── Parameters ──────────────────────────────────────────
    localparam CLK_PERIOD = 81; // ~12.288 MHz (same as tb_i2s_tx)

    // ── Signals ─────────────────────────────────────────────
    logic        clock;
    logic        reset;
    logic        bclk;
    logic        lrck;
    logic        adcdat;
    logic [23:0] left_sample;
    logic [23:0] right_sample;
    logic        sample_valid;

    // ── We need a clock generator to produce bclk/lrck ──────
    // Reuse the same i2s_clock_gen that i2s_tx uses.
    logic        bclk_fall;
    logic [5:0]  bit_cnt;

    i2s_clock_gen clk_gen (
        .clock     (clock),
        .reset     (reset),
        .bclk      (bclk),
        .lrck      (lrck),
        .bclk_fall (bclk_fall),
        .bit_cnt   (bit_cnt)
    );

    // ── DUT ─────────────────────────────────────────────────
    i2s_rx dut (
        .clock       (clock),
        .reset       (reset),
        .bclk        (bclk),
        .lrck        (lrck),
        .adcdat      (adcdat),
        .left_sample (left_sample),
        .right_sample(right_sample),
        .sample_valid(sample_valid)
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
            $display("PASS [%s]", label);
            pass_count++;
        end
    endtask

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

    // Run for one complete I2S frame (64 BCLK cycles = 256 master clocks).
    task automatic run_one_frame;
        repeat (256) @(posedge clock);
        #1;
    endtask

    // ── ADCDAT driver ───────────────────────────────────────
    // In real hardware, the codec drives ADCDAT on BCLK falling edge.
    // The I2S 1-bit delay means: the MSB of left channel is placed on
    // the wire at the BCLK falling edge where bit_cnt=0 (the LRCK
    // transition), so the receiver sees it at the BCLK rising edge of
    // bit_cnt=1.
    //
    // We drive adcdat combinatorially from the clock generator's bit_cnt,
    // updating on bclk_fall (just like a real codec would).

    logic [23:0] drive_left;
    logic [23:0] drive_right;
    logic        drive_active;

    initial begin
        drive_left   = 24'd0;
        drive_right  = 24'd0;
        drive_active = 1'b0;
        adcdat       = 1'b0;
    end

    // Drive ADCDAT on every bclk_fall based on current bit_cnt.
    // This runs continuously once drive_active is set.
    //
    // Timing: data driven at bclk_fall of bit_cnt N is sampled by
    // the receiver at bclk_rise of bit_cnt N+1 (because bclk_rise
    // detection adds one clock of latency, and bit_cnt increments
    // on bclk_rise).
    //
    // So to get MSB of left channel sampled at receiver's bit_cnt=1:
    //   drive left_val[23] at bclk_fall when bit_cnt=0
    //   drive left_val[22] at bclk_fall when bit_cnt=1
    //   ...
    //   drive left_val[0]  at bclk_fall when bit_cnt=23
    //   drive 0 (padding)  at bclk_fall when bit_cnt=24..31
    //   drive right_val[23] at bclk_fall when bit_cnt=32
    //   drive right_val[22] at bclk_fall when bit_cnt=33
    //   ...
    //   drive right_val[0]  at bclk_fall when bit_cnt=55
    //   drive 0 (padding)  at bclk_fall when bit_cnt=56..63
    always @(posedge clock) begin
        if (drive_active && bclk_fall) begin
            case (bit_cnt)
                // Left channel: MSB at bit_cnt 0, LSB at bit_cnt 23
                6'd0:  adcdat <= drive_left[23];
                6'd1:  adcdat <= drive_left[22];
                6'd2:  adcdat <= drive_left[21];
                6'd3:  adcdat <= drive_left[20];
                6'd4:  adcdat <= drive_left[19];
                6'd5:  adcdat <= drive_left[18];
                6'd6:  adcdat <= drive_left[17];
                6'd7:  adcdat <= drive_left[16];
                6'd8:  adcdat <= drive_left[15];
                6'd9:  adcdat <= drive_left[14];
                6'd10: adcdat <= drive_left[13];
                6'd11: adcdat <= drive_left[12];
                6'd12: adcdat <= drive_left[11];
                6'd13: adcdat <= drive_left[10];
                6'd14: adcdat <= drive_left[9];
                6'd15: adcdat <= drive_left[8];
                6'd16: adcdat <= drive_left[7];
                6'd17: adcdat <= drive_left[6];
                6'd18: adcdat <= drive_left[5];
                6'd19: adcdat <= drive_left[4];
                6'd20: adcdat <= drive_left[3];
                6'd21: adcdat <= drive_left[2];
                6'd22: adcdat <= drive_left[1];
                6'd23: adcdat <= drive_left[0];
                // Right channel: MSB at bit_cnt 32, LSB at bit_cnt 55
                6'd32: adcdat <= drive_right[23];
                6'd33: adcdat <= drive_right[22];
                6'd34: adcdat <= drive_right[21];
                6'd35: adcdat <= drive_right[20];
                6'd36: adcdat <= drive_right[19];
                6'd37: adcdat <= drive_right[18];
                6'd38: adcdat <= drive_right[17];
                6'd39: adcdat <= drive_right[16];
                6'd40: adcdat <= drive_right[15];
                6'd41: adcdat <= drive_right[14];
                6'd42: adcdat <= drive_right[13];
                6'd43: adcdat <= drive_right[12];
                6'd44: adcdat <= drive_right[11];
                6'd45: adcdat <= drive_right[10];
                6'd46: adcdat <= drive_right[9];
                6'd47: adcdat <= drive_right[8];
                6'd48: adcdat <= drive_right[7];
                6'd49: adcdat <= drive_right[6];
                6'd50: adcdat <= drive_right[5];
                6'd51: adcdat <= drive_right[4];
                6'd52: adcdat <= drive_right[3];
                6'd53: adcdat <= drive_right[2];
                6'd54: adcdat <= drive_right[1];
                6'd55: adcdat <= drive_right[0];
                // Padding
                default: adcdat <= 1'b0;
            endcase
        end
    end

    // Wait for sample_valid to pulse, with timeout.
    task automatic wait_sample_valid;
        integer timeout;
        timeout = 0;
        while (!sample_valid && timeout < 2000) begin
            @(posedge clock);
            timeout++;
        end
        if (timeout >= 2000)
            $display("WARNING: wait_sample_valid timed out");
    endtask

    // Set drive values and wait for them to appear on the output.
    task automatic drive_and_check(
        input [23:0] left_val,
        input [23:0] right_val,
        input string label
    );
        drive_left  = left_val;
        drive_right = right_val;
        // Wait for the receiver to capture a full frame with these values.
        // Need 1-2 frames for the new values to propagate.
        run_one_frame();
        run_one_frame();
        wait_sample_valid();

        check_hex24(left_sample,  left_val,  {label, " left"});
        check_hex24(right_sample, right_val, {label, " right"});
    endtask

    // ── Test sequence ───────────────────────────────────────
    initial begin
        $dumpfile("sim_out/tb_i2s_rx.vcd");
        $dumpvars(0, tb_i2s_rx);

        adcdat = 0;

        // ── T1: Reset state ─────────────────────────────────
        reset = 1;
        @(posedge clock); #1;
        check(left_sample,  0, "T1 reset left=0");
        check(right_sample, 0, "T1 reset right=0");
        check(sample_valid, 0, "T1 reset valid=0");

        reset = 0;
        drive_active = 1;

        // Let clocks stabilize for 2 frames
        run_one_frame();
        run_one_frame();

        // ── T2: Known sample capture ────────────────────────
        drive_and_check(24'hCAFE01, 24'h123456, "T2");

        // ── T3: Full-scale positive ─────────────────────────
        drive_and_check(24'h7FFFFF, 24'h7FFFFF, "T3 max pos");

        // ── T4: Full-scale negative ─────────────────────────
        drive_and_check(24'h800000, 24'h800000, "T4 max neg");

        // ── T5: Alternating bits ────────────────────────────
        drive_and_check(24'hAAAAAA, 24'h555555, "T5 alt");

        // ── T6: Zero ────────────────────────────────────────
        drive_and_check(24'h000000, 24'h000000, "T6 zero");

        // ── T7: Asymmetric channels ─────────────────────────
        drive_and_check(24'hFFFFFF, 24'h000001, "T7 asym");

        // ── T8: sample_valid is a one-cycle pulse ───────────
        drive_left  = 24'h111111;
        drive_right = 24'h222222;
        run_one_frame();
        run_one_frame();
        wait_sample_valid();
        @(posedge clock); #1;
        check(sample_valid, 0, "T8 sample_valid deasserts after 1 cycle");

        // ── Summary ─────────────────────────────────────────
        $display("\n=== I2S RX tests complete: %0d passed, %0d failed ===",
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
