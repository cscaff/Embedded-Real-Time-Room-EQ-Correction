`timescale 1ns / 1ps

module tb_fft_result_ram;

    // ── Clock parameters ──────────────────────────────────────
    localparam CLK_PERIOD = 20; // 50 MHz

    // ── Signals ───────────────────────────────────────────────
    logic        sysclk;
    logic        reset_n;
    logic [23:0] fft_real;
    logic [23:0] fft_imag;
    logic        fft_valid;
    logic        data_eop;
    logic        data_sop;
    logic [12:0] rd_addr;
    logic [23:0] rd_real;
    logic [23:0] rd_imag;
    logic        fft_done;

    // ── DUT ───────────────────────────────────────────────────
    fft_result_ram dut (
        .sysclk   (sysclk),
        .reset_n  (reset_n),
        .fft_real (fft_real),
        .fft_imag (fft_imag),
        .fft_valid(fft_valid),
        .data_eop (data_eop),
        .data_sop (data_sop),
        .rd_addr  (rd_addr),
        .rd_real  (rd_real),
        .rd_imag  (rd_imag),
        .fft_done (fft_done)
    );

    // ── Clock ─────────────────────────────────────────────────
    initial sysclk = 0;
    always #(CLK_PERIOD / 2) sysclk = ~sysclk;

    // ── write_sample ──────────────────────────────────────────
    // Drives one FFT output word into the DUT on the next posedge.
    // eop/sop are asserted for the same cycle as fft_valid.
    task automatic write_sample(
        input [23:0] r,
        input [23:0] im,
        input        eop,
        input        sop
    );
        @(posedge sysclk); #1;
        fft_real  = r;
        fft_imag  = im;
        fft_valid = 1;
        data_eop  = eop;
        data_sop  = sop;
        @(posedge sysclk); #1;  // DUT latches on this edge
        fft_valid = 0;
        data_eop  = 0;
        data_sop  = 0;
    endtask

    // ── read_ram ──────────────────────────────────────────────
    // Presents rd_addr and captures output after 1-cycle read latency.
    task automatic read_ram(
        input  [12:0] addr,
        output [23:0] rr,
        output [23:0] ri
    );
        @(posedge sysclk); #1;
        rd_addr = addr;
        @(posedge sysclk); #1;  // output valid after this edge
        rr = rd_real;
        ri = rd_imag;
    endtask

    // ── check ─────────────────────────────────────────────────
    task automatic check(
        input [23:0] got,
        input [23:0] expected,
        input string label
    );
        if (got !== expected)
            $display("FAIL [%s]  got=0x%06h  expected=0x%06h", label, got, expected);
        else
            $display("PASS [%s]  got=0x%06h", label, got);
    endtask

    // ── Test variables ────────────────────────────────────────
    integer      i;
    logic [23:0] rr, ri;

    // ── Test sequence ─────────────────────────────────────────
    initial begin
        reset_n   = 1;
        fft_real  = 0;
        fft_imag  = 0;
        fft_valid = 0;
        data_eop  = 0;
        data_sop  = 0;
        rd_addr   = 0;

        // ── T1: Active-low reset clears fft_done ──────────────
        reset_n = 0;
        repeat (4) @(posedge sysclk); #1;
        if (fft_done === 1'b0)
            $display("PASS [T1] fft_done=0 while reset asserted");
        else
            $display("FAIL [T1] expected fft_done=0 during reset, got %b", fft_done);
        reset_n = 1;
        repeat (2) @(posedge sysclk);

        // ── T2: fft_valid=0 does not advance write pointer ────
        // If the pointer were incorrectly advanced during invalid cycles,
        // the first real write would land at addr >0 instead of 0.
        reset_n = 0; repeat (2) @(posedge sysclk); #1;
        reset_n = 1; repeat (2) @(posedge sysclk);
        @(posedge sysclk); #1;
        fft_real  = 24'hDEAD00;   // "garbage" that must not be written
        fft_imag  = 24'hBEEF00;
        fft_valid = 0;
        repeat (4) @(posedge sysclk); #1;
        fft_valid = 0;
        // First valid write should land at addr 0 since pointer never moved
        write_sample(24'hCAFE00, 24'hBEEF01, 0, 0);
        read_ram(13'd0, rr, ri);
        check(rr, 24'hCAFE00, "T2 fft_valid=0 does not advance ptr (real at addr 0)");
        check(ri, 24'hBEEF01, "T2 fft_valid=0 does not advance ptr (imag at addr 0)");

        // ── T3: Consecutive writes land at sequential addresses ─
        reset_n = 0; repeat (2) @(posedge sysclk); #1;
        reset_n = 1; repeat (2) @(posedge sysclk);
        write_sample(24'hAA0001, 24'hBB0001, 0, 0);
        write_sample(24'hAA0002, 24'hBB0002, 0, 0);
        write_sample(24'hAA0003, 24'hBB0003, 0, 0);
        read_ram(13'd0, rr, ri);
        check(rr, 24'hAA0001, "T3 addr=0 real");
        check(ri, 24'hBB0001, "T3 addr=0 imag");
        read_ram(13'd1, rr, ri);
        check(rr, 24'hAA0002, "T3 addr=1 real");
        check(ri, 24'hBB0002, "T3 addr=1 imag");
        read_ram(13'd2, rr, ri);
        check(rr, 24'hAA0003, "T3 addr=2 real");
        check(ri, 24'hBB0003, "T3 addr=2 imag");

        // ── T4: data_sop (without fft_valid) resets write_addr ─
        // Write 5 samples to advance the pointer, then send sop with the next
        // valid sample (Avalon-ST: sop is only meaningful when valid is high).
        // That sample must land at addr 0 and reset the write pointer.
        reset_n = 0; repeat (2) @(posedge sysclk); #1;
        reset_n = 1; repeat (2) @(posedge sysclk);
        for (i = 0; i < 5; i++)
            write_sample(24'hCC0000 | i[23:0], 24'hDD0000 | i[23:0], 0, 0);
        // sop=1 with valid=1: resets pointer and writes this sample to addr 0
        write_sample(24'hFEED01, 24'hFACE01, 0, 1);
        read_ram(13'd0, rr, ri);
        check(rr, 24'hFEED01, "T4 sop resets write_addr: new write at addr 0 real");
        check(ri, 24'hFACE01, "T4 sop resets write_addr: new write at addr 0 imag");

        // ── T5: data_eop && fft_valid asserts fft_done ─────────
        reset_n = 0; repeat (2) @(posedge sysclk); #1;
        reset_n = 1; repeat (2) @(posedge sysclk);
        if (fft_done === 1'b0)
            $display("PASS [T5] fft_done=0 before eop (setup check)");
        else
            $display("FAIL [T5] fft_done should be 0 before eop, got %b", fft_done);
        write_sample(24'h123456, 24'h654321, 1, 0); // eop=1, valid=1
        repeat (2) @(posedge sysclk); #1;
        if (fft_done === 1'b1)
            $display("PASS [T5] fft_done=1 after data_eop && fft_valid");
        else
            $display("FAIL [T5] expected fft_done=1 after eop+valid, got %b", fft_done);

        // ── T6: data_eop without fft_valid does NOT assert fft_done
        reset_n = 0; repeat (2) @(posedge sysclk); #1;
        reset_n = 1; repeat (2) @(posedge sysclk);
        @(posedge sysclk); #1;
        data_eop  = 1;
        fft_valid = 0;
        @(posedge sysclk); #1;
        data_eop = 0;
        repeat (2) @(posedge sysclk); #1;
        if (fft_done === 1'b0)
            $display("PASS [T6] fft_done stays 0 when data_eop without fft_valid");
        else
            $display("FAIL [T6] fft_done must not assert without fft_valid, got %b", fft_done);

        // ── T7: data_sop clears fft_done ──────────────────────
        // Get fft_done high via eop, then start a new frame with sop+valid,
        // which must clear fft_done. sop is only meaningful when valid is high
        // (Avalon-ST), so fft_done only clears when they arrive together.
        reset_n = 0; repeat (2) @(posedge sysclk); #1;
        reset_n = 1; repeat (2) @(posedge sysclk);
        write_sample(24'hAABBCC, 24'hDDEEFF, 1, 0); // eop=1, valid=1 -> fft_done=1
        repeat (2) @(posedge sysclk); #1;
        if (fft_done !== 1'b1)
            $display("FAIL [T7 setup] fft_done should be 1, got %b", fft_done);
        write_sample(24'h112233, 24'h445566, 0, 1); // sop=1, valid=1 -> fft_done=0
        repeat (2) @(posedge sysclk); #1;
        if (fft_done === 1'b0)
            $display("PASS [T7] fft_done cleared by sop+valid");
        else
            $display("FAIL [T7] expected fft_done=0 after sop+valid, got %b", fft_done);

        // ── T8: Full 8192-sample frame — fft_done and read-back ─
        // Fill the entire RAM, verify fft_done asserts, then spot-check
        // eight addresses across the full address space.
        // sop is asserted with the first valid sample (i=0) per Avalon-ST protocol.
        reset_n = 0; repeat (2) @(posedge sysclk); #1;
        reset_n = 1; repeat (2) @(posedge sysclk);
        for (i = 0; i < 8192; i++) begin
            write_sample(
                24'hA00000 | i[23:0],
                24'hB00000 | i[23:0],
                (i == 8191) ? 1'b1 : 1'b0,  // eop on last sample
                (i == 0)    ? 1'b1 : 1'b0   // sop on first sample
            );
        end
        repeat (2) @(posedge sysclk); #1;
        if (fft_done === 1'b1)
            $display("PASS [T8] fft_done=1 after full 8192-sample frame");
        else
            $display("FAIL [T8] fft_done should be 1 after full frame, got %b", fft_done);

        // Spot-check addresses: boundaries and mid-range
        read_ram(13'd0,    rr, ri); check(rr, 24'hA00000, "T8 addr=0 real");    check(ri, 24'hB00000, "T8 addr=0 imag");
        read_ram(13'd1,    rr, ri); check(rr, 24'hA00001, "T8 addr=1 real");    check(ri, 24'hB00001, "T8 addr=1 imag");
        read_ram(13'd255,  rr, ri); check(rr, 24'hA000FF, "T8 addr=255 real");  check(ri, 24'hB000FF, "T8 addr=255 imag");
        read_ram(13'd1024, rr, ri); check(rr, 24'hA00400, "T8 addr=1024 real"); check(ri, 24'hB00400, "T8 addr=1024 imag");
        read_ram(13'd4095, rr, ri); check(rr, 24'hA00FFF, "T8 addr=4095 real"); check(ri, 24'hB00FFF, "T8 addr=4095 imag");
        read_ram(13'd4096, rr, ri); check(rr, 24'hA01000, "T8 addr=4096 real"); check(ri, 24'hB01000, "T8 addr=4096 imag");
        read_ram(13'd8190, rr, ri); check(rr, 24'hA01FFE, "T8 addr=8190 real"); check(ri, 24'hB01FFE, "T8 addr=8190 imag");
        read_ram(13'd8191, rr, ri); check(rr, 24'hA01FFF, "T8 addr=8191 real"); check(ri, 24'hB01FFF, "T8 addr=8191 imag");

        // ── T9: Reset mid-fill clears fft_done ────────────────
        reset_n = 0; repeat (2) @(posedge sysclk); #1;
        reset_n = 1; repeat (2) @(posedge sysclk);
        for (i = 0; i < 100; i++)
            write_sample(24'hEE0000 | i[23:0], 24'hFF0000 | i[23:0], 0, 0);
        reset_n = 0;
        repeat (4) @(posedge sysclk); #1;
        if (fft_done === 1'b0)
            $display("PASS [T9] fft_done=0 after reset mid-fill");
        else
            $display("FAIL [T9] expected fft_done=0 after mid-fill reset, got %b", fft_done);
        reset_n = 1; repeat (2) @(posedge sysclk);

        // ── T10: Read latency is exactly 1 sysclk cycle ────────
        // Write a known pattern, present rd_addr, and confirm output is
        // valid on the posedge immediately following the address presentation.
        reset_n = 0; repeat (2) @(posedge sysclk); #1;
        reset_n = 1; repeat (2) @(posedge sysclk);
        write_sample(24'h9A9A9A, 24'h6B6B6B, 0, 0);
        @(posedge sysclk); #1;
        rd_addr = 13'd0;             // present address on this edge
        @(posedge sysclk); #1;       // output registered on this edge (latency = 1)
        check(rd_real, 24'h9A9A9A, "T10 read latency 1 cycle real");
        check(rd_imag, 24'h6B6B6B, "T10 read latency 1 cycle imag");

        $display("\n=== All tests complete ===");
        $finish;
    end

    // ── Timeout watchdog ──────────────────────────────────────
    initial begin
        #2_000_000;
        $display("TIMEOUT — simulation limit reached");
        $finish;
    end

endmodule
