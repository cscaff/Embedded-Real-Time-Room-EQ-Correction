// ==================== MODULE INTERFACE ====================
// Parallel-to-serial shift register for I2S data transmission.
// Loads a 24-bit sample and shifts it out MSB-first, one bit
// per shift pulse.  After 24 shifts, zeros pad the output
// (the I2S don't-care bits).
//
// Inputs:
//   clock      – 12.288 MHz master clock
//   reset      – active-high synchronous reset
//   data_in    – 24-bit parallel data to load
//   load       – 1-cycle pulse: loads data_in into shift register
//   shift      – 1-cycle pulse: shifts register left by 1 bit
//
// Outputs:
//   serial_out – MSB of the shift register (combinational)
//
// Load has priority over shift.  If neither is asserted, the
// output holds its current value.
// ===========================================================

module i2s_shift_register (
    input  logic        clock,
    input  logic        reset,
    input  logic [23:0] data_in,
    input  logic        load,
    input  logic        shift,
    output logic        serial_out
);

    logic [23:0] shift_reg = 24'd0;

    // Output is always the MSB of the shift register.
    assign serial_out = shift_reg[23];

    always_ff @(posedge clock) begin
        if (reset)
            shift_reg <= 24'd0;
        else if (load)
            shift_reg <= data_in;
        else if (shift)
            shift_reg <= {shift_reg[22:0], 1'b0};
    end

endmodule
