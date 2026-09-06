// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Nonblocking cache for one 16-bit FBI framebuffer stream.  Lookups retire in
// issue order, while up to MSHR_COUNT independent 64-byte DDR line fills may
// complete out of order.  New scanline addresses allocate on arrival even
// while an older lookup is waiting, hiding the DDR first-beat latency.
module sst1_fb_read_cache #(
    parameter integer INDEX_BITS = 6,
    parameter integer MSHR_COUNT = 8,
    parameter integer WAIT_COUNT = 64,
    parameter integer PREFETCH_LINES = 0,
    parameter logic [3:0] TAG_PREFIX = 4'h4,
    parameter sst1_pkg::sst1_mem_source_t MEMORY_SOURCE =
        sst1_pkg::SST1_MEM_FB_COLOR
) (
    input  logic                    clk,
    input  logic                    reset_n,
    input  logic                    memory_enable,
    input  logic [39:0]             memory_base,
    input  logic [23:0]             memory_size,

    input  logic                    lookup_valid,
    output logic                    lookup_ready,
    input  logic [23:0]             lookup_address,
    input  logic [7:0]              lookup_id,
    output logic                    response_valid,
    input  logic                    response_ready,
    output logic [15:0]             response_data,
    output logic [7:0]              response_id,
    output logic                    response_error,

    input  logic                    invalidate_valid,
    input  logic [23:0]             invalidate_address,
    input  logic                    invalidate_all,

    output logic                    mem_req_valid,
    input  logic                    mem_req_ready,
    output sst1_pkg::sst1_mem_req_t mem_req,
    input  logic                    mem_rsp_valid,
    output logic                    mem_rsp_ready,
    input  sst1_pkg::sst1_mem_rsp_t mem_rsp,
    output logic                    idle,
    output sst1_pkg::sst1_cache_perf_events_t perf_events
);
    import sst1_pkg::*;

    localparam integer LINE_BITS = 6;
    localparam integer LINE_COUNT = 1 << INDEX_BITS;
    localparam integer TAG_BITS = 24 - LINE_BITS - INDEX_BITS;
    localparam integer BEATS_PER_LINE = (1 << LINE_BITS) / 16;
    localparam integer BEAT_BITS = $clog2(BEATS_PER_LINE);
    localparam integer RAM_ADDRESS_BITS = INDEX_BITS + LINE_BITS - 4;
    localparam integer MSHR_BITS = $clog2(MSHR_COUNT);
    localparam integer WAIT_BITS = $clog2(WAIT_COUNT);
    localparam integer WAIT_PAYLOAD_BITS = 33;

    logic [TAG_BITS-1:0] cache_tag [0:LINE_COUNT-1];
    logic cache_valid [0:LINE_COUNT-1];
    logic [127:0] cache_read_data;
    logic cache_read_enable;
    logic [RAM_ADDRESS_BITS-1:0] cache_read_index;
    logic cache_write_enable;
    logic [RAM_ADDRESS_BITS-1:0] cache_write_index;

    // Two front registers avoid an asynchronous mux across the complete
    // replay store. Vivado maps the shallow tail efficiently to LUTRAM.
    logic [WAIT_PAYLOAD_BITS-1:0] wait_memory [0:WAIT_COUNT-1];
    logic [WAIT_PAYLOAD_BITS-1:0] wait_front_payload;
    logic [WAIT_PAYLOAD_BITS-1:0] wait_prefetch_payload;
    logic [WAIT_PAYLOAD_BITS-1:0] wait_push_payload;
    logic [23:0] wait_front_address;
    logic [7:0] wait_front_id;
    logic wait_front_error;
    logic [WAIT_BITS-1:0] wait_head, wait_tail;
    logic [WAIT_BITS:0] wait_count;
    logic wait_push, wait_pop;

    logic mshr_valid [0:MSHR_COUNT-1];
    logic mshr_issued [0:MSHR_COUNT-1];
    logic mshr_error [0:MSHR_COUNT-1];
    logic [23:LINE_BITS] mshr_line [0:MSHR_COUNT-1];
    logic [BEAT_BITS-1:0] mshr_beat [0:MSHR_COUNT-1];

    logic live_hit, live_range_error;
    logic head_hit, head_line_error;
    logic free_mshr_found, issue_mshr_found;
    logic [MSHR_BITS-1:0] free_mshr, issue_mshr;
    logic issue_hold_valid;
    logic [MSHR_BITS-1:0] issue_hold_mshr, selected_issue_mshr;
    logic allocation_found;
    logic [23:LINE_BITS] allocation_line;
    logic head_allocation_active, head_allocation_index_busy;
    logic live_allocation_active, live_allocation_index_busy;
    logic prefetch_valid, prefetch_active, prefetch_resident;
    logic prefetch_index_busy, prefetch_in_range, allocation_prefetch;
    logic [23:LINE_BITS] prefetch_line;
    logic [1:0] prefetch_remaining;
    logic head_allocation_valid, live_allocation_valid;
    logic response_slot_ready, schedule_live, schedule_replay;
    logic scheduled_error;
    logic [23:0] scheduled_address;
    logic [7:0] scheduled_id;
    logic [3:0] response_byte_offset;
    logic response_valid_reg, response_error_reg;
    logic [7:0] response_id_reg;
    logic [MSHR_BITS-1:0] response_mshr;
    logic response_mshr_valid;
    logic any_mshr;
    logic [4:0] mshr_occupancy;

    integer comb_mshr, reset_line, reset_mshr;

    initial begin
        if ((MSHR_COUNT & (MSHR_COUNT - 1)) != 0 || MSHR_COUNT > 16)
            $error("MSHR_COUNT must be a power of two no larger than 16");
        if ((WAIT_COUNT & (WAIT_COUNT - 1)) != 0)
            $error("WAIT_COUNT must be a power of two");
    end

    function automatic logic address_hit(input logic [23:0] address);
        logic [INDEX_BITS-1:0] index;
        logic index_filling;
        integer active_mshr;
        begin
            index = address[LINE_BITS +: INDEX_BITS];
            // A replacement fill overwrites the victim data RAM one beat at
            // a time.  Hide the resident tag while an MSHR owns its direct-
            // mapped index so a framebuffer lookup cannot consume a mixture
            // of the old and new lines.
            index_filling = 1'b0;
            for (active_mshr = 0; active_mshr < MSHR_COUNT;
                 active_mshr = active_mshr + 1)
                if (mshr_valid[active_mshr] &&
                    mshr_line[active_mshr][LINE_BITS +: INDEX_BITS] == index)
                    index_filling = 1'b1;
            return cache_valid[index] &&
                   cache_tag[index] == address[23 -: TAG_BITS] &&
                   !index_filling;
        end
    endfunction

    // Use a true simple-dual-port block RAM: one independent fill port and
    // one synchronous replay/read port.
    (* ram_style = "block" *) logic [127:0]
        cache_data [0:(1<<RAM_ADDRESS_BITS)-1];
    always_ff @(posedge clk) begin
        if (cache_write_enable)
            cache_data[cache_write_index] <= mem_rsp.rdata;
        if (cache_read_enable)
            cache_read_data <= cache_data[cache_read_index];
    end

    always_comb begin
        wait_front_id = wait_front_payload[7:0];
        wait_front_address = wait_front_payload[31:8];
        wait_front_error = wait_front_payload[32];
        live_hit = address_hit(lookup_address);
        live_range_error = !memory_enable || lookup_address + 2 > memory_size;
        wait_push_payload = {live_range_error, lookup_address, lookup_id};
        head_hit = wait_count != 0 && address_hit(wait_front_address);
        head_line_error = 1'b0;
        for (comb_mshr = 0; comb_mshr < MSHR_COUNT;
             comb_mshr = comb_mshr + 1)
            if (wait_count != 0 && mshr_valid[comb_mshr] &&
                mshr_error[comb_mshr] &&
                mshr_line[comb_mshr] == wait_front_address[23:LINE_BITS])
                head_line_error = 1'b1;

        free_mshr_found = 1'b0;
        free_mshr = '0;
        issue_mshr_found = 1'b0;
        issue_mshr = '0;
        any_mshr = 1'b0;
        mshr_occupancy = '0;
        for (comb_mshr = 0; comb_mshr < MSHR_COUNT;
             comb_mshr = comb_mshr + 1) begin
            any_mshr = any_mshr || mshr_valid[comb_mshr];
            if (mshr_valid[comb_mshr])
                mshr_occupancy = mshr_occupancy + 1'b1;
            if (!mshr_valid[comb_mshr] && !free_mshr_found) begin
                free_mshr_found = 1'b1;
                free_mshr = MSHR_BITS'(comb_mshr);
            end
            if (mshr_valid[comb_mshr] && !mshr_issued[comb_mshr] &&
                !issue_mshr_found) begin
                issue_mshr_found = 1'b1;
                issue_mshr = MSHR_BITS'(comb_mshr);
            end
        end

        // Allocate the oldest blocked demand first. Once it has an active
        // fill, use arriving pixels to discover and launch later scanline
        // lines before the replay head reaches them.
        head_allocation_valid = wait_count != 0 && !wait_front_error &&
                                !head_hit && !head_line_error;
        live_allocation_valid = lookup_valid && !live_range_error &&
                                !live_hit;
        head_allocation_active = 1'b0;
        head_allocation_index_busy = 1'b0;
        live_allocation_active = 1'b0;
        live_allocation_index_busy = 1'b0;
        prefetch_active = 1'b0;
        prefetch_index_busy = 1'b0;
        for (comb_mshr = 0; comb_mshr < MSHR_COUNT;
             comb_mshr = comb_mshr + 1) begin
            if (mshr_valid[comb_mshr] &&
                mshr_line[comb_mshr] == wait_front_address[23:LINE_BITS])
                head_allocation_active = 1'b1;
            if (mshr_valid[comb_mshr] &&
                mshr_line[comb_mshr][LINE_BITS +: INDEX_BITS] ==
                    wait_front_address[LINE_BITS +: INDEX_BITS])
                head_allocation_index_busy = 1'b1;
            if (mshr_valid[comb_mshr] &&
                mshr_line[comb_mshr] == lookup_address[23:LINE_BITS])
                live_allocation_active = 1'b1;
            if (mshr_valid[comb_mshr] &&
                mshr_line[comb_mshr][LINE_BITS +: INDEX_BITS] ==
                    lookup_address[LINE_BITS +: INDEX_BITS])
                live_allocation_index_busy = 1'b1;
            if (mshr_valid[comb_mshr] &&
                mshr_line[comb_mshr] == prefetch_line)
                prefetch_active = 1'b1;
            if (mshr_valid[comb_mshr] &&
                mshr_line[comb_mshr][LINE_BITS +: INDEX_BITS] ==
                    prefetch_line[LINE_BITS +: INDEX_BITS])
                prefetch_index_busy = 1'b1;
        end
        prefetch_resident = cache_valid[
            prefetch_line[LINE_BITS +: INDEX_BITS]] &&
            cache_tag[prefetch_line[LINE_BITS +: INDEX_BITS]] ==
                prefetch_line[23 -: TAG_BITS];
        prefetch_in_range =
            {16'd0, prefetch_line, {LINE_BITS{1'b0}}} +
                (1 << LINE_BITS) <= {16'd0, memory_size};
        if (head_allocation_valid && !head_allocation_active &&
            !head_allocation_index_busy)
            allocation_line = wait_front_address[23:LINE_BITS];
        else if (live_allocation_valid && !live_allocation_active &&
                 !live_allocation_index_busy)
            allocation_line = lookup_address[23:LINE_BITS];
        else
            allocation_line = prefetch_line;
        allocation_prefetch =
            !(head_allocation_valid && !head_allocation_active &&
              !head_allocation_index_busy) &&
            !(live_allocation_valid && !live_allocation_active &&
              !live_allocation_index_busy);
        allocation_found = free_mshr_found &&
            ((head_allocation_valid && !head_allocation_active &&
              !head_allocation_index_busy) ||
             (live_allocation_valid && !live_allocation_active &&
              !live_allocation_index_busy) ||
             (prefetch_valid && !prefetch_resident && !prefetch_active &&
              !prefetch_index_busy && prefetch_in_range));

        response_slot_ready = !response_valid_reg || response_ready;
        schedule_replay = response_slot_ready && wait_count != 0 &&
                          (wait_front_error || head_line_error || head_hit);
        schedule_live = response_slot_ready && wait_count == 0 &&
                        lookup_valid && (live_range_error || live_hit);
        lookup_ready = wait_count == 0 && (live_range_error || live_hit) ?
                       response_slot_ready : wait_count < (WAIT_BITS+1)'(WAIT_COUNT);
        wait_push = lookup_valid && lookup_ready && !schedule_live;
        wait_pop = schedule_replay;

        scheduled_address = schedule_replay ? wait_front_address :
                                              lookup_address;
        scheduled_id = schedule_replay ? wait_front_id : lookup_id;
        scheduled_error = schedule_replay ?
            (wait_front_error || head_line_error) : live_range_error;
        cache_read_enable = (schedule_live || schedule_replay) &&
                            !scheduled_error;
        cache_read_index =
            {scheduled_address[LINE_BITS +: INDEX_BITS],
             scheduled_address[LINE_BITS-1:4]};

        response_valid = response_valid_reg;
        response_id = response_id_reg;
        response_error = response_error_reg;
        response_data = response_error_reg ? 16'd0 :
            16'(cache_read_data >> (response_byte_offset * 8));

        selected_issue_mshr = issue_hold_valid ? issue_hold_mshr : issue_mshr;
        mem_req_valid = issue_hold_valid || issue_mshr_found;
        mem_req = '0;
        mem_req.addr = memory_base +
                       {16'd0, mshr_line[selected_issue_mshr],
                        {LINE_BITS{1'b0}}};
        mem_req.beats = 8'(BEATS_PER_LINE);
        mem_req.tag = {TAG_PREFIX, 4'(selected_issue_mshr)};
        mem_req.source = MEMORY_SOURCE;
        mem_req.order_class = SST1_ORDER_RELAXED;

        response_mshr = mem_rsp.tag[MSHR_BITS-1:0];
        response_mshr_valid = mem_rsp.tag[7:4] == TAG_PREFIX &&
                              mshr_valid[response_mshr] &&
                              mshr_issued[response_mshr];
        mem_rsp_ready = response_mshr_valid;
        cache_write_enable = mem_rsp_valid && mem_rsp_ready &&
                             !mem_rsp.error;
        cache_write_index =
            {mshr_line[response_mshr][LINE_BITS +: INDEX_BITS],
             mshr_beat[response_mshr]};
        idle = wait_count == 0 && !any_mshr && !response_valid_reg;
        perf_events = '0;
        perf_events.lookup = lookup_valid && lookup_ready;
        perf_events.hit = perf_events.lookup && live_hit;
        perf_events.miss = perf_events.lookup && !live_hit;
        perf_events.replay = schedule_replay;
        perf_events.demand_allocation = allocation_found &&
                                        !allocation_prefetch;
        perf_events.prefetch_allocation = allocation_found &&
                                          allocation_prefetch;
        perf_events.fill_request = mem_req_valid && mem_req_ready;
        perf_events.fill_beat = mem_rsp_valid && mem_rsp_ready;
        perf_events.fill_error = perf_events.fill_beat && mem_rsp.error;
        perf_events.invalidation = invalidate_valid || invalidate_all;
        perf_events.wait_occupancy = 7'(wait_count);
        perf_events.mshr_occupancy = mshr_occupancy;
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            response_valid_reg <= 1'b0;
            response_error_reg <= 1'b0;
            response_id_reg <= '0;
            response_byte_offset <= '0;
            wait_front_payload <= '0;
            wait_prefetch_payload <= '0;
            wait_head <= '0;
            wait_tail <= '0;
            wait_count <= '0;
            prefetch_valid <= 1'b0;
            prefetch_line <= '0;
            prefetch_remaining <= '0;
            issue_hold_valid <= 1'b0;
            issue_hold_mshr <= '0;
            for (reset_line = 0; reset_line < LINE_COUNT;
                 reset_line = reset_line + 1)
                cache_valid[reset_line] <= 1'b0;
            for (reset_mshr = 0; reset_mshr < MSHR_COUNT;
                 reset_mshr = reset_mshr + 1) begin
                mshr_valid[reset_mshr] <= 1'b0;
                mshr_issued[reset_mshr] <= 1'b0;
                mshr_error[reset_mshr] <= 1'b0;
                mshr_line[reset_mshr] <= '0;
                mshr_beat[reset_mshr] <= '0;
            end
        end else begin
            if (response_valid_reg && response_ready)
                response_valid_reg <= 1'b0;
            if (schedule_live || schedule_replay) begin
                response_valid_reg <= 1'b1;
                response_error_reg <= scheduled_error;
                response_id_reg <= scheduled_id;
                response_byte_offset <= scheduled_address[3:0];
            end

            case ({wait_push, wait_pop})
                2'b10: begin
                    wait_count <= wait_count + 1'b1;
                    if (wait_count == 0)
                        wait_front_payload <= wait_push_payload;
                    else if (wait_count == 1)
                        wait_prefetch_payload <= wait_push_payload;
                    else begin
                        wait_memory[wait_tail] <= wait_push_payload;
                        wait_tail <= wait_tail + 1'b1;
                    end
                end
                2'b01: begin
                    wait_count <= wait_count - 1'b1;
                    if (wait_count >= 2)
                        wait_front_payload <= wait_prefetch_payload;
                    if (wait_count >= 3) begin
                        wait_prefetch_payload <= wait_memory[wait_head];
                        wait_head <= wait_head + 1'b1;
                    end
                end
                2'b11: begin
                    if (wait_count == 1)
                        wait_front_payload <= wait_push_payload;
                    else if (wait_count == 2) begin
                        wait_front_payload <= wait_prefetch_payload;
                        wait_prefetch_payload <= wait_push_payload;
                    end else begin
                        wait_front_payload <= wait_prefetch_payload;
                        wait_prefetch_payload <= wait_memory[wait_head];
                        wait_memory[wait_tail] <= wait_push_payload;
                        wait_head <= wait_head + 1'b1;
                        wait_tail <= wait_tail + 1'b1;
                    end
                end
                default: begin end
            endcase

            if (prefetch_valid &&
                (prefetch_resident || prefetch_active || !prefetch_in_range)) begin
                prefetch_valid <= 1'b0;
                prefetch_remaining <= '0;
            end
            if (allocation_found) begin
                mshr_valid[free_mshr] <= 1'b1;
                mshr_issued[free_mshr] <= 1'b0;
                mshr_error[free_mshr] <= 1'b0;
                mshr_line[free_mshr] <= allocation_line;
                mshr_beat[free_mshr] <= '0;
                if (allocation_prefetch) begin
                    if (prefetch_remaining > 1) begin
                        prefetch_valid <= 1'b1;
                        prefetch_line <= prefetch_line + 1'b1;
                        prefetch_remaining <= prefetch_remaining - 1'b1;
                    end else begin
                        prefetch_valid <= 1'b0;
                        prefetch_remaining <= '0;
                    end
                end else begin
                    prefetch_valid <= PREFETCH_LINES != 0;
                    prefetch_line <= allocation_line + 1'b1;
                    prefetch_remaining <= 2'(PREFETCH_LINES);
                end
            end
            if (!issue_hold_valid && issue_mshr_found && !mem_req_ready) begin
                issue_hold_valid <= 1'b1;
                issue_hold_mshr <= issue_mshr;
            end
            if (mem_req_valid && mem_req_ready) begin
                mshr_issued[selected_issue_mshr] <= 1'b1;
                issue_hold_valid <= 1'b0;
            end

            if (mem_rsp_valid && mem_rsp_ready) begin
                mshr_error[response_mshr] <=
                    mshr_error[response_mshr] || mem_rsp.error;
                if (mem_rsp.last ||
                    mshr_beat[response_mshr] ==
                        BEAT_BITS'(BEATS_PER_LINE-1)) begin
                    cache_tag[mshr_line[response_mshr]
                                  [LINE_BITS +: INDEX_BITS]] <=
                        mshr_line[response_mshr][23 -: TAG_BITS];
                    cache_valid[mshr_line[response_mshr]
                                    [LINE_BITS +: INDEX_BITS]] <=
                        !mshr_error[response_mshr] && !mem_rsp.error;
                    mshr_valid[response_mshr] <=
                        mshr_error[response_mshr] || mem_rsp.error;
                    mshr_issued[response_mshr] <=
                        mshr_error[response_mshr] || mem_rsp.error;
                    mshr_beat[response_mshr] <= '0;
                end else begin
                    mshr_beat[response_mshr] <=
                        mshr_beat[response_mshr] + 1'b1;
                end
            end

            if (wait_count == 0)
                for (reset_mshr = 0; reset_mshr < MSHR_COUNT;
                     reset_mshr = reset_mshr + 1)
                    if (mshr_error[reset_mshr]) begin
                        mshr_valid[reset_mshr] <= 1'b0;
                        mshr_issued[reset_mshr] <= 1'b0;
                        mshr_error[reset_mshr] <= 1'b0;
                        mshr_beat[reset_mshr] <= '0;
                    end

            if (invalidate_valid &&
                cache_tag[invalidate_address[LINE_BITS +: INDEX_BITS]] ==
                    invalidate_address[23 -: TAG_BITS])
                cache_valid[invalidate_address[LINE_BITS +: INDEX_BITS]] <=
                    1'b0;
            if (invalidate_all)
                for (reset_line = 0; reset_line < LINE_COUNT;
                     reset_line = reset_line + 1)
                    cache_valid[reset_line] <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    property p_request_stable;
        @(posedge clk) disable iff (!reset_n)
            mem_req_valid && !mem_req_ready |=> mem_req_valid &&
                                                $stable(mem_req);
    endproperty
    assert property (p_request_stable);
`endif
endmodule
