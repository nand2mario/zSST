// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Convert X.4 texture coordinates and an already selected integer LOD into
// packed TREX byte addresses. Four addresses are produced for bilinear mode;
// point mode uses address0 only.
module sst1_texture_address (
    input  logic signed [17:0]           tex_s,
    input  logic signed [17:0]           tex_t,
    input  logic [3:0]                   lod_level,
    input  logic                         magnification,
    input  logic                         clamp_to_zero,
    input  sst1_pkg::sst1_render_state_t state,
    output logic                         bilinear,
    output logic [3:0]                   ds,
    output logic [3:0]                   dt,
    output logic [21:0]                  address0,
    output logic [21:0]                  address1,
    output logic [21:0]                  address2,
    output logic [21:0]                  address3
);
    logic [31:0] texture_mode;
    logic [31:0] tlod;
    logic is_16bit;
    logic [8:0] base_width, base_height;
    logic [8:0] width, height;
    logic [3:0] resident_lod;
    logic [23:0] prefix_bytes;
    logic [23:0] selected_base;
    logic signed [17:0] scaled_s, scaled_t;
    logic signed [13:0] point_s, point_t;
    logic signed [13:0] bilinear_s, bilinear_t;
    logic [8:0] x0, x1, y0, y1;
    logic [8:0] level_width, level_height;
    integer level;

    function automatic logic [8:0] shrink_dimension(
        input logic [8:0] dimension,
        input integer amount
    );
        logic [8:0] reduced;
        begin
            reduced = dimension >> amount;
            return reduced == 0 ? 9'd1 : reduced;
        end
    endfunction

    function automatic logic [8:0] wrap_or_clamp(
        input logic signed [13:0] coordinate,
        input logic [8:0] dimension,
        input logic clamp_enable
    );
        logic [8:0] mask;
        begin
            mask = dimension - 1'b1;
            if (!clamp_enable)
                return coordinate[8:0] & mask;
            if (coordinate < 0)
                return 9'd0;
            if (coordinate >= $signed({1'b0, dimension}))
                return mask;
            return coordinate[8:0];
        end
    endfunction

    function automatic logic [21:0] texel_address(
        input logic [8:0] x,
        input logic [8:0] y,
        input logic [23:0] base,
        input logic [8:0] row_width,
        input logic word_texel
    );
        logic [23:0] offset;
        begin
            offset = base + y * row_width * (word_texel ? 2 : 1) +
                     x * (word_texel ? 2 : 1);
            return offset[21:0];
        end
    endfunction

    always_comb begin
        texture_mode = state.tmu_state[0];
        tlod = state.tmu_state[1];
        is_16bit = texture_mode[11];
        bilinear = magnification ? texture_mode[2] : texture_mode[1];

        // A split map contains only one mip parity.  During the two passes
        // used by a single TREX for trilinear filtering, an opposite-parity
        // logical LOD samples the next smaller resident mip.  The logical LOD
        // and fraction still continue to the TCU unchanged.
        resident_lod = lod_level;
        if (tlod[19] && lod_level[0] != tlod[18] && lod_level < 8)
            resident_lod = lod_level + 1'b1;

        base_width = 9'd256;
        base_height = 9'd256;
        if (tlod[20])
            base_height = base_height >> tlod[22:21];
        else
            base_width = base_width >> tlod[22:21];
        width = shrink_dimension(base_width, resident_lod);
        height = shrink_dimension(base_height, resident_lod);

        prefix_bytes = 24'd0;
        for (level = 0; level < 9; level = level + 1) begin
            if (level < resident_lod &&
                (!tlod[19] || level[0] == tlod[18])) begin
                level_width = shrink_dimension(base_width, level);
                level_height = shrink_dimension(base_height, level);
                prefix_bytes = prefix_bytes + level_width * level_height *
                               (is_16bit ? 2 : 1);
            end
        end
        // Some Glide binaries preserve an all-ones value in the reserved
        // upper nibble of tLOD.  Real SST-1 software relies on that value not
        // accidentally enabling multibase addressing through bit 24.
        if (tlod[24] && tlod[31:28] == 4'd0) begin
            case (resident_lod)
                4'd0: selected_base = {2'd0, state.tmu_state[3][18:0], 3'd0};
                4'd1: selected_base = {2'd0, state.tmu_state[4][18:0], 3'd0};
                4'd2: selected_base = {2'd0, state.tmu_state[5][18:0], 3'd0};
                default: selected_base = {2'd0, state.tmu_state[6][18:0], 3'd0};
            endcase
        end else begin
            selected_base = {2'd0, state.tmu_state[3][18:0], 3'd0};
        end
        selected_base = selected_base + prefix_bytes;

        point_s = tex_s >>> (4 + resident_lod);
        point_t = tex_t >>> (4 + resident_lod);
        scaled_s = (tex_s - (18'sd1 <<< (3 + resident_lod))) >>> resident_lod;
        scaled_t = (tex_t - (18'sd1 <<< (3 + resident_lod))) >>> resident_lod;
        bilinear_s = scaled_s >>> 4;
        bilinear_t = scaled_t >>> 4;
        ds = scaled_s[3:0];
        dt = scaled_t[3:0];
        if (clamp_to_zero) begin
            point_s = '0;
            point_t = '0;
            bilinear_s = '0;
            bilinear_t = '0;
            ds = '0;
            dt = '0;
        end

        x0 = wrap_or_clamp(bilinear ? bilinear_s : point_s,
                           width, texture_mode[6]);
        y0 = wrap_or_clamp(bilinear ? bilinear_t : point_t,
                           height, texture_mode[7]);
        x1 = wrap_or_clamp(bilinear_s + 1'b1, width, texture_mode[6]);
        y1 = wrap_or_clamp(bilinear_t + 1'b1, height, texture_mode[7]);
        address0 = texel_address(x0, y0, selected_base, width, is_16bit);
        address1 = texel_address(x1, y0, selected_base, width, is_16bit);
        address2 = texel_address(x0, y1, selected_base, width, is_16bit);
        address3 = texel_address(x1, y1, selected_base, width, is_16bit);
    end
endmodule
