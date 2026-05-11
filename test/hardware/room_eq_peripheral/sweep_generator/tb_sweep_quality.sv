`timescale 1ns / 1ps
module tb_sweep_quality;

    localparam CLK_PERIOD = 81;  // ~12.288 MHz

    logic        clock;
    logic        reset;
    logic [23:0] amplitude;
    logic        clk_sys;
    logic        we_lut;
    logic [9:0]  addr_lut;
    logic [23:0] din_lut;
    logic        start;
    logic        done;

    // Generate bclk/lrck same way as i2s_clock_gen
    logic [1:0] bclk_cnt;
    logic [5:0] bit_cnt;
    wire bclk_fall = (bclk_cnt == 2'd3);
    wire lrck = bit_cnt[5];

    always_ff @(posedge clock) begin
        if (reset) begin
            bclk_cnt <= 0;
            bit_cnt <= 0;
        end else begin
            bclk_cnt <= bclk_cnt + 1;
            if (bclk_fall)
                bit_cnt <= bit_cnt + 1;
        end
    end

    sweep_generator dut (
        .clock(clock), .reset(reset), .amplitude(amplitude),
        .clk_sys(clk_sys), .we_lut(we_lut), .addr_lut(addr_lut),
        .din_lut(din_lut), .start(start), .done(done), .lrck(lrck)
    );

    initial clock = 0;
    always #(CLK_PERIOD/2) clock = ~clock;
    initial clk_sys = 0;
    always #10 clk_sys = ~clk_sys;

    integer fd, sample_count;

    initial begin
        reset = 1; start = 0; we_lut = 0; addr_lut = 0; din_lut = 0;
        repeat (20) @(posedge clock);
        reset = 0;
        repeat (10) @(posedge clock);

        // Load sine LUT
        for (int i = 0; i < 1024; i++) begin
            @(posedge clk_sys);
            addr_lut = i;
            din_lut = $rtoi($sin(i * 3.14159265 / 2048.0) * 8388607.0);
            we_lut = 1;
            @(posedge clk_sys);
            we_lut = 0;
        end

        repeat (20) @(posedge clock);

        // Debug: check lrck is toggling
        $display("Before start: lrck=%b, lrck_d=%b, sweep_active=%b, done=%b",
                 lrck, dut.lrck_d, dut.sweep_active, done);

        start = 1;
        @(posedge clock);
        start = 0;

        // Wait a few frames
        repeat (2000) @(posedge clock);
        $display("After start: lrck=%b, lrck_d=%b, sweep_active=%b, sample_en=%b, done=%b, amplitude=%0d",
                 lrck, dut.lrck_d, dut.sweep_active, dut.sample_en, done, $signed(amplitude));

        // Wait for a lrck falling edge
        @(posedge lrck);
        @(negedge lrck);
        repeat (10) @(posedge clock);
        $display("After lrck fall: sample_en=%b, amplitude=%0d, increment=%0d",
                 dut.sample_en, $signed(amplitude), dut.mac.increment[63:32]);

        // Dump a few thousand samples
        fd = $fopen("sweep_quality.csv", "w");
        $fwrite(fd, "sample,amplitude,increment\n");
        sample_count = 0;

        while (!done && sample_count < 10000) begin
            @(negedge lrck);
            repeat (10) @(posedge clock);
            $fwrite(fd, "%0d,%0d,%0d\n", sample_count,
                    $signed(amplitude),
                    dut.mac.increment[63:32]);
            sample_count++;
        end

        $fclose(fd);
        $display("Dumped %0d samples, done=%b", sample_count, done);
        $finish;
    end

    initial begin
        #10_000_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
