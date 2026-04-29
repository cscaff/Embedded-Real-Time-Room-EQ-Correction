`timescale 1ns / 1ps

// Note: sample_fft.sv wires fftpts_in as wire [12:0] = 13'd8192.
// 8192 requires 14 bits, so the 13-bit wire truncates to 0 in simulation.
// This does not affect these tests because sample_fft.sv drives SOP/EOP
// from its own hardcoded counter, independent of fftpts_in.

module tb_sample_fft;

    // ── Clock period ──────────────────────────────────────────
    localparam SYSCLK_PERIOD = 20; // 50 MHz

    // ── DUT ports ─────────────────────────────────────────────
    logic        sysclk;
    logic        reset_n;
    logic [23:0] sink_real;
    logic        sink_valid;
    wire         sink_ready;
    wire  [23:0] source_real;
    wire  [23:0] source_imag;
    wire         source_valid;
    wire         source_eop;
    wire         source_sop;

    sample_fft dut (
        .sysclk      (sysclk),
        .reset_n     (reset_n),
        .sink_real   (sink_real),
        .sink_valid  (sink_valid),
        .sink_ready  (sink_ready),
        .source_real (source_real),
        .source_imag (source_imag),
        .source_valid(source_valid),
        .source_eop  (source_eop),
        .source_sop  (source_sop)
    );

    // ── Clock ─────────────────────────────────────────────────
    initial sysclk = 0;
    always #(SYSCLK_PERIOD / 2) sysclk = ~sysclk;

    // ── send_n_samples ────────────────────────────────────────
    // Streams n samples back-to-back with sink_valid high, respecting
    // backpressure on each cycle.
    task automatic send_n_samples(input integer n, input [23:0] base);
        integer k;
        sink_valid = 1;
        for (k = 0; k < n; k++) begin
            sink_real = base + 24'(k);
            @(posedge sysclk); #1;
            while (!sink_ready) @(posedge sysclk);
        end
        sink_valid = 0;
    endtask

    // ── Test variables ────────────────────────────────────────
    integer i;

    // ── Test sequence ─────────────────────────────────────────
    initial begin
        reset_n    = 0;
        sink_real  = 24'h0;
        sink_valid = 0;

        // ── T1: Active reset: sink_sop=1 (count=0), source_valid=0 ─
        repeat (4) @(posedge sysclk); #1;
        if (dut.sink_sop === 1'b1 && source_valid === 1'b0)
            $display("PASS [T1] reset: sink_sop=1, source_valid=0");
        else
            $display("FAIL [T1] sink_sop=%b source_valid=%b (expected 1,0)",
                     dut.sink_sop, source_valid);

        @(posedge sysclk); #1;
        reset_n = 1;
        repeat (4) @(posedge sysclk); #1;

        // ── T2: sink_ready asserts after reset released ────────
        if (sink_ready === 1'b1)
            $display("PASS [T2] sink_ready=1 after reset");
        else
            $display("FAIL [T2] sink_ready=%b after reset (expected 1)", sink_ready);

        // ── T3: First handshake advances counter 0→1 ──────────
        // sink_sop should be 1 going into this handshake (count=0).
        // After the clock edge, count=1 and sink_sop goes low.
        sink_real  = 24'hA5A5A5;
        sink_valid = 1;
        @(posedge sysclk); #1;
        sink_valid = 0;
        if (dut.sample_count === 13'd1 && dut.sink_sop === 1'b0)
            $display("PASS [T3] counter advanced to 1; sink_sop=0");
        else
            $display("FAIL [T3] sample_count=%0d sink_sop=%b (expected 1,0)",
                     dut.sample_count, dut.sink_sop);

        // ── T4: No handshake (sink_valid=0) → counter frozen ──
        begin : t4
            logic [12:0] cnt_before;
            cnt_before = dut.sample_count; // 1
            repeat (5) @(posedge sysclk); #1;
            if (dut.sample_count === cnt_before)
                $display("PASS [T4] counter frozen at %0d with sink_valid=0", cnt_before);
            else
                $display("FAIL [T4] counter moved to %0d without handshake",
                         dut.sample_count);
        end

        // ── T5: Feed remaining samples to reach count=8191 ────
        // count=1 after T3; send 8190 more → count=8191, sink_eop=1.
        send_n_samples(8190, 24'h0);
        if (dut.sample_count === 13'd8191 && dut.sink_eop === 1'b1)
            $display("PASS [T5] sample_count=8191, sink_eop=1");
        else
            $display("FAIL [T5] sample_count=%0d sink_eop=%b (expected 8191,1)",
                     dut.sample_count, dut.sink_eop);

        // ── T6: EOP handshake wraps counter; sink_sop re-asserts ─
        // Sending this sample completes the 8192-point frame.
        sink_real  = 24'hEEFFEE;
        sink_valid = 1;
        @(posedge sysclk); #1;
        sink_valid = 0;
        if (dut.sample_count === 13'd0 && dut.sink_sop === 1'b1)
            $display("PASS [T6] counter wrapped after EOP; sink_sop=1");
        else
            $display("FAIL [T6] sample_count=%0d sink_sop=%b (expected 0,1)",
                     dut.sample_count, dut.sink_sop);

        // ── T7: source_valid and source_sop fire on first output ─
        // The FFT stub starts streaming the buffered frame one cycle after
        // the EOP handshake sets frame_ready.
        @(posedge sysclk); #1;
        if (source_valid === 1'b1 && source_sop === 1'b1)
            $display("PASS [T7] source_valid=1, source_sop=1 on first output cycle");
        else
            $display("FAIL [T7] source_valid=%b source_sop=%b (expected 1,1)",
                     source_valid, source_sop);

        // ── T7 (cont): source_eop asserts at end of output frame ─
        begin : t7_eop
            integer cyc;
            cyc = 0;
            while (!source_eop && cyc < 10000) begin
                @(posedge sysclk); #1;
                cyc++;
            end
            if (source_eop === 1'b1 && source_valid === 1'b1)
                $display("PASS [T7] source_eop=1 with source_valid=1 (cycle %0d)", cyc);
            else
                $display("FAIL [T7] source_eop=%b source_valid=%b after %0d cycles",
                         source_eop, source_valid, cyc);
        end

        // ── T8: Reset mid-frame resets counter ────────────────
        // The stub re-enables sink_ready after its output phase completes.
        // Wait one more cycle for sink_ready to propagate, then send 100
        // samples to advance the counter deep into a second frame.
        @(posedge sysclk); #1;
        send_n_samples(100, 24'hCAFE00);
        // Assert async reset and check counter clears immediately
        reset_n = 0;
        #1;
        if (dut.sample_count === 13'd0 && dut.sink_sop === 1'b1)
            $display("PASS [T8] mid-frame async reset: counter=0, sink_sop=1");
        else
            $display("FAIL [T8] sample_count=%0d sink_sop=%b after mid-frame reset",
                     dut.sample_count, dut.sink_sop);
        reset_n = 1;

        $display("\n=== All tests complete ===");
        $finish;
    end

    // ── Timeout watchdog ──────────────────────────────────────
    initial begin
        #5_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
