// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// SST-1 TREX texture color/alpha combine unit.  The arithmetic follows the
// documented (other-local)*factor+local structure: the 8x9 multiply truncates
// its low eight bits, then the result is clamped and optionally inverted.
module sst1_texture_combine (
    input  logic [23:0] local_rgb,
    input  logic [7:0]  local_alpha,
    input  logic [23:0] other_rgb,
    input  logic [7:0]  other_alpha,
    input  logic [11:0] lod,
    input  logic [31:0] texture_mode,
    input  logic [31:0] tdetail,
    output logic [23:0] result_rgb,
    output logic [7:0]  result_alpha
);
    logic [7:0] color_factor [0:2];
    logic [7:0] alpha_factor;
    logic [7:0] detail_factor;
    logic color_reverse, alpha_reverse;
    logic signed [10:0] color_value [0:2];
    logic signed [10:0] alpha_value;
    logic signed [19:0] color_product [0:2];
    logic signed [19:0] alpha_product;
    logic signed [12:0] detail_delta;
    logic signed [12:0] detail_bias_ext, lod_integer_ext;
    logic [8:0] color_multiplier [0:2];
    logic [8:0] alpha_multiplier;
    logic signed [19:0] combined_value;
    integer channel;

    function automatic logic [7:0] clamp_u8(input logic signed [19:0] value);
        if (value < 0)
            return 8'd0;
        if (value > 255)
            return 8'd255;
        return value[7:0];
    endfunction

    always_comb begin
        // tDetail uses an integer signed bias while LOD is carried as 4.8.
        detail_bias_ext = {{7{tdetail[13]}}, tdetail[13:8]};
        lod_integer_ext = $signed({9'd0, lod[11:8]});
        detail_delta = (detail_bias_ext - lod_integer_ext) <<<
                       tdetail[16:14];
        if (detail_delta < 0)
            detail_factor = 8'd0;
        else if (detail_delta > $signed({5'd0, tdetail[7:0]}))
            detail_factor = tdetail[7:0];
        else
            detail_factor = detail_delta[7:0];

        // Trilinear alternates the sense of the LOD-fraction blend on odd
        // levels.  This is the SST-1 one-TREX behavior used for split maps.
        if (texture_mode[30] && lod[8]) begin
            color_reverse = texture_mode[17];
            alpha_reverse = texture_mode[26];
        end else begin
            color_reverse = !texture_mode[17];
            alpha_reverse = !texture_mode[26];
        end

        for (channel = 0; channel < 3; channel = channel + 1) begin
            case (texture_mode[16:14])
                3'd1: color_factor[channel] = local_rgb[channel*8 +: 8];
                3'd2: color_factor[channel] = other_alpha;
                3'd3: color_factor[channel] = local_alpha;
                3'd4: color_factor[channel] = detail_factor;
                3'd5: color_factor[channel] = lod[7:0];
                default: color_factor[channel] = 8'd0;
            endcase

            color_value[channel] = texture_mode[12] ? 11'sd0 :
                $signed({3'd0, other_rgb[channel*8 +: 8]});
            if (texture_mode[13])
                color_value[channel] = color_value[channel] -
                    $signed({3'd0, local_rgb[channel*8 +: 8]});
            color_multiplier[channel] = color_reverse ?
                {1'b0, ~color_factor[channel]} + 9'd1 :
                {1'b0, color_factor[channel]} + 9'd1;
            color_product[channel] = color_value[channel] *
                $signed({1'b0, color_multiplier[channel]});
            combined_value = color_product[channel] >>> 8;
            if (texture_mode[18])
                combined_value = combined_value +
                    $signed({12'd0, local_rgb[channel*8 +: 8]});
            else if (texture_mode[19])
                combined_value = combined_value +
                    $signed({12'd0, local_alpha});
            result_rgb[channel*8 +: 8] =
                clamp_u8(combined_value);
            if (texture_mode[20])
                result_rgb[channel*8 +: 8] =
                    ~result_rgb[channel*8 +: 8];
        end

        case (texture_mode[25:23])
            3'd1: alpha_factor = local_alpha;
            3'd2: alpha_factor = other_alpha;
            3'd3: alpha_factor = local_alpha;
            3'd4: alpha_factor = detail_factor;
            3'd5: alpha_factor = lod[7:0];
            default: alpha_factor = 8'd0;
        endcase
        alpha_value = texture_mode[21] ? 11'sd0 :
            $signed({3'd0, other_alpha});
        if (texture_mode[22])
            alpha_value = alpha_value - $signed({3'd0, local_alpha});
        alpha_multiplier = alpha_reverse ?
            {1'b0, ~alpha_factor} + 9'd1 :
            {1'b0, alpha_factor} + 9'd1;
        alpha_product = alpha_value * $signed({1'b0, alpha_multiplier});
        combined_value = alpha_product >>> 8;
        if (texture_mode[27] || texture_mode[28])
            combined_value = combined_value + $signed({12'd0, local_alpha});
        result_alpha = clamp_u8(combined_value);
        if (texture_mode[29])
            result_alpha = ~result_alpha;
    end
endmodule
