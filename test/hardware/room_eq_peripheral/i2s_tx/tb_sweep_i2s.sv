// Integration testbench: sweep_generator → i2s_tx → deserialize → file.
// Wires the sweep generator's amplitude output through I2S serialization,
// reconstructs left-channel samples from dacdat, and writes them to a
// text file for Python post-processing (plot + WAV).

`timescale 1ns / 1ps

module tb_sweep_i2s;

    // ── Parameters ──────────────────────────────────────────
    `ifndef N_SAMPLES
        `define N_SAMPLES 10000
    `endif

    localparam CLK_SYS_PERIOD = 20;   // 50 MHz
    localparam CLK_PERIOD     = 81;   // ~12.288 MHz
    localparam integer N_SAMPLES = `N_SAMPLES;

    // ── Signals ─────────────────────────────────────────────
    logic        clock, clk_sys;
    logic        reset;

    // Sweep generator interface
    logic [23:0] amplitude;
    logic        we_lut;
    logic  [7:0] addr_lut;
    logic [23:0] din_lut;

    // I2S outputs
    logic        bclk, lrck, dacdat;

    // ── Sweep generator ─────────────────────────────────────
    sweep_generator sweep_inst (
        .clock    (clock),
        .reset    (reset),
        .amplitude(amplitude),
        .clk_sys  (clk_sys),
        .we_lut   (we_lut),
        .addr_lut (addr_lut),
        .din_lut  (din_lut)
    );

    // ── I2S transmitter ─────────────────────────────────────
    i2s_tx i2s_inst (
        .clock        (clock),
        .reset        (reset),
        .left_sample  (amplitude),
        .right_sample (amplitude),
        .bclk         (bclk),
        .lrck         (lrck),
        .dacdat       (dacdat)
    );

    // ── Clocks ──────────────────────────────────────────────
    initial clk_sys = 0;
    always #(CLK_SYS_PERIOD / 2) clk_sys = ~clk_sys;
    initial clock = 0;
    always #(CLK_PERIOD / 2) clock = ~clock;

    // ── LUT initialization (same as tb_sweep_generator) ─────
    task automatic write_lut(input [7:0] a, input [23:0] d);
        @(posedge clk_sys); #1;
        addr_lut = a; din_lut = d; we_lut = 1;
        @(posedge clk_sys); #1;
        we_lut = 0;
    endtask

    localparam real MAX_AMP = 8388607.0;
    localparam real PI      = 3.14159265358979;

    // ── Capture one left-channel sample from dacdat ─────────
    // Waits for LRCK to go low (left channel start), skips the
    // I2S delay slot, then captures 24 bits on BCLK rising edges.
    task automatic capture_left(output [23:0] sample);
        integer i;
        // Wait for LRCK falling edge (start of left channel)
        @(negedge lrck);
        // Skip delay slot: one BCLK rising edge
        @(posedge bclk);
        // Capture 24 data bits MSB-first
        for (i = 23; i >= 0; i--) begin
            @(posedge bclk);
            sample[i] = dacdat;
        end
    endtask

    // ── Main test sequence ──────────────────────────────────
    integer i;
    real    sv;
    integer fd;
    integer sample_count;
    logic [23:0] captured;

    initial begin
        reset = 1; we_lut = 0; addr_lut = 0; din_lut = 0;

        // Initialize sine LUT (quarter-wave, 256 entries)
        for (i = 0; i < 256; i++) begin
            sv = $sin(i * PI / 512.0) * MAX_AMP;
            write_lut(i[7:0], $rtoi(sv));
        end
        repeat (4) @(posedge clk_sys);

        // Release reset
        @(posedge clock); #1;
        reset = 0;

        $display("Starting sweep -> I2S integration test (%0d samples)...", N_SAMPLES);

        // Open output file
        fd = $fopen("sim_out/i2s_sweep_samples.txt", "w");

        // Capture N_SAMPLES left-channel samples
        for (sample_count = 0; sample_count < N_SAMPLES; sample_count++) begin
            capture_left(captured);
            $fdisplay(fd, "%0d", $signed(captured));
            if ((sample_count + 1) % 1000 == 0)
                $display("  %0d / %0d samples captured...",
                         sample_count + 1, N_SAMPLES);
        end

        $fclose(fd);
        $display("Wrote %0d samples to sim_out/i2s_sweep_samples.txt", N_SAMPLES);
        $finish;
    end

    // ── Timeout watchdog ────────────────────────────────────
    initial begin
        #10_000_000_000_000; // 10 seconds of sim time — covers full 5s sweep
        $display("TIMEOUT — simulation limit reached");
        $finish;
    end

endmodule
