// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Four-stage, initiation-interval-one TREX perspective/LOD front end.
// sst1_tmu_front remains the compact combinational arithmetic oracle; this
// implementation places registers around square/normalize, reciprocal/log,
// perspective multiply, and final shift/clamp boundaries.
module sst1_tmu_front_staged (
    input  logic               clk,
    input  logic               reset_n,
    input  logic               start,
    input  logic [9:0]         pixel_x,
    input  logic [9:0]         pixel_y,
    input  logic signed [63:0] s_over_w,
    input  logic signed [63:0] t_over_w,
    input  logic signed [63:0] one_over_w,
    input  logic signed [31:0] dsdx,
    input  logic signed [31:0] dtdx,
    input  logic signed [31:0] dsdy,
    input  logic signed [31:0] dtdy,
    input  logic [31:0]        texture_mode,
    input  logic [31:0]        tlod,
    output logic               busy,
    output logic               done,
    output logic signed [17:0] tex_s,
    output logic signed [17:0] tex_t,
    output logic [11:0]        lod,
    output logic [3:0]         lod_level,
    output logic               magnification,
    output logic               clamp_to_zero
);
    import sst1_tmu_tables_pkg::*;

    logic [3:0] valid_pipe;

    logic signed [63:0] p0_s, p0_t;
    logic [31:0] p0_mode, p0_tlod;
    logic [1:0] p0_lod_dither;
    logic p0_q_negative, p0_q_zero;
    logic [6:0] p0_q_msb;
    logic [7:0] p0_recip_index, p0_recip_fraction;
    logic signed [63:0] p0_dsdx_square, p0_dtdx_square;
    logic signed [63:0] p0_dsdy_square, p0_dtdy_square;

    logic signed [63:0] p1_s, p1_t;
    logic [31:0] p1_mode, p1_tlod;
    logic [1:0] p1_lod_dither;
    logic p1_q_negative, p1_q_zero;
    logic [6:0] p1_q_msb;
    logic [16:0] p1_reciprocal;
    logic signed [15:0] p1_base_lod, p1_perspective_lod;

    logic [31:0] p2_mode, p2_tlod;
    logic [1:0] p2_lod_dither;
    logic p2_q_negative, p2_q_zero;
    logic [6:0] p2_q_msb;
    logic signed [80:0] p2_product_s, p2_product_t;
    logic signed [63:0] p2_linear_s, p2_linear_t;
    logic signed [15:0] p2_base_lod, p2_perspective_lod;

    logic [63:0] input_abs_q, input_normalized_q;
    logic [6:0] input_q_msb;
    logic [16:0] p0_recip_base, p0_recip_next;
    logic [24:0] p0_recip_correction;
    logic [63:0] p0_grad_x, p0_grad_y, p0_grad_max, p0_normalized_grad;
    logic [6:0] p0_grad_msb;
    logic [7:0] p0_grad_fraction;
    logic signed [80:0] p2_rounded_s, p2_rounded_t;
    logic signed [15:0] p2_biased_lod, p2_dithered_lod;
    logic signed [15:0] p2_lod_min, p2_lod_max;
    logic signed [15:0] p2_clamped_lod;
    logic signed [5:0] p2_lod_bias;
    integer bit_index;

    always_comb begin
        input_abs_q = one_over_w[63] ? $unsigned(-one_over_w) :
                                             $unsigned(one_over_w);
        input_q_msb = 7'd0;
        for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1)
            if (input_abs_q[bit_index])
                input_q_msb = bit_index[6:0];
        input_normalized_q = input_abs_q << (63 - input_q_msb);

        p0_recip_base = sst1_reciprocal_entry({1'b0, p0_recip_index});
        p0_recip_next = sst1_reciprocal_entry({1'b0, p0_recip_index} + 9'd1);
        p0_recip_correction = (25'(p0_recip_base) - 25'(p0_recip_next)) *
                              p0_recip_fraction;
        p0_grad_x = $unsigned(p0_dsdx_square + p0_dtdx_square);
        p0_grad_y = $unsigned(p0_dsdy_square + p0_dtdy_square);
        p0_grad_max = p0_grad_x > p0_grad_y ? p0_grad_x : p0_grad_y;
        p0_grad_msb = 7'd0;
        for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1)
            if (p0_grad_max[bit_index])
                p0_grad_msb = bit_index[6:0];
        p0_normalized_grad = p0_grad_max << (63 - p0_grad_msb);
        p0_grad_fraction = p0_normalized_grad[62:55];

        p2_rounded_s = p2_product_s;
        p2_rounded_t = p2_product_t;
        if (p2_q_msb != 0) begin
            p2_rounded_s = p2_product_s + (81'sd1 <<< (p2_q_msb - 1'b1));
            p2_rounded_t = p2_product_t + (81'sd1 <<< (p2_q_msb - 1'b1));
        end
        p2_lod_bias = p2_tlod[17:12];
        p2_biased_lod = p2_base_lod + p2_perspective_lod +
                        (16'($signed(p2_lod_bias)) <<< 6);
        p2_dithered_lod = p2_biased_lod;
        if (p2_mode[4])
            p2_dithered_lod = p2_biased_lod +
                              $signed({8'd0, p2_lod_dither, 6'd0});
        p2_lod_min = $signed({4'd0, p2_tlod[5:0], 6'd0});
        p2_lod_max = $signed({4'd0, p2_tlod[11:6], 6'd0});
        if (p2_lod_max > 16'sh0800)
            p2_lod_max = 16'sh0800;
        if (p2_dithered_lod < p2_lod_min)
            p2_clamped_lod = p2_lod_min;
        else if (p2_dithered_lod > p2_lod_max)
            p2_clamped_lod = p2_lod_max;
        else
            p2_clamped_lod = p2_dithered_lod;
    end

    assign busy = |valid_pipe;
    assign done = valid_pipe[3];

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            valid_pipe <= '0;
            tex_s <= '0;
            tex_t <= '0;
            lod <= '0;
            lod_level <= '0;
            magnification <= 1'b0;
            clamp_to_zero <= 1'b0;
        end else begin
            valid_pipe <= {valid_pipe[2:0], start};

            if (start) begin
                p0_s <= s_over_w;
                p0_t <= t_over_w;
                p0_mode <= texture_mode;
                p0_tlod <= tlod;
                p0_lod_dither <= {pixel_x[0] ^ pixel_y[0], pixel_y[0]};
                p0_q_negative <= one_over_w[63];
                p0_q_zero <= one_over_w == 0;
                p0_q_msb <= input_q_msb;
                p0_recip_index <= input_normalized_q[62:55];
                p0_recip_fraction <= input_normalized_q[54:47];
                p0_dsdx_square <= dsdx * dsdx;
                p0_dtdx_square <= dtdx * dtdx;
                p0_dsdy_square <= dsdy * dsdy;
                p0_dtdy_square <= dtdy * dtdy;
            end

            if (valid_pipe[0]) begin
                p1_s <= p0_s;
                p1_t <= p0_t;
                p1_mode <= p0_mode;
                p1_tlod <= p0_tlod;
                p1_lod_dither <= p0_lod_dither;
                p1_q_negative <= p0_q_negative;
                p1_q_zero <= p0_q_zero;
                p1_q_msb <= p0_q_msb;
                p1_reciprocal <= p0_recip_base - p0_recip_correction[24:8];
                if (p0_grad_max == 0)
                    p1_base_lod <= 16'sd0;
                else
                    p1_base_lod <= ($signed({1'b0, p0_grad_msb, 8'd0}) +
                        $signed({8'd0, sst1_log_fraction(p0_grad_fraction)}) -
                        16'sd9216) >>> 2;
                if (!p0_mode[0] || p0_q_negative || p0_q_zero)
                    p1_perspective_lod <= 16'sd0;
                else
                    p1_perspective_lod <= $signed({1'b0, 7'd29, 8'd0}) -
                        $signed({1'b0, p0_q_msb, 8'd0}) -
                        $signed({8'd0, sst1_log_fraction(p0_recip_index)});
            end

            if (valid_pipe[1]) begin
                p2_mode <= p1_mode;
                p2_tlod <= p1_tlod;
                p2_lod_dither <= p1_lod_dither;
                p2_q_negative <= p1_q_negative;
                p2_q_zero <= p1_q_zero;
                p2_q_msb <= p1_q_msb;
                p2_product_s <= p1_s * $signed({1'b0, p1_reciprocal});
                p2_product_t <= p1_t * $signed({1'b0, p1_reciprocal});
                p2_linear_s <= p1_s;
                p2_linear_t <= p1_t;
                p2_base_lod <= p1_base_lod;
                p2_perspective_lod <= p1_perspective_lod;
            end

            if (valid_pipe[2]) begin
                clamp_to_zero <= p2_mode[3] && p2_q_negative;
                if (p2_mode[3] && p2_q_negative) begin
                    tex_s <= 18'sd0;
                    tex_t <= 18'sd0;
                end else if (!p2_mode[0]) begin
                    tex_s <= p2_linear_s >>> 14;
                    tex_t <= p2_linear_t >>> 14;
                end else if (p2_q_zero) begin
                    tex_s <= 18'sd0;
                    tex_t <= 18'sd0;
                end else begin
                    tex_s <= p2_rounded_s >>> p2_q_msb;
                    tex_t <= p2_rounded_t >>> p2_q_msb;
                end
                magnification <= p2_biased_lod < p2_lod_min;
                lod <= p2_tlod[23] ? {p2_clamped_lod[11:8], 8'd0} :
                                    p2_clamped_lod[11:0];
                lod_level <= p2_clamped_lod[11:8] > 4'd8 ? 4'd8 :
                                                                 p2_clamped_lod[11:8];
            end
        end
    end
endmodule
