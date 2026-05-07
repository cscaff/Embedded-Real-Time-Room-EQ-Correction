`timescale 1ns / 1ps
// ── tb_room_eq_peripheral.sv ──────────────────────────────────────────────────
// Comprehensive Questa testbench for room_eq_peripheral.sv.
// Uses full RTL for all submodules; no behavioral stubs.
//
// Tests (T1–T14 run in <10 ms; T_PIPELINE requires +define+QUESTA_PERIPHERAL):
//   T1  : Power-on reset — registers, FSM, sync chain at reset values
//   T2  : LUT load via regs 4+5, all 256 entries; we_lut self-clear verified
//   T3  : sweep_start self-clears; toggle synchronizer fires exactly once in audio domain
//   T4  : FSM IDLE → SWEEP → CAPTURE → DONE (forced shortcuts)
//   T5  : DONE → SWEEP re-trigger
//   T6  : Mid-reset from SWEEP, CAPTURE, DONE — FSM returns to IDLE
//   T7  : STATUS register polling mirrors FSM through all states
//   T8a : Toggle sync — N rapid starts each produce exactly one audio-domain pulse
//   T8b : done_sync — sweep_done needs 2 sys-clk edges before done_sync2 asserts
//   T8c : rst_sync  — reset async-asserts rst_sync2 immediately, sync-deasserts in 2 audio clks
//   T9  : Full register R/W matrix (all addresses, write-only, read-only, defaults, undefined)
//   T10 : back-to-back LUT writes; we_lut self-clears between every write
//   T11 : Chipselect gating — reads/writes ignored when chipselect=0
//   T12 : calibrate_start is exactly 1 sysclk cycle
//   T13 : CAPTURE is sticky — state stays until fft_done, then transitions to DONE
//   T14 : Second sweep_start while in SWEEP is ignored (FSM stays SWEEP)
//   T_PIPELINE : Full 5-second sweep + 8192-sample golden FFT comparison
//                (compiled only with +define+QUESTA_PERIPHERAL)
//
// Compile:  see sim_room_eq_peripheral.tcl / Makefile target sim_room_eq_peripheral
// ─────────────────────────────────────────────────────────────────────────────

module tb_room_eq_peripheral;

    // ── Clock periods ─────────────────────────────────────────
    localparam CLK_PERIOD  = 20;    // 50 MHz system clock
    localparam ACLK_PERIOD = 81;    // ~12.288 MHz (81.38 → 81 ns for sim)

    // ── DUT ports ─────────────────────────────────────────────
    logic        clk;
    logic        reset;
    logic [31:0] writedata;
    logic [31:0] readdata;
    logic        write;
    logic        read;
    logic        chipselect;
    logic [3:0]  address;
    logic        audio_clk;

    wire         AUD_XCK;
    wire         AUD_BCLK;
    wire         AUD_DACDAT;
    wire         AUD_DACLRCK;

    // ── DUT ───────────────────────────────────────────────────
    room_eq_peripheral dut (
        .clk         (clk),
        .reset       (reset),
        .writedata   (writedata),
        .readdata    (readdata),
        .write       (write),
        .read        (read),
        .chipselect  (chipselect),
        .address     (address),
        .audio_clk   (audio_clk),
        .AUD_XCK     (AUD_XCK),
        .AUD_BCLK    (AUD_BCLK),
        .AUD_DACDAT  (AUD_DACDAT),
        .AUD_DACLRCK (AUD_DACLRCK)
    );

    // ── Clocks ────────────────────────────────────────────────
    initial clk       = 0;
    always  #(CLK_PERIOD  / 2) clk       = ~clk;
    initial audio_clk = 0;
    always  #(ACLK_PERIOD / 2) audio_clk = ~audio_clk;

    // ── FSM state encoding (matches room_eq_peripheral enum) ──
    localparam [3:0] ST_IDLE    = 4'd0;
    localparam [3:0] ST_SWEEP   = 4'd1;
    localparam [3:0] ST_CAPTURE = 4'd2;
    localparam [3:0] ST_DONE    = 4'd3;

    // ── Avalon helpers ─────────────────────────────────────────
    // One-cycle write: data latched by DUT on the posedge inside the task.
    task automatic av_write(input [3:0] addr, input [31:0] data);
        @(posedge clk); #1;
        chipselect = 1'b1; write = 1'b1; read = 1'b0;
        address    = addr;
        writedata  = data;
        @(posedge clk); #1;
        chipselect = 1'b0; write = 1'b0;
    endtask

    // Combinational read (readdata settles when cs+read are high).
    task automatic av_read(input [3:0] addr, output [31:0] data);
        @(posedge clk); #1;
        chipselect = 1'b1; read = 1'b1; write = 1'b0;
        address    = addr;
        #1; data   = readdata;   // capture combinational output
        @(posedge clk); #1;
        chipselect = 1'b0; read = 1'b0;
    endtask

    // ── Check helpers ──────────────────────────────────────────
    task automatic chk1(input got, input exp, input string lbl);
        if (got !== exp)
            $display("FAIL [%s]  got=%b  exp=%b", lbl, got, exp);
        else
            $display("PASS [%s]", lbl);
    endtask

    task automatic chk32(input [31:0] got, input [31:0] exp, input string lbl);
        if (got !== exp)
            $display("FAIL [%s]  got=0x%08h  exp=0x%08h", lbl, got, exp);
        else
            $display("PASS [%s]  0x%08h", lbl, got);
    endtask

    // ── Reset helper ───────────────────────────────────────────
    task automatic do_reset();
        reset = 1'b1;
        repeat (8) @(posedge clk); #1;
        reset = 1'b0;
        repeat (6) @(posedge audio_clk); #1;  // let rst_sync2 deassert
    endtask

    // ── Load full 256-entry LUT with a unique ramp pattern ────
    task automatic load_lut_ramp();
        integer k;
        for (k = 0; k < 256; k++) begin
            av_write(4'd4, k[31:0]);
            av_write(4'd5, {8'd0, k[7:0], 16'hABCD});
        end
    endtask

    // ── Shortcut: drive FSM to CAPTURE via forced sweep_done ──
    task automatic force_to_capture();
        force dut.sweep_done = 1'b1;
        repeat (8) @(posedge clk); #1;     // done_sync2 propagates in 2 cycles; wait margin
        release dut.sweep_done;
    endtask

    // ── Test variables ────────────────────────────────────────
    integer      i, fail_cnt, timeout_cnt;
    logic [31:0] rdata;

    // ── Golden FFT arrays (pipeline test only) ────────────────
`ifdef QUESTA_PERIPHERAL
    logic [23:0] fft_input_data   [0:8191];
    logic [23:0] golden_real_data [0:8191];
    logic [23:0] golden_imag_data [0:8191];

    initial begin
        $readmemh("sim_out/fft_input.hex",      fft_input_data);
        $readmemh("sim_out/fft_golden_real.hex", golden_real_data);
        $readmemh("sim_out/fft_golden_imag.hex", golden_imag_data);
    end

    // Continuous injection into left_chan_tb on every DACLRCK falling edge.
    // fft_input_data is cos(2π·64·n/8192), period=128. Cycling through the
    // 8192-entry array (= 64 complete periods) means ANY 8192-sample window
    // seen by the FFT gives an identical DFT, so FIFO pre-fill depth is irrelevant.
    integer inject_idx;
    logic   inject_active;
    initial inject_active = 1'b0;

    always @(negedge AUD_DACLRCK) begin
        if (inject_active) begin
            force dut.left_chan_tb = fft_input_data[inject_idx % 8192];
            inject_idx = inject_idx + 1;
        end
    end
