`timescale 1ns / 1ps

module tb_sine_lookup;

    // ── Clock parameters ─────────────────────────────────────
    // clk_sys: 20 ns (50 MHz) — drives Port A LUT initialization
    // clock:  200 ns (5 MHz)  — drives sine_lookup sample pipeline
    //                           (scaled from 48 kHz for sim speed)
    localparam CLK_SYS_PERIOD  = 20;
    localparam CLK_SAMP_PERIOD = 200;

    // ── Signals ──────────────────────────────────────────────
    logic        clock, clk_sys;
    logic        reset;
    logic        sample_en;
    logic [31:0] phase;
    logic [23:0] amplitude;

    // Port A — LUT init
    logic        we_lut;
    logic [7:0]  addr_lut;
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
    always #(CLK_SAMP_PERIOD / 2) clock   = ~clock;

    // ── LUT write task (Port A) ───────────────────────────────
    task automatic write_lut(input [7:0] a, input [23:0] d);
        @(posedge clk_sys); #1;
        addr_lut = a;
        din_lut  = d;
        we_lut   = 1;
        @(posedge clk_sys); #1;
        we_lut   = 0;
    endtask

    // ── Sample pipeline task ──────────────────────────────────
    // Presents phase and returns amplitude after the 2-cycle pipeline delay.
    task automatic sample(input [31:0] ph, output [23:0] amp);
        @(posedge clock); #1;
        phase = ph;
        @(posedge clock); #1;  // cycle 1: BRAM read + quadrant_d register
        @(posedge clock); #1;  // cycle 2: amplitude mux register
        amp = amplitude;
    endtask

    // ── Check task ────────────────────────────────────────────
    task automatic check(
        input signed [23:0] got,
        input signed [23:0] expected,
        input signed [23:0] tolerance, // The idea behind tolerance is that our simulated result will vary slightly from the mathematical ideal,
        input string        label      // but that is generally ok within a bound.
    );
        logic signed [23:0] diff;
        diff = got - expected;
        if (diff < 0) diff = -diff;
        if (diff > tolerance)
            $display("FAIL [%s]  got=%0d  expected=%0d  diff=%0d",
                     label, got, expected, diff);
        else
            $display("PASS [%s]  amplitude=%0d", label, got);
    endtask

    // ── Variables ─────────────────────────────────────────────
    integer      i;
    real         sine_val;
    logic [23:0] amp;
    integer      csv_fd;

    localparam real MAX_AMP = 8388607.0;  // 2^23 - 1 (max positive value in a signed 24-bit representation)
    localparam real PI      = 3.14159265358979;

    initial begin
        // ── Default state ─────────────────────────────────────
        reset     = 1;
        sample_en = 1; // unit test: every clock edge is a sample tick
        phase     = 0;
        we_lut    = 0;
        addr_lut  = 0;
        din_lut   = 0;

        // ── Load LUT via Port A ───────────────────────────────
        // Entry i = round(sin(i/256 * pi/2) * MAX_AMP)
        // Each entry is some fraction of the MAX_AMP based on the sine of its angle.
        // Covers Q1 (0 to pi/2). Quadrant logic mirrors it for Q2-Q4.
        for (i = 0; i < 256; i++) begin
            sine_val = $sin(i * PI / 512.0) * MAX_AMP;
            write_lut(i[7:0], $rtoi(sine_val)); // $rtoi rounds real sine value to integer for LUT.
        end

        repeat (4) @(posedge clk_sys); // settle after last write

        // ── Release reset ─────────────────────────────────────
        @(posedge clock); #1;
        reset = 0;
        repeat (2) @(posedge clock); // flush pipeline

        // ── T1: Reset holds amplitude at 0 ───────────────────
        reset = 1;
        @(posedge clock); #1;
        check($signed(amplitude), 24'sd0, 24'sd0, "T1 reset -> 0"); // $signed interprets a bit vector as a signed (two's complement)
        reset = 0;
        repeat (2) @(posedge clock);

        // ── T2: Pipeline latency is exactly 2 clock cycles ───
        @(posedge clock); #1;
        phase = 32'h10000000;   // Q1, index=64 ([31:30] = 00, [29:22] = 01000000 = 64)
        @(posedge clock); #1;
        $display("T2 cycle 1 (stale, expect ~0): amplitude=%0d", $signed(amplitude));
        @(posedge clock); #1;
        $display("T2 cycle 2 (valid, expect ~%0d): amplitude=%0d",
                 $rtoi($sin(64.0 * PI / 512.0) * MAX_AMP), $signed(amplitude)); // index = 64

        // ── T3: Key phase landmarks ───────────────────────────
        sample(32'h00000000, amp);
        check($signed(amp),  24'sd0,        24'sd2, "T3 phase=0   -> ~0");
        // Tolerance of 2? I honestly do not know the exact reasoning.

        // Tolerance 200: LUT index 255 = sin(255/256 * pi/2), not exactly sin(pi/2).
        // The 256-entry table can't represent 90° exactly — max reachable ≈ 8388449.
        //0x40000000 = 0100 0000 0000 0000 0000 0000 0000 0000             
        //   [31:30] = 01  → Q2, [29:22] = 00000000 = 0                                           
        sample(32'h40000000, amp);
        check($signed(amp),  24'sd8388607,  24'sd200, "T3 phase=90  -> ~+max");

        // 0x80000000 = 1000 0000 0000 0000 0000 0000 0000 0000 
        //   [31:30] = 10  → Q3, [29:22] = 00000000 = 0                                           
        sample(32'h80000000, amp);
        check($signed(amp),  24'sd0,        24'sd2,   "T3 phase=180 -> ~0");

        // 0xC0000000 = 1100 0000 0000 0000 0000 0000 0000 0000 
        //   [31:30] = 11  → Q4, [29:22] = 00000000 = 0                                           
        sample(32'hC0000000, amp);
        check($signed(amp), -24'sd8388607,  24'sd200, "T3 phase=270 -> ~-max");

        // ── T4: Each quadrant has the correct sign ─────────────
        sample(32'h10000000, amp); // Q1 mid — expect positive
        if ($signed(amp) > 0) $display("PASS [T4 Q1 positive]  amplitude=%0d", $signed(amp));
        else                   $display("FAIL [T4 Q1 positive]  amplitude=%0d", $signed(amp));

        sample(32'h50000000, amp); // Q2 mid — expect positive
        if ($signed(amp) > 0) $display("PASS [T4 Q2 positive]  amplitude=%0d", $signed(amp));
        else                   $display("FAIL [T4 Q2 positive]  amplitude=%0d", $signed(amp));

        sample(32'h90000000, amp); // Q3 mid — expect negative
        if ($signed(amp) < 0) $display("PASS [T4 Q3 negative]  amplitude=%0d", $signed(amp));
        else                   $display("FAIL [T4 Q3 negative]  amplitude=%0d", $signed(amp));

        sample(32'hD0000000, amp); // Q4 mid — expect negative
        if ($signed(amp) < 0) $display("PASS [T4 Q4 negative]  amplitude=%0d", $signed(amp));
        else                   $display("FAIL [T4 Q4 negative]  amplitude=%0d", $signed(amp));

        // ── T5: Q1/Q2 symmetry: sin(x) == sin(pi - x) ────────
        // Q2 reads the LUT backwards: lut_index = ~phase[29:22].
        // For Q2 to hit LUT[80], we need ~phase[29:22] = 80, so phase[29:22] = 175.
        begin
            logic [23:0] q1_amp, q2_amp;
            sample({2'b00, 8'd80,  22'b0}, q1_amp); // Q1: lut_index = 80
            sample({2'b01, 8'd175, 22'b0}, q2_amp); // Q2: ~175 = 80, reads LUT[80]
            check($signed(q2_amp), $signed(q1_amp), 24'sd2, "T5 Q1/Q2 symmetry index 80");
        end

        // ── T6: Q3 is negation of Q1 ──────────────────────────
        begin
            logic [23:0] q1_amp, q3_amp;
            sample({2'b00, 8'd40, 22'b0}, q1_amp);
            sample({2'b10, 8'd40, 22'b0}, q3_amp);
            check($signed(q3_amp), -$signed(q1_amp), 24'sd2, "T6 Q3 = -Q1 index 40");
        end

        // ── T7: Full cycle CSV dump ───────────────────────────
        // 1024 evenly-spaced phase values across 32-bit phase space.
        // Open sine_wave.csv, write header, then one row per sample.
        csv_fd = $fopen("sim_out/sine_wave.csv", "w");
        $fdisplay(csv_fd, "phase_index,amplitude");

        for (i = 0; i < 1024; i++) begin
            sample(32'(i * (65536 * 64)), amp); // evenly spaces 1024 steps across 2^32
            $fdisplay(csv_fd, "%0d,%0d", i, $signed(amp));
        end

        $fclose(csv_fd);
        $display("T7 CSV written to sim_out/sine_wave.csv");

        $display("\n=== All tests complete ===");
        $finish;
    end

    // ── Timeout watchdog ──────────────────────────────────────
    initial begin
        #100_000_000;
        $display("TIMEOUT — simulation limit reached");
        $finish;
    end

endmodule
