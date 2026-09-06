// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

package sst1_pkg;

    localparam int SST1_BAR_ADDR_WIDTH = 24;
    localparam int SST1_BAR_SIZE       = 16 * 1024 * 1024;
    localparam int SST1_REG_SIZE       = 4 * 1024 * 1024;
    localparam int SST1_LFB_SIZE       = 4 * 1024 * 1024;
    localparam int SST1_TEX_SIZE       = 8 * 1024 * 1024;

    typedef enum logic [1:0] {
        SST1_REGION_REG      = 2'd0,
        SST1_REGION_LFB      = 2'd1,
        SST1_REGION_TEXTURE0 = 2'd2,
        SST1_REGION_TEXTURE1 = 2'd3
    } sst1_bar_region_t;

    typedef struct packed {
        logic [SST1_BAR_ADDR_WIDTH-1:0] addr;
        logic [31:0]                    wdata;
        logic [3:0]                     be;
        logic                           write;
    } sst1_host_req_t;

    typedef struct packed {
        logic [31:0] rdata;
        logic        error;
    } sst1_host_rsp_t;

    typedef enum logic [2:0] {
        SST1_MEM_FB_WRITE   = 3'd0,
        SST1_MEM_FB_COLOR   = 3'd1,
        SST1_MEM_FB_AUX     = 3'd2,
        SST1_MEM_TEXTURE    = 3'd3,
        SST1_MEM_TEX_UPLOAD = 3'd4,
        SST1_MEM_SCANOUT    = 3'd5
    } sst1_mem_source_t;

    typedef enum logic [1:0] {
        SST1_ORDER_RELAXED = 2'd0,
        SST1_ORDER_SOURCE  = 2'd1,
        SST1_ORDER_FENCE   = 2'd2
    } sst1_mem_order_t;

    typedef struct packed {
        logic [39:0]       addr;
        logic [127:0]      wdata;
        logic [15:0]       wstrb;
        logic [7:0]        beats;
        logic [7:0]        tag;
        sst1_mem_source_t  source;
        sst1_mem_order_t   order_class;
        logic              write;
    } sst1_mem_req_t;

    typedef struct packed {
        logic [127:0] rdata;
        logic [7:0]   tag;
        logic         last;
        logic         error;
    } sst1_mem_rsp_t;

    // One-cycle event pulses plus live occupancy samples used by the optional
    // platform performance-counter bank. They are deliberately outside the
    // SST-1 software-visible register contract.
    typedef struct packed {
        logic       lookup;
        logic       hit;
        logic       miss;
        logic       replay;
        logic       demand_allocation;
        logic       prefetch_allocation;
        logic       fill_request;
        logic       fill_beat;
        logic       fill_error;
        logic       invalidation;
        logic [6:0] wait_occupancy;
        logic [4:0] mshr_occupancy;
    } sst1_cache_perf_events_t;

    typedef struct packed {
        logic       sample_accept;
        logic       result_retire;
        logic [6:0] rob_occupancy;
        sst1_cache_perf_events_t cache;
    } sst1_tmu_perf_events_t;

    typedef struct packed {
        logic       raster_candidate;
        logic       pixel_issue;
        logic       pixel_retire;
        logic       join_allocate;
        logic       join_complete;
        logic       pixel_pass;
        logic       chroma_fail;
        logic       depth_fail;
        logic       alpha_fail;
        logic       color_read;
        logic       aux_read;
        logic       color_update;
        logic       aux_update;
        logic       color_drain;
        logic       aux_drain;
        logic       color_forward;
        logic       aux_forward;
        logic [6:0] pending_occupancy;
        logic [6:0] join_occupancy;
        sst1_cache_perf_events_t color_cache;
        sst1_cache_perf_events_t aux_cache;
    } sst1_fbi_perf_events_t;

    typedef struct packed {
        logic [31:0] transaction_id;
        sst1_bar_region_t region;
        logic [21:0] region_offset;
        logic [7:0]  wrap;
        logic [3:0]  chip_select;
        logic [11:0] register_offset;
        logic [31:0] data;
        logic [3:0]  be;
        logic        write;
        logic        accepted;
    } sst1_debug_host_event_t;

    typedef enum logic [2:0] {
        SST1_COMMAND_TRIANGLE_FIXED = 3'd0,
        SST1_COMMAND_TRIANGLE_FLOAT = 3'd1,
        SST1_COMMAND_NOP            = 3'd2,
        SST1_COMMAND_FASTFILL       = 3'd3,
        SST1_COMMAND_SWAPBUFFER     = 3'd4
    } sst1_command_kind_t;

    typedef struct packed {
        logic [29:0][31:0] triangle_parameters;
        // Floating STW aliases have more range than their 32-bit fixed ports.
        // Preserve upper bits separately; fixed writes and hand-built test
        // states retain the original sign-extended 32-bit interpretation.
        logic [8:0][31:0] stw_high;
        logic [8:0] stw_extended;
        logic [31:0] fbz_color_path;
        logic [31:0] fog_mode;
        logic [31:0] alpha_mode;
        logic [31:0] fbz_mode;
        logic [31:0] lfb_mode;
        logic [31:0] clip_left_right;
        logic [31:0] clip_low_y_high_y;
        logic [31:0] fog_color;
        logic [31:0] za_color;
        logic [31:0] chroma_key;
        logic [31:0] stipple;
        logic [31:0] stipple_generation;
        logic [31:0] color0;
        logic [31:0] color1;
        logic [31:0][31:0] fog_table;
        logic [31:0] fbi_init1;
        logic [31:0] fbi_init2;
        logic [31:0] video_dimensions;
        logic [8:0][31:0] tmu_state;
    } sst1_render_state_t;

    function automatic integer stw_slot(input integer parameter_index);
        case (parameter_index)
            11: return 0; 12: return 1; 13: return 2;
            19: return 3; 20: return 4; 21: return 5;
            27: return 6; 28: return 7; 29: return 8;
            default: return -1;
        endcase
    endfunction

    function automatic logic signed [63:0] stw_parameter(
        input sst1_render_state_t state_value, input integer parameter_index);
        integer slot;
        slot = stw_slot(parameter_index);
        if (slot >= 0 && state_value.stw_extended[slot])
            return $signed({state_value.stw_high[slot],
                            state_value.triangle_parameters[parameter_index]});
        return 64'($signed(state_value.triangle_parameters[parameter_index]));
    endfunction

    typedef struct packed {
        logic [31:0] transaction_id;
        sst1_command_kind_t kind;
        logic [31:0] command_data;
        sst1_render_state_t state;
    } sst1_render_command_t;

    typedef struct packed {
        logic [31:0] transaction_id;
        sst1_bar_region_t region;
        logic [21:0] region_offset;
        logic [11:0] register_address;
        logic [3:0]  chip_select;
        logic [31:0] data;
        logic [3:0]  byte_enable;
        logic        sync_required;
        logic        float_alias;
        logic [11:0] float_target;
        logic [5:0]  float_fraction;
        logic [5:0]  float_width;
    } sst1_fifo_entry_t;

    typedef struct packed {
        logic [31:0] transaction_id;
        logic [21:0] offset;
        logic [31:0] data;
        logic [3:0]  byte_enable;
        logic        write;
        sst1_render_state_t state;
    } sst1_lfb_command_t;

    typedef struct packed {
        logic [31:0] transaction_id;
        logic        table_write;
        logic [22:0] aperture_offset;
        logic [11:0] register_address;
        logic [31:0] data;
        logic [3:0]  byte_enable;
        sst1_render_state_t state;
    } sst1_texture_command_t;

    typedef struct packed {
        logic [9:0]          pixel_x;
        logic [9:0]          pixel_y;
        logic signed [63:0] s_over_w;
        logic signed [63:0] t_over_w;
        logic signed [63:0] one_over_w;
        logic signed [31:0] dsdx;
        logic signed [31:0] dtdx;
        logic signed [31:0] dsdy;
        logic signed [31:0] dtdy;
        logic [23:0]         other_rgb;
        logic [7:0]          other_alpha;
        sst1_render_state_t  state;
    } sst1_texture_sample_t;

    typedef struct packed {
        logic [23:0] rgb;
        logic [7:0]  alpha;
        logic [11:0] lod;
        logic        error;
    } sst1_texture_result_t;

    function automatic sst1_bar_region_t sst1_decode_region(
        input logic [SST1_BAR_ADDR_WIDTH-1:0] addr
    );
        return sst1_bar_region_t'(addr[23:22]);
    endfunction

    function automatic logic [21:0] sst1_region_offset(
        input logic [SST1_BAR_ADDR_WIDTH-1:0] addr
    );
        return addr[21:0];
    endfunction

    // The register field is eight words: bits 9:2 plus the byte address bits.
    // Bits 13:10 select chips and bits 21:14 select a wrap alias. Address bit
    // 21 also selects the alternate triangle layout when fbiInit3[0] is set.
    function automatic logic [11:0] sst1_register_offset(
        input logic [SST1_BAR_ADDR_WIDTH-1:0] addr
    );
        return {2'b00, addr[9:2], 2'b00};
    endfunction

endpackage
