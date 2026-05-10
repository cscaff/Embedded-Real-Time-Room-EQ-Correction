// ==================== MODULE INTERFACE ====================
// I2S receiver.  Deserializes stereo 24-bit audio from the
// WM8731 codec (Philips I2S format: 1-bit delay, MSB-first,
// 24 data + 8 don't-care bits per channel).
//
// Shares BCLK and LRCK with the I2S transmitter; both are
// data signals in the 12.288 MHz clock domain, NOT clock nets.
// adcdat is sampled on the rising edge of BCLK.
//
// Inputs:
//   clock        – 12.288 MHz master clock
//   reset        – active-high synchronous reset
//   bclk         – 3.072 MHz bit clock  (from i2s_tx)
//   lrck         – 48 kHz frame clock   (from i2s_tx)
//   adcdat       – serial ADC data from codec (AUD_ADCDAT)
//
// Outputs:
//   left_sample  – 24-bit left  channel, updated each frame
//   right_sample – 24-bit right channel, updated each frame
// ===========================================================

module i2s_rx (
    input  logic        clock,
    input  logic        reset,
    input  logic        bclk,
    input  logic        lrck,
    input  logic        adcdat,
    output logic [23:0] left_sample,
    output logic [23:0] right_sample
);

    // ── Edge detection ──────────────────────────────────────
    logic bclk_d;
    always_ff @(posedge clock) begin
        if (reset) bclk_d <= 1'b0;
        else       bclk_d <= bclk;
    end

    wire bclk_rise = bclk  && !bclk_d;
    wire bclk_fall = !bclk && bclk_d;

    // ── Frame bit counter ───────────────────────────────────
    // Mirrors the TX clock_gen bit_cnt: increments on each
    // BCLK falling edge, wraps 63 → 0.
    logic [5:0] bit_cnt;
    always_ff @(posedge clock) begin
        if (reset)          bit_cnt <= 6'd0;
        else if (bclk_fall) bit_cnt <= bit_cnt + 6'd1;
    end

    // ── Capture and latch ───────────────────────────────────
    // Philips I2S 1-bit delay: MSB of left appears 1 BCLK
    // after LRCK falls, so the left data window is
    // bit_cnt 1–24 (24 bits, MSB first).  Right is 33–56.
    //
    // On each bclk_rise in the window, shift adcdat into the
    // LSB of the accumulator.  Latch the parallel result into
    // the output register on the last bit of each window.
    logic [23:0] left_shift, right_shift;

    always_ff @(posedge clock) begin
        if (reset) begin
            left_shift   <= 24'd0;
            right_shift  <= 24'd0;
            left_sample  <= 24'd0;
            right_sample <= 24'd0;
        end else if (bclk_rise) begin
            // Left channel: bit_cnt 1 (MSB) … 24 (LSB)
            if (bit_cnt >= 6'd1 && bit_cnt <= 6'd24) begin
                left_shift <= {left_shift[22:0], adcdat};
                if (bit_cnt == 6'd24)
                    left_sample <= {left_shift[22:0], adcdat};
            end
            // Right channel: bit_cnt 33 (MSB) … 56 (LSB)
            if (bit_cnt >= 6'd33 && bit_cnt <= 6'd56) begin
                right_shift <= {right_shift[22:0], adcdat};
                if (bit_cnt == 6'd56)
                    right_sample <= {right_shift[22:0], adcdat};
            end
        end
    end

endmodule
