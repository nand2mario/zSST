// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Expand one SST-1 texture-memory value into the internal 8-bit RGBA format.
// NCC and palette lookup occur before filtering, as on TREX.
module sst1_texel_decode (
    input  logic [15:0] raw_texel,
    input  logic [3:0]  format,
    input  logic [7:0]  ncc_y [0:15],
    input  logic [26:0] ncc_i [0:3],
    input  logic [26:0] ncc_q [0:3],
    input  logic [23:0] palette_rgb,
    output logic [23:0] rgb,
    output logic [7:0]  alpha
);
    logic [7:0] texel8;
    logic [7:0] yiq_y;
    logic signed [8:0] yiq_ir, yiq_ig, yiq_ib;
    logic signed [8:0] yiq_qr, yiq_qg, yiq_qb;
    logic signed [10:0] yiq_r, yiq_g, yiq_b;

    function automatic logic [7:0] clamp_u8(input logic signed [10:0] value);
        if (value < 0)
            return 8'd0;
        if (value > 255)
            return 8'd255;
        return value[7:0];
    endfunction

    always_comb begin
        texel8 = raw_texel[7:0];
        yiq_y = ncc_y[texel8[7:4]];
        yiq_ir = $signed(ncc_i[texel8[3:2]][26:18]);
        yiq_ig = $signed(ncc_i[texel8[3:2]][17:9]);
        yiq_ib = $signed(ncc_i[texel8[3:2]][8:0]);
        yiq_qr = $signed(ncc_q[texel8[1:0]][26:18]);
        yiq_qg = $signed(ncc_q[texel8[1:0]][17:9]);
        yiq_qb = $signed(ncc_q[texel8[1:0]][8:0]);
        yiq_r = $signed({3'b000, yiq_y}) +
                $signed({{2{yiq_ir[8]}}, yiq_ir}) +
                $signed({{2{yiq_qr[8]}}, yiq_qr});
        yiq_g = $signed({3'b000, yiq_y}) +
                $signed({{2{yiq_ig[8]}}, yiq_ig}) +
                $signed({{2{yiq_qg[8]}}, yiq_qg});
        yiq_b = $signed({3'b000, yiq_y}) +
                $signed({{2{yiq_ib[8]}}, yiq_ib}) +
                $signed({{2{yiq_qb[8]}}, yiq_qb});

        rgb = 24'd0;
        alpha = 8'hff;
        case (format)
            4'd0: rgb = {{texel8[7:5], texel8[7:5], texel8[7:6]},
                         {texel8[4:2], texel8[4:2], texel8[4:3]},
                         {4{texel8[1:0]}}};
            4'd1: rgb = {clamp_u8(yiq_r), clamp_u8(yiq_g), clamp_u8(yiq_b)};
            4'd2: begin
                rgb = {texel8, texel8, texel8};
                alpha = texel8;
            end
            4'd3: rgb = {texel8, texel8, texel8};
            4'd4: begin
                rgb = {6{texel8[3:0]}};
                alpha = {texel8[7:4], texel8[7:4]};
            end
            4'd5: rgb = palette_rgb;
            4'd8: begin
                rgb = {{raw_texel[7:5], raw_texel[7:5], raw_texel[7:6]},
                       {raw_texel[4:2], raw_texel[4:2], raw_texel[4:3]},
                       {4{raw_texel[1:0]}}};
                alpha = raw_texel[15:8];
            end
            4'd9: begin
                rgb = {clamp_u8(yiq_r), clamp_u8(yiq_g), clamp_u8(yiq_b)};
                alpha = raw_texel[15:8];
            end
            4'd10: rgb = {{raw_texel[15:11], raw_texel[15:13]},
                          {raw_texel[10:5], raw_texel[10:9]},
                          {raw_texel[4:0], raw_texel[4:2]}};
            4'd11: begin
                rgb = {{raw_texel[14:10], raw_texel[14:12]},
                       {raw_texel[9:5], raw_texel[9:7]},
                       {raw_texel[4:0], raw_texel[4:2]}};
                alpha = {8{raw_texel[15]}};
            end
            4'd12: begin
                rgb = {raw_texel[11:8], raw_texel[11:8],
                       raw_texel[7:4], raw_texel[7:4],
                       raw_texel[3:0], raw_texel[3:0]};
                alpha = {raw_texel[15:12], raw_texel[15:12]};
            end
            4'd13: begin
                rgb = {3{raw_texel[7:0]}};
                alpha = raw_texel[15:8];
            end
            4'd14: begin
                rgb = palette_rgb;
                alpha = raw_texel[15:8];
            end
            default: begin
                rgb = 24'd0;
                alpha = 8'd0;
            end
        endcase
    end
endmodule
