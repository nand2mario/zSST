// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// One asynchronous tag read and one synchronous update. The texture cache
// replicates this small distributed RAM for each logical lookup port. That is
// much cheaper, and easier to route, than implementing many asynchronous reads
// from one flip-flop array with a separate 64:1 mux on every port.
module sst1_texture_tag_ram #(
    parameter integer INDEX_BITS = 6,
    parameter integer TAG_BITS = 10
) (
    input  logic                    clk,
    input  logic                    write_enable,
    input  logic [INDEX_BITS-1:0]   write_address,
    input  logic [TAG_BITS:0]       write_data,
    input  logic [INDEX_BITS-1:0]   read_address,
    output logic [TAG_BITS:0]       read_data
);
    (* ram_style = "distributed" *) logic [TAG_BITS:0]
        storage [0:(1<<INDEX_BITS)-1];

    assign read_data = storage[read_address];

    always_ff @(posedge clk)
        if (write_enable)
            storage[write_address] <= write_data;
endmodule

// Two-way, four-read texture cache with coalescing miss contexts.  A
// lookup that misses is parked in a replay queue while independent resident
// lookups continue.  Unique 64-byte lines are allocated to tagged MSHRs and
// may complete out of request order; lookup results retain their caller ID.
module sst1_texture_cache #(
    parameter integer INDEX_BITS = 6,
    parameter integer LINE_BITS = 6,
    parameter integer MSHR_COUNT = 8,
    parameter integer WAIT_COUNT = 64,
    parameter integer PREFETCH_DISTANCE_LINES = 2
) (
    input  logic                    clk,
    input  logic                    reset_n,
    input  logic                    memory_enable,
    input  logic [39:0]             memory_base,
    input  logic [23:0]             memory_size,
    input  logic                    lookup_valid,
    output logic                    lookup_ready,
    input  logic [3:0]              lookup_mask,
    input  logic [21:0]             lookup_address [0:3],
    input  logic [7:0]              lookup_id,
    output logic                    response_valid,
    input  logic                    response_ready,
    output logic [15:0]             response_texel [0:3],
    output logic [7:0]              response_id,
    output logic                    response_error,
    input  logic                    invalidate_valid,
    input  logic [21:0]             invalidate_address,
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

    localparam integer LINE_BYTES = 1 << LINE_BITS;
    localparam integer LINE_COUNT = 1 << INDEX_BITS;
    localparam integer TAG_BITS = 22 - LINE_BITS - INDEX_BITS;
    localparam integer BEATS_PER_LINE = LINE_BYTES / 16;
    localparam integer BEAT_BITS = $clog2(BEATS_PER_LINE);
    localparam integer RAM_ADDRESS_BITS = INDEX_BITS + LINE_BITS - 4;
    localparam integer MSHR_BITS = $clog2(MSHR_COUNT);
    localparam integer WAIT_BITS = $clog2(WAIT_COUNT);
    localparam integer WAIT_PAYLOAD_BITS = 101;
    localparam integer WAY_COUNT = 2;
    localparam integer WAY_BITS = $clog2(WAY_COUNT);
    localparam integer TAG_LIVE_BASE = 0;
    localparam integer TAG_HEAD_BASE = 4;
    localparam integer TAG_WAIT_PREFETCH_BASE = 8;
    localparam integer TAG_PREFETCH_LINE = 12;
    localparam integer TAG_LOOKUP_COUNT = 13;

    logic [WAY_BITS-1:0] replacement_way [0:LINE_COUNT-1];
    logic [INDEX_BITS-1:0] tag_lookup_address [0:TAG_LOOKUP_COUNT-1];
    logic [TAG_BITS:0] tag_lookup_data [0:TAG_LOOKUP_COUNT-1]
                                          [0:WAY_COUNT-1];
    logic [TAG_BITS:0] allocation_tag_data [0:WAY_COUNT-1];
    logic tag_write_enable [0:WAY_COUNT-1];
    logic [INDEX_BITS-1:0] tag_write_address;
    logic [TAG_BITS:0] tag_write_data [0:WAY_COUNT-1];
    logic cache_initializing;
    logic [INDEX_BITS-1:0] cache_init_index;

    // Keep the active and prefetched heads in registers. Requests behind
    // them use a synchronous simple-dual-port memory, allowing one enqueue
    // and one replay dequeue per clock without an asynchronous 64-way mux.
    // Vivado maps this shallow 64 x 101 store efficiently into RAM64M LUTRAM;
    // forcing a K26 block RAM would waste most of a much deeper primitive.
    logic [WAIT_PAYLOAD_BITS-1:0] wait_memory [0:WAIT_COUNT-1];
    logic [WAIT_PAYLOAD_BITS-1:0] wait_front_payload;
    logic [WAIT_PAYLOAD_BITS-1:0] wait_prefetch_payload;
    logic [WAIT_PAYLOAD_BITS-1:0] wait_push_payload;
    logic wait_front_error;
    logic [3:0] wait_front_mask;
    logic [21:0] wait_front_address [0:3];
    logic [7:0] wait_front_id;
    logic wait_front_served;
    logic wait_prefetch_error;
    logic [3:0] wait_prefetch_mask;
    logic [21:0] wait_prefetch_address [0:3];
    logic [7:0] wait_prefetch_id;
    logic wait_prefetch_served;
    logic [WAIT_BITS-1:0] wait_head, wait_tail;
    logic [WAIT_BITS:0] wait_count;
    logic [3:0] head_hit;
    logic [WAY_BITS-1:0] head_way [0:3];
    logic [WAY_BITS:0] head_lookup [0:3];
    logic head_all_hit, head_line_error;
    logic [3:0] prefetch_hit;
    logic [WAY_BITS-1:0] prefetch_way [0:3];
    logic [WAY_BITS:0] wait_prefetch_lookup [0:3];
    logic prefetch_all_hit, prefetch_line_error;
    logic wait_push, wait_pop, wait_drop_served;

    logic mshr_valid [0:MSHR_COUNT-1];
    logic mshr_issued [0:MSHR_COUNT-1];
    logic mshr_error [0:MSHR_COUNT-1];
    logic [21:0] mshr_line [0:MSHR_COUNT-1];
    logic [BEAT_BITS-1:0] mshr_beat [0:MSHR_COUNT-1];
    logic [WAY_BITS-1:0] mshr_way [0:MSHR_COUNT-1];
    logic [LINE_COUNT-1:0] mshr_busy_way [0:WAY_COUNT-1];

    logic [3:0] live_hit;
    logic [WAY_BITS-1:0] live_way [0:3];
    logic [WAY_BITS:0] live_lookup [0:3];
    logic live_all_hit, live_range_error;
    logic free_mshr_found;
    logic [MSHR_BITS-1:0] free_mshr;
    logic issue_mshr_found;
    logic [MSHR_BITS-1:0] issue_mshr;
    logic allocation_found;
    logic [21:0] allocation_line;
    logic allocation_line_active;
    logic allocation_prefetch;
    logic demand_allocation_found;
    logic [21:0] demand_allocation_line;
    logic live_allocation_found;
    logic [21:0] live_allocation_line;
    logic live_line_active;
    logic prefetch_valid;
    logic [21:0] prefetch_line;
    logic [WAY_BITS:0] prefetch_line_lookup;
    logic prefetch_resident, prefetch_active, prefetch_index_busy;
    logic prefetch_in_range;
    logic response_slot_ready;
    logic schedule_live, schedule_replay, schedule_replay_head;
    logic schedule_replay_prefetch;
    logic scheduled_error;
    logic [7:0] scheduled_id;
    logic [21:0] scheduled_address [0:3];
    logic [WAY_BITS-1:0] scheduled_way [0:3];
    logic [WAY_BITS-1:0] allocation_way;
    logic [INDEX_BITS-1:0] allocation_index;

    logic cache_read_enable, cache_write_enable;
    logic [RAM_ADDRESS_BITS:0] cache_read_address [0:3];
    logic [RAM_ADDRESS_BITS:0] cache_write_address;
    logic [127:0] cache_read_data [0:3];
    logic [3:0] response_byte_offset [0:3];
    logic [127:0] shifted_read_data [0:3];
    logic response_valid_reg, response_error_reg;
    logic [7:0] response_id_reg;

    logic [MSHR_BITS-1:0] response_mshr;
    logic response_mshr_valid;
    logic any_wait, any_mshr;
    logic [4:0] mshr_occupancy;

    integer comb_port, comb_mshr, busy_mshr, busy_way;
    integer seq_port, reset_line, reset_mshr, reset_way, tag_comb_way;

    initial begin
        if ((MSHR_COUNT & (MSHR_COUNT - 1)) != 0 || MSHR_COUNT > 16)
            $error("MSHR_COUNT must be a power of two no larger than 16");
        if ((WAIT_COUNT & (WAIT_COUNT - 1)) != 0)
            $error("WAIT_COUNT must be a power of two");
    end

    // Return the resident indication and way from one tag-array lookup.  Keep
    // these together: separate hit and way helpers duplicate every tag compare
    // for the live and replay ports and create a congested high-fanout cone.
    function automatic logic [WAY_BITS:0] address_lookup(
        input logic [TAG_BITS:0] way0_entry,
        input logic [TAG_BITS:0] way1_entry,
        input logic [21:0] address
    );
        logic [INDEX_BITS-1:0] index;
        logic [TAG_BITS-1:0] address_tag;
        logic [TAG_BITS:0] active_entry;
        logic way_filling;
        integer active_way;
        begin
            index = address[LINE_BITS +: INDEX_BITS];
            address_tag = address[21 -: TAG_BITS];
            address_lookup = '0;
            for (active_way = 0; active_way < WAY_COUNT;
                 active_way = active_way + 1) begin
                active_entry = active_way == 0 ? way0_entry : way1_entry;
                // Suppress only the way being overwritten by an active fill.
                // The other way remains available for hit-under-miss service.
                way_filling = mshr_busy_way[active_way][index];
                if (active_entry[TAG_BITS] &&
                    active_entry[TAG_BITS-1:0] == address_tag) begin
                    address_lookup[WAY_BITS-1:0] = WAY_BITS'(active_way);
                    if (!way_filling)
                        address_lookup[WAY_BITS] = 1'b1;
                end
            end
        end
    endfunction

    generate
        genvar tag_port, tag_way;
        for (tag_port = 0; tag_port < TAG_LOOKUP_COUNT;
             tag_port = tag_port + 1) begin : g_tag_port
            for (tag_way = 0; tag_way < WAY_COUNT;
                 tag_way = tag_way + 1) begin : g_tag_way
                sst1_texture_tag_ram #(.INDEX_BITS(INDEX_BITS),
                    .TAG_BITS(TAG_BITS)) tag_ram (
                    .clk,
                    .write_enable(tag_write_enable[tag_way]),
                    .write_address(tag_write_address),
                    .write_data(tag_write_data[tag_way]),
                    .read_address(tag_lookup_address[tag_port]),
                    .read_data(tag_lookup_data[tag_port][tag_way])
                );
            end
        end

        for (tag_way = 0; tag_way < WAY_COUNT;
             tag_way = tag_way + 1) begin : g_allocation_tag_way
            sst1_texture_tag_ram #(.INDEX_BITS(INDEX_BITS),
                .TAG_BITS(TAG_BITS)) tag_ram (
                .clk,
                .write_enable(tag_write_enable[tag_way]),
                .write_address(tag_write_address),
                .write_data(tag_write_data[tag_way]),
                .read_address(allocation_index),
                .read_data(allocation_tag_data[tag_way])
            );
        end

        genvar tag_request_port;
        for (tag_request_port = 0; tag_request_port < 4;
             tag_request_port = tag_request_port + 1) begin : g_tag_address
            assign tag_lookup_address[TAG_LIVE_BASE + tag_request_port] =
                lookup_address[tag_request_port][LINE_BITS +: INDEX_BITS];
            assign tag_lookup_address[TAG_HEAD_BASE + tag_request_port] =
                wait_front_address[tag_request_port]
                                  [LINE_BITS +: INDEX_BITS];
            assign tag_lookup_address[TAG_WAIT_PREFETCH_BASE +
                                      tag_request_port] =
                wait_prefetch_address[tag_request_port]
                                     [LINE_BITS +: INDEX_BITS];
        end
    endgenerate

    assign tag_lookup_address[TAG_PREFETCH_LINE] =
        prefetch_line[LINE_BITS +: INDEX_BITS];

    // Decode the small MSHR bank once. Previously every tag lookup repeated
    // all MSHR index/way comparisons, multiplying the same logic across 13
    // ports and making the MSHR state a high-fanout routing source.
    always_comb begin
        for (busy_way = 0; busy_way < WAY_COUNT; busy_way = busy_way + 1)
            mshr_busy_way[busy_way] = '0;
        for (busy_mshr = 0; busy_mshr < MSHR_COUNT;
             busy_mshr = busy_mshr + 1)
            if (mshr_valid[busy_mshr])
                mshr_busy_way[mshr_way[busy_mshr]]
                              [mshr_line[busy_mshr]
                                  [LINE_BITS +: INDEX_BITS]] = 1'b1;
    end

    assign wait_front_id = wait_front_payload[7:0];
    assign wait_front_mask = wait_front_payload[11:8];
    assign wait_front_address[0] = wait_front_payload[33:12];
    assign wait_front_address[1] = wait_front_payload[55:34];
    assign wait_front_address[2] = wait_front_payload[77:56];
    assign wait_front_address[3] = wait_front_payload[99:78];
    assign wait_front_error = wait_front_payload[100];
    assign wait_prefetch_id = wait_prefetch_payload[7:0];
    assign wait_prefetch_mask = wait_prefetch_payload[11:8];
    assign wait_prefetch_address[0] = wait_prefetch_payload[33:12];
    assign wait_prefetch_address[1] = wait_prefetch_payload[55:34];
    assign wait_prefetch_address[2] = wait_prefetch_payload[77:56];
    assign wait_prefetch_address[3] = wait_prefetch_payload[99:78];
    assign wait_prefetch_error = wait_prefetch_payload[100];

    generate
        genvar ram_port;
        for (ram_port = 0; ram_port < 4; ram_port = ram_port + 1) begin : g_cache_ram
            sst1_texture_cache_ram #(.ADDRESS_BITS(RAM_ADDRESS_BITS + 1)) ram (
                .clk, .write_enable(cache_write_enable),
                .write_address(cache_write_address), .write_data(mem_rsp.rdata),
                .read_enable(cache_read_enable),
                .read_address(cache_read_address[ram_port]),
                .read_data(cache_read_data[ram_port])
            );
        end
    endgenerate

    always_comb begin
        live_range_error = !memory_enable;
        for (comb_port = 0; comb_port < 4; comb_port = comb_port + 1) begin
            live_lookup[comb_port] =
                address_lookup(
                    tag_lookup_data[TAG_LIVE_BASE + comb_port][0],
                    tag_lookup_data[TAG_LIVE_BASE + comb_port][1],
                    lookup_address[comb_port]);
            live_hit[comb_port] = !lookup_mask[comb_port] ||
                                  live_lookup[comb_port][WAY_BITS];
            live_way[comb_port] =
                live_lookup[comb_port][WAY_BITS-1:0];
            if (lookup_mask[comb_port] &&
                ({2'd0, lookup_address[comb_port][21:LINE_BITS],
                  {LINE_BITS{1'b0}}} + LINE_BYTES > memory_size))
                live_range_error = 1'b1;
        end
        live_all_hit = &live_hit;
        wait_push_payload = {live_range_error, lookup_address[3],
                             lookup_address[2], lookup_address[1],
                             lookup_address[0], lookup_mask, lookup_id};

        any_wait = wait_count != 0;
        head_all_hit = 1'b1;
        head_line_error = 1'b0;
        prefetch_all_hit = wait_count >= 2;
        prefetch_line_error = 1'b0;
        for (comb_port = 0; comb_port < 4; comb_port = comb_port + 1) begin
            head_lookup[comb_port] =
                address_lookup(
                    tag_lookup_data[TAG_HEAD_BASE + comb_port][0],
                    tag_lookup_data[TAG_HEAD_BASE + comb_port][1],
                    wait_front_address[comb_port]);
            head_hit[comb_port] = !any_wait ||
                                  !wait_front_mask[comb_port] ||
                                  head_lookup[comb_port][WAY_BITS];
            head_way[comb_port] =
                head_lookup[comb_port][WAY_BITS-1:0];
            head_all_hit = head_all_hit && head_hit[comb_port];
            for (comb_mshr = 0; comb_mshr < MSHR_COUNT;
                 comb_mshr = comb_mshr + 1)
                if (any_wait && mshr_valid[comb_mshr] &&
                    mshr_error[comb_mshr] &&
                    wait_front_mask[comb_port] &&
                    mshr_line[comb_mshr][21:LINE_BITS] ==
                    wait_front_address[comb_port][21:LINE_BITS])
                    head_line_error = 1'b1;
            wait_prefetch_lookup[comb_port] =
                address_lookup(
                    tag_lookup_data[TAG_WAIT_PREFETCH_BASE + comb_port][0],
                    tag_lookup_data[TAG_WAIT_PREFETCH_BASE + comb_port][1],
                    wait_prefetch_address[comb_port]);
            prefetch_hit[comb_port] =
                wait_count >= 2 &&
                (!wait_prefetch_mask[comb_port] ||
                 wait_prefetch_lookup[comb_port][WAY_BITS]);
            prefetch_way[comb_port] =
                wait_prefetch_lookup[comb_port][WAY_BITS-1:0];
            prefetch_all_hit = prefetch_all_hit && prefetch_hit[comb_port];
            for (comb_mshr = 0; comb_mshr < MSHR_COUNT;
                 comb_mshr = comb_mshr + 1)
                if (wait_count >= 2 && mshr_valid[comb_mshr] &&
                    mshr_error[comb_mshr] &&
                    wait_prefetch_mask[comb_port] &&
                    mshr_line[comb_mshr][21:LINE_BITS] ==
                    wait_prefetch_address[comb_port][21:LINE_BITS])
                    prefetch_line_error = 1'b1;
        end

        free_mshr_found = 1'b0;
        free_mshr = '0;
        issue_mshr_found = 1'b0;
        issue_mshr = '0;
        any_mshr = 1'b0;
        mshr_occupancy = '0;
        for (comb_mshr = 0; comb_mshr < MSHR_COUNT; comb_mshr = comb_mshr + 1) begin
            any_mshr = any_mshr || mshr_valid[comb_mshr];
            if (mshr_valid[comb_mshr])
                mshr_occupancy = mshr_occupancy + 1'b1;
            if (!mshr_valid[comb_mshr] && !free_mshr_found) begin
                free_mshr_found = 1'b1;
                free_mshr = MSHR_BITS'(comb_mshr);
            end
            if (mshr_valid[comb_mshr] && !mshr_issued[comb_mshr] &&
                !mshr_error[comb_mshr] &&
                !issue_mshr_found) begin
                issue_mshr_found = 1'b1;
                issue_mshr = MSHR_BITS'(comb_mshr);
            end
        end

        demand_allocation_found = 1'b0;
        demand_allocation_line = '0;
        allocation_line_active = 1'b0;
        for (comb_port = 0; comb_port < 4; comb_port = comb_port + 1) begin
            if (any_wait && !wait_front_error && !head_line_error &&
                wait_front_mask[comb_port] && !head_hit[comb_port] &&
                !demand_allocation_found) begin
                allocation_line_active = 1'b0;
                for (comb_mshr = 0; comb_mshr < MSHR_COUNT;
                     comb_mshr = comb_mshr + 1)
                    // A direct-mapped index cannot safely have two different
                    // fills in flight: an older response could overwrite the
                    // newer line/tag.
                    if (mshr_valid[comb_mshr] &&
                        (mshr_line[comb_mshr][21:LINE_BITS] ==
                         wait_front_address[comb_port][21:LINE_BITS] ||
                         mshr_line[comb_mshr][LINE_BITS +: INDEX_BITS] ==
                         wait_front_address[comb_port]
                             [LINE_BITS +: INDEX_BITS]))
                        allocation_line_active = 1'b1;
                if (!allocation_line_active) begin
                    demand_allocation_found = 1'b1;
                    demand_allocation_line =
                        wait_front_address[comb_port];
                end
            end
        end

        // Once the oldest replay dependency has a fill in flight, use the
        // currently arriving lookup to discover later independent lines.
        // The request is already captured in the replay queue this cycle, so
        // launching one of its fills early is safe and raises useful MSHR
        // occupancy on 2-D texture walks.
        live_allocation_found = 1'b0;
        live_allocation_line = '0;
        live_line_active = 1'b0;
        for (comb_port = 0; comb_port < 4; comb_port = comb_port + 1) begin
            if (!cache_initializing && lookup_valid && !live_range_error &&
                lookup_mask[comb_port] &&
                !live_hit[comb_port] && !live_allocation_found) begin
                live_line_active = 1'b0;
                for (comb_mshr = 0; comb_mshr < MSHR_COUNT;
                     comb_mshr = comb_mshr + 1)
                    if (mshr_valid[comb_mshr] &&
                        (mshr_line[comb_mshr][21:LINE_BITS] ==
                         lookup_address[comb_port][21:LINE_BITS] ||
                         mshr_line[comb_mshr][LINE_BITS +: INDEX_BITS] ==
                         lookup_address[comb_port]
                             [LINE_BITS +: INDEX_BITS]))
                        live_line_active = 1'b1;
                if (!live_line_active) begin
                    live_allocation_found = 1'b1;
                    live_allocation_line = lookup_address[comb_port];
                end
            end
        end

        prefetch_line_lookup = address_lookup(
            tag_lookup_data[TAG_PREFETCH_LINE][0],
            tag_lookup_data[TAG_PREFETCH_LINE][1], prefetch_line);
        prefetch_resident = prefetch_line_lookup[WAY_BITS];
        prefetch_active = 1'b0;
        prefetch_index_busy = 1'b0;
        for (comb_mshr = 0; comb_mshr < MSHR_COUNT; comb_mshr = comb_mshr + 1) begin
            if (mshr_valid[comb_mshr] &&
                mshr_line[comb_mshr][21:LINE_BITS] ==
                prefetch_line[21:LINE_BITS])
                prefetch_active = 1'b1;
            if (mshr_valid[comb_mshr] &&
                mshr_line[comb_mshr][LINE_BITS +: INDEX_BITS] ==
                prefetch_line[LINE_BITS +: INDEX_BITS])
                prefetch_index_busy = 1'b1;
        end
        prefetch_in_range =
            ({2'd0, prefetch_line[21:LINE_BITS], {LINE_BITS{1'b0}}} +
             LINE_BYTES <= memory_size);

        // A demand allocation seeds a one-line lookahead. Prefer that
        // lookahead on the following cycle, then return to demand work. This
        // converts coherent scanlines from demand/replay traffic to resident
        // hits without changing the visible result order.
        allocation_prefetch = !demand_allocation_found &&
                              !live_allocation_found &&
                              PREFETCH_DISTANCE_LINES != 0 &&
                              prefetch_valid && !prefetch_resident &&
                              !prefetch_active && !prefetch_index_busy &&
                              prefetch_in_range;
        allocation_found = demand_allocation_found || live_allocation_found ||
                           allocation_prefetch;
        response_slot_ready = !response_valid_reg || response_ready;
        schedule_replay_head = !cache_initializing && response_slot_ready && any_wait &&
                               !wait_front_served &&
                               (wait_front_error || head_line_error ||
                                head_all_hit);
        // The second parked lookup may bypass a blocked head. Result IDs are
        // retired in order by the TMU ROB, so this small ready window removes
        // common line-boundary head-of-line stalls without an associative
        // 64-entry payload mux on the cache critical path.
        schedule_replay_prefetch = response_slot_ready && !schedule_replay_head &&
                                   !wait_front_served &&
                                   wait_count >= 2 &&
                                   !wait_prefetch_served &&
                                   (wait_prefetch_error ||
                                    prefetch_line_error ||
                                    prefetch_all_hit);
        schedule_replay = schedule_replay_head || schedule_replay_prefetch;
        schedule_live = !cache_initializing && response_slot_ready && !schedule_replay &&
                        lookup_valid && live_all_hit;
        lookup_ready = !cache_initializing &&
                       (live_all_hit ?
                            (response_slot_ready && !schedule_replay) :
                            wait_count < WAIT_COUNT);
        wait_push = lookup_valid && lookup_ready && !live_all_hit;
        // A ready second entry may complete before the blocked head.  Mark it
        // served in place and discard it when it naturally reaches the head;
        // the backing store consequently remains a conventional one-read,
        // one-write FIFO that Vivado can map to distributed RAM.
        wait_drop_served = any_wait && wait_front_served;
        wait_pop = schedule_replay_head || wait_drop_served;

        scheduled_error = 1'b0;
        scheduled_id = lookup_id;
        for (comb_port = 0; comb_port < 4; comb_port = comb_port + 1) begin
            scheduled_address[comb_port] = lookup_address[comb_port];
            scheduled_way[comb_port] = live_way[comb_port];
        end
        if (schedule_replay_head) begin
            scheduled_error = wait_front_error || head_line_error;
            scheduled_id = wait_front_id;
            for (comb_port = 0; comb_port < 4; comb_port = comb_port + 1) begin
                scheduled_address[comb_port] = wait_front_address[comb_port];
                scheduled_way[comb_port] = head_way[comb_port];
            end
        end else if (schedule_replay_prefetch) begin
            scheduled_error = wait_prefetch_error || prefetch_line_error;
            scheduled_id = wait_prefetch_id;
            for (comb_port = 0; comb_port < 4; comb_port = comb_port + 1) begin
                scheduled_address[comb_port] =
                    wait_prefetch_address[comb_port];
                scheduled_way[comb_port] = prefetch_way[comb_port];
            end
        end

        cache_read_enable = (schedule_live || schedule_replay) && !scheduled_error;
        for (comb_port = 0; comb_port < 4; comb_port = comb_port + 1) begin
            cache_read_address[comb_port] =
                {scheduled_way[comb_port],
                 scheduled_address[comb_port][LINE_BITS +: INDEX_BITS],
                 scheduled_address[comb_port][LINE_BITS-1:4]};
            shifted_read_data[comb_port] = cache_read_data[comb_port] >>
                                           (response_byte_offset[comb_port] * 8);
            response_texel[comb_port] = response_error_reg ? 16'd0 :
                                                               shifted_read_data[comb_port][15:0];
        end

        mem_req_valid = issue_mshr_found;
        mem_req = '0;
        mem_req.addr = memory_base +
                       {18'd0, mshr_line[issue_mshr][21:LINE_BITS],
                        {LINE_BITS{1'b0}}};
        mem_req.beats = 8'(BEATS_PER_LINE);
        mem_req.tag = 8'h90 | 8'(issue_mshr);
        mem_req.source = SST1_MEM_TEXTURE;
        mem_req.order_class = SST1_ORDER_RELAXED;

        response_mshr = mem_rsp.tag[MSHR_BITS-1:0];
        response_mshr_valid = mshr_valid[response_mshr] &&
                              mshr_issued[response_mshr] &&
                              !mshr_error[response_mshr];
        mem_rsp_ready = response_mshr_valid;
        cache_write_enable = mem_rsp_valid && mem_rsp_ready && !mem_rsp.error;
        cache_write_address =
            {mshr_way[response_mshr],
             mshr_line[response_mshr][LINE_BITS +: INDEX_BITS],
             mshr_beat[response_mshr]};

        response_valid = response_valid_reg;
        response_error = response_error_reg;
        response_id = response_id_reg;
        idle = !cache_initializing && !any_wait && !any_mshr &&
               !response_valid_reg;
    end

    always_comb begin
        allocation_line = demand_allocation_found ? demand_allocation_line :
                          live_allocation_found ? live_allocation_line :
                                                  prefetch_line;
        allocation_index = allocation_line[LINE_BITS +: INDEX_BITS];
    end

    always_comb begin
        allocation_way = replacement_way[allocation_index];
        if (!allocation_tag_data[0][TAG_BITS])
            allocation_way = '0;
        else if (!allocation_tag_data[1][TAG_BITS])
            allocation_way = WAY_BITS'(1);
    end

    // Distributed RAM has no fabric reset. Clear one set per cycle after
    // reset, then use its single write port for invalidations or completed
    // fills. Invalidation wins over a simultaneous fill; dropping that tag is
    // safe because the line will simply be fetched again on its next use.
    always_comb begin
        for (tag_comb_way = 0; tag_comb_way < WAY_COUNT;
             tag_comb_way = tag_comb_way + 1) begin
            tag_write_enable[tag_comb_way] = 1'b0;
            tag_write_data[tag_comb_way] = '0;
        end
        tag_write_address = cache_init_index;
        if (cache_initializing) begin
            for (tag_comb_way = 0; tag_comb_way < WAY_COUNT;
                 tag_comb_way = tag_comb_way + 1)
                tag_write_enable[tag_comb_way] = 1'b1;
        end else if (invalidate_valid) begin
            tag_write_address =
                invalidate_address[LINE_BITS +: INDEX_BITS];
            for (tag_comb_way = 0; tag_comb_way < WAY_COUNT;
                 tag_comb_way = tag_comb_way + 1)
                tag_write_enable[tag_comb_way] = 1'b1;
        end else if (mem_rsp_valid && mem_rsp_ready &&
                     (mem_rsp.last ||
                      mshr_beat[response_mshr] ==
                          BEAT_BITS'(BEATS_PER_LINE-1))) begin
            tag_write_address =
                mshr_line[response_mshr][LINE_BITS +: INDEX_BITS];
            tag_write_enable[mshr_way[response_mshr]] = 1'b1;
            tag_write_data[mshr_way[response_mshr]] = {
                !mshr_error[response_mshr] && !mem_rsp.error,
                mshr_line[response_mshr][21 -: TAG_BITS]
            };
        end
    end

    // Keep instrumentation out of the request-selection cone. In particular,
    // invalidate_valid is derived from an accepted upload request; placing it
    // in the large cache combinational block creates a false ready/valid loop
    // even though invalidation cannot affect the request being issued.
    always_comb begin
        perf_events = '0;
        perf_events.lookup = lookup_valid && lookup_ready;
        perf_events.hit = perf_events.lookup && live_all_hit;
        perf_events.miss = perf_events.lookup && !live_all_hit;
        perf_events.replay = schedule_replay;
        perf_events.demand_allocation = allocation_found &&
                                        free_mshr_found &&
                                        !allocation_prefetch;
        perf_events.prefetch_allocation = allocation_found &&
                                          free_mshr_found &&
                                          allocation_prefetch;
        perf_events.fill_request = mem_req_valid && mem_req_ready;
        perf_events.fill_beat = mem_rsp_valid && mem_rsp_ready;
        perf_events.fill_error = perf_events.fill_beat && mem_rsp.error;
        perf_events.invalidation = invalidate_valid;
        perf_events.wait_occupancy = 7'(wait_count);
        perf_events.mshr_occupancy = mshr_occupancy;
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            cache_initializing <= 1'b1;
            cache_init_index <= '0;
            response_valid_reg <= 1'b0;
            response_error_reg <= 1'b0;
            response_id_reg <= '0;
            for (reset_line = 0; reset_line < LINE_COUNT;
                 reset_line = reset_line + 1) begin
                replacement_way[reset_line] <= '0;
            end
            wait_front_payload <= '0;
            wait_prefetch_payload <= '0;
            wait_front_served <= 1'b0;
            wait_prefetch_served <= 1'b0;
            wait_head <= '0;
            wait_tail <= '0;
            wait_count <= '0;
            for (reset_mshr = 0; reset_mshr < MSHR_COUNT; reset_mshr = reset_mshr + 1) begin
                mshr_valid[reset_mshr] <= 1'b0;
                mshr_issued[reset_mshr] <= 1'b0;
                mshr_error[reset_mshr] <= 1'b0;
                mshr_beat[reset_mshr] <= '0;
                mshr_way[reset_mshr] <= '0;
            end
            prefetch_valid <= 1'b0;
            prefetch_line <= '0;
        end else begin
            if (cache_initializing) begin
                if (cache_init_index == INDEX_BITS'(LINE_COUNT-1))
                    cache_initializing <= 1'b0;
                else
                    cache_init_index <= cache_init_index + 1'b1;
            end

            if (response_valid_reg && response_ready)
                response_valid_reg <= 1'b0;

            if (schedule_live || schedule_replay) begin
                response_valid_reg <= 1'b1;
                response_error_reg <= scheduled_error;
                response_id_reg <= scheduled_id;
                for (seq_port = 0; seq_port < 4; seq_port = seq_port + 1)
                    response_byte_offset[seq_port] <= scheduled_address[seq_port][3:0];
            end

            if (schedule_replay_prefetch)
                wait_prefetch_served <= 1'b1;

            case ({wait_push, wait_pop})
                2'b10: begin
                    wait_count <= wait_count + 1'b1;
                    if (wait_count == 0) begin
                        wait_front_payload <= wait_push_payload;
                        wait_front_served <= 1'b0;
                    end else if (wait_count == 1) begin
                        wait_prefetch_payload <= wait_push_payload;
                        wait_prefetch_served <= 1'b0;
                    end else begin
                        wait_memory[wait_tail] <= wait_push_payload;
                        wait_tail <= wait_tail + 1'b1;
                    end
                end
                2'b01: begin
                    wait_count <= wait_count - 1'b1;
                    if (wait_count >= 2) begin
                        wait_front_payload <= wait_prefetch_payload;
                        wait_front_served <= wait_prefetch_served;
                    end else
                        wait_front_served <= 1'b0;
                    if (wait_count >= 3) begin
                        wait_prefetch_payload <= wait_memory[wait_head];
                        wait_prefetch_served <= 1'b0;
                        wait_head <= wait_head + 1'b1;
                    end else
                        wait_prefetch_served <= 1'b0;
                end
                2'b11: begin
                    if (wait_count == 1) begin
                        wait_front_payload <= wait_push_payload;
                        wait_front_served <= 1'b0;
                    end else if (wait_count == 2) begin
                        wait_front_payload <= wait_prefetch_payload;
                        wait_front_served <= wait_prefetch_served;
                        wait_prefetch_payload <= wait_push_payload;
                        wait_prefetch_served <= 1'b0;
                    end else begin
                        wait_front_payload <= wait_prefetch_payload;
                        wait_front_served <= wait_prefetch_served;
                        wait_prefetch_payload <= wait_memory[wait_head];
                        wait_prefetch_served <= 1'b0;
                        wait_memory[wait_tail] <= wait_push_payload;
                        wait_head <= wait_head + 1'b1;
                        wait_tail <= wait_tail + 1'b1;
                    end
                end
                default: begin end
            endcase

            if (prefetch_valid &&
                (prefetch_resident || prefetch_active || !prefetch_in_range))
                prefetch_valid <= 1'b0;

            if (allocation_found && free_mshr_found) begin
                mshr_valid[free_mshr] <= 1'b1;
                mshr_issued[free_mshr] <= 1'b0;
                mshr_error[free_mshr] <= 1'b0;
                mshr_beat[free_mshr] <= '0;
                mshr_line[free_mshr] <=
                    {allocation_line[21:LINE_BITS], {LINE_BITS{1'b0}}};
                mshr_way[free_mshr] <= allocation_way;
                replacement_way[allocation_index] <= allocation_way + 1'b1;
                if (allocation_prefetch)
                    prefetch_valid <= 1'b0;
                else begin
                    prefetch_valid <= PREFETCH_DISTANCE_LINES != 0;
                    prefetch_line <=
                        {allocation_line[21:LINE_BITS],
                         {LINE_BITS{1'b0}}} +
                        (PREFETCH_DISTANCE_LINES * LINE_BYTES);
                end
            end

            if (mem_req_valid && mem_req_ready)
                mshr_issued[issue_mshr] <= 1'b1;

            if (mem_rsp_valid && mem_rsp_ready) begin
                mshr_error[response_mshr] <=
                    mshr_error[response_mshr] || mem_rsp.error;
                if (mem_rsp.last ||
                    mshr_beat[response_mshr] == BEAT_BITS'(BEATS_PER_LINE-1)) begin
                    mshr_valid[response_mshr] <=
                        mshr_error[response_mshr] || mem_rsp.error;
                    mshr_issued[response_mshr] <=
                        mshr_error[response_mshr] || mem_rsp.error;
                    mshr_beat[response_mshr] <= '0;
                end else
                    mshr_beat[response_mshr] <= mshr_beat[response_mshr] + 1'b1;
            end

            // Failed line records remain long enough to mark every queued
            // dependent lookup, then release their MSHRs at the command gap.
            if (wait_count == 0)
                for (reset_mshr = 0; reset_mshr < MSHR_COUNT;
                     reset_mshr = reset_mshr + 1)
                    if (mshr_error[reset_mshr]) begin
                        mshr_valid[reset_mshr] <= 1'b0;
                        mshr_issued[reset_mshr] <= 1'b0;
                        mshr_error[reset_mshr] <= 1'b0;
                    end
        end
    end
endmodule
