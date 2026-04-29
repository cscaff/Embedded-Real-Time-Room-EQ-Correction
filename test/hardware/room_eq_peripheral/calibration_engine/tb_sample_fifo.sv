`timescale 1ns / 1ps

module tb_sample_fifo;

    // ── Clock periods ─────────────────────────────────────────
    localparam BCLK_PERIOD   = 326;  // ~3.07 MHz (I2S bit clock)
    localparam SYSCLK_PERIOD = 20;   // 50 MHz (system clock)
    // After a bclk-domain write, the gray-coded write pointer crosses to the
    // sysclk domain through rdsync_delaypipe=4 stages (~1 bclk + 4 sysclk
    // cycles). 30 sysclk cycles gives comfortable margin.
    localparam CDC_WAIT = 30;

    // ── DUT ports ─────────────────────────────────────────────
    logic        bclk;
    logic        lrclk;
    logic [23:0] left_chan;
    logic        sysclk;
    // aclr is driven via continuous assign because dcfifo in altera_mf.v
    // declares its aclr port as tri0 unconditionally, which Icarus propagates
    // up the hierarchy and blocks procedural assignment to a plain logic.
    reg          aclr_drv;
    wire         aclr;
    assign aclr = aclr_drv;
    logic [23:0] data_out;
    logic        data_valid;
    logic        fft_ready;

    sample_fifo dut (
        .bclk      (bclk),
        .lrclk     (lrclk),
        .left_chan  (left_chan),
        .sysclk    (sysclk),
        .aclr      (aclr),
        .data_out  (data_out),
        .data_valid(data_valid),
        .fft_ready (fft_ready)
    );

    // ── Clocks ────────────────────────────────────────────────
    initial bclk   = 0;
    always #(BCLK_PERIOD   / 2) bclk   = ~bclk;
    initial sysclk = 0;
    always #(SYSCLK_PERIOD / 2) sysclk = ~sysclk;

    // ── send_sample ───────────────────────────────────────────
    // Creates one lrclk falling edge with left_chan stable.
    // lrclk_reg in the DUT captures lrclk=1 on the first posedge bclk,
    // then lrclk falls; wrreq asserts; the FIFO captures left_chan on
    // the following posedge bclk.
    task automatic send_sample(input [23:0] sample);
        left_chan = sample;
        @(posedge bclk); #1;
        lrclk = 0;               // falling edge: DUT detects lrclk_neg_edge
        @(posedge bclk); #1;     // FIFO write happens on this bclk posedge
        lrclk = 1;
    endtask

    // ── read_sample ───────────────────────────────────────────
    // dcfifo is in showahead mode: q is already presented when rdempty=0.
    // Sample data_out, then pulse fft_ready for one sysclk to pop the entry.
    task automatic read_sample(output [23:0] d);
        d = data_out;
        fft_ready = 1;
        @(posedge sysclk); #1;   // FIFO advances on this sysclk posedge
        fft_ready = 0;
    endtask

    // ── Test variables ────────────────────────────────────────
    integer      i;
    logic [23:0] read_val;
    logic [23:0] expected [0:3];

    // ── Test sequence ─────────────────────────────────────────
    initial begin
        aclr_drv  = 1;
        lrclk     = 1;
        left_chan  = 24'h0;
        fft_ready = 0;

        // ── T1: Async reset holds FIFO empty; data_valid=0 ────
        repeat (4) @(posedge bclk); #1;
        if (data_valid === 1'b0)
            $display("PASS [T1] data_valid=0 during reset");
        else
            $display("FAIL [T1] expected data_valid=0 during reset, got %b", data_valid);

        @(posedge bclk); #1;
        aclr_drv = 0;
        repeat (4) @(posedge bclk);

        // ── T2: Single write; data_valid asserts after CDC ────
        send_sample(24'hA5A5A5);
        repeat (CDC_WAIT) @(posedge sysclk); #1;
        if (data_valid === 1'b1)
            $display("PASS [T2] data_valid=1 after write + CDC propagation");
        else
            $display("FAIL [T2] expected data_valid=1 after write+CDC, got %b", data_valid);

        // ── T3: Data integrity ────────────────────────────────
        read_sample(read_val);
        if (read_val === 24'hA5A5A5)
            $display("PASS [T3] data_out=0x%06h correct", read_val);
        else
            $display("FAIL [T3] data_out=0x%06h, expected 0xA5A5A5", read_val);
        // After draining the only entry, rdempty goes high on this sysclk domain
        repeat (4) @(posedge sysclk); #1;
        if (data_valid === 1'b0)
            $display("PASS [T3] data_valid=0 after FIFO fully drained");
        else
            $display("FAIL [T3] expected data_valid=0 after drain, got %b", data_valid);

        // ── T4: Backpressure: fft_ready=0 keeps data in FIFO ─
        send_sample(24'hDEAD42);
        repeat (CDC_WAIT) @(posedge sysclk);
        repeat (10) @(posedge sysclk); #1;   // hold fft_ready=0 for extra cycles
        if (data_valid === 1'b1)
            $display("PASS [T4] data_valid stays 1 with fft_ready=0 (backpressure held)");
        else
            $display("FAIL [T4] data drained without fft_ready, got data_valid=%b", data_valid);

        // ── T5: fft_ready=1 drains correct value ──────────────
        read_sample(read_val);
        if (read_val === 24'hDEAD42)
            $display("PASS [T5] correct data drained when fft_ready=1, got 0x%06h", read_val);
        else
            $display("FAIL [T5] wrong data, got 0x%06h expected 0xDEAD42", read_val);

        // ── T6: Multi-sample FIFO ordering ────────────────────
        expected[0] = 24'h111111;
        expected[1] = 24'h222222;
        expected[2] = 24'h333333;
        expected[3] = 24'h444444;
        for (i = 0; i < 4; i++) begin
            send_sample(expected[i]);
            repeat (8) @(posedge bclk);   // inter-sample gap
        end
        repeat (CDC_WAIT) @(posedge sysclk); #1;
        begin : t6_check
            integer pass_count;
            pass_count = 0;
            for (i = 0; i < 4; i++) begin
                read_sample(read_val);
                if (read_val === expected[i])
                    pass_count++;
                else
                    $display("FAIL [T6] sample[%0d] got 0x%06h, expected 0x%06h",
                             i, read_val, expected[i]);
                @(posedge sysclk); #1;
            end
            if (pass_count == 4)
                $display("PASS [T6] all 4 samples read back in correct FIFO order");
        end

        // ── T7: Async reset mid-operation flushes FIFO ────────
        send_sample(24'hCAFE00);
        repeat (CDC_WAIT) @(posedge sysclk);
        aclr_drv = 1;
        repeat (4) @(posedge sysclk); #1;
        if (data_valid === 1'b0)
            $display("PASS [T7] data_valid=0 after mid-operation async reset");
        else
            $display("FAIL [T7] expected data_valid=0 after reset, got %b", data_valid);
        aclr_drv = 0;

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
