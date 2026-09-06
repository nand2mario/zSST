// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Registered SST-1 FBI pixel path.  The boundaries follow the dependencies in
// the documented abstract pipeline, but are chosen for FPGA timing rather than
// as a claim about SST-1 ASIC cycle latency.  Render state must remain stable
// from input_valid through output_valid.  The fixed-latency valid pipeline has
// an initiation interval of one cycle.
module sst1_pixel_pipeline (
    input  logic                        clk,
    input  logic                        reset_n,
    input  logic                        input_valid,
    output logic                        input_ready,
    output logic                        output_valid,

    input  logic [9:0]                  pixel_x,
    input  logic [9:0]                  pixel_y,
    input  logic                        lfb_pixel,
    input  logic                        stipple_pass,
    input  logic [23:0]                 lfb_rgb,
    input  logic [7:0]                  lfb_alpha,
    input  logic [15:0]                 lfb_depth,
    input  logic [23:0]                 iter_rgb,
    input  logic [7:0]                  iter_alpha,
    input  logic signed [47:0]          iter_z,
    input  logic signed [63:0]          iter_w,
    input  logic [23:0]                 texture_rgb,
    input  logic [7:0]                  texture_alpha,
    input  logic [15:0]                 destination_color,
    input  logic [15:0]                 destination_aux,
    input  sst1_pkg::sst1_render_state_t state,

    output logic                        accepted,
    output logic                        chroma_failed,
    output logic                        depth_failed,
    output logic                        alpha_failed,
    output logic                        color_write,
    output logic                        aux_write,
    output logic [15:0]                 color_value,
    output logic [15:0]                 aux_value,
    output logic [23:0]                 color_before_fog,
    output logic [23:0]                 color_after_fog,
    output logic [7:0]                  alpha_value,
    output logic [15:0]                 depth_value,
    output logic [15:0]                 w_depth
);
    typedef struct packed {
        logic [9:0] pixel_x;
        logic [9:0] pixel_y;
        logic lfb_pixel;
        logic stipple_pass;
        logic clip_ok;
        logic chroma_ok;
        logic [7:0] other_r;
        logic [7:0] other_g;
        logic [7:0] other_b;
        logic [7:0] other_a;
        logic [7:0] local_r;
        logic [7:0] local_g;
        logic [7:0] local_b;
        logic [7:0] local_a;
        logic [7:0] texture_a;
        logic [7:0] fog_alpha;
        logic [7:0] iter_z_a;
        logic [15:0] destination_color;
        logic [15:0] destination_aux;
        logic [15:0] depth;
        logic [15:0] compare_depth;
        logic [15:0] w_depth;
    } stage0_t;

    typedef struct packed {
        logic [9:0] pixel_x;
        logic [9:0] pixel_y;
        logic stipple_pass;
        logic clip_ok;
        logic chroma_ok;
        logic alpha_mask_ok;
        logic [7:0] source_r;
        logic [7:0] source_g;
        logic [7:0] source_b;
        logic [7:0] source_a;
        logic [7:0] fog_alpha;
        logic [7:0] iter_z_a;
        logic [15:0] destination_color;
        logic [15:0] destination_aux;
        logic [15:0] depth;
        logic [15:0] compare_depth;
        logic [15:0] w_depth;
    } stage1_t;

    typedef struct packed {
        logic [9:0] pixel_x;
        logic [9:0] pixel_y;
        logic stipple_pass;
        logic clip_ok;
        logic chroma_ok;
        logic alpha_mask_ok;
        logic alpha_ok;
        logic depth_ok;
        logic [7:0] prefog_r;
        logic [7:0] prefog_g;
        logic [7:0] prefog_b;
        logic [7:0] source_r;
        logic [7:0] source_g;
        logic [7:0] source_b;
        logic [7:0] source_a;
        logic [8:0] fog_factor;
        logic [15:0] destination_color;
        logic [15:0] destination_aux;
        logic [15:0] depth;
        logic [15:0] w_depth;
    } fog_lookup_t;

    typedef struct packed {
        logic [9:0] pixel_x;
        logic [9:0] pixel_y;
        logic stipple_pass;
        logic clip_ok;
        logic chroma_ok;
        logic alpha_mask_ok;
        logic alpha_ok;
        logic depth_ok;
        logic [7:0] prefog_r;
        logic [7:0] prefog_g;
        logic [7:0] prefog_b;
        logic [7:0] source_r;
        logic [7:0] source_g;
        logic [7:0] source_b;
        logic [7:0] source_a;
        logic [15:0] destination_color;
        logic [15:0] destination_aux;
        logic [15:0] depth;
        logic [15:0] w_depth;
    } stage2_t;

    typedef struct packed {
        logic [9:0] pixel_x;
        logic [9:0] pixel_y;
        logic stipple_pass;
        logic clip_ok;
        logic chroma_ok;
        logic alpha_mask_ok;
        logic alpha_ok;
        logic depth_ok;
        logic [7:0] prefog_r;
        logic [7:0] prefog_g;
        logic [7:0] prefog_b;
        logic [7:0] fogged_r;
        logic [7:0] fogged_g;
        logic [7:0] fogged_b;
        logic [7:0] source_r;
        logic [7:0] source_g;
        logic [7:0] source_b;
        logic [7:0] source_a;
        logic [4:0] dither_matrix;
        logic [15:0] depth;
        logic [15:0] w_depth;
    } stage3_t;

    stage0_t s0_next, s0;
    stage1_t s1_next, s1;
    fog_lookup_t fog_next, fog;
    stage2_t s2_next, s2;
    stage3_t s3_next, s3;
    logic s0_valid, s1_valid, fog_valid, s2_valid, s3_valid;

    function automatic logic [7:0] clamp8(input logic signed [47:0] value);
        if (value < 0)
            return 8'd0;
        if (value > 255)
            return 8'd255;
        return value[7:0];
    endfunction

    function automatic logic [15:0] clamp16(input logic signed [47:0] value);
        if (value < 0)
            return 16'd0;
        if (value > 65535)
            return 16'hffff;
        return value[15:0];
    endfunction

    function automatic logic compare8(
        input logic [2:0] operation,
        input logic [7:0] source,
        input logic [7:0] reference
    );
        case (operation)
            3'd0: return 1'b0;
            3'd1: return source < reference;
            3'd2: return source == reference;
            3'd3: return source <= reference;
            3'd4: return source > reference;
            3'd5: return source != reference;
            3'd6: return source >= reference;
            default: return 1'b1;
        endcase
    endfunction

    function automatic logic compare16(
        input logic [2:0] operation,
        input logic [15:0] source,
        input logic [15:0] destination
    );
        case (operation)
            3'd0: return 1'b0;
            3'd1: return source < destination;
            3'd2: return source == destination;
            3'd3: return source <= destination;
            3'd4: return source > destination;
            3'd5: return source != destination;
            3'd6: return source >= destination;
            default: return 1'b1;
        endcase
    endfunction

    function automatic logic [15:0] compute_w_depth(input logic signed [63:0] value);
        logic [63:0] normalized;
        logic [15:0] upper;
        logic [4:0] leading;
        logic [16:0] encoded;
        logic [63:0] mantissa_shifted;
        integer bit_index;
        begin
            normalized = $unsigned(value <<< 2);
            if (|normalized[47:32])
                return 16'h0000;
            upper = normalized[31:16];
            if (upper == 0)
                return 16'hf001;
            leading = 5'd16;
            for (bit_index = 15; bit_index >= 0; bit_index = bit_index - 1)
                if (upper[bit_index] && leading == 16)
                    leading = 5'(15 - bit_index);
            mantissa_shifted = ~normalized >> (19 - leading);
            encoded = {leading, 12'd0} | {5'd0, mantissa_shifted[11:0]};
            encoded = encoded + 1'b1;
            return encoded[16] ? 16'hffff : encoded[15:0];
        end
    endfunction

    function automatic logic [7:0] blend_scale(
        input logic [3:0] selection,
        input logic [7:0] source_alpha,
        input logic [7:0] destination_alpha,
        input logic [7:0] color_factor,
        input logic [7:0] before_fog,
        input logic source_side
    );
        case (selection)
            4'h0: return 8'd0;
            4'h1: return source_alpha;
            4'h2: return color_factor;
            4'h3: return destination_alpha;
            4'h4: return 8'd255;
            4'h5: return 8'd255 - source_alpha;
            4'h6: return 8'd255 - color_factor;
            4'h7: return 8'd255 - destination_alpha;
            4'hf: begin
                if (source_side)
                    return source_alpha < (8'd255 - destination_alpha) ?
                           source_alpha : (8'd255 - destination_alpha);
                return before_fog;
            end
            default: return source_side ? 8'd255 : 8'd0;
        endcase
    endfunction

    function automatic logic [7:0] blend_multiply(
        input logic [7:0] color,
        input logic [7:0] factor
    );
        logic [15:0] product;
        logic [16:0] corrected;
        begin
            product = color * factor;
            corrected = {1'b0, product} + 1'b1 +
                        ({1'b0, product} >> 8);
            return corrected[15:8];
        end
    endfunction

    function automatic logic [4:0] dither_rb(
        input logic [7:0] value,
        input logic [4:0] matrix
    );
        logic [9:0] scaled;
        logic [9:0] wide_value;
        begin
            wide_value = {2'd0, value};
            scaled = (wide_value << 1) - (wide_value >> 4) +
                     (wide_value >> 7) + {5'd0, matrix};
            return scaled[8:4];
        end
    endfunction

    function automatic logic [5:0] dither_green(
        input logic [7:0] value,
        input logic [4:0] matrix
    );
        logic [10:0] scaled;
        logic [10:0] wide_value;
        begin
            wide_value = {3'd0, value};
            scaled = (wide_value << 2) - (wide_value >> 4) +
                     (wide_value >> 6) + {6'd0, matrix};
            return scaled[9:4];
        end
    endfunction

    // F0: source selection/chroma and Z/W preparation.  Chroma observes the
    // pre-CCU value, as required by the SST-1 register specification.
    always_comb begin : make_s0
        logic [15:0] z_depth;
        s0_next = '0;
        s0_next.pixel_x = pixel_x;
        s0_next.pixel_y = pixel_y;
        s0_next.lfb_pixel = lfb_pixel;
        s0_next.stipple_pass = stipple_pass;
        s0_next.texture_a = texture_alpha;
        s0_next.fog_alpha = iter_alpha;
        s0_next.iter_z_a = clamp8(iter_z >>> 20);
        s0_next.destination_color = destination_color;
        s0_next.destination_aux = destination_aux;

        s0_next.w_depth = lfb_pixel ?
            (state.lfb_mode[14] ? state.za_color[15:0] : lfb_depth) :
            compute_w_depth(iter_w);
        if (lfb_pixel) begin
            z_depth = lfb_depth;
        end else begin
            z_depth = clamp16(iter_z >>> 12);
            if (state.fbz_mode[16])
                z_depth = clamp16($signed({32'd0, z_depth}) +
                                  $signed({{32{state.za_color[15]}},
                                           state.za_color[15:0]}));
            if (state.fbz_mode[3])
                z_depth = s0_next.w_depth;
        end
        s0_next.depth = z_depth;
        s0_next.compare_depth = state.fbz_mode[20] ?
                                state.za_color[15:0] : z_depth;
        s0_next.clip_ok = !state.fbz_mode[0] ||
            (pixel_x >= state.clip_left_right[25:16] &&
             pixel_x < state.clip_left_right[9:0] &&
             pixel_y >= state.clip_low_y_high_y[25:16] &&
             pixel_y < state.clip_low_y_high_y[9:0]);

        if (lfb_pixel) begin
            {s0_next.other_r, s0_next.other_g, s0_next.other_b} = lfb_rgb;
            s0_next.other_a = lfb_alpha;
            {s0_next.local_r, s0_next.local_g, s0_next.local_b} = lfb_rgb;
            s0_next.local_a = lfb_alpha;
        end else begin
            case (state.fbz_color_path[1:0])
                2'd0: {s0_next.other_r, s0_next.other_g, s0_next.other_b} = iter_rgb;
                2'd1: {s0_next.other_r, s0_next.other_g, s0_next.other_b} = texture_rgb;
                2'd2: {s0_next.other_r, s0_next.other_g, s0_next.other_b} = state.color1[23:0];
                default: {s0_next.other_r, s0_next.other_g, s0_next.other_b} = 24'd0;
            endcase
            case (state.fbz_color_path[3:2])
                2'd0: s0_next.other_a = iter_alpha;
                2'd1: s0_next.other_a = texture_alpha;
                2'd2: s0_next.other_a = state.color1[31:24];
                default: s0_next.other_a = 8'd0;
            endcase
            if (state.fbz_color_path[7] ? texture_alpha[7] : state.fbz_color_path[4])
                {s0_next.local_r, s0_next.local_g, s0_next.local_b} = state.color0[23:0];
            else
                {s0_next.local_r, s0_next.local_g, s0_next.local_b} = iter_rgb;
            case (state.fbz_color_path[6:5])
                2'd0: s0_next.local_a = iter_alpha;
                2'd1: s0_next.local_a = state.color0[31:24];
                2'd2: s0_next.local_a = s0_next.iter_z_a;
                default: s0_next.local_a = 8'd0;
            endcase
        end
        s0_next.chroma_ok = !state.fbz_mode[1] ||
            ({s0_next.other_r, s0_next.other_g, s0_next.other_b} !=
             state.chroma_key[23:0]);
    end

    // F1: the parallel FBI Color and Alpha Combine Units.
    always_comb begin : make_s1
        logic [8:0] factor_r, factor_g, factor_b, factor_a;
        logic signed [10:0] combine_r, combine_g, combine_b, combine_a;
        logic signed [19:0] product_r, product_g, product_b, product_a;
        s1_next = '0;
        s1_next.pixel_x = s0.pixel_x;
        s1_next.pixel_y = s0.pixel_y;
        s1_next.stipple_pass = s0.stipple_pass;
        s1_next.clip_ok = s0.clip_ok;
        s1_next.chroma_ok = s0.chroma_ok;
        s1_next.iter_z_a = s0.iter_z_a;
        s1_next.fog_alpha = s0.fog_alpha;
        s1_next.destination_color = s0.destination_color;
        s1_next.destination_aux = s0.destination_aux;
        s1_next.depth = s0.depth;
        s1_next.compare_depth = s0.compare_depth;
        s1_next.w_depth = s0.w_depth;
        factor_r = '0;
        factor_g = '0;
        factor_b = '0;
        factor_a = '0;
        combine_r = '0;
        combine_g = '0;
        combine_b = '0;
        combine_a = '0;
        product_r = '0;
        product_g = '0;
        product_b = '0;
        product_a = '0;

        if (s0.lfb_pixel) begin
            s1_next.source_r = s0.other_r;
            s1_next.source_g = s0.other_g;
            s1_next.source_b = s0.other_b;
            s1_next.source_a = s0.other_a;
        end else begin
            combine_r = state.fbz_color_path[8] ? 11'sd0 : $signed({3'd0, s0.other_r});
            combine_g = state.fbz_color_path[8] ? 11'sd0 : $signed({3'd0, s0.other_g});
            combine_b = state.fbz_color_path[8] ? 11'sd0 : $signed({3'd0, s0.other_b});
            combine_a = state.fbz_color_path[17] ? 11'sd0 : $signed({3'd0, s0.other_a});
            if (state.fbz_color_path[9]) begin
                combine_r = combine_r - $signed({3'd0, s0.local_r});
                combine_g = combine_g - $signed({3'd0, s0.local_g});
                combine_b = combine_b - $signed({3'd0, s0.local_b});
            end
            if (state.fbz_color_path[18])
                combine_a = combine_a - $signed({3'd0, s0.local_a});

            case (state.fbz_color_path[12:10])
                3'd1: begin
                    factor_r = {1'b0, s0.local_r};
                    factor_g = {1'b0, s0.local_g};
                    factor_b = {1'b0, s0.local_b};
                end
                3'd2: begin
                    factor_r = {1'b0, s0.other_a};
                    factor_g = {1'b0, s0.other_a};
                    factor_b = {1'b0, s0.other_a};
                end
                3'd3: begin
                    factor_r = {1'b0, s0.local_a};
                    factor_g = {1'b0, s0.local_a};
                    factor_b = {1'b0, s0.local_a};
                end
                3'd4: begin
                    factor_r = {1'b0, s0.texture_a};
                    factor_g = {1'b0, s0.texture_a};
                    factor_b = {1'b0, s0.texture_a};
                end
                default: begin end
            endcase
            case (state.fbz_color_path[21:19])
                3'd1, 3'd3: factor_a = {1'b0, s0.local_a};
                3'd2: factor_a = {1'b0, s0.other_a};
                3'd4: factor_a = {1'b0, s0.texture_a};
                default: begin end
            endcase
            factor_r = (state.fbz_color_path[13] ? factor_r :
                        (factor_r ^ 9'h0ff)) + 1'b1;
            factor_g = (state.fbz_color_path[13] ? factor_g :
                        (factor_g ^ 9'h0ff)) + 1'b1;
            factor_b = (state.fbz_color_path[13] ? factor_b :
                        (factor_b ^ 9'h0ff)) + 1'b1;
            factor_a = (state.fbz_color_path[22] ? factor_a :
                        (factor_a ^ 9'h0ff)) + 1'b1;
            product_r = combine_r * $signed({1'b0, factor_r});
            product_g = combine_g * $signed({1'b0, factor_g});
            product_b = combine_b * $signed({1'b0, factor_b});
            product_a = combine_a * $signed({1'b0, factor_a});
            combine_r = 11'(product_r >>> 8);
            combine_g = 11'(product_g >>> 8);
            combine_b = 11'(product_b >>> 8);
            combine_a = 11'(product_a >>> 8);
            case (state.fbz_color_path[15:14])
                2'd1: begin
                    combine_r = combine_r + $signed({3'd0, s0.local_r});
                    combine_g = combine_g + $signed({3'd0, s0.local_g});
                    combine_b = combine_b + $signed({3'd0, s0.local_b});
                end
                2'd2: begin
                    combine_r = combine_r + $signed({3'd0, s0.local_a});
                    combine_g = combine_g + $signed({3'd0, s0.local_a});
                    combine_b = combine_b + $signed({3'd0, s0.local_a});
                end
                default: begin end
            endcase
            if (|state.fbz_color_path[24:23])
                combine_a = combine_a + $signed({3'd0, s0.local_a});
            s1_next.source_r = clamp8(48'(combine_r));
            s1_next.source_g = clamp8(48'(combine_g));
            s1_next.source_b = clamp8(48'(combine_b));
            s1_next.source_a = clamp8(48'(combine_a));
            if (state.fbz_color_path[16]) begin
                s1_next.source_r = s1_next.source_r ^ 8'hff;
                s1_next.source_g = s1_next.source_g ^ 8'hff;
                s1_next.source_b = s1_next.source_b ^ 8'hff;
            end
            if (state.fbz_color_path[25])
                s1_next.source_a = s1_next.source_a ^ 8'hff;
        end
        // Both tests consume the ACU output.  This only differs from the old
        // model when software deliberately makes "other alpha" differ from
        // the combined alpha.
        s1_next.alpha_mask_ok = !state.fbz_mode[13] || s1_next.source_a[0];
    end

    // F2a: alpha/depth tests and fog-table interpolation.  Keeping the table
    // mux/interpolation on the input side of a register avoids placing it in
    // series with the three fog multiplies and output clamps.
    always_comb begin : make_fog_lookup
        logic [8:0] fog_factor;
        logic [7:0] fog_base, fog_delta, fog_fraction;
        logic [5:0] fog_index;
        logic [31:0] fog_word;
        logic [15:0] fog_interp_product;
        fog_next = '0;
        fog_next.pixel_x = s1.pixel_x;
        fog_next.pixel_y = s1.pixel_y;
        fog_next.stipple_pass = s1.stipple_pass;
        fog_next.clip_ok = s1.clip_ok;
        fog_next.chroma_ok = s1.chroma_ok;
        fog_next.alpha_mask_ok = s1.alpha_mask_ok;
        fog_next.source_r = s1.source_r;
        fog_next.source_g = s1.source_g;
        fog_next.source_b = s1.source_b;
        fog_next.source_a = s1.source_a;
        fog_next.prefog_r = s1.source_r;
        fog_next.prefog_g = s1.source_g;
        fog_next.prefog_b = s1.source_b;
        fog_next.destination_color = s1.destination_color;
        fog_next.destination_aux = s1.destination_aux;
        fog_next.depth = s1.depth;
        fog_next.w_depth = s1.w_depth;
        fog_next.alpha_ok = !state.alpha_mode[0] ||
            compare8(state.alpha_mode[3:1], s1.source_a,
                     state.alpha_mode[31:24]);
        fog_next.depth_ok = !state.fbz_mode[4] ||
            compare16(state.fbz_mode[7:5], s1.compare_depth,
                      s1.destination_aux);
        fog_factor = '0;
        fog_base = '0;
        fog_delta = '0;
        fog_fraction = '0;
        fog_index = '0;
        fog_word = '0;
        fog_interp_product = '0;

        if (state.fog_mode[0] && !state.fog_mode[5]) begin
            if (state.fog_mode[4]) begin
                fog_factor = {1'b0, s1.iter_z_a} + 1'b1;
            end else if (state.fog_mode[3]) begin
                fog_factor = {1'b0, s1.fog_alpha} + 1'b1;
            end else begin
                fog_index = s1.w_depth[15:10];
                fog_fraction = s1.w_depth[9:2];
                fog_word = state.fog_table[fog_index[5:1]];
                if (fog_index[0]) begin
                    fog_delta = fog_word[23:16];
                    fog_base = fog_word[31:24];
                end else begin
                    fog_delta = fog_word[7:0];
                    fog_base = fog_word[15:8];
                end
                fog_interp_product = fog_delta * fog_fraction;
                fog_factor = {1'b0, fog_base} +
                             {3'd0, fog_interp_product[15:10]} + 1'b1;
            end
        end
        fog_next.fog_factor = fog_factor;
    end

    // F2b: apply the registered fog factor.  This is still an II=1 path; it
    // adds one cycle of latency while separating table lookup from multiply.
    always_comb begin : make_s2
        logic signed [11:0] fog_term_r, fog_term_g, fog_term_b;
        logic signed [20:0] fog_product_r, fog_product_g, fog_product_b;
        s2_next = '0;
        s2_next.pixel_x = fog.pixel_x;
        s2_next.pixel_y = fog.pixel_y;
        s2_next.stipple_pass = fog.stipple_pass;
        s2_next.clip_ok = fog.clip_ok;
        s2_next.chroma_ok = fog.chroma_ok;
        s2_next.alpha_mask_ok = fog.alpha_mask_ok;
        s2_next.alpha_ok = fog.alpha_ok;
        s2_next.depth_ok = fog.depth_ok;
        s2_next.source_r = fog.source_r;
        s2_next.source_g = fog.source_g;
        s2_next.source_b = fog.source_b;
        s2_next.source_a = fog.source_a;
        s2_next.prefog_r = fog.prefog_r;
        s2_next.prefog_g = fog.prefog_g;
        s2_next.prefog_b = fog.prefog_b;
        s2_next.destination_color = fog.destination_color;
        s2_next.destination_aux = fog.destination_aux;
        s2_next.depth = fog.depth;
        s2_next.w_depth = fog.w_depth;
        fog_term_r = '0;
        fog_term_g = '0;
        fog_term_b = '0;
        fog_product_r = '0;
        fog_product_g = '0;
        fog_product_b = '0;

        if (state.fog_mode[0]) begin
            if (state.fog_mode[5]) begin
                s2_next.source_r = clamp8($signed({39'd0, fog.source_r}) +
                    $signed({39'd0, state.fog_color[23:16]}));
                s2_next.source_g = clamp8($signed({39'd0, fog.source_g}) +
                    $signed({39'd0, state.fog_color[15:8]}));
                s2_next.source_b = clamp8($signed({39'd0, fog.source_b}) +
                    $signed({39'd0, state.fog_color[7:0]}));
            end else begin
                fog_term_r = state.fog_mode[1] ? 12'sd0 :
                    $signed({4'd0, state.fog_color[23:16]});
                fog_term_g = state.fog_mode[1] ? 12'sd0 :
                    $signed({4'd0, state.fog_color[15:8]});
                fog_term_b = state.fog_mode[1] ? 12'sd0 :
                    $signed({4'd0, state.fog_color[7:0]});
                if (!state.fog_mode[2]) begin
                    fog_term_r = fog_term_r - $signed({4'd0, fog.source_r});
                    fog_term_g = fog_term_g - $signed({4'd0, fog.source_g});
                    fog_term_b = fog_term_b - $signed({4'd0, fog.source_b});
                end
                fog_product_r = fog_term_r * $signed({1'b0, fog.fog_factor});
                fog_product_g = fog_term_g * $signed({1'b0, fog.fog_factor});
                fog_product_b = fog_term_b * $signed({1'b0, fog.fog_factor});
                if (state.fog_mode[2]) begin
                    s2_next.source_r = clamp8(48'(fog_product_r >>> 8));
                    s2_next.source_g = clamp8(48'(fog_product_g >>> 8));
                    s2_next.source_b = clamp8(48'(fog_product_b >>> 8));
                end else begin
                    s2_next.source_r = clamp8($signed({39'd0, fog.source_r}) +
                                              48'(fog_product_r >>> 8));
                    s2_next.source_g = clamp8($signed({39'd0, fog.source_g}) +
                                              48'(fog_product_g >>> 8));
                    s2_next.source_b = clamp8($signed({39'd0, fog.source_b}) +
                                              48'(fog_product_b >>> 8));
                end
            end
        end
    end

    // F3: destination reconstruction/dither subtraction and alpha blending.
    always_comb begin : make_s3
        logic [7:0] dest_r, dest_g, dest_b, dest_a;
        logic signed [5:0] dither_sub_rb, dither_sub_g;
        logic signed [9:0] dest_sub_r, dest_sub_g, dest_sub_b;
        logic [7:0] blend_src_r, blend_src_g, blend_src_b, blend_src_a;
        logic [7:0] blend_dst_r, blend_dst_g, blend_dst_b, blend_dst_a;
        logic [7:0] term_sr, term_sg, term_sb, term_sa;
        logic [7:0] term_dr, term_dg, term_db, term_da;
        logic [8:0] sum_r, sum_g, sum_b, sum_a;
        logic [4:0] matrix;
        s3_next = '0;
        blend_src_r = '0;
        blend_src_g = '0;
        blend_src_b = '0;
        blend_src_a = '0;
        blend_dst_r = '0;
        blend_dst_g = '0;
        blend_dst_b = '0;
        blend_dst_a = '0;
        term_sr = '0;
        term_sg = '0;
        term_sb = '0;
        term_sa = '0;
        term_dr = '0;
        term_dg = '0;
        term_db = '0;
        term_da = '0;
        sum_r = '0;
        sum_g = '0;
        sum_b = '0;
        sum_a = '0;
        s3_next.pixel_x = s2.pixel_x;
        s3_next.pixel_y = s2.pixel_y;
        s3_next.stipple_pass = s2.stipple_pass;
        s3_next.clip_ok = s2.clip_ok;
        s3_next.chroma_ok = s2.chroma_ok;
        s3_next.alpha_mask_ok = s2.alpha_mask_ok;
        s3_next.alpha_ok = s2.alpha_ok;
        s3_next.depth_ok = s2.depth_ok;
        s3_next.prefog_r = s2.prefog_r;
        s3_next.prefog_g = s2.prefog_g;
        s3_next.prefog_b = s2.prefog_b;
        s3_next.fogged_r = s2.source_r;
        s3_next.fogged_g = s2.source_g;
        s3_next.fogged_b = s2.source_b;
        s3_next.source_r = s2.source_r;
        s3_next.source_g = s2.source_g;
        s3_next.source_b = s2.source_b;
        s3_next.source_a = s2.source_a;
        s3_next.depth = s2.depth;
        s3_next.w_depth = s2.w_depth;

        case ({s2.pixel_y[1:0], s2.pixel_x[1:0]})
            4'h0: matrix = 0;  4'h1: matrix = 8;
            4'h2: matrix = 2;  4'h3: matrix = 10;
            4'h4: matrix = 12; 4'h5: matrix = 4;
            4'h6: matrix = 14; 4'h7: matrix = 6;
            4'h8: matrix = 3;  4'h9: matrix = 11;
            4'ha: matrix = 1;  4'hb: matrix = 9;
            4'hc: matrix = 15; 4'hd: matrix = 7;
            4'he: matrix = 13; default: matrix = 5;
        endcase
        if (state.fbz_mode[11]) begin
            case ({s2.pixel_y[0], s2.pixel_x[0]})
                2'd0: matrix = 2;
                2'd1: matrix = 10;
                2'd2: matrix = 14;
                default: matrix = 6;
            endcase
        end
        s3_next.dither_matrix = matrix;

        dest_r = {s2.destination_color[15:11], s2.destination_color[15:13]};
        dest_g = {s2.destination_color[10:5], s2.destination_color[10:9]};
        dest_b = {s2.destination_color[4:0], s2.destination_color[4:2]};
        dest_a = state.fbz_mode[18] ? s2.destination_aux[7:0] : 8'hff;
        dither_sub_rb = ($signed({1'b0, 5'd10}) -
                         $signed({1'b0, matrix})) >>> 1;
        dither_sub_g = ($signed({1'b0, 5'd12}) -
                        $signed({1'b0, matrix})) >>> 2;
        dest_sub_r = $signed({2'd0, dest_r});
        dest_sub_g = $signed({2'd0, dest_g});
        dest_sub_b = $signed({2'd0, dest_b});
        if (state.fbz_mode[19] && state.fbz_mode[8]) begin
            dest_sub_r = dest_sub_r + 10'(dither_sub_rb);
            dest_sub_g = dest_sub_g + 10'(dither_sub_g);
            dest_sub_b = dest_sub_b + 10'(dither_sub_rb);
            if (dest_sub_r < 0) dest_sub_r = 0;
            if (dest_sub_g < 0) dest_sub_g = 0;
            if (dest_sub_b < 0) dest_sub_b = 0;
            if (dest_sub_r > 255) dest_sub_r = 255;
            if (dest_sub_g > 255) dest_sub_g = 255;
            if (dest_sub_b > 255) dest_sub_b = 255;
        end

        if (state.alpha_mode[4]) begin
            blend_src_r = blend_scale(state.alpha_mode[11:8], s2.source_a,
                dest_a, dest_sub_r[7:0], s2.prefog_r, 1'b1);
            blend_src_g = blend_scale(state.alpha_mode[11:8], s2.source_a,
                dest_a, dest_sub_g[7:0], s2.prefog_g, 1'b1);
            blend_src_b = blend_scale(state.alpha_mode[11:8], s2.source_a,
                dest_a, dest_sub_b[7:0], s2.prefog_b, 1'b1);
            blend_dst_r = blend_scale(state.alpha_mode[15:12], s2.source_a,
                dest_a, s2.source_r, s2.prefog_r, 1'b0);
            blend_dst_g = blend_scale(state.alpha_mode[15:12], s2.source_a,
                dest_a, s2.source_g, s2.prefog_g, 1'b0);
            blend_dst_b = blend_scale(state.alpha_mode[15:12], s2.source_a,
                dest_a, s2.source_b, s2.prefog_b, 1'b0);
            term_sr = blend_multiply(s2.source_r, blend_src_r);
            term_sg = blend_multiply(s2.source_g, blend_src_g);
            term_sb = blend_multiply(s2.source_b, blend_src_b);
            term_dr = blend_multiply(dest_sub_r[7:0], blend_dst_r);
            term_dg = blend_multiply(dest_sub_g[7:0], blend_dst_g);
            term_db = blend_multiply(dest_sub_b[7:0], blend_dst_b);
            sum_r = {1'b0, term_sr} + term_dr;
            sum_g = {1'b0, term_sg} + term_dg;
            sum_b = {1'b0, term_sb} + term_db;
            s3_next.source_r = sum_r[8] ? 8'hff : sum_r[7:0];
            s3_next.source_g = sum_g[8] ? 8'hff : sum_g[7:0];
            s3_next.source_b = sum_b[8] ? 8'hff : sum_b[7:0];

            blend_src_a = blend_scale(state.alpha_mode[19:16], s2.source_a,
                dest_a, dest_a, s2.source_a, 1'b1);
            blend_dst_a = blend_scale(state.alpha_mode[23:20], s2.source_a,
                dest_a, s2.source_a, s2.source_a, 1'b0);
            term_sa = blend_multiply(s2.source_a, blend_src_a);
            term_da = blend_multiply(dest_a, blend_dst_a);
            sum_a = {1'b0, term_sa} + term_da;
            s3_next.source_a = sum_a[8] ? 8'hff : sum_a[7:0];
        end
    end

    assign input_ready = 1'b1;

    // F4: final framebuffer precision conversion and visibility/write masks.
    always_ff @(posedge clk) begin
        logic [4:0] out_r, out_b;
        logic [5:0] out_g;
        logic visible;
        if (!reset_n) begin
            s0 <= '0;
            s1 <= '0;
            fog <= '0;
            s2 <= '0;
            s3 <= '0;
            s0_valid <= 1'b0;
            s1_valid <= 1'b0;
            fog_valid <= 1'b0;
            s2_valid <= 1'b0;
            s3_valid <= 1'b0;
            output_valid <= 1'b0;
            accepted <= 1'b0;
            chroma_failed <= 1'b0;
            depth_failed <= 1'b0;
            alpha_failed <= 1'b0;
            color_write <= 1'b0;
            aux_write <= 1'b0;
            color_value <= '0;
            aux_value <= '0;
            color_before_fog <= '0;
            color_after_fog <= '0;
            alpha_value <= '0;
            depth_value <= '0;
            w_depth <= '0;
        end else begin
            s0 <= s0_next;
            s1 <= s1_next;
            fog <= fog_next;
            s2 <= s2_next;
            s3 <= s3_next;
            s0_valid <= input_valid;
            s1_valid <= s0_valid;
            fog_valid <= s1_valid;
            s2_valid <= fog_valid;
            s3_valid <= s2_valid;
            output_valid <= s3_valid;
            if (s3_valid) begin
                if (state.fbz_mode[8]) begin
                    out_r = dither_rb(s3.source_r, s3.dither_matrix);
                    out_g = dither_green(s3.source_g, s3.dither_matrix);
                    out_b = dither_rb(s3.source_b, s3.dither_matrix);
                end else begin
                    out_r = s3.source_r[7:3];
                    out_g = s3.source_g[7:2];
                    out_b = s3.source_b[7:3];
                end
                visible = s3.clip_ok && s3.stipple_pass && s3.depth_ok &&
                          s3.chroma_ok && s3.alpha_mask_ok && s3.alpha_ok;
                accepted <= visible;
                chroma_failed <= s3.clip_ok && s3.stipple_pass &&
                                 s3.depth_ok && !s3.chroma_ok;
                depth_failed <= s3.clip_ok && s3.stipple_pass && !s3.depth_ok;
                alpha_failed <= s3.clip_ok && s3.stipple_pass && s3.depth_ok &&
                                s3.chroma_ok &&
                                (!s3.alpha_mask_ok || !s3.alpha_ok);
                color_write <= visible && state.fbz_mode[9];
                aux_write <= visible && state.fbz_mode[10];
                color_value <= {out_r, out_g, out_b};
                aux_value <= state.fbz_mode[18] ?
                             {8'd0, s3.source_a} : s3.depth;
                color_before_fog <= {s3.prefog_r, s3.prefog_g, s3.prefog_b};
                color_after_fog <= {s3.fogged_r, s3.fogged_g, s3.fogged_b};
                alpha_value <= s3.source_a;
                depth_value <= s3.depth;
                w_depth <= s3.w_depth;
            end
        end
    end

endmodule