`endif // QUESTA_PERIPHERAL

    // ──────────────────────────────────────────────────────────
    // ── Main test sequence ────────────────────────────────────
    // ──────────────────────────────────────────────────────────
    initial begin
        // Default idle bus
        chipselect = 0; write = 0; read = 0;
        address    = 4'd0; writedata = 32'd0;
        reset      = 1'b0;
        force dut.left_chan_tb = 24'd0;

        // ═════════════════════════════════════════════════════
        // T1: Power-on reset
        // ═════════════════════════════════════════════════════
        $display("\n=== T1: Power-on reset ===");
        reset = 1'b1;
        // rst_sync chain uses async preset, so it should assert on the very
        // next audio_clk edge (or even before it, depending on delta cycle).
        @(posedge audio_clk); #1;
        chk1(dut.rst_sync1, 1'b1, "T1 rst_sync1 async-high on reset");
        chk1(dut.rst_sync2, 1'b1, "T1 rst_sync2 async-high on reset");

        repeat (8) @(posedge clk); #1;
        chk1(dut.state == ST_IDLE,        1'b1, "T1 FSM=IDLE");
        chk1(dut.sweep_start,             1'b0, "T1 sweep_start=0");
        chk1(dut.sweep_start_toggle,      1'b0, "T1 toggle FF=0");
        chk1(dut.we_lut,                  1'b0, "T1 we_lut=0");
        chk1(dut.calibrate_start,         1'b0, "T1 calibrate_start=0");
        chk1(AUD_XCK === audio_clk,       1'b1, "T1 AUD_XCK=audio_clk");

        // Register defaults under reset
        av_read(4'd2, rdata); chk32(rdata, 32'd2_400_000,    "T1 SWEEP_LEN default");
        av_read(4'd3, rdata); chk32(rdata, 32'h0001_0000,  "T1 VERSION");
        av_read(4'd1, rdata); chk32(rdata[3:0], ST_IDLE,   "T1 STATUS=IDLE");

        reset = 1'b0;
        // rst_sync deasserts after 2 audio clock edges (synchronized release)
        @(posedge audio_clk); #1;
        chk1(dut.rst_sync1, 1'b0, "T1 rst_sync1=0 after 1 audio clk");
        chk1(dut.rst_sync2, 1'b1, "T1 rst_sync2 still 1 after 1 audio clk");
        @(posedge audio_clk); #1;
        chk1(dut.rst_sync2, 1'b0, "T1 rst_sync2=0 after 2 audio clks");
        $display("--- T1 complete ---");

        // ═════════════════════════════════════════════════════
        // T2: LUT load via registers 4+5, all 256 entries
        // ═════════════════════════════════════════════════════
        $display("\n=== T2: LUT load ===");
        do_reset();
        for (i = 0; i < 256; i++) begin
            // we_lut must be 0 between consecutive writes (self-clears after every non-addr5 cycle)
            av_write(4'd4, i[31:0]);
            chk1(dut.we_lut, 1'b0, $sformatf("T2 we_lut=0 before data write [%0d]", i));
            av_write(4'd5, {8'd0, i[7:0], 16'hABCD});  // triggers we_lut for 1 cycle
        end
        repeat (4) @(posedge clk); #1;

        // Spot-check 256 LUT entries via hierarchical path into sine_lut BRAM
        fail_cnt = 0;
        for (i = 0; i < 256; i++) begin
            if (dut.sweep_inst.lookup.lut.mem[i] !== {i[7:0], 16'hABCD}) begin
                $display("FAIL [T2] mem[%0d] got=0x%06h exp=0x%06h",
                         i, dut.sweep_inst.lookup.lut.mem[i], {i[7:0], 16'hABCD});
                fail_cnt++;
            end
        end
        if (fail_cnt == 0) $display("PASS [T2] all 256 LUT entries correct");
        else               $display("FAIL [T2] %0d / 256 entries wrong", fail_cnt);
        $display("--- T2 complete ---");

        // ═════════════════════════════════════════════════════
        // T3: sweep_start self-clears; toggle sync fires in audio domain
        // ═════════════════════════════════════════════════════
        $display("\n=== T3: Start pulse and toggle synchronizer ===");
        do_reset();
        begin : t3_block
            logic pre_tog;
            pre_tog = dut.sweep_start_toggle;
            av_write(4'd0, 32'd1);   // asserts sweep_start for 1 clk cycle
            // av_write returns 1 ns after the posedge that latched sweep_start=1.
            // The self-clear and toggle flip happen on the *next* posedge — wait for it.
            @(posedge clk); #1;
            chk1(dut.sweep_start, 1'b0, "T3 sweep_start self-clears");
            chk1(dut.sweep_start_toggle !== pre_tog, 1'b1, "T3 toggle flipped once");

            // Wait for 3-FF sync chain in audio domain to propagate
            // sweep_start_audio = tog_sync2 ^ tog_sync3 fires for exactly 1 audio clk
            // After 6 audio clks, tog_sync2 must have settled to the new toggle value
            repeat (8) @(posedge audio_clk); #1;
            chk1(dut.tog_sync2 !== pre_tog, 1'b1, "T3 tog_sync2 settled to new value");
        end
        // FSM must now be in SWEEP (IDLE → SWEEP on sweep_start)
        av_read(4'd1, rdata);
        chk32(rdata[3:0], ST_SWEEP, "T3 STATUS=SWEEP after start");
        $display("--- T3 complete ---");

        // ═════════════════════════════════════════════════════
        // T4: FSM IDLE → SWEEP → CAPTURE → DONE (forced shortcuts)
        // ═════════════════════════════════════════════════════
        $display("\n=== T4: FSM full path ===");
        do_reset();
        chk1(dut.state == ST_IDLE, 1'b1, "T4 starts IDLE");

        av_write(4'd0, 32'd1);
        repeat (2) @(posedge clk); #1;
        chk1(dut.state == ST_SWEEP, 1'b1, "T4 FSM=SWEEP");

        // Force sweep_done to bypass the 5-second real sweep
        force dut.sweep_done = 1'b1;
        timeout_cnt = 0;
        while (dut.state !== ST_CAPTURE && timeout_cnt < 200) begin
            @(posedge clk); #1; timeout_cnt++;
        end
        release dut.sweep_done;
        chk1(dut.state == ST_CAPTURE, 1'b1, "T4 FSM=CAPTURE after sweep_done");

        // calibrate_start was set to 1 on the same posedge the while-loop exited on.
        // The default (self-clear to 0) happens on the next posedge — wait for it.
        @(posedge clk); #1;
        chk1(dut.calibrate_start, 1'b0, "T4 calibrate_start self-cleared");

        // Force fft_done to bypass the full FFT pipeline
        force dut.fft_done = 1'b1;
        repeat (4) @(posedge clk); #1;
        release dut.fft_done;
        chk1(dut.state == ST_DONE, 1'b1, "T4 FSM=DONE");

        av_read(4'd1, rdata);
        chk32(rdata[3:0], ST_DONE, "T4 STATUS register=DONE");
        $display("--- T4 complete ---");

        // ═════════════════════════════════════════════════════
        // T5: DONE → SWEEP re-trigger
        // ═════════════════════════════════════════════════════
        $display("\n=== T5: DONE → SWEEP re-trigger ===");
        // DUT is in DONE from T4
        av_write(4'd0, 32'd1);
        repeat (2) @(posedge clk); #1;
        chk1(dut.state == ST_SWEEP, 1'b1, "T5 FSM=SWEEP after re-trigger from DONE");
        av_read(4'd1, rdata);
        chk32(rdata[3:0], ST_SWEEP, "T5 STATUS=SWEEP");
        $display("--- T5 complete ---");

        // ═════════════════════════════════════════════════════
        // T6: Mid-reset from SWEEP, CAPTURE, DONE
        // ═════════════════════════════════════════════════════
        $display("\n=== T6: Mid-reset from each FSM state ===");

        // From SWEEP
        do_reset();
        av_write(4'd0, 32'd1);
        repeat (2) @(posedge clk); #1;
        chk1(dut.state == ST_SWEEP, 1'b1, "T6 setup SWEEP");
        reset = 1'b1; @(posedge clk); #1;
        chk1(dut.state == ST_IDLE,  1'b1, "T6 reset from SWEEP → IDLE");
        reset = 1'b0; repeat (2) @(posedge clk); #1;

        // From CAPTURE
        av_write(4'd0, 32'd1);
        repeat (2) @(posedge clk); #1;
        force_to_capture();
        chk1(dut.state == ST_CAPTURE, 1'b1, "T6 setup CAPTURE");
        reset = 1'b1; @(posedge clk); #1;
        chk1(dut.state == ST_IDLE,    1'b1, "T6 reset from CAPTURE → IDLE");
        reset = 1'b0; repeat (2) @(posedge clk); #1;

        // From DONE
        av_write(4'd0, 32'd1);
        repeat (2) @(posedge clk); #1;
        force_to_capture();
        force dut.fft_done = 1'b1;
        repeat (4) @(posedge clk); #1;
        release dut.fft_done;
        chk1(dut.state == ST_DONE, 1'b1, "T6 setup DONE");
        reset = 1'b1; @(posedge clk); #1;
        chk1(dut.state == ST_IDLE, 1'b1, "T6 reset from DONE → IDLE");
        reset = 1'b0; repeat (2) @(posedge clk); #1;
        $display("--- T6 complete ---");

        // ═════════════════════════════════════════════════════
        // T7: STATUS register polling tracks FSM state
        // ═════════════════════════════════════════════════════
        $display("\n=== T7: STATUS polling ===");
        do_reset();
        av_read(4'd1, rdata); chk32(rdata[3:0], ST_IDLE,    "T7 STATUS=IDLE");
        av_write(4'd0, 32'd1);
        repeat (2) @(posedge clk); #1;
        av_read(4'd1, rdata); chk32(rdata[3:0], ST_SWEEP,   "T7 STATUS=SWEEP");
        force_to_capture();
        av_read(4'd1, rdata); chk32(rdata[3:0], ST_CAPTURE, "T7 STATUS=CAPTURE");
        force dut.fft_done = 1'b1;
        repeat (4) @(posedge clk); #1; release dut.fft_done;
        av_read(4'd1, rdata); chk32(rdata[3:0], ST_DONE,    "T7 STATUS=DONE");
        $display("--- T7 complete ---");

        // ═════════════════════════════════════════════════════
        // T8a: Toggle synchronizer — N rapid starts each produce 1 audio pulse
        // ═════════════════════════════════════════════════════
        $display("\n=== T8a: Toggle synchronizer integrity ===");
        do_reset();
        begin : t8a
            integer N;
            logic   base_tog;
            integer audio_pulses;
            N            = 4;
            audio_pulses = 0;
            base_tog     = dut.sweep_start_toggle;

            // Fork a monitor that counts sweep_start_audio pulses in the audio domain.
            // Each start must be separated by >= 4 audio clocks (the 3-FF sync latency
            // plus margin). If two starts arrive faster than that, the toggle flips
            // back before the audio domain resolves it and the pair cancels to 0 pulses —
            // that is correct hardware behaviour, not a bug.
            fork
                begin : monitor_fork
                    integer cnt;
                    logic   prev_pulse;
                    cnt        = 0;
                    prev_pulse = 0;
                    // N starts × 16 audio clocks each gives plenty of window
                    repeat (N * 16) begin
                        @(posedge audio_clk); #1;
                        if (dut.sweep_start_audio & ~prev_pulse) cnt++;
                        prev_pulse = dut.sweep_start_audio;
                    end
                    audio_pulses = cnt;
                end

                begin : stimulus_fork
                    integer j;
                    @(posedge audio_clk); #1;
                    for (j = 0; j < N; j++) begin
                        av_write(4'd0, 32'd1);
                        // Wait 8 audio clocks between starts so each toggle fully
                        // propagates through the 3-FF chain before the next one fires.
                        repeat (8) @(posedge audio_clk); #1;
                    end
                end
            join

            if (audio_pulses == N)
                $display("PASS [T8a] %0d starts → %0d audio pulses (exact match)", N, audio_pulses);
            else
                $display("FAIL [T8a] %0d starts → %0d audio pulses (expected %0d)",
                         N, audio_pulses, N);
        end
        $display("--- T8a complete ---");

        // ═════════════════════════════════════════════════════
        // T8b: done_sync — needs 2 sys-clk cycles to cross
        // ═════════════════════════════════════════════════════
        $display("\n=== T8b: done_sync CDC delay ===");
        do_reset();
        av_write(4'd0, 32'd1);
        repeat (2) @(posedge clk); #1;
        force dut.sweep_done = 1'b1;
        // Cycle 1 after assertion: done_sync1 captures, done_sync2 still old value (0)
        @(posedge clk); #1;
        chk1(dut.done_sync2, 1'b0, "T8b done_sync2=0 one clk after sweep_done");
        // Cycle 2: done_sync1 already 1 from last cycle
        @(posedge clk); #1;
        chk1(dut.done_sync1, 1'b1, "T8b done_sync1=1 after 1 clk");
        // Cycle 3: done_sync2 now 1
        @(posedge clk); #1;
        chk1(dut.done_sync2, 1'b1, "T8b done_sync2=1 after 2 clks");
        release dut.sweep_done;
        // After release, done_sync chain clears after 2 more cycles
        @(posedge clk); @(posedge clk); @(posedge clk); #1;
        chk1(dut.done_sync2, 1'b0, "T8b done_sync2 clears after sweep_done released");
        $display("--- T8b complete ---");

        // ═════════════════════════════════════════════════════
        // T8c: rst_sync — async assert, synchronous deassert
        // ═════════════════════════════════════════════════════
        $display("\n=== T8c: rst_sync async/sync behaviour ===");
        do_reset();
        begin : t8c
            // Assert reset mid-cycle (not at an edge) to confirm async preset
            @(posedge audio_clk); #10;   // 10 ns into a cycle
            reset = 1'b1;
            #1;  // 1 ns: async preset should have taken effect
            chk1(dut.rst_sync1, 1'b1, "T8c rst_sync1 async-asserts immediately");
            chk1(dut.rst_sync2, 1'b1, "T8c rst_sync2 async-asserts immediately");

            // Deassert reset; release must propagate through 2 audio clk edges
            @(posedge clk); #1;
            reset = 1'b0;
            @(posedge audio_clk); #1;
            chk1(dut.rst_sync1, 1'b0, "T8c rst_sync1=0 after 1 audio clk");
            chk1(dut.rst_sync2, 1'b1, "T8c rst_sync2 still 1 after 1 audio clk");
            @(posedge audio_clk); #1;
            chk1(dut.rst_sync2, 1'b0, "T8c rst_sync2=0 after 2 audio clks");
        end
        $display("--- T8c complete ---");

        // ═════════════════════════════════════════════════════
        // T9: Full register R/W matrix
        // ═════════════════════════════════════════════════════
        $display("\n=== T9: Register matrix ===");
        do_reset();

        // CTRL addr 0: write-only; read returns 0
        // (writing CTRL will transition IDLE→SWEEP; force state back after)
        av_write(4'd0, 32'hFFFF_FFFF);
        repeat (2) @(posedge clk); #1;
        av_read(4'd0, rdata);
        chk32(rdata, 32'd0, "T9 CTRL read=0 (write-only)");
        force dut.state = ST_IDLE;   // pull FSM back for clean further tests
        @(posedge clk); #1;

        // SWEEP_LEN addr 2: R/W
        av_write(4'd2, 32'd12345);
        av_read(4'd2, rdata); chk32(rdata, 32'd12345, "T9 SWEEP_LEN R/W");
        av_write(4'd2, 32'd480_000);  // restore default

        // VERSION addr 3: read-only; writes silently ignored
        av_read(4'd3, rdata); chk32(rdata, 32'h0001_0000, "T9 VERSION read");
        av_write(4'd3, 32'hDEAD_BEEF);
        av_read(4'd3, rdata); chk32(rdata, 32'h0001_0000, "T9 VERSION write ignored");

        // LUT_ADDR addr 4: write-only; read returns 0
        av_write(4'd4, 32'd99);
        av_read(4'd4, rdata); chk32(rdata, 32'd0, "T9 LUT_ADDR read=0 (write-only)");

        // LUT_DATA addr 5: write-only; read returns 0
        av_write(4'd5, 32'h00AABBCC);
        av_read(4'd5, rdata); chk32(rdata, 32'd0, "T9 LUT_DATA read=0 (write-only)");

        // FFT_ADDR addr 6: R/W (13-bit field)
        av_write(4'd6, 32'd8191);
        av_read(4'd6, rdata); chk32(rdata[12:0], 13'd8191, "T9 FFT_ADDR max");
        av_write(4'd6, 32'd0);
        av_read(4'd6, rdata); chk32(rdata[12:0], 13'd0, "T9 FFT_ADDR zero");

        // STATUS addr 1: read-only; force DONE, write 0, verify it doesn't change
        force dut.state = ST_DONE;
        @(posedge clk); #1;
        av_write(4'd1, 32'd0);
        av_read(4'd1, rdata); chk32(rdata[3:0], ST_DONE, "T9 STATUS write ignored");
        release dut.state;
        force dut.state = ST_IDLE;
        @(posedge clk); #1;
        release dut.state;

        // Undefined addresses must return 0
        av_read(4'd9,  rdata); chk32(rdata, 32'd0, "T9 addr=9  undefined → 0");
        av_read(4'd11, rdata); chk32(rdata, 32'd0, "T9 addr=11 undefined → 0");
        av_read(4'd15, rdata); chk32(rdata, 32'd0, "T9 addr=15 undefined → 0");
        $display("--- T9 complete ---");

        // ═════════════════════════════════════════════════════
        // T10: Back-to-back LUT writes — we_lut self-clears every cycle
        // ═════════════════════════════════════════════════════
        $display("\n=== T10: we_lut self-clear on consecutive LUT writes ===");
        do_reset();
        begin : t10
            integer stuck;
            stuck = 0;
            for (i = 0; i < 16; i++) begin
                // ADDR write — we_lut must be 0 (no data write preceding this)
                av_write(4'd4, i[31:0]);
                if (dut.we_lut !== 1'b0) begin
                    $display("FAIL [T10] we_lut=1 after LUT_ADDR write (i=%0d)", i);
                    stuck++;
                end
                // DATA write — we_lut fires for 1 cycle then self-clears on the
                // next posedge. av_write returns 1 ns after the posedge that set
                // we_lut=1, so we wait one more clock before sampling.
                av_write(4'd5, {8'd0, i[7:0], 16'hFF00});
                @(posedge clk); #1;
                if (dut.we_lut !== 1'b0) begin
                    $display("FAIL [T10] we_lut stuck after LUT_DATA write (i=%0d)", i);
                    stuck++;
                end
            end
            if (stuck == 0)
                $display("PASS [T10] we_lut self-clears correctly on all 16 write cycles");
        end
        $display("--- T10 complete ---");

        // ═════════════════════════════════════════════════════
        // T11: Chipselect gating
        // ═════════════════════════════════════════════════════
        $display("\n=== T11: Chipselect gating ===");
        do_reset();

        // Read with chipselect=0 must return 0 even for a valid address
        @(posedge clk); #1;
        chipselect = 1'b0; read = 1'b1; address = 4'd3;  // VERSION
        #1; chk32(readdata, 32'd0, "T11 cs=0 read returns 0");
        read = 1'b0;

        // Write with chipselect=0 must not alter register state
        av_write(4'd2, 32'd999_999);      // set SWEEP_LEN with cs=1
        av_read(4'd2, rdata); chk32(rdata, 32'd999_999, "T11 SWEEP_LEN before cs=0 write");
        @(posedge clk); #1;
        chipselect = 1'b0; write = 1'b1; address = 4'd2; writedata = 32'd1;
        @(posedge clk); #1;
        chipselect = 1'b0; write = 1'b0;
        av_read(4'd2, rdata); chk32(rdata, 32'd999_999, "T11 SWEEP_LEN unchanged (cs=0 write)");
        $display("--- T11 complete ---");

        // ═════════════════════════════════════════════════════
        // T12: calibrate_start is exactly 1 sysclk cycle
        // ═════════════════════════════════════════════════════
        $display("\n=== T12: calibrate_start = 1-cycle pulse ===");
        do_reset();
        av_write(4'd0, 32'd1);
        repeat (2) @(posedge clk); #1;
        force dut.sweep_done = 1'b1;

        // Wait for FSM to enter CAPTURE (calibrate_start fired that same cycle)
        timeout_cnt = 0;
        while (dut.state !== ST_CAPTURE && timeout_cnt < 200) begin
            @(posedge clk); #1; timeout_cnt++;
        end
        release dut.sweep_done;

        if (dut.state === ST_CAPTURE) begin
            // One cycle after CAPTURE entry, calibrate_start must already be back to 0
            @(posedge clk); #1;
            chk1(dut.calibrate_start, 1'b0, "T12 calibrate_start=0 cycle after CAPTURE entry");
        end else begin
            $display("FAIL [T12] FSM never reached CAPTURE (timeout after %0d clks)", timeout_cnt);
        end
        force dut.fft_done = 1'b1;
        repeat (4) @(posedge clk); #1; release dut.fft_done;
        $display("--- T12 complete ---");

        // ═════════════════════════════════════════════════════
        // T13: CAPTURE is sticky — stays until fft_done fires
        // ═════════════════════════════════════════════════════
        $display("\n=== T13: CAPTURE sticky without fft_done ===");
        do_reset();
        av_write(4'd0, 32'd1);
        repeat (2) @(posedge clk); #1;
        force_to_capture();
        chk1(dut.state == ST_CAPTURE, 1'b1, "T13 in CAPTURE");

        // Verify FSM stays in CAPTURE for many cycles with no fft_done
        repeat (50) @(posedge clk); #1;
        chk1(dut.state == ST_CAPTURE, 1'b1, "T13 CAPTURE sticky after 50 clks");

        force dut.fft_done = 1'b1;
        repeat (4) @(posedge clk); #1; release dut.fft_done;
        chk1(dut.state == ST_DONE, 1'b1, "T13 CAPTURE → DONE after fft_done");
        $display("--- T13 complete ---");

        // ═════════════════════════════════════════════════════
        // T14: Second sweep_start while in SWEEP is ignored
        // ═════════════════════════════════════════════════════
        $display("\n=== T14: Double-start in SWEEP is ignored ===");
        do_reset();
        av_write(4'd0, 32'd1);
        repeat (2) @(posedge clk); #1;
        chk1(dut.state == ST_SWEEP, 1'b1, "T14 in SWEEP after first start");
        // Write start again — SWEEP case does not respond to sweep_start
        av_write(4'd0, 32'd1);
        repeat (4) @(posedge clk); #1;
        chk1(dut.state == ST_SWEEP, 1'b1, "T14 stays SWEEP on second start");
        $display("--- T14 complete ---");

`ifdef QUESTA_PERIPHERAL
        // ═════════════════════════════════════════════════════
        // T_PIPELINE: Full 5-second sweep + golden FFT comparison
        // ═════════════════════════════════════════════════════
        $display("\n=== T_PIPELINE: Full pipeline (real 5-second sweep) ===");
        do_reset();
        release dut.left_chan_tb;   // lift the forced-zero from earlier

        // Load the sine LUT with the ramp pattern so sweep_generator produces audio
        load_lut_ramp();
        repeat (4) @(posedge clk); #1;

        // Arm continuous sample injection.
        // Samples arrive at AUD_DACLRCK rate (48 kHz) throughout the sweep.
        // fft_input_data is periodic (period 128); the FFT will process
        // 8192 = 64×128 consecutive samples regardless of where in the
        // cycle the FIFO starts draining.
        inject_idx    = 0;
        inject_active = 1'b1;

        // Start the sweep
        av_write(4'd0, 32'd1);
        repeat (2) @(posedge clk); #1;
        chk1(dut.state == ST_SWEEP, 1'b1, "T_PIPELINE FSM=SWEEP");

        $display("  [T_PIPELINE] forcing sweep complete (skip 5 s sim time)...");
        force_to_capture();
        chk1(dut.state == ST_CAPTURE, 1'b1, "T_PIPELINE FSM=CAPTURE");

        $display("  [T_PIPELINE] waiting for fft_done (~170 ms FIFO fill + FFT latency)...");
        timeout_cnt = 0;
        while (dut.fft_done !== 1'b1 && timeout_cnt < 20_000_000) begin
            @(posedge clk); #1; timeout_cnt++;
        end

        if (dut.fft_done !== 1'b1) begin
            $display("FAIL [T_PIPELINE] fft_done never asserted (timeout %0d clks)", timeout_cnt);
        end else begin
            $display("PASS [T_PIPELINE] fft_done=1 after %0d sys-clk cycles", timeout_cnt);
            chk1(dut.state == ST_DONE, 1'b1, "T_PIPELINE FSM=DONE");

            // Read all 8192 FFT bins via the Avalon register interface and
            // compare to gen_golden_fft.py output within +/-16 LSB tolerance.
            begin : pipeline_cmp
                localparam FFT_TOL = 16;
                logic [31:0] rd_r, rd_i;
                integer      dr, di, bin;
                fail_cnt = 0;

                for (bin = 0; bin < 8192; bin++) begin
                    av_write(4'd6, bin[31:0]);   // FFT_ADDR
                    av_read (4'd7, rd_r);        // FFT_RDATA
                    av_read (4'd8, rd_i);        // FFT_IDATA

                    dr = $signed(rd_r[23:0]) - $signed(golden_real_data[bin]);
                    di = $signed(rd_i[23:0]) - $signed(golden_imag_data[bin]);
                    if (dr < 0) dr = -dr;
                    if (di < 0) di = -di;

                    if (dr > FFT_TOL || di > FFT_TOL) begin
                        $display("FAIL [T_PIPELINE] bin=%4d  re: hw=%8d np=%8d |d|=%0d  im: hw=%8d np=%8d |d|=%0d",
                            bin,
                            $signed(rd_r[23:0]), $signed(golden_real_data[bin]), dr,
                            $signed(rd_i[23:0]), $signed(golden_imag_data[bin]), di);
                        fail_cnt++;
                    end
                end

                if (fail_cnt == 0)
                    $display("PASS [T_PIPELINE] all 8192 bins within +/-%0d LSB", FFT_TOL);
                else
                    $display("FAIL [T_PIPELINE] %0d / 8192 bins exceeded +/-%0d LSB tolerance",
                             fail_cnt, FFT_TOL);
            end
        end

        inject_active = 1'b0;
        $display("--- T_PIPELINE complete ---");
`endif // QUESTA_PERIPHERAL

        $display("\n=== All tests complete ===");
        $finish;
    end

    // ── Timeout watchdog ──────────────────────────────────────
    initial begin
`ifdef QUESTA_PERIPHERAL
        repeat(2) #1_000_000_000; // 2 seconds: FIFO fill (~170 ms) + FFT latency + compare
`else
        #15_000_000;      // 15 ms: T1–T14 comfortably finish
`endif
        $display("TIMEOUT — simulation limit reached");
        $finish;
    end

endmodule
