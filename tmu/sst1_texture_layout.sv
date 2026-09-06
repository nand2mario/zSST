// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// SST-1 texture-aperture translation and packed mip layout. Addresses are byte
// offsets within one TREX texture-memory image. The host aperture encodes TMU,
// LOD, T, and aligned S rather than exposing linear texture RAM.
module sst1_texture_layout (
    input  logic [22:0]                    aperture_offset,
    input  logic [31:0]                    write_data,
    input  logic [3:0]                     write_enable,
    input  sst1_pkg::sst1_render_state_t   state,
    output logic                           valid,
    output logic [22:0]                    memory_offset,
    output logic [31:0]                    memory_data,
    output logic [3:0]                     memory_enable
);
    logic [31:0] texture_mode;
    logic [31:0] tlod;
    logic [3:0] format;
    logic is_16bit;
    logic [3:0] lod;
    logic [7:0] tex_s;
    logic [7:0] tex_t;
    logic [8:0] width;
    logic [8:0] height;
    logic [8:0] level_width;
    logic [8:0] level_height;
    logic [23:0] prefix_bytes;
    logic [23:0] selected_base;
    logic [23:0] row_offset;
    logic [31:0] swizzled_data;
    logic [3:0] swizzled_enable;
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

    always_comb begin
        texture_mode = state.tmu_state[0];
        tlod = state.tmu_state[1];
        format = texture_mode[11:8];
        is_16bit = format[3];
        lod = aperture_offset[20:17];
        tex_t = aperture_offset[16:9];
        if (is_16bit)
            tex_s = {aperture_offset[8:2], 1'b0};
        else if (texture_mode[31])
            tex_s = {aperture_offset[7:2], 2'b00};
        else
            tex_s = {aperture_offset[8:3], 2'b00};

        width = 9'd256;
        height = 9'd256;
        if (tlod[20])
            height = height >> tlod[22:21];
        else
            width = width >> tlod[22:21];

        prefix_bytes = 24'd0;
        for (level = 0; level < 9; level = level + 1) begin
            if (level < lod &&
                (!tlod[19] || (level[0] == tlod[18]))) begin
                level_width = shrink_dimension(width, level);
                level_height = shrink_dimension(height, level);
                prefix_bytes = prefix_bytes +
                               level_width * level_height * (is_16bit ? 2 : 1);
            end
        end

        // A nonzero reserved upper nibble is a legacy Glide sentinel, not a
        // request to enable multibase addressing through bit 24.
        if (tlod[24] && tlod[31:28] == 4'd0) begin
            case (lod)
                4'd0: selected_base = {2'd0, state.tmu_state[3][18:0], 3'd0};
                4'd1: selected_base = {2'd0, state.tmu_state[4][18:0], 3'd0};
                4'd2: selected_base = {2'd0, state.tmu_state[5][18:0], 3'd0};
                default: selected_base = {2'd0, state.tmu_state[6][18:0], 3'd0};
            endcase
        end else begin
            selected_base = {2'd0, state.tmu_state[3][18:0], 3'd0};
        end

        level_width = shrink_dimension(width, lod);
        level_height = shrink_dimension(height, lod);
        row_offset = tex_t * level_width * (is_16bit ? 2 : 1);
        // A 19-bit base at eight-byte granularity addresses one 4 MiB TREX
        // image. Arithmetic wraps there, including intentionally negative
        // bases used when the first resident mip is not LOD0.
        memory_offset = {1'b0, 22'(selected_base + prefix_bytes + row_offset +
                                   tex_s * (is_16bit ? 2 : 1))};

        swizzled_data = write_data;
        swizzled_enable = write_enable;
        if (tlod[25]) begin
            swizzled_data = {write_data[7:0], write_data[15:8],
                             write_data[23:16], write_data[31:24]};
            swizzled_enable = {write_enable[0], write_enable[1],
                               write_enable[2], write_enable[3]};
        end
        if (tlod[26]) begin
            memory_data = {swizzled_data[15:0], swizzled_data[31:16]};
            memory_enable = {swizzled_enable[1:0], swizzled_enable[3:2]};
        end else begin
            memory_data = swizzled_data;
            memory_enable = swizzled_enable;
        end

        // SST-1 supports one TREX here. Split textures accept only the chosen
        // parity; LODs above 8 and rows outside the configured map are ignored.
        valid = aperture_offset[22:21] == 2'b00 && lod <= 8 &&
                (!tlod[19] || lod[0] == tlod[18]) &&
                tex_t < level_height && tex_s < level_width;
        if (is_16bit) begin
            if (tex_s + 1 >= level_width)
                memory_enable[3:2] = 2'b00;
        end else begin
            if (tex_s + 1 >= level_width) memory_enable[1] = 1'b0;
            if (tex_s + 2 >= level_width) memory_enable[2] = 1'b0;
            if (tex_s + 3 >= level_width) memory_enable[3] = 1'b0;
        end
        valid = valid && |memory_enable;
    end

endmodule
