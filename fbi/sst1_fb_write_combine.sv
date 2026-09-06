// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Combines adjacent 16-bit framebuffer updates into aligned 128-bit beats.
// One active line absorbs pixels while a completed/partial older line drains.
// The probe interface exposes newest pending bytes for read-after-write
// forwarding; it does not consume either queue entry.
module sst1_fb_write_combine (
    input  logic                     clk,
    input  logic                     reset_n,

    input  logic                     update_valid,
    output logic                     update_ready,
    input  logic [23:0]              update_address,
    input  logic [15:0]              update_data,
    input  logic [1:0]               update_enable,
    input  sst1_pkg::sst1_mem_source_t update_source,

    input  logic                     flush_valid,
    output logic                     flush_ready,

    input  logic [23:0]              probe_address,
    output logic [1:0]               probe_hit,
    output logic [15:0]              probe_data,

    input  logic [39:0]              memory_base,
    output logic                     mem_req_valid,
    input  logic                     mem_req_ready,
    output sst1_pkg::sst1_mem_req_t  mem_req,
    output logic                     idle
);
    import sst1_pkg::*;

    logic active_valid;
    logic [23:4] active_line;
    logic [127:0] active_data;
    logic [15:0] active_strobe;
    sst1_mem_source_t active_source;

    logic drain_valid;
    logic [23:4] drain_line;
    logic [127:0] drain_data;
    logic [15:0] drain_strobe;
    sst1_mem_source_t drain_source;

    logic [23:4] update_line;
    logic [3:0] update_lane;
    logic active_match;
    logic drain_fire, drain_available;
    logic [127:0] update_mask;
    logic [127:0] merged_active_data;
    logic [15:0] merged_active_strobe;
    logic merged_active_full;
    logic accept_update;
    integer byte_number;

    always_comb begin
        update_line = update_address[23:4];
        update_lane = update_address[3:0];
        active_match = active_valid && active_line == update_line;
        drain_fire = drain_valid && mem_req_ready;
        drain_available = !drain_valid || drain_fire;

        update_mask = '0;
        if (update_enable[0])
            update_mask[(update_lane * 8) +: 8] = 8'hff;
        if (update_enable[1])
            update_mask[((update_lane + 1'b1) * 8) +: 8] = 8'hff;
        merged_active_data = (active_data & ~update_mask) |
                             ((128'(update_data) << (update_lane * 8)) &
                              update_mask);
        merged_active_strobe = active_strobe |
                               (16'(update_enable) << update_lane);
        merged_active_full = &merged_active_strobe;

        // A new line can replace the active line only when the old line has a
        // drain slot. A full matching update needs the same slot so it can be
        // handed off immediately instead of blocking the following line.
        update_ready = !flush_valid &&
                       (!active_valid ||
                        (active_match && (!merged_active_full ||
                                          drain_available)) ||
                        (!active_match && drain_available));
        accept_update = update_valid && update_ready;
        flush_ready = !active_valid || drain_available;

        mem_req_valid = drain_valid;
        mem_req = '0;
        mem_req.addr = memory_base + {16'd0, drain_line, 4'd0};
        mem_req.wdata = drain_data;
        mem_req.wstrb = drain_strobe;
        mem_req.beats = 8'd1;
        mem_req.tag = 8'h01;
        mem_req.source = drain_source;
        mem_req.order_class = SST1_ORDER_SOURCE;
        mem_req.write = 1'b1;
        idle = !active_valid && !drain_valid;

        probe_hit = 2'b00;
        probe_data = 16'd0;
        for (byte_number = 0; byte_number < 2; byte_number = byte_number + 1) begin
            if (drain_valid && drain_line == probe_address[23:4] &&
                drain_strobe[probe_address[3:0] + byte_number]) begin
                probe_hit[byte_number] = 1'b1;
                probe_data[byte_number*8 +: 8] =
                    drain_data[(probe_address[3:0] + byte_number)*8 +: 8];
            end
            if (active_valid && active_line == probe_address[23:4] &&
                active_strobe[probe_address[3:0] + byte_number]) begin
                probe_hit[byte_number] = 1'b1;
                probe_data[byte_number*8 +: 8] =
                    active_data[(probe_address[3:0] + byte_number)*8 +: 8];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            active_valid <= 1'b0;
            active_line <= '0;
            active_data <= '0;
            active_strobe <= '0;
            active_source <= SST1_MEM_FB_WRITE;
            drain_valid <= 1'b0;
            drain_line <= '0;
            drain_data <= '0;
            drain_strobe <= '0;
            drain_source <= SST1_MEM_FB_WRITE;
        end else begin
            if (drain_fire)
                drain_valid <= 1'b0;

            if (flush_valid && flush_ready && active_valid) begin
                drain_valid <= 1'b1;
                drain_line <= active_line;
                drain_data <= active_data;
                drain_strobe <= active_strobe;
                drain_source <= active_source;
                active_valid <= 1'b0;
            end

            if (accept_update) begin
                if (!active_valid) begin
                    active_valid <= 1'b1;
                    active_line <= update_line;
                    active_data <= (128'(update_data) << (update_lane * 8));
                    active_strobe <= 16'(update_enable) << update_lane;
                    active_source <= update_source;
                end else if (active_match) begin
                    if (merged_active_full) begin
                        drain_valid <= 1'b1;
                        drain_line <= active_line;
                        drain_data <= merged_active_data;
                        drain_strobe <= merged_active_strobe;
                        drain_source <= active_source;
                        active_valid <= 1'b0;
                    end else begin
                        active_data <= merged_active_data;
                        active_strobe <= merged_active_strobe;
                    end
                end else begin
                    drain_valid <= 1'b1;
                    drain_line <= active_line;
                    drain_data <= active_data;
                    drain_strobe <= active_strobe;
                    drain_source <= active_source;
                    active_valid <= 1'b1;
                    active_line <= update_line;
                    active_data <= 128'(update_data) << (update_lane * 8);
                    active_strobe <= 16'(update_enable) << update_lane;
                    active_source <= update_source;
                end
            end
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
