`timescale 1ns / 1ps

module tb_sine_lut;

    // ── Clock parameters ─────────────────────────────────────
    // clk_a: 20 ns  (50 MHz  — write port, exact target frequency)
    // clk_b: 200 ns (5 MHz   — scaled from 48 kHz for sim speed)
    // 10:1 ratio preserves "many writes between each read" relationship.
    localparam CLK_A_PERIOD = 20;
    localparam CLK_B_PERIOD = 200;

    // ── Signals ─────────────────────────────────────────────
    logic        clk_a, clk_b;
    logic        we_a;
    logic [7:0]  addr_a;
    logic [23:0] din_a;
    logic [7:0]  addr_b;
    logic [23:0] dout_b;

    // ── DUT ─────────────────────────────────────────────────
    sine_lut dut (
        .clk_a  (clk_a),
        .we_a   (we_a),
        .addr_a (addr_a),
        .din_a  (din_a),
        .clk_b  (clk_b),
        .addr_b (addr_b),
        .dout_b (dout_b)
    );

    // ── Independent clock generators ─────────────────────────
    initial clk_a = 0;
    always #(CLK_A_PERIOD / 2) clk_a = ~clk_a; // Simulates Clock Flip (low for 10 ns, high for 10 ns)
                                               // 50 MHz
    initial clk_b = 0;
    always #(CLK_B_PERIOD / 2) clk_b = ~clk_b; // Simulates Clock Flip (low for 100 ns, high for 100 ns)
                                               // 5 MHz
    // ── Helper: write one word via Port A ────────────────────
    // Signals are set after a posedge so they are stable going into the next edge.
    task automatic write_a(input [7:0] a, input [23:0] d);
        @(posedge clk_a); #1;
        addr_a = a;
        din_a  = d;
        we_a   = 1;
        @(posedge clk_a); #1;  // write latches on this edge
        we_a   = 0;
    endtask

    // ── Helper: read one word via Port B ─────────────────────
    // Presents addr_b then waits exactly 1 clk_b cycle for registered output.
    task automatic read_b(input [7:0] a, output [23:0] d);
        @(posedge clk_b); #1;
        addr_b = a;
        @(posedge clk_b); #1;  // dout_b valid after this edge (1-cycle latency)
        d = dout_b;
    endtask

    // ── Helper: pass/fail check ───────────────────────────────
    task automatic check(
        input [23:0] got,
        input [23:0] expected,
        input string label
    );
        if (got !== expected)
            $display("FAIL [%s]  got=0x%06h  expected=0x%06h", label, got, expected);
        else
            $display("PASS [%s]  dout_b=0x%06h", label, got);
    endtask

    // ── Test variables ───────────────────────────────────────
    integer      i;
    logic [23:0] rdata;

    initial begin
        we_a   = 0;
        addr_a = 0;
        din_a  = 0;
        addr_b = 0;

        repeat (4) @(posedge clk_a); // let clocks settle

        // ── T1: Basic write -> read roundtrip ─────────────────
        write_a(8'd42, 24'hABCDEF);
        repeat (4) @(posedge clk_a);   // settle across clock domains
        read_b(8'd42, rdata);
        check(rdata, 24'hABCDEF, "T1 basic write->read");

        // ── T2: Read latency is exactly 1 clk_b cycle ─────────
        write_a(8'd10, 24'h123456);
        repeat (4) @(posedge clk_a);

        @(posedge clk_b); #1;
        addr_b = 8'd10;                // present address on cycle N
        @(posedge clk_b); #1;         // dout_b registers on cycle N+1
        check(dout_b, 24'h123456, "T2 latency exactly 1 clk_b cycle");

        // ── T3: Write enable gating ───────────────────────────
        // Confirm we_a = 0 does not modify memory.
        write_a(8'd7, 24'hCAFE00);
        repeat (4) @(posedge clk_a);

        @(posedge clk_a); #1;          // attempt write with we_a = 0
        addr_a = 8'd7;
        din_a  = 24'hDEAD00;
        we_a   = 0;
        @(posedge clk_a); #1;

        repeat (4) @(posedge clk_a);
        read_b(8'd7, rdata);
        check(rdata, 24'hCAFE00, "T3 we_a=0 does not overwrite");

        // ── T4: All 256 addresses independent ─────────────────
        // Write address value to each location, then verify every entry.
        for (i = 0; i < 256; i++)
            write_a(i[7:0], {16'b0, i[7:0]});
        repeat (8) @(posedge clk_a);

        for (i = 0; i < 256; i++) begin
            read_b(i[7:0], rdata);
            check(rdata, {16'b0, i[7:0]}, $sformatf("T4 addr=%0d", i));
        end

        // ── T5: Adjacent address independence ─────────────────
        write_a(8'd20, 24'hAAAA00);
        write_a(8'd21, 24'hBBBB00);
        write_a(8'd19, 24'hCCCC00);
        repeat (4) @(posedge clk_a);

        read_b(8'd20, rdata); check(rdata, 24'hAAAA00, "T5 addr 20 isolated");
        read_b(8'd21, rdata); check(rdata, 24'hBBBB00, "T5 addr 21 isolated");
        read_b(8'd19, rdata); check(rdata, 24'hCCCC00, "T5 addr 19 isolated");

        // ── T6: Burst writes on clk_a, then burst reads on clk_b
        // Simulates the real use case: many write cycles per read cycle.
        for (i = 0; i < 10; i++)
            write_a(i[7:0], 24'hF00000 | i[7:0]); // Uses Bitwise OR to create unique data pattern.
        repeat (4) @(posedge clk_a);

        for (i = 0; i < 10; i++) begin
            read_b(i[7:0], rdata);
            check(rdata, 24'hF00000 | i[7:0], $sformatf("T6 burst addr=%0d", i));
        end

        // ── T7: Reading uninitialized memory ──────────────────
        // Address 255 was set to 255 in T4. Displaying it to confirm
        // behaviour — on real hardware, unwritten BRAM is undefined at power-up.
        read_b(8'd255, rdata);
        $display("T7 addr 255 (T4 wrote 0x0000FF): dout_b=0x%06h", rdata);

        $display("\n=== All tests complete ===");
        $finish;
    end

    // ── Timeout watchdog ─────────────────────────────────────
    initial begin
        #5_000_000;
        $display("TIMEOUT — simulation limit reached");
        $finish;
    end

endmodule
