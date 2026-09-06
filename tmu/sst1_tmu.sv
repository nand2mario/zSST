// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// One-TREX TMU with an elastic, in-order retirement pipeline. Samples reserve
// a reorder entry before entering the fixed-latency perspective/LOD front end.
// Cache requests and responses carry that entry ID, allowing resident hits to
// run at one sample per clock while delayed misses remain correctly ordered.
module sst1_tmu #(
    parameter integer ROB_DEPTH = 64,
    parameter integer CACHE_PREFETCH_DISTANCE_LINES = 2
) (
    input  logic                             clk,
    input  logic                             reset_n,
    input  logic                             memory_enable,
    input  logic [39:0]                      memory_base,
    input  logic [23:0]                      memory_size,

    input  logic                             command_valid,
    output logic                             command_ready,
    input  sst1_pkg::sst1_texture_command_t command,
    input  logic                             sample_valid,
    output logic                             sample_ready,
    input  sst1_pkg::sst1_texture_sample_t  sample,
    output logic                             result_valid,
    input  logic                             result_ready,
    output sst1_pkg::sst1_texture_result_t  result,

    output logic                             mem_req_valid,
    input  logic                             mem_req_ready,
    output sst1_pkg::sst1_mem_req_t          mem_req,
    input  logic                             mem_rsp_valid,
    output logic                             mem_rsp_ready,
    input  sst1_pkg::sst1_mem_rsp_t          mem_rsp,
    output logic                             idle,
    output sst1_pkg::sst1_tmu_perf_events_t  perf_events
);
    import sst1_pkg::*;

    localparam integer ROB_BITS = $clog2(ROB_DEPTH);

    logic layout_valid;
    logic [22:0] layout_offset;
    logic [31:0] layout_data;
    logic [3:0] layout_enable;

    logic [31:0] ncc_words [0:1][0:11];
    logic [7:0] decode_ncc_y [0:15];
    logic [26:0] decode_ncc_i [0:3];
    logic [26:0] decode_ncc_q [0:3];

    logic rob_valid [0:ROB_DEPTH-1];
    logic rob_front_ready [0:ROB_DEPTH-1];
    logic rob_issued [0:ROB_DEPTH-1];
    logic rob_done [0:ROB_DEPTH-1];
    logic rob_address_error [0:ROB_DEPTH-1];
    // Register state is fixed for every sample emitted by one triangle
    // command.  Keeping a 288-bit copy in every ROB entry wastes more than
    // 18 Kbits of flops and builds large state-selection muxes.  A new command
    // cannot be accepted until the ROB and cache are idle, so one active copy
    // is sufficient; only genuinely per-pixel values remain in the ROB.
    logic [8:0][31:0] active_tmu_state;
    logic [23:0] rob_other_rgb [0:ROB_DEPTH-1];
    logic [7:0] rob_other_alpha [0:ROB_DEPTH-1];
    logic [11:0] rob_lod [0:ROB_DEPTH-1];
    logic [3:0] rob_ds [0:ROB_DEPTH-1];
    logic [3:0] rob_dt [0:ROB_DEPTH-1];
    logic rob_bilinear [0:ROB_DEPTH-1];
    logic [21:0] rob_address [0:ROB_DEPTH-1][0:3];
    sst1_texture_result_t rob_result [0:ROB_DEPTH-1];

    logic [ROB_BITS-1:0] allocate_pointer, issue_pointer, retire_pointer;
    logic [ROB_BITS:0] rob_count;
    logic sample_fire, retire_fire, issue_fire, issue_skip;

    logic front_start, front_busy, front_done;
    logic signed [17:0] front_s, front_t;
    logic [11:0] front_lod;
    logic [3:0] front_lod_level;
    logic front_magnification, front_clamp_to_zero;
    logic [ROB_BITS-1:0] front_id_pipe [0:3];
    logic [ROB_BITS-1:0] front_output_id;

    sst1_render_state_t address_state;
    logic address_bilinear;
    logic [3:0] address_ds, address_dt;
    logic [21:0] address_value [0:3];
    logic address_valid;
    logic [ROB_BITS-1:0] address_id;
    logic [11:0] address_lod;
    logic [3:0] address_ds_reg, address_dt_reg;
    logic address_bilinear_reg;
    logic address_error;
    logic [21:0] address_value_reg [0:3];

    logic cache_lookup_ready, cache_response_valid, cache_response_ready;
    logic [15:0] cache_texel [0:3];
    logic [7:0] cache_response_id;
    logic cache_response_error;
    logic cache_mem_req_valid, cache_mem_req_ready, cache_mem_rsp_ready;
    logic cache_idle;
    sst1_cache_perf_events_t cache_perf_events;
    sst1_mem_req_t cache_mem_req;

    logic upload_pending;
    logic [22:0] upload_offset;
    logic [31:0] upload_data;
    logic [3:0] upload_enable;
    logic upload_fire;

    logic command_table_number;
    logic [3:0] command_table_index;

    logic decode0_valid, decode1_valid, filter_valid;
    logic [ROB_BITS-1:0] decode0_id, decode1_id, filter_id;
    logic [15:0] decode0_raw [0:3];
    logic [23:0] decode0_palette_rgb [0:3];
    wire palette_write = command_valid && command_ready && command.table_write &&
                         !command_table_number && command_table_index >= 4 &&
                         command.data[31];
    for (genvar p = 0; p < 4; p++) begin : palette_ports
        sst1_palette_ram palette_ram (
            .clk, .reset_n, .write_enable(palette_write),
            .write_address({command.data[30:24], command_table_index[0]}),
            .write_data(command.data[23:0]),
            .read_enable(cache_response_valid && cache_response_ready),
            .read_address(cache_texel[p][7:0]),
            .read_data(decode0_palette_rgb[p])
        );
    end
    logic decode0_error;
    logic [23:0] decode_rgb_comb [0:3];
    logic [7:0] decode_alpha_comb [0:3];
    logic [23:0] decode1_rgb [0:3];
    logic [7:0] decode1_alpha [0:3];
    logic decode1_error;
    logic [8:0] filter_weight [0:3];
    logic [19:0] filter_sum_rgb [0:2];
    logic [19:0] filter_sum_alpha;
    logic [23:0] filtered_rgb_comb, filtered_rgb;
    logic [7:0] filtered_alpha_comb, filtered_alpha;
    logic filter_error;
    logic [23:0] combined_rgb;
    logic [7:0] combined_alpha;

    integer byte_index, ncc_texel, filter_channel, seq_texel;
    integer reset_table, reset_index, reset_rob;

    initial begin
        if (ROB_DEPTH < 8 || (ROB_DEPTH & (ROB_DEPTH - 1)) != 0)
            $error("ROB_DEPTH must be a power of two and at least eight");
        if (ROB_DEPTH > 256)
            $error("ROB_DEPTH must fit in the cache lookup ID");
    end

    sst1_texture_layout layout (
        .aperture_offset(command.aperture_offset),
        .write_data(command.data), .write_enable(command.byte_enable),
        .state(command.state), .valid(layout_valid),
        .memory_offset(layout_offset), .memory_data(layout_data),
        .memory_enable(layout_enable)
    );

    assign command_table_number = command.register_address >= 12'h354;
    assign command_table_index =
        (command.register_address -
         (command_table_number ? 12'h354 : 12'h324)) >> 2;

    assign sample_ready = !command_valid && !upload_pending && rob_count < ROB_DEPTH;
    assign sample_fire = sample_valid && sample_ready;
    assign front_start = sample_fire;

    sst1_tmu_front_staged front (
        .clk, .reset_n, .start(front_start), .busy(front_busy), .done(front_done),
        .pixel_x(sample.pixel_x), .pixel_y(sample.pixel_y),
        .s_over_w(sample.s_over_w), .t_over_w(sample.t_over_w),
        .one_over_w(sample.one_over_w), .dsdx(sample.dsdx),
        .dtdx(sample.dtdx), .dsdy(sample.dsdy), .dtdy(sample.dtdy),
        .texture_mode(sample.state.tmu_state[0]), .tlod(sample.state.tmu_state[1]),
        .tex_s(front_s), .tex_t(front_t), .lod(front_lod),
        .lod_level(front_lod_level), .magnification(front_magnification),
        .clamp_to_zero(front_clamp_to_zero)
    );

    assign front_output_id = front_id_pipe[3];
    always_comb begin
        address_state = '0;
        address_state.tmu_state = active_tmu_state;
    end

    sst1_texture_address address (
        .tex_s(front_s), .tex_t(front_t), .lod_level(front_lod_level),
        .magnification(front_magnification),
        .clamp_to_zero(front_clamp_to_zero), .state(address_state),
        .bilinear(address_bilinear), .ds(address_ds), .dt(address_dt),
        .address0(address_value[0]), .address1(address_value[1]),
        .address2(address_value[2]), .address3(address_value[3])
    );

    assign issue_skip = rob_valid[issue_pointer] &&
                        rob_front_ready[issue_pointer] &&
                        !rob_issued[issue_pointer] &&
                        rob_address_error[issue_pointer];
    assign issue_fire = rob_valid[issue_pointer] &&
                        rob_front_ready[issue_pointer] &&
                        !rob_issued[issue_pointer] &&
                        !rob_address_error[issue_pointer] &&
                        cache_lookup_ready;

    sst1_texture_cache #(
        .PREFETCH_DISTANCE_LINES(CACHE_PREFETCH_DISTANCE_LINES)
    ) cache (
        .clk, .reset_n, .memory_enable, .memory_base, .memory_size,
        .lookup_valid(rob_valid[issue_pointer] &&
                      rob_front_ready[issue_pointer] &&
                      !rob_issued[issue_pointer] &&
                      !rob_address_error[issue_pointer]),
        .lookup_ready(cache_lookup_ready),
        .lookup_mask(rob_bilinear[issue_pointer] ? 4'hf : 4'h1),
        .lookup_address(rob_address[issue_pointer]),
        .lookup_id(8'(issue_pointer)),
        .response_valid(cache_response_valid),
        .response_ready(cache_response_ready), .response_texel(cache_texel),
        .response_id(cache_response_id),
        .response_error(cache_response_error),
        .invalidate_valid(upload_fire),
        .invalidate_address(upload_offset[21:0]),
        .mem_req_valid(cache_mem_req_valid),
        .mem_req_ready(cache_mem_req_ready), .mem_req(cache_mem_req),
        .mem_rsp_valid, .mem_rsp_ready(cache_mem_rsp_ready), .mem_rsp,
        .idle(cache_idle), .perf_events(cache_perf_events)
    );

    assign cache_response_ready = 1'b1;

    always_comb begin
        for (ncc_texel = 0; ncc_texel < 16; ncc_texel = ncc_texel + 1)
            decode_ncc_y[ncc_texel] =
                ncc_words[active_tmu_state[0][5]][ncc_texel >> 2]
                         [(ncc_texel & 3)*8 +: 8];
        for (ncc_texel = 0; ncc_texel < 4; ncc_texel = ncc_texel + 1) begin
            decode_ncc_i[ncc_texel] =
                ncc_words[active_tmu_state[0][5]][ncc_texel + 4][26:0];
            decode_ncc_q[ncc_texel] =
                ncc_words[active_tmu_state[0][5]][ncc_texel + 8][26:0];
        end
    end

    generate
        genvar decoder_number;
        for (decoder_number = 0; decoder_number < 4; decoder_number++) begin : g_decode
            sst1_texel_decode decoder (
                .raw_texel(decode0_raw[decoder_number]),
                .format(active_tmu_state[0][11:8]),
                .ncc_y(decode_ncc_y), .ncc_i(decode_ncc_i),
                .ncc_q(decode_ncc_q),
                .palette_rgb(decode0_palette_rgb[decoder_number]),
                .rgb(decode_rgb_comb[decoder_number]),
                .alpha(decode_alpha_comb[decoder_number])
            );
        end
    endgenerate

    always_comb begin
        filter_weight[0] = 9'(5'(16 - rob_ds[decode1_id]) *
                              5'(16 - rob_dt[decode1_id]));
        filter_weight[1] = 9'(5'(rob_ds[decode1_id]) *
                              5'(16 - rob_dt[decode1_id]));
        filter_weight[2] = 9'(5'(16 - rob_ds[decode1_id]) *
                              5'(rob_dt[decode1_id]));
        filter_weight[3] = 9'(5'(rob_ds[decode1_id]) *
                              5'(rob_dt[decode1_id]));
        filtered_rgb_comb = decode1_rgb[0];
        filtered_alpha_comb = decode1_alpha[0];
        for (filter_channel = 0; filter_channel < 3;
             filter_channel = filter_channel + 1)
            filter_sum_rgb[filter_channel] = 20'd0;
        filter_sum_alpha = 20'd0;
        if (rob_bilinear[decode1_id]) begin
            for (filter_channel = 0; filter_channel < 3;
                 filter_channel = filter_channel + 1) begin
                filter_sum_rgb[filter_channel] =
                    decode1_rgb[0][filter_channel*8 +: 8] * filter_weight[0] +
                    decode1_rgb[1][filter_channel*8 +: 8] * filter_weight[1] +
                    decode1_rgb[2][filter_channel*8 +: 8] * filter_weight[2] +
                    decode1_rgb[3][filter_channel*8 +: 8] * filter_weight[3];
                filtered_rgb_comb[filter_channel*8 +: 8] =
                    filter_sum_rgb[filter_channel][15:8];
            end
            filter_sum_alpha = decode1_alpha[0] * filter_weight[0] +
                               decode1_alpha[1] * filter_weight[1] +
                               decode1_alpha[2] * filter_weight[2] +
                               decode1_alpha[3] * filter_weight[3];
            filtered_alpha_comb = filter_sum_alpha[15:8];
        end
    end

    sst1_texture_combine combine (
        .local_rgb(filtered_rgb), .local_alpha(filtered_alpha),
        .other_rgb(rob_other_rgb[filter_id]),
        .other_alpha(rob_other_alpha[filter_id]),
        .lod(rob_lod[filter_id]),
        .texture_mode(active_tmu_state[0]),
        .tdetail(active_tmu_state[2]),
        .result_rgb(combined_rgb), .result_alpha(combined_alpha)
    );

    assign result_valid = rob_valid[retire_pointer] && rob_done[retire_pointer];
    assign result = rob_result[retire_pointer];
    assign retire_fire = result_valid && result_ready;

    assign command_ready = rob_count == 0 && !front_busy && !address_valid &&
                           !upload_pending && cache_idle;
    assign upload_fire = upload_pending && mem_req_valid && mem_req_ready;
    assign idle = command_ready;
    always_comb begin
        perf_events = '0;
        perf_events.sample_accept = sample_fire;
        perf_events.result_retire = retire_fire;
        perf_events.rob_occupancy = 7'(rob_count);
        perf_events.cache = cache_perf_events;
    end

    always_comb begin
        mem_req_valid = upload_pending || cache_mem_req_valid;
        mem_req = '0;
        mem_req.beats = 8'd1;
        mem_req.order_class = SST1_ORDER_SOURCE;
        if (upload_pending) begin
            mem_req.addr = memory_base + {17'd0, upload_offset[22:4], 4'd0};
            mem_req.wdata = 128'(upload_data) << (upload_offset[3:0] * 8);
            mem_req.wstrb = 16'(upload_enable) << upload_offset[3:0];
            mem_req.tag = 8'h80;
            mem_req.source = SST1_MEM_TEX_UPLOAD;
            mem_req.write = 1'b1;
        end else
            mem_req = cache_mem_req;
        cache_mem_req_ready = mem_req_ready && !upload_pending;
        mem_rsp_ready = cache_mem_rsp_ready;
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            allocate_pointer <= '0;
            issue_pointer <= '0;
            retire_pointer <= '0;
            rob_count <= '0;
            active_tmu_state <= '0;
            upload_pending <= 1'b0;
            decode0_valid <= 1'b0;
            decode1_valid <= 1'b0;
            filter_valid <= 1'b0;
            address_valid <= 1'b0;
            for (reset_rob = 0; reset_rob < ROB_DEPTH; reset_rob = reset_rob + 1) begin
                rob_valid[reset_rob] <= 1'b0;
                rob_front_ready[reset_rob] <= 1'b0;
                rob_issued[reset_rob] <= 1'b0;
                rob_done[reset_rob] <= 1'b0;
                rob_address_error[reset_rob] <= 1'b0;
                rob_result[reset_rob] <= '0;
            end
            for (reset_table = 0; reset_table < 2; reset_table = reset_table + 1)
                for (reset_index = 0; reset_index < 12; reset_index = reset_index + 1)
                    ncc_words[reset_table][reset_index] <= '0;
            for (reset_index = 0; reset_index < 4; reset_index = reset_index + 1)
                front_id_pipe[reset_index] <= '0;
        end else begin
            case ({sample_fire, retire_fire})
                2'b10: rob_count <= rob_count + 1'b1;
                2'b01: rob_count <= rob_count - 1'b1;
                default: rob_count <= rob_count;
            endcase

            front_id_pipe[3] <= front_id_pipe[2];
            front_id_pipe[2] <= front_id_pipe[1];
            front_id_pipe[1] <= front_id_pipe[0];
            if (sample_fire)
                front_id_pipe[0] <= allocate_pointer;

            if (sample_fire) begin
                rob_valid[allocate_pointer] <= 1'b1;
                rob_front_ready[allocate_pointer] <= 1'b0;
                rob_issued[allocate_pointer] <= 1'b0;
                rob_done[allocate_pointer] <= 1'b0;
                rob_address_error[allocate_pointer] <= 1'b0;
                active_tmu_state <= sample.state.tmu_state;
                rob_other_rgb[allocate_pointer] <= sample.other_rgb;
                rob_other_alpha[allocate_pointer] <= sample.other_alpha;
                allocate_pointer <= allocate_pointer + 1'b1;
            end

            // Register the address-generator result before its dynamically
            // selected ROB write.  Without this boundary, LOD selection and
            // all four address calculations fed both the 64-way write decode
            // and the error-result enable in one cycle.  This stage changes
            // latency only; one completed address set can still enter the ROB
            // every clock.
            address_valid <= front_done;
            if (front_done) begin
                address_id <= front_output_id;
                address_lod <= front_lod;
                address_ds_reg <= address_ds;
                address_dt_reg <= address_dt;
                address_bilinear_reg <= address_bilinear;
                address_error <= !memory_enable ||
                                 address_value[0] + 2 > memory_size;
                for (seq_texel = 0; seq_texel < 4; seq_texel = seq_texel + 1)
                    address_value_reg[seq_texel] <= address_value[seq_texel];
            end

            if (address_valid) begin
                rob_front_ready[address_id] <= 1'b1;
                rob_lod[address_id] <= address_lod;
                rob_ds[address_id] <= address_ds_reg;
                rob_dt[address_id] <= address_dt_reg;
                rob_bilinear[address_id] <= address_bilinear_reg;
                for (seq_texel = 0; seq_texel < 4; seq_texel = seq_texel + 1)
                    rob_address[address_id][seq_texel] <= address_value_reg[seq_texel];
                if (address_error) begin
                    rob_address_error[address_id] <= 1'b1;
                    rob_done[address_id] <= 1'b1;
                    rob_result[address_id] <= '0;
                    rob_result[address_id].lod <= address_lod;
                    rob_result[address_id].error <= 1'b1;
                end
            end

            if (issue_fire || issue_skip) begin
                rob_issued[issue_pointer] <= 1'b1;
                issue_pointer <= issue_pointer + 1'b1;
            end

            decode0_valid <= cache_response_valid && cache_response_ready;
            if (cache_response_valid && cache_response_ready) begin
                decode0_id <= cache_response_id[ROB_BITS-1:0];
                decode0_error <= cache_response_error;
                for (seq_texel = 0; seq_texel < 4; seq_texel = seq_texel + 1) begin
                    decode0_raw[seq_texel] <= cache_texel[seq_texel];
                end
            end

            decode1_valid <= decode0_valid;
            if (decode0_valid) begin
                decode1_id <= decode0_id;
                decode1_error <= decode0_error;
                for (seq_texel = 0; seq_texel < 4; seq_texel = seq_texel + 1) begin
                    decode1_rgb[seq_texel] <= decode_rgb_comb[seq_texel];
                    decode1_alpha[seq_texel] <= decode_alpha_comb[seq_texel];
                end
            end

            filter_valid <= decode1_valid;
            if (decode1_valid) begin
                filter_id <= decode1_id;
                filter_error <= decode1_error;
                filtered_rgb <= filtered_rgb_comb;
                filtered_alpha <= filtered_alpha_comb;
            end

            if (filter_valid) begin
                rob_done[filter_id] <= 1'b1;
                rob_result[filter_id].rgb <= combined_rgb;
                rob_result[filter_id].alpha <= combined_alpha;
                rob_result[filter_id].lod <= rob_lod[filter_id];
                rob_result[filter_id].error <= filter_error;
            end

            if (retire_fire) begin
                rob_valid[retire_pointer] <= 1'b0;
                rob_front_ready[retire_pointer] <= 1'b0;
                rob_issued[retire_pointer] <= 1'b0;
                rob_done[retire_pointer] <= 1'b0;
                retire_pointer <= retire_pointer + 1'b1;
            end

            if (upload_fire)
                upload_pending <= 1'b0;

            if (command_valid && command_ready) begin
                if (command.table_write) begin
                    if (!command_table_number && command_table_index >= 4 &&
                        command.data[31]) begin
                        // Palette RAM write is handled by the replicated ports.
                    end else if (command_table_index < 12) begin
                        for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                            if (command.byte_enable[byte_index])
                                ncc_words[command_table_number][command_table_index]
                                         [byte_index*8 +: 8] <=
                                    command.data[byte_index*8 +: 8];
                    end
                end else if (layout_valid && memory_enable &&
                             layout_offset + 4 <= memory_size) begin
                    upload_offset <= layout_offset;
                    upload_data <= layout_data;
                    upload_enable <= layout_enable;
                    upload_pending <= 1'b1;
                end
            end
        end
    end
endmodule

// One synchronous read per bilinear neighbor, preserving decode0 latency.
// Reset only validity, not RAM data, so this infers block RAM. Same-address
// read/write returns the old value (including zero before the first write).
module sst1_palette_ram (
    input logic clk, reset_n, write_enable, read_enable,
    input logic [7:0] write_address, read_address,
    input logic [23:0] write_data,
    output wire [23:0] read_data
);
    (* ram_style = "block" *) logic [23:0] data [0:255];
    logic [255:0] valid;
    logic [23:0] read_raw;
    logic read_valid;
    always_ff @(posedge clk) begin
        if (reset_n && write_enable)
            data[write_address] <= write_data;
        if (read_enable)
            read_raw <= data[read_address];
    end
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            valid <= '0;
            read_valid <= 1'b0;
        end else begin
            if (write_enable) valid[write_address] <= 1'b1;
            if (read_enable) read_valid <= valid[read_address];
        end
    end
    assign read_data = read_valid ? read_raw : 24'd0;
endmodule
