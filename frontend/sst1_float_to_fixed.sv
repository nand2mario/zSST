// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module sst1_float_to_fixed (
    input  logic [31:0] ieee754,
    input  logic [5:0]  fraction_bits,
    input  logic [5:0]  result_width,
    output logic [31:0] fixed,
    output logic [63:0] extended_fixed,
    output logic        overflow,
    output logic        invalid
);
    logic sign;
    logic [7:0] exponent;
    logic [22:0] fraction;
    logic [23:0] mantissa;
    logic [63:0] magnitude;
    logic signed [64:0] value;
    logic signed [64:0] maximum;
    logic signed [64:0] minimum;
    integer shift;

    always_comb begin
        sign = ieee754[31];
        exponent = ieee754[30:23];
        fraction = ieee754[22:0];
        mantissa = {1'b1, fraction};
        magnitude = 64'd0;
        value = 65'sd0;
        maximum = 65'sd0;
        minimum = 65'sd0;
        fixed = 32'd0;
        extended_fixed = 64'd0;
        overflow = 1'b0;
        invalid = 1'b0;
        shift = 0;

        if (exponent == 0) begin
            // Zero and IEEE subnormals are below every SST parameter LSB.
            fixed = 32'd0;
        end else begin
            if (exponent == 8'hff) begin
                invalid = fraction != 0;
                overflow = 1'b1;
                value = sign ? -65'sh100000000 : 65'sh0ffffffff;
            end else begin
                shift = int'(exponent) - 150 + int'(fraction_bits);
                if (shift >= 40) begin
                    overflow = 1'b1;
                    value = sign ? -65'sh100000000 : 65'sh0ffffffff;
                end else begin
                    if (shift >= 0)
                        magnitude = {40'd0, mantissa} << shift;
                    else if (shift > -64)
                        magnitude = {40'd0, mantissa} >> -shift;
                    if (sign)
                        value = -$signed({1'b0, magnitude});
                    else
                        value = $signed({1'b0, magnitude});
                end
            end

            // SST-1 register fields retain the low fixed-point bits rather
            // than saturating to the field's signed range.  Original Glide
            // relies on this for SNAP_BIAS: 786743.4375 converts to
            // 0x00c01377 and the 12.4 vertex register retains 0x1377.
            // Report discarded significant bits for diagnostics, but leave
            // canonical field masking/sign extension to the register file.
            if (result_width >= 2 && result_width < 32) begin
                maximum = (65'sd1 <<< (result_width - 1)) - 1'b1;
                minimum = -(65'sd1 <<< (result_width - 1));
                if (value > maximum || value < minimum)
                    overflow = 1'b1;
            end
            fixed = value[31:0];
            extended_fixed = value[63:0];
        end
    end

endmodule
