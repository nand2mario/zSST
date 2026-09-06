// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Initial SST-1 FBI implementation.  All software-visible storage remains in
// external memory; this block emits byte-masked 128-bit requests so the board
// shell can connect it to a combining cache or directly to AXI during bring-up.
module sst1_fbi #(
    parameter integer FB_READ_PREFETCH_LINES = 0
) (
    input  logic                            clk,
    input  logic                            reset_n,
    input  logic                            memory_enable,
    input  logic [39:0]                     memory_base,
    input  logic [23:0]                     memory_size,

    input  logic                            command_valid,
    output logic                            command_ready,
    input  sst1_pkg::sst1_render_command_t  command,
    input  logic                            lfb_valid,
    output logic                            lfb_ready,
    input  sst1_pkg::sst1_lfb_command_t     lfb,
    output logic                            lfb_read_rsp_valid,
    input  logic                            lfb_read_rsp_ready,
    output logic [31:0]                     lfb_read_rsp_data,
    output logic                            lfb_read_rsp_error,

    output logic                            texture_sample_valid,
    input  logic                            texture_sample_ready,
    output sst1_pkg::sst1_texture_sample_t  texture_sample,
    input  logic                            texture_result_valid,
    output logic                            texture_result_ready,
    input  sst1_pkg::sst1_texture_result_t  texture_result,

    output logic                            mem_req_valid,
    input  logic                            mem_req_ready,
    output sst1_pkg::sst1_mem_req_t         mem_req,
    input  logic                            mem_rsp_valid,
    output logic                            mem_rsp_ready,
    input  sst1_pkg::sst1_mem_rsp_t         mem_rsp,

    output logic                            idle,
    input  logic [1:0]                      displayed_buffer,
    output logic [31:0]                     pixels_in,
    output logic [31:0]                     chroma_fail,
    output logic [31:0]                     zfunc_fail,
    output logic [31:0]                     afunc_fail,
    output logic [31:0]                     pixels_out,
    output logic [31:0]                     current_stipple,
    output logic [31:0]                     current_stipple_generation,
    output logic [31:0]                     last_alpha,
    output logic [31:0]                     last_w,
    output sst1_pkg::sst1_fbi_perf_events_t perf_events
);
    import sst1_pkg::*;

    typedef enum logic [4:0] {
        ST_IDLE,
        ST_LFB_WRITE,
        ST_LFB_READ_REQ,
        ST_LFB_READ_WAIT,
        ST_LFB_READ_RSP,
        ST_LFB_PIPE_SETUP,
        ST_FILL,
        ST_TRI_SETUP,
        ST_TRI_TEST,
        ST_TRI_PREFETCH,
        ST_TRI_EVALUATE,
        ST_TRI_PIPE_WAIT,
        ST_TRI_WRITE_COLOR,
        ST_TRI_WRITE_AUX,
        ST_PIXEL_FINISH,
        ST_TRI_STREAM,
        ST_TRI_STREAM_DRAIN,
        ST_WRITE_DRAIN
    } state_t;

    state_t state;
    sst1_render_state_t work;
    logic [2:0] lfb_step;
    logic [1:0] lfb_write_color;
    logic [1:0] lfb_write_aux;
    logic [15:0] lfb_color [0:1];
    logic [15:0] lfb_aux [0:1];
    logic [23:0] lfb_pipeline_rgb [0:1];
    logic [7:0] lfb_pipeline_alpha [0:1];
    logic [15:0] lfb_pipeline_depth [0:1];
    logic [1:0] lfb_pipeline_valid;
    logic [9:0] lfb_pixel_x;
    logic [9:0] lfb_pixel_y;
    logic pixel_source_lfb;
    logic pixel_input_ready;
    logic pixel_output_valid;
    logic [23:0] lfb_color_address;
    logic [23:0] lfb_aux_address;
    logic [23:0] lfb_read_address;
    logic [3:0] lfb_read_lane;

    logic signed [16:0] ax, ay, bx, by, cx, cy;
    logic signed [16:0] raster_x, raster_y;
    logic signed [16:0] min_x, max_x, max_y;
    logic signed [37:0] edge_ab, edge_bc, edge_ca;
    logic triangle_negative;
    logic signed [17:0] sample_x, sample_y;
    logic triangle_inside;
    logic [23:0] triangle_iter_rgb;
    logic [7:0] triangle_iter_alpha;
    logic signed [47:0] triangle_iter_z;
    logic signed [63:0] triangle_iter_w;
    logic signed [63:0] triangle_iter_s;
    logic signed [63:0] triangle_iter_t;
    logic [23:0] triangle_texture_rgb;
    logic [7:0] triangle_texture_alpha;
    logic [15:0] destination_color;
    logic [15:0] destination_aux;
    logic [31:0] stipple_value;
    logic [31:0] observed_stipple_generation;
    logic stipple_candidate;
    logic pixel_stipple_latched;
    logic pixel_accepted;
    logic pixel_chroma_failed;
    logic pixel_depth_failed;
    logic pixel_alpha_failed;
    logic pixel_color_write;
    logic pixel_aux_write;
    logic [15:0] pixel_color_value;
    logic [15:0] pixel_aux_value;
    logic [23:0] triangle_color_address;
    logic [23:0] triangle_aux_address;
    logic triangle_texture_request_pending;
    logic triangle_texture_done;
    logic triangle_aux_request_pending;
    logic triangle_aux_done;
    logic triangle_color_request_pending;
    logic triangle_color_done;

    logic [10:0] fill_x, fill_y;
    logic [10:0] fill_left, fill_right, fill_high;
    logic fill_color_done;

    logic [23:0] row_width;
    logic [23:0] buffer_size;
    logic [23:0] front_base;
    logic [23:0] back_base;
    logic [23:0] aux_base;
    logic [23:0] draw_base;

    logic [23:0] active_write_address;
    logic [15:0] active_write_data;
    logic active_write_valid;
    logic request_in_range;
    logic request_fire;
    logic read_request_valid;
    sst1_mem_req_t read_request;
    logic write_update_valid, write_update_ready, write_update_fire;
    logic color_update_ready, aux_update_ready;
    logic color_combiner_update_valid, aux_combiner_update_valid;
    logic [23:0] color_combiner_update_address;
    logic [23:0] aux_combiner_update_address;
    logic [15:0] color_combiner_update_data;
    logic [15:0] aux_combiner_update_data;
    logic active_write_aux;
    logic write_flush_valid;
    logic write_combiner_idle;
    logic color_write_idle, aux_write_idle;
    logic color_mem_req_valid, color_mem_req_ready;
    logic aux_mem_req_valid, aux_mem_req_ready;
    sst1_mem_req_t color_mem_req, aux_mem_req;
    logic [23:0] color_probe_address, aux_probe_address;
    logic [1:0] write_probe_hit;
    logic [15:0] write_probe_data;
    logic [1:0] color_probe_hit, aux_probe_hit;
    logic [15:0] color_probe_data, aux_probe_data;
    logic color_span_valid, aux_span_valid;
    logic [23:4] color_span_line, aux_span_line;
    logic [127:0] color_span_data, aux_span_data;
    logic color_span_hit, aux_span_hit;
    logic color_value_ready, aux_value_ready;
    logic [15:0] cached_color_value, cached_aux_value;
    logic need_color_read, need_aux_read;

    logic fb_color_lookup_valid, fb_color_lookup_ready;
    logic fb_aux_lookup_valid, fb_aux_lookup_ready;
    logic fb_color_response_valid, fb_color_response_ready;
    logic fb_aux_response_valid, fb_aux_response_ready;
    logic [15:0] fb_color_response_data, fb_aux_response_data;
    logic fb_color_cache_mem_req_valid, fb_color_cache_mem_req_ready;
    logic fb_aux_cache_mem_req_valid, fb_aux_cache_mem_req_ready;
    logic fb_color_cache_mem_rsp_valid, fb_color_cache_mem_rsp_ready;
    logic fb_aux_cache_mem_rsp_valid, fb_aux_cache_mem_rsp_ready;
    logic fb_color_cache_idle, fb_aux_cache_idle;
    sst1_cache_perf_events_t fb_color_cache_perf, fb_aux_cache_perf;
    sst1_mem_req_t fb_color_cache_mem_req, fb_aux_cache_mem_req;
    logic fb_color_invalidate_valid, fb_aux_invalidate_valid;
    logic fb_invalidate_all;
    logic [23:0] fb_color_invalidate_address, fb_aux_invalidate_address;

    typedef enum logic [2:0] {
        MEM_ARB_COLOR_WRITE,
        MEM_ARB_AUX_WRITE,
        MEM_ARB_AUX_READ,
        MEM_ARB_COLOR_READ,
        MEM_ARB_LEGACY_READ
    } mem_arb_source_t;
    mem_arb_source_t mem_arb_select, mem_hold_source;
    logic mem_arb_select_valid, mem_hold_valid;
    sst1_mem_req_t mem_arb_request, mem_hold_request;
    logic legacy_mem_req_ready, legacy_mem_rsp_ready;

    // Sixty-four entries cover the measured ~28-cycle DDR latency plus
    // response reordering and the six-stage pixel pipeline without forcing
    // the raster walker to stop at ordinary scanline boundaries.
    localparam integer STREAM_FIFO_DEPTH = 64;
    localparam integer STREAM_FIFO_BITS = $clog2(STREAM_FIFO_DEPTH);
    logic stream_fast_path, stream_textured, stream_needs_join;
    logic stream_pixel_eligible, stream_issue_slot_ready;
    logic stream_step, stream_issue, stream_dispatch, stream_pipeline_fire;
    logic stream_row_started;
    logic stream_issue_valid;
    logic [9:0] stream_pixel_x, stream_pixel_y;
    logic stream_stipple;
    logic [23:0] stream_iter_rgb;
    logic [7:0] stream_iter_alpha;
    logic signed [47:0] stream_iter_z;
    logic signed [63:0] stream_iter_w;
    logic signed [63:0] stream_iter_s, stream_iter_t;
    logic [23:0] stream_color_address;
    logic [23:0] stream_address_pipe [0:5];
    logic [23:0] stream_aux_address;
    logic [23:0] stream_aux_address_pipe [0:5];
    logic [5:0] stream_address_valid;
    logic [STREAM_FIFO_BITS-1:0] stream_fifo_head, stream_fifo_tail;
    logic [STREAM_FIFO_BITS:0] stream_fifo_count, stream_pending_count;
    logic stream_fifo_accepted [0:STREAM_FIFO_DEPTH-1];
    logic stream_fifo_chroma_failed [0:STREAM_FIFO_DEPTH-1];
    logic stream_fifo_depth_failed [0:STREAM_FIFO_DEPTH-1];
    logic stream_fifo_alpha_failed [0:STREAM_FIFO_DEPTH-1];
    logic stream_fifo_color_write [0:STREAM_FIFO_DEPTH-1];
    logic [15:0] stream_fifo_color_value [0:STREAM_FIFO_DEPTH-1];
    logic [23:0] stream_fifo_address [0:STREAM_FIFO_DEPTH-1];
    logic stream_fifo_aux_write [0:STREAM_FIFO_DEPTH-1];
    logic [15:0] stream_fifo_aux_value [0:STREAM_FIFO_DEPTH-1];
    logic [23:0] stream_fifo_aux_address [0:STREAM_FIFO_DEPTH-1];
    logic stream_output, stream_retire_valid, stream_retire_fire;

    logic [STREAM_FIFO_BITS-1:0] stream_join_head, stream_join_tail;
    logic [STREAM_FIFO_BITS:0] stream_join_count;
    logic [9:0] stream_join_x [0:STREAM_FIFO_DEPTH-1];
    logic [9:0] stream_join_y [0:STREAM_FIFO_DEPTH-1];
    logic stream_join_stipple [0:STREAM_FIFO_DEPTH-1];
    logic [23:0] stream_join_rgb [0:STREAM_FIFO_DEPTH-1];
    logic [7:0] stream_join_alpha [0:STREAM_FIFO_DEPTH-1];
    logic signed [47:0] stream_join_z [0:STREAM_FIFO_DEPTH-1];
    logic signed [63:0] stream_join_w [0:STREAM_FIFO_DEPTH-1];
    logic [23:0] stream_join_address [0:STREAM_FIFO_DEPTH-1];
    logic [23:0] stream_join_aux_address [0:STREAM_FIFO_DEPTH-1];
    logic stream_texture_push, stream_texture_pop;

    logic [9:0] pipeline_pixel_x, pipeline_pixel_y;
    logic pipeline_stipple;
    logic [23:0] pipeline_iter_rgb;
    logic [7:0] pipeline_iter_alpha;
    logic signed [47:0] pipeline_iter_z;
    logic signed [63:0] pipeline_iter_w;
    logic [23:0] pipeline_texture_rgb;
    logic [7:0] pipeline_texture_alpha;
    logic [15:0] pipeline_destination_color, pipeline_destination_aux;

    assign current_stipple = stipple_value;
    assign current_stipple_generation = observed_stipple_generation;

    sst1_fb_read_cache #(
        .MSHR_COUNT(8), .PREFETCH_LINES(FB_READ_PREFETCH_LINES),
        .TAG_PREFIX(4'h4),
        .MEMORY_SOURCE(SST1_MEM_FB_COLOR)
    ) color_read_cache (
        .clk, .reset_n, .memory_enable, .memory_base, .memory_size,
        .lookup_valid(fb_color_lookup_valid),
        .lookup_ready(fb_color_lookup_ready),
        .lookup_address(stream_color_address),
        .lookup_id({2'd0, stream_join_tail}),
        .response_valid(fb_color_response_valid),
        .response_ready(fb_color_response_ready),
        .response_data(fb_color_response_data),
        .response_id(), .response_error(),
        .invalidate_valid(fb_color_invalidate_valid),
        .invalidate_address(fb_color_invalidate_address),
        .invalidate_all(fb_invalidate_all),
        .mem_req_valid(fb_color_cache_mem_req_valid),
        .mem_req_ready(fb_color_cache_mem_req_ready),
        .mem_req(fb_color_cache_mem_req),
        .mem_rsp_valid(fb_color_cache_mem_rsp_valid),
        .mem_rsp_ready(fb_color_cache_mem_rsp_ready), .mem_rsp,
        .idle(fb_color_cache_idle), .perf_events(fb_color_cache_perf)
    );

    sst1_fb_read_cache #(
        .MSHR_COUNT(8), .PREFETCH_LINES(FB_READ_PREFETCH_LINES),
        .TAG_PREFIX(4'h5),
        .MEMORY_SOURCE(SST1_MEM_FB_AUX)
    ) aux_read_cache (
        .clk, .reset_n, .memory_enable, .memory_base, .memory_size,
        .lookup_valid(fb_aux_lookup_valid),
        .lookup_ready(fb_aux_lookup_ready),
        .lookup_address(stream_aux_address),
        .lookup_id({2'd0, stream_join_tail}),
        .response_valid(fb_aux_response_valid),
        .response_ready(fb_aux_response_ready),
        .response_data(fb_aux_response_data),
        .response_id(), .response_error(),
        .invalidate_valid(fb_aux_invalidate_valid),
        .invalidate_address(fb_aux_invalidate_address),
        .invalidate_all(fb_invalidate_all),
        .mem_req_valid(fb_aux_cache_mem_req_valid),
        .mem_req_ready(fb_aux_cache_mem_req_ready),
        .mem_req(fb_aux_cache_mem_req),
        .mem_rsp_valid(fb_aux_cache_mem_rsp_valid),
        .mem_rsp_ready(fb_aux_cache_mem_rsp_ready), .mem_rsp,
        .idle(fb_aux_cache_idle), .perf_events(fb_aux_cache_perf)
    );

    sst1_pixel_pipeline pixel_pipeline (
        .clk,
        .reset_n,
        .input_valid(stream_output ? stream_pipeline_fire :
                                           state == ST_TRI_EVALUATE),
        .input_ready(pixel_input_ready),
        .output_valid(pixel_output_valid),
        .pixel_x(pipeline_pixel_x),
        .pixel_y(pipeline_pixel_y),
        .lfb_pixel(pixel_source_lfb),
        .stipple_pass(pipeline_stipple),
        .lfb_rgb(lfb_pipeline_rgb[lfb_step[0]]),
        .lfb_alpha(lfb_pipeline_alpha[lfb_step[0]]),
        .lfb_depth(lfb_pipeline_depth[lfb_step[0]]),
        .iter_rgb(pipeline_iter_rgb),
        .iter_alpha(pipeline_iter_alpha),
        .iter_z(pipeline_iter_z),
        .iter_w(pipeline_iter_w),
        .texture_rgb(pipeline_texture_rgb),
        .texture_alpha(pipeline_texture_alpha),
        .destination_color(pipeline_destination_color),
        .destination_aux(pipeline_destination_aux),
        .state(work),
        .accepted(pixel_accepted),
        .chroma_failed(pixel_chroma_failed),
        .depth_failed(pixel_depth_failed),
        .alpha_failed(pixel_alpha_failed),
        .color_write(pixel_color_write),
        .aux_write(pixel_aux_write),
        .color_value(pixel_color_value),
        .aux_value(pixel_aux_value),
        .color_before_fog(), .color_after_fog(), .alpha_value(),
        .depth_value(), .w_depth()
    );

    sst1_fb_write_combine color_write_combiner (
        .clk, .reset_n,
        .update_valid(color_combiner_update_valid),
        .update_ready(color_update_ready),
        .update_address(color_combiner_update_address),
        .update_data(color_combiner_update_data), .update_enable(2'b11),
        .update_source(SST1_MEM_FB_COLOR),
        .flush_valid(write_flush_valid), .flush_ready(),
        .probe_address(color_probe_address), .probe_hit(color_probe_hit),
        .probe_data(color_probe_data), .memory_base,
        .mem_req_valid(color_mem_req_valid),
        .mem_req_ready(color_mem_req_ready), .mem_req(color_mem_req),
        .idle(color_write_idle)
    );

    sst1_fb_write_combine aux_write_combiner (
        .clk, .reset_n,
        .update_valid(aux_combiner_update_valid),
        .update_ready(aux_update_ready),
        .update_address(aux_combiner_update_address),
        .update_data(aux_combiner_update_data), .update_enable(2'b11),
        .update_source(SST1_MEM_FB_AUX),
        .flush_valid(write_flush_valid), .flush_ready(),
        .probe_address(aux_probe_address), .probe_hit(aux_probe_hit),
        .probe_data(aux_probe_data),
        .memory_base, .mem_req_valid(aux_mem_req_valid),
        .mem_req_ready(aux_mem_req_ready), .mem_req(aux_mem_req),
        .idle(aux_write_idle)
    );

    function automatic logic [15:0] lfb_565(
        input logic [15:0] value,
        input logic [1:0] channels,
        input logic shifted_555
    );
        logic [4:0] red;
        logic [4:0] green;
        logic [4:0] blue;
        begin
            if (shifted_555 || channels[1]) begin
                red = channels[0] ? value[5:1] : value[15:11];
                green = value[10:6];
                blue = channels[0] ? value[15:11] : value[5:1];
            end else begin
                red = channels[0] ? value[4:0] : value[14:10];
                green = value[9:5];
                blue = channels[0] ? value[14:10] : value[4:0];
            end
            return {red, green, green[4], blue};
        end
    endfunction

    function automatic logic [23:0] lfb_rgb888(
        input logic [31:0] value,
        input logic [1:0] channels
    );
        logic [7:0] red;
        logic [7:0] green;
        logic [7:0] blue;
        begin
            green = channels[1] ? value[23:16] : value[15:8];
            if (channels[1]) begin
                red = channels[0] ? value[15:8] : value[31:24];
                blue = channels[0] ? value[31:24] : value[15:8];
            end else begin
                red = channels[0] ? value[7:0] : value[23:16];
                blue = channels[0] ? value[23:16] : value[7:0];
            end
            return {red, green, blue};
        end
    endfunction

    function automatic logic [23:0] expand_rgb565(input logic [15:0] value);
        return {{value[15:11], value[15:13]},
                {value[10:5], value[10:9]},
                {value[4:0], value[4:2]}};
    endfunction

    function automatic logic [15:0] rgb888_to_565(input logic [23:0] value);
        return {value[23:19], value[15:10], value[7:3]};
    endfunction

    function automatic logic [7:0] clamp_color(input logic signed [47:0] value);
        logic signed [47:0] integer_value;
        begin
            integer_value = value >>> 12;
            if (integer_value < 0)
                return 8'd0;
            if (integer_value > 255)
                return 8'd255;
            return integer_value[7:0];
        end
    endfunction

    function automatic logic signed [16:0] min3(
        input logic signed [16:0] a,
        input logic signed [16:0] b,
        input logic signed [16:0] c
    );
        logic signed [16:0] value;
        begin
            value = a < b ? a : b;
            return value < c ? value : c;
        end
    endfunction

    function automatic logic signed [16:0] max3(
        input logic signed [16:0] a,
        input logic signed [16:0] b,
        input logic signed [16:0] c
    );
        logic signed [16:0] value;
        begin
            value = a > b ? a : b;
            return value > c ? value : c;
        end
    endfunction

    always_comb begin
        row_width = {20'd0, work.fbi_init1[7:4]} << 7;
        buffer_size = {15'd0, work.fbi_init2[19:11]} << 12;
        front_base = displayed_buffer[0] ? buffer_size : 24'd0;
        back_base = displayed_buffer[0] ? 24'd0 : buffer_size;
        aux_base = buffer_size << 1;
        draw_base = work.fbz_mode[15:14] == 2'd1 ? back_base : front_base;
        sample_x = (raster_x <<< 4) + 8;
        sample_y = (raster_y <<< 4) + 8;
        edge_ab = ((sample_x - ax) * (by - ay)) -
                  ((sample_y - ay) * (bx - ax));
        edge_bc = ((sample_x - bx) * (cy - by)) -
                  ((sample_y - by) * (cx - bx));
        edge_ca = ((sample_x - cx) * (ay - cy)) -
                  ((sample_y - cy) * (ax - cx));
        triangle_inside = triangle_negative ?
                          (edge_ab >= 0 && edge_bc >= 0 && edge_ca >= 0) :
                          (edge_ab <= 0 && edge_bc <= 0 && edge_ca <= 0);
        need_color_read = work.alpha_mode[4];
        need_aux_read = work.fbz_mode[4] ||
                        (work.alpha_mode[4] && work.fbz_mode[18]);
        stream_textured = work.fbz_color_path[27];
        stream_needs_join = stream_textured || need_color_read || need_aux_read;
        stream_fast_path = work.fbz_mode[9] || work.fbz_mode[10];
        stream_pixel_eligible = triangle_inside &&
            (!work.fbz_mode[0] ||
             (raster_x >= $signed({1'b0, work.clip_left_right[25:16]}) &&
              raster_x <  $signed({1'b0, work.clip_left_right[9:0]}) &&
              raster_y >= $signed({1'b0, work.clip_low_y_high_y[25:16]}) &&
              raster_y <  $signed({1'b0, work.clip_low_y_high_y[9:0]})));
        stream_output = state == ST_TRI_STREAM ||
                        state == ST_TRI_STREAM_DRAIN;
        stream_dispatch = stream_output && stream_issue_valid &&
            (!stream_textured || texture_sample_ready) &&
            (!need_color_read || fb_color_lookup_ready) &&
            (!need_aux_read || fb_aux_lookup_ready);
        stream_issue_slot_ready = !stream_issue_valid ||
            (stream_needs_join ? stream_dispatch : pixel_input_ready);
        stream_step = state == ST_TRI_STREAM && stream_issue_slot_ready &&
                      (!stream_pixel_eligible ||
                       stream_pending_count < STREAM_FIFO_DEPTH);
        stream_issue = stream_step && stream_pixel_eligible;
        stream_texture_push = stream_dispatch && stream_needs_join;
        stream_texture_pop = stream_output && stream_needs_join &&
            stream_join_count != 0 && pixel_input_ready &&
            (!stream_textured || texture_result_valid) &&
            (!need_color_read || fb_color_response_valid) &&
            (!need_aux_read || fb_aux_response_valid);
        stream_pipeline_fire = stream_needs_join ? stream_texture_pop :
            (stream_issue_valid && pixel_input_ready);
        stream_retire_valid = stream_fifo_count != 0;
        stream_retire_fire = stream_retire_valid &&
            (!stream_fifo_color_write[stream_fifo_head] || color_update_ready) &&
            (!stream_fifo_aux_write[stream_fifo_head] || aux_update_ready);

        pipeline_pixel_x = pixel_source_lfb ? lfb_pixel_x + lfb_step[0] :
                           stream_output && stream_needs_join ?
                               stream_join_x[stream_join_head] :
                           stream_output ? stream_pixel_x : raster_x[9:0];
        pipeline_pixel_y = pixel_source_lfb ? lfb_pixel_y :
                           stream_output && stream_needs_join ?
                               stream_join_y[stream_join_head] :
                           stream_output ? stream_pixel_y : raster_y[9:0];
        pipeline_stipple = stream_output && stream_needs_join ?
                               stream_join_stipple[stream_join_head] :
                           stream_output ? stream_stipple :
                                           pixel_stipple_latched;
        pipeline_iter_rgb = stream_output && stream_needs_join ?
                                stream_join_rgb[stream_join_head] :
                            stream_output ? stream_iter_rgb :
                                            triangle_iter_rgb;
        pipeline_iter_alpha = stream_output && stream_needs_join ?
                                  stream_join_alpha[stream_join_head] :
                              stream_output ? stream_iter_alpha :
                                              triangle_iter_alpha;
        pipeline_iter_z = stream_output && stream_needs_join ?
                              stream_join_z[stream_join_head] :
                          stream_output ? stream_iter_z : triangle_iter_z;
        pipeline_iter_w = stream_output && stream_needs_join ?
                              stream_join_w[stream_join_head] :
                          stream_output ? stream_iter_w : triangle_iter_w;
        pipeline_texture_rgb = stream_output && stream_textured ?
                                   texture_result.rgb : triangle_texture_rgb;
        pipeline_texture_alpha = stream_output && stream_textured ?
                                     texture_result.alpha :
                                     triangle_texture_alpha;
        pipeline_destination_color = stream_output && need_color_read ?
                                     fb_color_response_data : destination_color;
        pipeline_destination_aux = stream_output && need_aux_read ?
                                   fb_aux_response_data : destination_aux;
        if (stream_output && need_color_read) begin
            if (color_probe_hit[0])
                pipeline_destination_color[7:0] = color_probe_data[7:0];
            if (color_probe_hit[1])
                pipeline_destination_color[15:8] = color_probe_data[15:8];
        end
        if (stream_output && need_aux_read) begin
            if (aux_probe_hit[0])
                pipeline_destination_aux[7:0] = aux_probe_data[7:0];
            if (aux_probe_hit[1])
                pipeline_destination_aux[15:8] = aux_probe_data[15:8];
        end
        if (!work.fbz_mode[2])
            stipple_candidate = 1'b1;
        else if (work.fbz_mode[12])
            stipple_candidate = stipple_value[
                {pixel_source_lfb ? lfb_pixel_y[1:0] : raster_y[1:0],
                 ~(pixel_source_lfb ? lfb_pixel_x[2:0] + lfb_step[0] :
                                      raster_x[2:0])}];
        else
            stipple_candidate = stipple_value[31];

        write_combiner_idle = color_write_idle && aux_write_idle &&
                              fb_color_cache_idle && fb_aux_cache_idle;
        command_ready = state == ST_IDLE && memory_enable &&
                        write_combiner_idle;
        lfb_ready = state == ST_IDLE && memory_enable && write_combiner_idle;
        idle = state == ST_IDLE && write_combiner_idle;
        lfb_read_rsp_valid = state == ST_LFB_READ_RSP;
        legacy_mem_rsp_ready = state == ST_LFB_READ_WAIT ||
                               (state == ST_TRI_PREFETCH &&
                                ((mem_rsp.tag == 8'h20 && !triangle_aux_done) ||
                                 (mem_rsp.tag == 8'h21 && !triangle_color_done)));
        fb_color_cache_mem_rsp_valid = mem_rsp_valid &&
                                       mem_rsp.tag[7:4] == 4'h4;
        fb_aux_cache_mem_rsp_valid = mem_rsp_valid &&
                                     mem_rsp.tag[7:4] == 4'h5;
        mem_rsp_ready = mem_rsp.tag[7:4] == 4'h4 ?
                            fb_color_cache_mem_rsp_ready :
                        mem_rsp.tag[7:4] == 4'h5 ?
                            fb_aux_cache_mem_rsp_ready : legacy_mem_rsp_ready;
        texture_sample_valid = stream_output && stream_textured ?
                               stream_issue_valid &&
                                   (!need_color_read || fb_color_lookup_ready) &&
                                   (!need_aux_read || fb_aux_lookup_ready) :
                               state == ST_TRI_PREFETCH &&
                                   triangle_texture_request_pending;
        texture_sample = '0;
        texture_sample.pixel_x = stream_output ? stream_pixel_x : raster_x[9:0];
        texture_sample.pixel_y = stream_output ? stream_pixel_y : raster_y[9:0];
        texture_sample.s_over_w = stream_output ? stream_iter_s : triangle_iter_s;
        texture_sample.t_over_w = stream_output ? stream_iter_t : triangle_iter_t;
        texture_sample.one_over_w = stream_output ? stream_iter_w : triangle_iter_w;
        texture_sample.dsdx = work.triangle_parameters[19];
        texture_sample.dtdx = work.triangle_parameters[20];
        texture_sample.dsdy = work.triangle_parameters[27];
        texture_sample.dtdy = work.triangle_parameters[28];
        texture_sample.state = work;
        texture_result_ready = stream_output && stream_textured ?
                               stream_join_count != 0 && pixel_input_ready &&
                                   (!need_color_read || fb_color_response_valid) &&
                                   (!need_aux_read || fb_aux_response_valid) :
                               state == ST_TRI_PREFETCH && !triangle_texture_done;
        fb_color_lookup_valid = stream_output && need_color_read &&
            stream_issue_valid && (!stream_textured || texture_sample_ready) &&
            (!need_aux_read || fb_aux_lookup_ready);
        fb_aux_lookup_valid = stream_output && need_aux_read &&
            stream_issue_valid && (!stream_textured || texture_sample_ready) &&
            (!need_color_read || fb_color_lookup_ready);
        fb_color_response_ready = stream_output && need_color_read &&
            stream_join_count != 0 && pixel_input_ready &&
            (!stream_textured || texture_result_valid) &&
            (!need_aux_read || fb_aux_response_valid);
        fb_aux_response_ready = stream_output && need_aux_read &&
            stream_join_count != 0 && pixel_input_ready &&
            (!stream_textured || texture_result_valid) &&
            (!need_color_read || fb_color_response_valid);

        active_write_valid = 1'b0;
        active_write_address = 24'd0;
        active_write_data = 16'd0;
        if (state == ST_LFB_WRITE) begin
            case (lfb_step)
                3'd0: begin
                    active_write_valid = lfb_write_color[0];
                    active_write_address = lfb_color_address;
                    active_write_data = lfb_color[0];
                end
                3'd1: begin
                    active_write_valid = lfb_write_color[1];
                    active_write_address = lfb_color_address + 2'd2;
                    active_write_data = lfb_color[1];
                end
                3'd2: begin
                    active_write_valid = lfb_write_aux[0];
                    active_write_address = lfb_aux_address;
                    active_write_data = lfb_aux[0];
                end
                default: begin
                    active_write_valid = lfb_write_aux[1];
                    active_write_address = lfb_aux_address + 2'd2;
                    active_write_data = lfb_aux[1];
                end
            endcase
        end else if (state == ST_FILL) begin
            active_write_valid = !fill_color_done ? work.fbz_mode[9] : work.fbz_mode[10];
            active_write_address = (!fill_color_done ? draw_base : aux_base) +
                                   fill_y * row_width + fill_x * 2;
            active_write_data = !fill_color_done ? rgb888_to_565(work.color1[23:0]) :
                                                   work.za_color[15:0];
        end else if (state == ST_TRI_WRITE_COLOR) begin
            active_write_valid = pixel_color_write;
            active_write_address = triangle_color_address;
            active_write_data = pixel_color_value;
        end else if (state == ST_TRI_WRITE_AUX) begin
            active_write_valid = pixel_aux_write;
            active_write_address = triangle_aux_address;
            active_write_data = pixel_aux_value;
        end

        active_write_aux = state == ST_TRI_WRITE_AUX ||
                           (state == ST_FILL && fill_color_done) ||
                           (state == ST_LFB_WRITE && lfb_step >= 3'd2);
        write_update_ready = active_write_aux ? aux_update_ready :
                                                color_update_ready;
        write_update_valid = active_write_valid && memory_enable &&
                             active_write_address + 2 <= memory_size;
        write_update_fire = write_update_valid && write_update_ready;
        color_combiner_update_valid = stream_output ?
            stream_retire_valid &&
                stream_fifo_color_write[stream_fifo_head] :
            write_update_valid && !active_write_aux;
        aux_combiner_update_valid = stream_output ?
            stream_retire_valid && stream_fifo_aux_write[stream_fifo_head] :
            write_update_valid && active_write_aux;
        color_combiner_update_address = stream_output ?
            stream_fifo_address[stream_fifo_head] : active_write_address;
        aux_combiner_update_address = stream_output ?
            stream_fifo_aux_address[stream_fifo_head] : active_write_address;
        color_combiner_update_data = stream_output ?
            stream_fifo_color_value[stream_fifo_head] : active_write_data;
        aux_combiner_update_data = stream_output ?
            stream_fifo_aux_value[stream_fifo_head] : active_write_data;
        // A triangle visits a pixel only once. Keep its fetched 16-byte lines
        // resident while adjacent pixels consume the other lanes; both read
        // caches are cleared before accepting the next render command.
        fb_color_invalidate_valid = !stream_output && write_update_fire &&
                                    !active_write_aux;
        fb_aux_invalidate_valid = !stream_output && write_update_fire &&
                                  active_write_aux;
        fb_color_invalidate_address = stream_output ?
            stream_fifo_address[stream_fifo_head] : active_write_address;
        fb_aux_invalidate_address = stream_output ?
            stream_fifo_aux_address[stream_fifo_head] : active_write_address;
        write_flush_valid = state == ST_WRITE_DRAIN;
        color_probe_address = stream_output && stream_needs_join ?
                              stream_join_address[stream_join_head] :
                              state == ST_TRI_PREFETCH ?
                                  triangle_color_address : lfb_read_address;
        aux_probe_address = stream_output && stream_needs_join ?
                            stream_join_aux_address[stream_join_head] :
                            triangle_aux_address;
        if (state == ST_TRI_PREFETCH && mem_rsp.tag == 8'h20) begin
            write_probe_hit = aux_probe_hit;
            write_probe_data = aux_probe_data;
        end else begin
            write_probe_hit = color_probe_hit;
            write_probe_data = color_probe_data;
        end

        color_span_hit = color_span_valid &&
                         color_span_line == triangle_color_address[23:4];
        aux_span_hit = aux_span_valid &&
                       aux_span_line == triangle_aux_address[23:4];
        cached_color_value = color_span_hit ?
            16'(color_span_data >> (triangle_color_address[3:0] * 8)) : 16'd0;
        cached_aux_value = aux_span_hit ?
            16'(aux_span_data >> (triangle_aux_address[3:0] * 8)) : 16'd0;
        if (color_probe_hit[0])
            cached_color_value[7:0] = color_probe_data[7:0];
        if (color_probe_hit[1])
            cached_color_value[15:8] = color_probe_data[15:8];
        if (aux_probe_hit[0])
            cached_aux_value[7:0] = aux_probe_data[7:0];
        if (aux_probe_hit[1])
            cached_aux_value[15:8] = aux_probe_data[15:8];
        color_value_ready = color_span_hit || &color_probe_hit;
        aux_value_ready = aux_span_hit || &aux_probe_hit;

        read_request = '0;
        read_request.beats = 8'd1;
        read_request.order_class = SST1_ORDER_SOURCE;
        read_request.write = 1'b0;
        read_request_valid = 1'b0;
        if (state == ST_LFB_READ_REQ) begin
            read_request_valid = 1'b1;
            read_request.addr = memory_base +
                                {16'd0, lfb_read_address[23:4], 4'd0};
            read_request.tag = 8'h10;
            read_request.source = SST1_MEM_FB_COLOR;
        end else if (state == ST_TRI_PREFETCH &&
                     triangle_aux_request_pending && !aux_value_ready) begin
            read_request_valid = 1'b1;
            read_request.addr = memory_base +
                                {16'd0, triangle_aux_address[23:4], 4'd0};
            read_request.tag = 8'h20;
            read_request.source = SST1_MEM_FB_AUX;
        end else if (state == ST_TRI_PREFETCH &&
                     triangle_color_request_pending && !color_value_ready) begin
            read_request_valid = 1'b1;
            read_request.addr = memory_base +
                                {16'd0, triangle_color_address[23:4], 4'd0};
            read_request.tag = 8'h21;
            read_request.source = SST1_MEM_FB_COLOR;
        end
        request_in_range = (read_request.addr >= memory_base) &&
                           ((read_request.addr - memory_base) <
                            {16'd0, memory_size});
        if (!request_in_range)
            read_request_valid = 1'b0;

        mem_arb_select_valid = 1'b1;
        mem_arb_select = MEM_ARB_COLOR_WRITE;
        mem_arb_request = color_mem_req;
        if (!color_mem_req_valid) begin
            mem_arb_select = MEM_ARB_AUX_WRITE;
            mem_arb_request = aux_mem_req;
            if (!aux_mem_req_valid) begin
                mem_arb_select = MEM_ARB_AUX_READ;
                mem_arb_request = fb_aux_cache_mem_req;
                if (!fb_aux_cache_mem_req_valid) begin
                    mem_arb_select = MEM_ARB_COLOR_READ;
                    mem_arb_request = fb_color_cache_mem_req;
                    if (!fb_color_cache_mem_req_valid) begin
                        mem_arb_select = MEM_ARB_LEGACY_READ;
                        mem_arb_request = read_request;
                        mem_arb_select_valid = read_request_valid;
                    end
                end
            end
        end

        mem_req_valid = mem_hold_valid || mem_arb_select_valid;
        mem_req = mem_hold_valid ? mem_hold_request : mem_arb_request;
        color_mem_req_ready = mem_req_ready &&
            ((mem_hold_valid && mem_hold_source == MEM_ARB_COLOR_WRITE) ||
             (!mem_hold_valid && mem_arb_select_valid &&
              mem_arb_select == MEM_ARB_COLOR_WRITE));
        aux_mem_req_ready = mem_req_ready &&
            ((mem_hold_valid && mem_hold_source == MEM_ARB_AUX_WRITE) ||
             (!mem_hold_valid && mem_arb_select_valid &&
              mem_arb_select == MEM_ARB_AUX_WRITE));
        fb_aux_cache_mem_req_ready = mem_req_ready &&
            ((mem_hold_valid && mem_hold_source == MEM_ARB_AUX_READ) ||
             (!mem_hold_valid && mem_arb_select_valid &&
              mem_arb_select == MEM_ARB_AUX_READ));
        fb_color_cache_mem_req_ready = mem_req_ready &&
            ((mem_hold_valid && mem_hold_source == MEM_ARB_COLOR_READ) ||
             (!mem_hold_valid && mem_arb_select_valid &&
              mem_arb_select == MEM_ARB_COLOR_READ));
        legacy_mem_req_ready = mem_req_ready &&
            ((mem_hold_valid && mem_hold_source == MEM_ARB_LEGACY_READ) ||
             (!mem_hold_valid && mem_arb_select_valid &&
              mem_arb_select == MEM_ARB_LEGACY_READ));
        request_fire = read_request_valid && legacy_mem_req_ready;

        perf_events = '0;
        perf_events.raster_candidate = stream_step;
        perf_events.pixel_issue = stream_issue;
        perf_events.pixel_retire = stream_retire_fire;
        perf_events.join_allocate = stream_texture_push;
        perf_events.join_complete = stream_texture_pop;
        perf_events.pixel_pass = stream_retire_fire &&
                                 stream_fifo_accepted[stream_fifo_head];
        perf_events.chroma_fail = stream_retire_fire &&
                                  stream_fifo_chroma_failed[stream_fifo_head];
        perf_events.depth_fail = stream_retire_fire &&
                                 stream_fifo_depth_failed[stream_fifo_head];
        perf_events.alpha_fail = stream_retire_fire &&
                                 stream_fifo_alpha_failed[stream_fifo_head];
        perf_events.color_read = fb_color_lookup_valid &&
                                 fb_color_lookup_ready;
        perf_events.aux_read = fb_aux_lookup_valid && fb_aux_lookup_ready;
        perf_events.color_update = color_combiner_update_valid &&
                                   color_update_ready;
        perf_events.aux_update = aux_combiner_update_valid && aux_update_ready;
        perf_events.color_drain = color_mem_req_valid && color_mem_req_ready;
        perf_events.aux_drain = aux_mem_req_valid && aux_mem_req_ready;
        perf_events.color_forward = stream_texture_pop && need_color_read &&
                                    |color_probe_hit;
        perf_events.aux_forward = stream_texture_pop && need_aux_read &&
                                  |aux_probe_hit;
        perf_events.pending_occupancy = 7'(stream_pending_count);
        perf_events.join_occupancy = 7'(stream_join_count);
        perf_events.color_cache = fb_color_cache_perf;
        perf_events.aux_cache = fb_aux_cache_perf;
    end

    always_ff @(posedge clk) begin : engine
        logic [31:0] transformed;
        logic [21:0] mapped_offset;
        logic [10:0] x_byte;
        logic [10:0] y_value;
        logic [3:0] format;
        logic [15:0] low_pixel;
        logic [15:0] high_pixel;
        logic [23:0] low_rgb;
        logic [23:0] high_rgb;
        logic [7:0] low_alpha;
        logic [7:0] high_alpha;
        logic [15:0] low_depth;
        logic [15:0] high_depth;
        logic [1:0] pipeline_valid;
        logic signed [47:0] red_value;
        logic signed [47:0] green_value;
        logic signed [47:0] blue_value;
        logic signed [47:0] z_value;
        logic signed [47:0] alpha_value;
        logic signed [63:0] w_value;
        logic signed [63:0] s_value;
        logic signed [63:0] t_value;
        logic signed [17:0] dx_subpixel;
        logic signed [17:0] dy_subpixel;
        logic [7:0] red;
        logic [7:0] green;
        logic [7:0] blue;
        logic [31:0] read_word;
        integer stream_index;

        if (!reset_n) begin
            state <= ST_IDLE;
            work <= '0;
            lfb_read_rsp_data <= '0;
            lfb_read_rsp_error <= 1'b0;
            pixels_in <= '0;
            chroma_fail <= '0;
            zfunc_fail <= '0;
            afunc_fail <= '0;
            pixels_out <= '0;
            stipple_value <= '0;
            observed_stipple_generation <= '0;
            pixel_source_lfb <= 1'b0;
            lfb_pipeline_valid <= '0;
            destination_color <= '0;
            destination_aux <= '0;
            pixel_stipple_latched <= 1'b1;
            last_alpha <= 32'd0;
            last_w <= 32'd0;
            triangle_texture_rgb <= 24'd0;
            triangle_texture_alpha <= 8'd0;
            triangle_texture_request_pending <= 1'b0;
            triangle_texture_done <= 1'b0;
            triangle_aux_request_pending <= 1'b0;
            triangle_aux_done <= 1'b0;
            triangle_color_request_pending <= 1'b0;
            triangle_color_done <= 1'b0;
            mem_hold_valid <= 1'b0;
            mem_hold_source <= MEM_ARB_LEGACY_READ;
            mem_hold_request <= '0;
            color_span_valid <= 1'b0;
            aux_span_valid <= 1'b0;
            color_span_line <= '0;
            aux_span_line <= '0;
            color_span_data <= '0;
            aux_span_data <= '0;
            stream_issue_valid <= 1'b0;
            stream_row_started <= 1'b0;
            stream_address_valid <= '0;
            stream_fifo_head <= '0;
            stream_fifo_tail <= '0;
            stream_fifo_count <= '0;
            stream_pending_count <= '0;
            stream_pixel_x <= '0;
            stream_pixel_y <= '0;
            stream_stipple <= 1'b1;
            stream_iter_rgb <= '0;
            stream_iter_alpha <= '0;
            stream_iter_z <= '0;
            stream_iter_w <= '0;
            stream_iter_s <= '0;
            stream_iter_t <= '0;
            stream_color_address <= '0;
            stream_aux_address <= '0;
            stream_join_head <= '0;
            stream_join_tail <= '0;
            stream_join_count <= '0;
            fb_invalidate_all <= 1'b0;
            for (stream_index = 0; stream_index < 6;
                 stream_index = stream_index + 1)
                stream_address_pipe[stream_index] <= '0;
            for (stream_index = 0; stream_index < 6;
                 stream_index = stream_index + 1)
                stream_aux_address_pipe[stream_index] <= '0;
        end else begin
            // A newly accepted render command cannot issue framebuffer reads
            // until after setup.  Register the command-boundary invalidation
            // so the cache-valid array is not driven through the complete FBI
            // idle/ready path in a single 100 MHz cycle.
            fb_invalidate_all <= command_valid && command_ready;
            if (stream_issue_slot_ready)
                stream_issue_valid <= stream_issue;
            stream_address_valid <= {stream_address_valid[4:0],
                                     stream_pipeline_fire};
            stream_address_pipe[5] <= stream_address_pipe[4];
            stream_address_pipe[4] <= stream_address_pipe[3];
            stream_address_pipe[3] <= stream_address_pipe[2];
            stream_address_pipe[2] <= stream_address_pipe[1];
            stream_address_pipe[1] <= stream_address_pipe[0];
            stream_aux_address_pipe[5] <= stream_aux_address_pipe[4];
            stream_aux_address_pipe[4] <= stream_aux_address_pipe[3];
            stream_aux_address_pipe[3] <= stream_aux_address_pipe[2];
            stream_aux_address_pipe[2] <= stream_aux_address_pipe[1];
            stream_aux_address_pipe[1] <= stream_aux_address_pipe[0];
            if (stream_pipeline_fire)
                stream_address_pipe[0] <= stream_needs_join ?
                    stream_join_address[stream_join_head] :
                    stream_color_address;
            if (stream_pipeline_fire)
                stream_aux_address_pipe[0] <= stream_needs_join ?
                    stream_join_aux_address[stream_join_head] :
                    stream_aux_address;

            if (stream_texture_push) begin
                stream_join_x[stream_join_tail] <= stream_pixel_x;
                stream_join_y[stream_join_tail] <= stream_pixel_y;
                stream_join_stipple[stream_join_tail] <= stream_stipple;
                stream_join_rgb[stream_join_tail] <= stream_iter_rgb;
                stream_join_alpha[stream_join_tail] <= stream_iter_alpha;
                stream_join_z[stream_join_tail] <= stream_iter_z;
                stream_join_w[stream_join_tail] <= stream_iter_w;
                stream_join_address[stream_join_tail] <= stream_color_address;
                stream_join_aux_address[stream_join_tail] <= stream_aux_address;
                stream_join_tail <= stream_join_tail + 1'b1;
            end
            if (stream_texture_pop)
                stream_join_head <= stream_join_head + 1'b1;
            case ({stream_texture_push, stream_texture_pop})
                2'b10: stream_join_count <= stream_join_count + 1'b1;
                2'b01: stream_join_count <= stream_join_count - 1'b1;
                default: stream_join_count <= stream_join_count;
            endcase

            if (stream_output && pixel_output_valid) begin
                stream_fifo_accepted[stream_fifo_tail] <= pixel_accepted;
                stream_fifo_chroma_failed[stream_fifo_tail] <=
                    pixel_chroma_failed;
                stream_fifo_depth_failed[stream_fifo_tail] <=
                    pixel_depth_failed;
                stream_fifo_alpha_failed[stream_fifo_tail] <=
                    pixel_alpha_failed;
                stream_fifo_color_write[stream_fifo_tail] <=
                    pixel_color_write;
                stream_fifo_color_value[stream_fifo_tail] <=
                    pixel_color_value;
                stream_fifo_address[stream_fifo_tail] <=
                    stream_address_pipe[5];
                stream_fifo_aux_write[stream_fifo_tail] <= pixel_aux_write;
                stream_fifo_aux_value[stream_fifo_tail] <= pixel_aux_value;
                stream_fifo_aux_address[stream_fifo_tail] <=
                    stream_aux_address_pipe[5];
                stream_fifo_tail <= stream_fifo_tail + 1'b1;
            end
            if (stream_retire_fire) begin
                if (stream_fifo_chroma_failed[stream_fifo_head])
                    chroma_fail <= {8'd0, chroma_fail[23:0] + 1'b1};
                if (stream_fifo_depth_failed[stream_fifo_head])
                    zfunc_fail <= {8'd0, zfunc_fail[23:0] + 1'b1};
                if (stream_fifo_alpha_failed[stream_fifo_head])
                    afunc_fail <= {8'd0, afunc_fail[23:0] + 1'b1};
                if (stream_fifo_accepted[stream_fifo_head])
                    pixels_out <= {8'd0, pixels_out[23:0] + 1'b1};
                if (stream_fifo_color_write[stream_fifo_head])
                    color_span_valid <= 1'b0;
                if (stream_fifo_aux_write[stream_fifo_head])
                    aux_span_valid <= 1'b0;
                stream_fifo_head <= stream_fifo_head + 1'b1;
            end
            case ({stream_output && pixel_output_valid, stream_retire_fire})
                2'b10: stream_fifo_count <= stream_fifo_count + 1'b1;
                2'b01: stream_fifo_count <= stream_fifo_count - 1'b1;
                default: stream_fifo_count <= stream_fifo_count;
            endcase
            case ({stream_issue, stream_retire_fire})
                2'b10: stream_pending_count <= stream_pending_count + 1'b1;
                2'b01: stream_pending_count <= stream_pending_count - 1'b1;
                default: stream_pending_count <= stream_pending_count;
            endcase

            if (!mem_hold_valid && mem_arb_select_valid && !mem_req_ready) begin
                mem_hold_valid <= 1'b1;
                mem_hold_source <= mem_arb_select;
                mem_hold_request <= mem_arb_request;
            end else if (mem_hold_valid && mem_req_ready) begin
                mem_hold_valid <= 1'b0;
            end
            if (write_update_fire) begin
                if (active_write_aux && aux_span_valid &&
                    aux_span_line == active_write_address[23:4]) begin
                    aux_span_data[active_write_address[3:0]*8 +: 8] <=
                        active_write_data[7:0];
                    aux_span_data[(active_write_address[3:0]+1'b1)*8 +: 8] <=
                        active_write_data[15:8];
                end else if (!active_write_aux && color_span_valid &&
                             color_span_line == active_write_address[23:4]) begin
                    color_span_data[active_write_address[3:0]*8 +: 8] <=
                        active_write_data[7:0];
                    color_span_data[(active_write_address[3:0]+1'b1)*8 +: 8] <=
                        active_write_data[15:8];
                end
            end
            case (state)
                ST_IDLE: begin
                    if (lfb_valid && lfb_ready) begin
                        work <= lfb.state;
                        if (lfb.state.stipple_generation != observed_stipple_generation) begin
                            stipple_value <= lfb.state.stipple;
                            observed_stipple_generation <= lfb.state.stipple_generation;
                        end
                        if (!lfb.write) begin
                            x_byte = lfb.offset[10:0] & 11'h7fe;
                            y_value = lfb.offset[20:11];
                            if (lfb.state.lfb_mode[8] ? lfb.state.fbz_mode[17] :
                                                       lfb.state.lfb_mode[13])
                                y_value = lfb.state.video_dimensions[25:16] - 1'b1 - y_value;
                            case (lfb.state.lfb_mode[7:6])
                                2'd1: lfb_read_address <=
                                    ({15'd0, lfb.state.fbi_init2[19:11]} << 12) +
                                    y_value * ({16'd0, lfb.state.fbi_init1[7:4]} << 7) + x_byte;
                                2'd2: lfb_read_address <=
                                    ({14'd0, lfb.state.fbi_init2[19:11]} << 13) +
                                    y_value * ({16'd0, lfb.state.fbi_init1[7:4]} << 7) + x_byte;
                                default: lfb_read_address <=
                                    y_value * ({16'd0, lfb.state.fbi_init1[7:4]} << 7) + x_byte;
                            endcase
                            lfb_read_lane <= x_byte[3:0];
                            state <= ST_LFB_READ_REQ;
                        end else begin
                            transformed = lfb.state.lfb_mode[12] ?
                                {lfb.data[7:0], lfb.data[15:8], lfb.data[23:16], lfb.data[31:24]} :
                                lfb.data;
                            if (lfb.state.lfb_mode[11] &&
                                !(lfb.state.lfb_mode[3:0] inside {4'd4, 4'd5}))
                                transformed = {transformed[15:0], transformed[31:16]};
                            format = lfb.state.lfb_mode[3:0];
                            mapped_offset = format inside {4'd4, 4'd5, 4'd12, 4'd13, 4'd14} ?
                                            (lfb.offset >> 1) : lfb.offset;
                            x_byte = mapped_offset[10:0] & 11'h7fe;
                            y_value = mapped_offset[20:11];
                            if (lfb.state.lfb_mode[13])
                                y_value = lfb.state.video_dimensions[25:16] - 1'b1 - y_value;
                            lfb_color_address <=
                                (lfb.state.lfb_mode[5:4] == 2'd1 ?
                                 ({15'd0, lfb.state.fbi_init2[19:11]} << 12) : 24'd0) +
                                y_value * ({16'd0, lfb.state.fbi_init1[7:4]} << 7) + x_byte;
                            lfb_aux_address <=
                                ({14'd0, lfb.state.fbi_init2[19:11]} << 13) +
                                y_value * ({16'd0, lfb.state.fbi_init1[7:4]} << 7) + x_byte;
                            lfb_color[0] <= transformed[15:0];
                            lfb_color[1] <= transformed[31:16];
                            lfb_aux[0] <= transformed[15:0];
                            lfb_aux[1] <= transformed[31:16];
                            lfb_write_color <= 2'b00;
                            lfb_write_aux <= 2'b00;
                            low_pixel = transformed[15:0];
                            high_pixel = transformed[31:16];
                            low_rgb = 24'd0;
                            high_rgb = 24'd0;
                            low_alpha = lfb.state.za_color[31:24];
                            high_alpha = lfb.state.za_color[31:24];
                            low_depth = lfb.state.za_color[15:0];
                            high_depth = lfb.state.za_color[15:0];
                            pipeline_valid = 2'b00;
                            case (format)
                                4'd0: begin
                                    if (lfb.state.lfb_mode[9]) begin
                                        lfb_color[0] <= {transformed[4:0], transformed[10:5], transformed[15:11]};
                                        lfb_color[1] <= {transformed[20:16], transformed[26:21], transformed[31:27]};
                                        low_pixel = {transformed[4:0], transformed[10:5], transformed[15:11]};
                                        high_pixel = {transformed[20:16], transformed[26:21], transformed[31:27]};
                                    end
                                    lfb_write_color <= {(|lfb.byte_enable[3:2]), (|lfb.byte_enable[1:0])};
                                    low_rgb = expand_rgb565(low_pixel);
                                    high_rgb = expand_rgb565(high_pixel);
                                    pipeline_valid = {(|lfb.byte_enable[3:2]), (|lfb.byte_enable[1:0])};
                                end
                                4'd1, 4'd2: begin
                                    lfb_color[0] <= lfb_565(transformed[15:0], lfb.state.lfb_mode[10:9], 1'b0);
                                    lfb_color[1] <= lfb_565(transformed[31:16], lfb.state.lfb_mode[10:9], 1'b0);
                                    low_pixel = lfb_565(transformed[15:0], lfb.state.lfb_mode[10:9], 1'b0);
                                    high_pixel = lfb_565(transformed[31:16], lfb.state.lfb_mode[10:9], 1'b0);
                                    low_rgb = expand_rgb565(low_pixel);
                                    high_rgb = expand_rgb565(high_pixel);
                                    lfb_write_color <= {(|lfb.byte_enable[3:2]), (|lfb.byte_enable[1:0])};
                                    pipeline_valid = {(|lfb.byte_enable[3:2]), (|lfb.byte_enable[1:0])};
                                    if (format == 4'd2) begin
                                        low_alpha = transformed[lfb.state.lfb_mode[10] ? 0 : 15] ? 8'hff : 8'h00;
                                        high_alpha = transformed[lfb.state.lfb_mode[10] ? 16 : 31] ? 8'hff : 8'h00;
                                    end
                                    if (format == 4'd2 && lfb.state.fbz_mode[18]) begin
                                        lfb_aux[0] <= transformed[lfb.state.lfb_mode[10] ? 0 : 15] ? 16'h00ff : 16'h0000;
                                        lfb_aux[1] <= transformed[lfb.state.lfb_mode[10] ? 16 : 31] ? 16'h00ff : 16'h0000;
                                        lfb_write_aux <= {(|lfb.byte_enable[3:2]), (|lfb.byte_enable[1:0])};
                                    end
                                end
                                4'd4, 4'd5: begin
                                    low_rgb = lfb_rgb888(transformed, lfb.state.lfb_mode[10:9]);
                                    lfb_color[0] <= rgb888_to_565(
                                        lfb_rgb888(transformed, lfb.state.lfb_mode[10:9]));
                                    lfb_write_color <= {1'b0, |lfb.byte_enable};
                                    pipeline_valid = {1'b0, |lfb.byte_enable};
                                    if (format == 4'd5)
                                        low_alpha = lfb.state.lfb_mode[10] ?
                                                    transformed[7:0] : transformed[31:24];
                                    if (format == 4'd5 && lfb.state.fbz_mode[18]) begin
                                        lfb_aux[0] <= {8'd0, lfb.state.lfb_mode[10] ?
                                            transformed[7:0] : transformed[31:24]};
                                        lfb_write_aux <= {1'b0, |lfb.byte_enable};
                                    end
                                end
                                4'd12: begin
                                    low_pixel = transformed[15:0];
                                    low_depth = transformed[31:16];
                                    pipeline_valid = {1'b0, |lfb.byte_enable};
                                    if (lfb.state.lfb_mode[9])
                                        low_pixel = {transformed[4:0], transformed[10:5], transformed[15:11]};
                                    low_rgb = expand_rgb565(low_pixel);
                                    lfb_color[0] <= low_pixel;
                                    lfb_write_color <= {1'b0, |lfb.byte_enable[1:0]};
                                    lfb_write_aux <= {1'b0, |lfb.byte_enable[3:2]};
                                    lfb_aux[0] <= transformed[31:16];
                                end
                                4'd13, 4'd14: begin
                                    low_pixel = lfb_565(transformed[15:0], lfb.state.lfb_mode[10:9], 1'b0);
                                    low_rgb = expand_rgb565(low_pixel);
                                    low_depth = transformed[31:16];
                                    pipeline_valid = {1'b0, |lfb.byte_enable};
                                    if (format == 4'd14)
                                        low_alpha = transformed[lfb.state.lfb_mode[10] ? 0 : 15] ? 8'hff : 8'h00;
                                    lfb_color[0] <= lfb_565(transformed[15:0], lfb.state.lfb_mode[10:9], 1'b0);
                                    lfb_write_color <= {1'b0, |lfb.byte_enable[1:0]};
                                    lfb_write_aux <= {1'b0, |lfb.byte_enable[3:2]};
                                    lfb_aux[0] <= format == 4'd14 && lfb.state.fbz_mode[18] ?
                                                  (transformed[lfb.state.lfb_mode[10] ? 0 : 15] ? 16'h00ff : 16'h0000) :
                                                  transformed[31:16];
                                end
                                4'd15: begin
                                    low_rgb = lfb.state.color1[23:0];
                                    high_rgb = lfb.state.color1[23:0];
                                    low_depth = transformed[15:0];
                                    high_depth = transformed[31:16];
                                    pipeline_valid = {(|lfb.byte_enable[3:2]), (|lfb.byte_enable[1:0])};
                                    lfb_write_aux <= {(|lfb.byte_enable[3:2]), (|lfb.byte_enable[1:0])};
                                end
                                default: begin end
                            endcase
                            lfb_pipeline_rgb[0] <= low_rgb;
                            lfb_pipeline_rgb[1] <= high_rgb;
                            lfb_pipeline_alpha[0] <= low_alpha;
                            lfb_pipeline_alpha[1] <= high_alpha;
                            lfb_pipeline_depth[0] <= low_depth;
                            lfb_pipeline_depth[1] <= high_depth;
                            lfb_pipeline_valid <= pipeline_valid;
                            lfb_pixel_x <= x_byte[10:1];
                            lfb_pixel_y <= y_value[9:0];
                            lfb_step <= 3'd0;
                            if (lfb.state.lfb_mode[8]) begin
                                pixel_source_lfb <= 1'b1;
                                state <= ST_LFB_PIPE_SETUP;
                            end else begin
                                pixel_source_lfb <= 1'b0;
                                state <= ST_LFB_WRITE;
                            end
                        end
                    end else if (command_valid && command_ready) begin
                        work <= command.state;
                        if (command.state.stipple_generation != observed_stipple_generation) begin
                            stipple_value <= command.state.stipple;
                            observed_stipple_generation <= command.state.stipple_generation;
                        end
                        if (command.kind == SST1_COMMAND_FASTFILL) begin
                            fill_left <= command.state.clip_left_right[25:16];
                            fill_right <= command.state.clip_left_right[9:0];
                            if (command.state.fbz_mode[17]) begin
                                fill_high <= command.state.video_dimensions[25:16] -
                                             command.state.clip_low_y_high_y[25:16];
                            end else begin
                                fill_high <= command.state.clip_low_y_high_y[9:0];
                            end
                            fill_x <= command.state.clip_left_right[25:16];
                            fill_y <= command.state.fbz_mode[17] ?
                                      command.state.video_dimensions[25:16] -
                                      command.state.clip_low_y_high_y[9:0] :
                                      command.state.clip_low_y_high_y[25:16];
                            fill_color_done <= 1'b0;
                            state <= ST_FILL;
                        end else if (command.kind inside {SST1_COMMAND_TRIANGLE_FIXED,
                                                         SST1_COMMAND_TRIANGLE_FLOAT}) begin
                            triangle_negative <= command.command_data[31];
                            pixel_source_lfb <= 1'b0;
                            state <= ST_TRI_SETUP;
                        end else if (command.kind == SST1_COMMAND_NOP &&
                                     command.command_data[0]) begin
                            pixels_in <= '0;
                            chroma_fail <= '0;
                            zfunc_fail <= '0;
                            afunc_fail <= '0;
                            pixels_out <= '0;
                        end
                    end
                end

                ST_LFB_WRITE: begin
                    if (!active_write_valid || write_update_fire) begin
                        if (lfb_step == 3'd3)
                            state <= ST_WRITE_DRAIN;
                        else
                            lfb_step <= lfb_step + 1'b1;
                    end
                end
                ST_LFB_READ_REQ: if (request_fire) state <= ST_LFB_READ_WAIT;
                ST_LFB_READ_WAIT: if (mem_rsp_valid && mem_rsp_ready) begin
                    read_word = 32'(mem_rsp.rdata >> (lfb_read_lane * 8));
                    if (work.lfb_mode[15])
                        read_word = {read_word[15:0], read_word[31:16]};
                    if (work.lfb_mode[16])
                        read_word = {read_word[7:0], read_word[15:8],
                                     read_word[23:16], read_word[31:24]};
                    lfb_read_rsp_data <= read_word;
                    lfb_read_rsp_error <= mem_rsp.error;
                    state <= ST_LFB_READ_RSP;
                end
                ST_LFB_READ_RSP: if (lfb_read_rsp_ready) state <= ST_IDLE;

                ST_LFB_PIPE_SETUP: begin
                    if (lfb_pipeline_valid[lfb_step[0]]) begin
                        triangle_color_address <= lfb_color_address +
                                                  (lfb_step[0] ? 2 : 0);
                        triangle_aux_address <= lfb_aux_address +
                                                (lfb_step[0] ? 2 : 0);
                        pixel_stipple_latched <= stipple_candidate;
                        if (!work.fbz_mode[12])
                            stipple_value <= {stipple_value[30:0], stipple_value[31]};
                        triangle_texture_request_pending <= 1'b0;
                        triangle_texture_done <= 1'b1;
                        triangle_aux_request_pending <= need_aux_read;
                        triangle_aux_done <= !need_aux_read;
                        triangle_color_request_pending <= need_color_read;
                        triangle_color_done <= !need_color_read;
                        state <= ST_TRI_PREFETCH;
                    end else if (!lfb_step[0]) begin
                        lfb_step <= 3'd1;
                    end else begin
                        state <= ST_WRITE_DRAIN;
                    end
                end

                ST_FILL: begin
                    if (!active_write_valid || write_update_fire) begin
                        if (!fill_color_done && work.fbz_mode[10]) begin
                            fill_color_done <= 1'b1;
                        end else begin
                            fill_color_done <= 1'b0;
                            pixels_out <= {8'd0, pixels_out[23:0] + 1'b1};
                            if (fill_x + 1'b1 >= fill_right) begin
                                fill_x <= fill_left;
                                if (fill_y + 1'b1 >= fill_high)
                                    state <= ST_WRITE_DRAIN;
                                else
                                    fill_y <= fill_y + 1'b1;
                            end else begin
                                fill_x <= fill_x + 1'b1;
                            end
                        end
                    end
                end

                ST_TRI_SETUP: begin
                    ax <= $signed(work.triangle_parameters[0][15:0]);
                    ay <= $signed(work.triangle_parameters[1][15:0]);
                    bx <= $signed(work.triangle_parameters[2][15:0]);
                    by <= $signed(work.triangle_parameters[3][15:0]);
                    cx <= $signed(work.triangle_parameters[4][15:0]);
                    cy <= $signed(work.triangle_parameters[5][15:0]);
                    min_x <= (min3($signed(work.triangle_parameters[0][15:0]),
                                  $signed(work.triangle_parameters[2][15:0]),
                                  $signed(work.triangle_parameters[4][15:0])) + 7) >>> 4;
                    max_x <= (max3($signed(work.triangle_parameters[0][15:0]),
                                  $signed(work.triangle_parameters[2][15:0]),
                                  $signed(work.triangle_parameters[4][15:0])) + 7) >>> 4;
                    max_y <= (max3($signed(work.triangle_parameters[1][15:0]),
                                  $signed(work.triangle_parameters[3][15:0]),
                                  $signed(work.triangle_parameters[5][15:0])) + 7) >>> 4;
                    raster_x <= (min3($signed(work.triangle_parameters[0][15:0]),
                                     $signed(work.triangle_parameters[2][15:0]),
                                     $signed(work.triangle_parameters[4][15:0])) + 7) >>> 4;
                    raster_y <= (min3($signed(work.triangle_parameters[1][15:0]),
                                     $signed(work.triangle_parameters[3][15:0]),
                                     $signed(work.triangle_parameters[5][15:0])) + 7) >>> 4;
                    stream_fifo_head <= '0;
                    stream_fifo_tail <= '0;
                    stream_fifo_count <= '0;
                    stream_pending_count <= '0;
                    stream_issue_valid <= 1'b0;
                    stream_row_started <= 1'b0;
                    stream_address_valid <= '0;
                    stream_join_head <= '0;
                    stream_join_tail <= '0;
                    stream_join_count <= '0;
                    state <= stream_fast_path ? ST_TRI_STREAM : ST_TRI_TEST;
                end

                ST_TRI_STREAM: begin
                    if (stream_step) begin
                        if (stream_issue) begin
                            dx_subpixel = (raster_x <<< 4) + 8 - ax;
                            dy_subpixel = (raster_y <<< 4) + 8 - ay;
                            red_value = $signed(work.triangle_parameters[6]) +
                                (($signed(work.triangle_parameters[14]) * dx_subpixel +
                                  $signed(work.triangle_parameters[22]) * dy_subpixel) >>> 4);
                            green_value = $signed(work.triangle_parameters[7]) +
                                (($signed(work.triangle_parameters[15]) * dx_subpixel +
                                  $signed(work.triangle_parameters[23]) * dy_subpixel) >>> 4);
                            blue_value = $signed(work.triangle_parameters[8]) +
                                (($signed(work.triangle_parameters[16]) * dx_subpixel +
                                  $signed(work.triangle_parameters[24]) * dy_subpixel) >>> 4);
                            z_value = $signed(work.triangle_parameters[9]) +
                                (($signed(work.triangle_parameters[17]) * dx_subpixel +
                                  $signed(work.triangle_parameters[25]) * dy_subpixel) >>> 4);
                            alpha_value = $signed(work.triangle_parameters[10]) +
                                (($signed(work.triangle_parameters[18]) * dx_subpixel +
                                  $signed(work.triangle_parameters[26]) * dy_subpixel) >>> 4);
                            w_value = stw_parameter(work, 13) +
                                ((stw_parameter(work, 21) * dx_subpixel +
                                  stw_parameter(work, 29) * dy_subpixel) >>> 4);
                            s_value = stw_parameter(work, 11) +
                                ((stw_parameter(work, 19) * dx_subpixel +
                                  stw_parameter(work, 27) * dy_subpixel) >>> 4);
                            t_value = stw_parameter(work, 12) +
                                ((stw_parameter(work, 20) * dx_subpixel +
                                  stw_parameter(work, 28) * dy_subpixel) >>> 4);
                            stream_pixel_x <= raster_x[9:0];
                            stream_pixel_y <= raster_y[9:0];
                            stream_stipple <= stipple_candidate;
                            stream_iter_rgb <= {clamp_color(red_value),
                                                clamp_color(green_value),
                                                clamp_color(blue_value)};
                            stream_iter_alpha <= clamp_color(alpha_value);
                            stream_iter_z <= z_value;
                            stream_iter_w <= w_value;
                            stream_iter_s <= s_value;
                            stream_iter_t <= t_value;
                            stream_color_address <= draw_base +
                                (work.fbz_mode[17] ?
                                 (work.video_dimensions[25:16] - 1'b1 - raster_y) :
                                 raster_y) * row_width + raster_x * 2;
                            stream_aux_address <= aux_base +
                                (work.fbz_mode[17] ?
                                 (work.video_dimensions[25:16] - 1'b1 - raster_y) :
                                 raster_y) * row_width + raster_x * 2;
                            pixels_in <= {8'd0, pixels_in[23:0] + 1'b1};
                            last_alpha <= alpha_value[31:0];
                            last_w <= w_value[31:0];
                            if (!work.fbz_mode[12])
                                stipple_value <= {stipple_value[30:0],
                                                  stipple_value[31]};
                        end
                        if ((!stream_pixel_eligible && stream_row_started) ||
                            raster_x >= max_x) begin
                            raster_x <= min_x;
                            stream_row_started <= 1'b0;
                            if (raster_y >= max_y)
                                state <= ST_TRI_STREAM_DRAIN;
                            else
                                raster_y <= raster_y + 1'b1;
                        end else begin
                            raster_x <= raster_x + 1'b1;
                            if (stream_pixel_eligible)
                                stream_row_started <= 1'b1;
                        end
                    end
                end

                ST_TRI_STREAM_DRAIN: begin
                    if (stream_pending_count == 0 &&
                        stream_fifo_count == 0 && !stream_issue_valid &&
                        stream_join_count == 0 && stream_address_valid == 0)
                        state <= ST_WRITE_DRAIN;
                end

                ST_TRI_TEST: begin
                    if (triangle_inside &&
                        (!work.fbz_mode[0] ||
                         (raster_x >= $signed({1'b0, work.clip_left_right[25:16]}) &&
                          raster_x <  $signed({1'b0, work.clip_left_right[9:0]}) &&
                          raster_y >= $signed({1'b0, work.clip_low_y_high_y[25:16]}) &&
                          raster_y <  $signed({1'b0, work.clip_low_y_high_y[9:0]})))) begin
                        dx_subpixel = (raster_x <<< 4) + 8 - ax;
                        dy_subpixel = (raster_y <<< 4) + 8 - ay;
                        red_value = $signed(work.triangle_parameters[6]) +
                            (($signed(work.triangle_parameters[14]) * dx_subpixel +
                              $signed(work.triangle_parameters[22]) * dy_subpixel) >>> 4);
                        green_value = $signed(work.triangle_parameters[7]) +
                            (($signed(work.triangle_parameters[15]) * dx_subpixel +
                              $signed(work.triangle_parameters[23]) * dy_subpixel) >>> 4);
                        blue_value = $signed(work.triangle_parameters[8]) +
                            (($signed(work.triangle_parameters[16]) * dx_subpixel +
                              $signed(work.triangle_parameters[24]) * dy_subpixel) >>> 4);
                        z_value = $signed(work.triangle_parameters[9]) +
                            (($signed(work.triangle_parameters[17]) * dx_subpixel +
                              $signed(work.triangle_parameters[25]) * dy_subpixel) >>> 4);
                        alpha_value = $signed(work.triangle_parameters[10]) +
                            (($signed(work.triangle_parameters[18]) * dx_subpixel +
                              $signed(work.triangle_parameters[26]) * dy_subpixel) >>> 4);
                        w_value = stw_parameter(work, 13) +
                            ((stw_parameter(work, 21) * dx_subpixel +
                              stw_parameter(work, 29) * dy_subpixel) >>> 4);
                        s_value = stw_parameter(work, 11) +
                            ((stw_parameter(work, 19) * dx_subpixel +
                              stw_parameter(work, 27) * dy_subpixel) >>> 4);
                        t_value = stw_parameter(work, 12) +
                            ((stw_parameter(work, 20) * dx_subpixel +
                              stw_parameter(work, 28) * dy_subpixel) >>> 4);
                        red = clamp_color(red_value);
                        green = clamp_color(green_value);
                        blue = clamp_color(blue_value);
                        triangle_iter_rgb <= {red, green, blue};
                        triangle_iter_alpha <= clamp_color(alpha_value);
                        triangle_iter_z <= z_value;
                        triangle_iter_w <= w_value;
                        triangle_iter_s <= s_value;
                        triangle_iter_t <= t_value;
                        pixel_stipple_latched <= stipple_candidate;
                        last_alpha <= alpha_value[31:0];
                        last_w <= w_value[31:0];
                        triangle_color_address <= draw_base +
                            (work.fbz_mode[17] ?
                            (work.video_dimensions[25:16] - 1'b1 - raster_y) : raster_y) *
                            row_width + raster_x * 2;
                        triangle_aux_address <= aux_base +
                            (work.fbz_mode[17] ?
                            (work.video_dimensions[25:16] - 1'b1 - raster_y) : raster_y) *
                            row_width + raster_x * 2;
                        pixels_in <= {8'd0, pixels_in[23:0] + 1'b1};
                        if (!work.fbz_mode[12])
                            stipple_value <= {stipple_value[30:0], stipple_value[31]};
                        triangle_texture_request_pending <= work.fbz_color_path[27];
                        triangle_texture_done <= !work.fbz_color_path[27];
                        triangle_aux_request_pending <= need_aux_read;
                        triangle_aux_done <= !need_aux_read;
                        triangle_color_request_pending <= need_color_read;
                        triangle_color_done <= !need_color_read;
                        if (!work.fbz_color_path[27]) begin
                            triangle_texture_rgb <= 24'd0;
                            triangle_texture_alpha <= 8'd0;
                        end
                        state <= ST_TRI_PREFETCH;
                    end else begin
                        if (raster_x >= max_x) begin
                            raster_x <= min_x;
                            if (raster_y >= max_y)
                                state <= ST_WRITE_DRAIN;
                            else
                                raster_y <= raster_y + 1'b1;
                        end else begin
                            raster_x <= raster_x + 1'b1;
                        end
                    end
                end
                ST_TRI_PREFETCH: begin
                    if (triangle_aux_request_pending && aux_value_ready) begin
                        destination_aux <= cached_aux_value;
                        triangle_aux_request_pending <= 1'b0;
                        triangle_aux_done <= 1'b1;
                    end
                    if (triangle_color_request_pending && color_value_ready) begin
                        destination_color <= cached_color_value;
                        triangle_color_request_pending <= 1'b0;
                        triangle_color_done <= 1'b1;
                    end
                    if (texture_sample_valid && texture_sample_ready)
                        triangle_texture_request_pending <= 1'b0;
                    if (texture_result_valid && texture_result_ready) begin
                        triangle_texture_rgb <= texture_result.rgb;
                        triangle_texture_alpha <= texture_result.alpha;
                        triangle_texture_done <= 1'b1;
                    end
                    if (request_fire) begin
                        if (read_request.tag == 8'h20)
                            triangle_aux_request_pending <= 1'b0;
                        else if (read_request.tag == 8'h21)
                            triangle_color_request_pending <= 1'b0;
                    end
                    if (mem_rsp_valid && mem_rsp_ready) begin
                        if (mem_rsp.tag == 8'h20) begin
                            aux_span_valid <= !mem_rsp.error;
                            aux_span_line <= triangle_aux_address[23:4];
                            aux_span_data <= mem_rsp.rdata;
                            destination_aux <= 16'(mem_rsp.rdata >>
                                                   (triangle_aux_address[3:0] * 8));
                            if (write_probe_hit[0])
                                destination_aux[7:0] <= write_probe_data[7:0];
                            if (write_probe_hit[1])
                                destination_aux[15:8] <= write_probe_data[15:8];
                            triangle_aux_done <= 1'b1;
                        end else if (mem_rsp.tag == 8'h21) begin
                            color_span_valid <= !mem_rsp.error;
                            color_span_line <= triangle_color_address[23:4];
                            color_span_data <= mem_rsp.rdata;
                            destination_color <= 16'(mem_rsp.rdata >>
                                                     (triangle_color_address[3:0] * 8));
                            if (write_probe_hit[0])
                                destination_color[7:0] <= write_probe_data[7:0];
                            if (write_probe_hit[1])
                                destination_color[15:8] <= write_probe_data[15:8];
                            triangle_color_done <= 1'b1;
                        end
                    end
                    if ((triangle_texture_done ||
                         (texture_result_valid && texture_result_ready)) &&
                        (triangle_aux_done ||
                         (triangle_aux_request_pending && aux_value_ready) ||
                         (mem_rsp_valid && mem_rsp_ready && mem_rsp.tag == 8'h20)) &&
                        (triangle_color_done ||
                         (triangle_color_request_pending && color_value_ready) ||
                         (mem_rsp_valid && mem_rsp_ready && mem_rsp.tag == 8'h21)))
                        state <= ST_TRI_EVALUATE;
                end
                ST_TRI_EVALUATE: begin
                    if (pixel_input_ready)
                        state <= ST_TRI_PIPE_WAIT;
                end
                ST_TRI_PIPE_WAIT: if (pixel_output_valid) begin
                    if (pixel_chroma_failed)
                        chroma_fail <= {8'd0, chroma_fail[23:0] + 1'b1};
                    if (pixel_depth_failed)
                        zfunc_fail <= {8'd0, zfunc_fail[23:0] + 1'b1};
                    if (pixel_alpha_failed)
                        afunc_fail <= {8'd0, afunc_fail[23:0] + 1'b1};
                    if (pixel_accepted)
                        pixels_out <= {8'd0, pixels_out[23:0] + 1'b1};
                    if (pixel_color_write)
                        state <= ST_TRI_WRITE_COLOR;
                    else if (pixel_aux_write)
                        state <= ST_TRI_WRITE_AUX;
                    else
                        state <= ST_PIXEL_FINISH;
                end
                ST_TRI_WRITE_COLOR: begin
                    if (!active_write_valid || write_update_fire) begin
                        if (pixel_aux_write)
                            state <= ST_TRI_WRITE_AUX;
                        else
                            state <= ST_PIXEL_FINISH;
                    end
                end
                ST_TRI_WRITE_AUX: if (!active_write_valid || write_update_fire) begin
                    state <= ST_PIXEL_FINISH;
                end
                ST_PIXEL_FINISH: begin
                    if (pixel_source_lfb) begin
                        if (!lfb_step[0]) begin
                            lfb_step <= 3'd1;
                            state <= ST_LFB_PIPE_SETUP;
                        end else begin
                            state <= ST_WRITE_DRAIN;
                        end
                    end else begin
                        state <= ST_TRI_TEST;
                        if (raster_x >= max_x) begin
                            raster_x <= min_x;
                            if (raster_y >= max_y)
                                state <= ST_WRITE_DRAIN;
                            else
                                raster_y <= raster_y + 1'b1;
                        end else raster_x <= raster_x + 1'b1;
                    end
                end
                ST_WRITE_DRAIN: begin
                    if (write_combiner_idle)
                        state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    property p_memory_request_stable;
        @(posedge clk) disable iff (!reset_n)
            mem_req_valid && !mem_req_ready |=> mem_req_valid && $stable(mem_req);
    endproperty
    assert property (p_memory_request_stable);

    property p_lfb_response_stable;
        @(posedge clk) disable iff (!reset_n)
            lfb_read_rsp_valid && !lfb_read_rsp_ready |=>
                lfb_read_rsp_valid && $stable(lfb_read_rsp_data) &&
                $stable(lfb_read_rsp_error);
    endproperty
    assert property (p_lfb_response_stable);
`endif

endmodule
