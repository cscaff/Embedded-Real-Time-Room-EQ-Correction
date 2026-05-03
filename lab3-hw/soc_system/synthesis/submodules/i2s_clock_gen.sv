// ==================== MODULE INTERFACE ====================
// Derives I2S bit clock (BCLK) and frame clock (LRCK) from the
// 12.288 MHz master clock.  Both outputs are data signals toggled
// by always_ff blocks — NOT separate clock nets — so the entire
// design stays in a single clock domain.
//
// Inputs:
//   clock     – 12.288 MHz master clock (from PLL)
//   reset     – active-high synchronous reset
//
// Outputs:
//   bclk      – 3.072 MHz bit clock  (12.288 MHz / 4)
//               Physical wire to codec AUD_BCLK.
//   lrck      – 48 kHz frame clock   (BCLK / 64)
//               Physical wire to codec AUD_DACLRCK.
//               Low = left channel, high = right channel.
//   bclk_fall – 1-cycle internal strobe, high when bclk is about
//               to fall. Used by i2s_tx to time data shifts.
//   bit_cnt   – 6-bit position within the 64-bit I2S frame (0-63).
//               Internal signal used by i2s_tx for protocol control.
// ===========================================================

module i2s_clock_gen (
    input  logic        clock,
    input  logic        reset,
    output logic        bclk,
    output logic        lrck,
    output logic        bclk_fall,
    output logic [5:0]  bit_cnt
);

    logic [1:0] bclk_cnt = 2'd0;

    // BCLK: high when bclk_cnt[1] == 1 (counts 2, 3)
    assign bclk = bclk_cnt[1];

    // bclk_fall: asserted for 1 master-clock cycle when bclk_cnt == 3.
    // On the NEXT posedge, bclk_cnt wraps to 0 and bclk goes low.
    assign bclk_fall = (bclk_cnt == 2'd3);

    // LRCK: low for bit_cnt 0-31 (left channel),
    //        high for bit_cnt 32-63 (right channel).
    assign lrck = bit_cnt[5];

    always_ff @(posedge clock) begin
        if (reset) begin
            bclk_cnt <= 2'd0;
            bit_cnt  <= 6'd0;
        end else begin
            bclk_cnt <= bclk_cnt + 2'd1;
            if (bclk_fall)
                bit_cnt <= bit_cnt + 6'd1; // wraps 63 -> 0 naturally
        end
    end

endmodule
