`timescale 1ns / 1ps

module tb_sweep_generator;

    localparam CLK_SYS_PERIOD  = 20;           // 50 MHz
    localparam CLK_PERIOD      = 81;           // ~12.288 MHz (81.38 ns period)
    localparam N_SAMPLES       = 240_000; // 5 s × 48 kHz

    logic        clock, clk_sys;
    logic        reset;
    logic [23:0] amplitude;
    logic        we_lut;
    logic  [7:0] addr_lut;
    logic [23:0] din_lut;

    // Hierarchical reference to internal sample_en for capture gating
    logic sample_en;
    assign sample_en = dut.sample_en;

    sweep_generator dut (
        .clock    (clock),
        .reset    (reset),
        .amplitude(amplitude),
        .clk_sys  (clk_sys),
        .we_lut   (we_lut),
        .addr_lut (addr_lut),
        .din_lut  (din_lut)
    );

    initial clk_sys = 0;
    always #(CLK_SYS_PERIOD  / 2) clk_sys = ~clk_sys;
    initial clock   = 0;
    always #(CLK_PERIOD      / 2) clock   = ~clock;

    task automatic write_lut(input [7:0] a, input [23:0] d);
        @(posedge clk_sys); #1;
        addr_lut = a; din_lut = d; we_lut = 1;
        @(posedge clk_sys); #1;
        we_lut = 0;
    endtask

    integer i;
    real    sv;
    integer fd;
    localparam real MAX_AMP = 8388607.0;
    localparam real PI      = 3.14159265358979;

    initial begin
        reset = 1; we_lut = 0; addr_lut = 0; din_lut = 0;

        for (i = 0; i < 256; i++) begin
            sv = $sin(i * PI / 512.0) * MAX_AMP;
            write_lut(i[7:0], $rtoi(sv));
        end
        repeat (4) @(posedge clk_sys);

        @(posedge clock); #1;
        reset = 0;
        repeat (2) @(posedge clock);

        // ── T_DIV: clock divider rate ─────────────────────────
        // Verify sample_en fires exactly every 256 clock cycles.
        begin
            integer div_count;

            // Wait for a sample_en pulse to use as start reference
            @(posedge clock);
            while (!sample_en) @(posedge clock);

            // Count clock edges until the next sample_en pulse
            div_count = 0;
            @(posedge clock);
            while (!sample_en) begin
                div_count++;
                @(posedge clock);
            end
            div_count++; // include the edge where sample_en fires

            if (div_count == 256)
                $display("PASS [T_DIV] sample_en period = %0d clock cycles", div_count);
            else
                $display("FAIL [T_DIV] expected 256, got %0d", div_count);
        end

        fd = $fopen("sim_out/sweep_amplitude.txt", "w");
        for (i = 0; i < N_SAMPLES; i++) begin
            @(posedge clock);
            while (!sample_en) @(posedge clock); // wait for 48 kHz sample tick
            #1;
            $fdisplay(fd, "%0d", $signed(amplitude));
        end
        $fclose(fd);

        $display("Wrote %0d samples to sim_out/sweep_amplitude.txt", N_SAMPLES);
        $finish;
    end

    initial begin
        #6_000_000_000; // 6 s — covers full 5 s sweep at 12.288 MHz
        $display("TIMEOUT");
        $finish;
    end

endmodule
