// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// Platform-visible M6 instrumentation. This bank is intentionally separate
// from the SST-1 BAR: it describes the FPGA implementation, not 3dfx state.
// Reads have one clock of latency. Snapshot and clear requests are held until
// the complete renderer is idle, so software observes an atomic interval.
module sst1_perf_counters #(
    parameter integer COUNTER_BITS = 64,
    parameter bit SNAPSHOT_WHILE_BUSY = 0
) (
    input  logic                              clk,
    input  logic                              reset_n,
    input  logic                              renderer_busy,
    input  logic                              snapshot,
    input  logic                              clear,
    input  logic [6:0]                        read_index,
    output logic [63:0]                       read_data,
    output logic                              pending,

    input  sst1_pkg::sst1_fbi_perf_events_t   fbi,
    input  sst1_pkg::sst1_tmu_perf_events_t   tmu,
    input  logic                              mem_req_fire,
    input  sst1_pkg::sst1_mem_req_t           mem_req,
    input  logic                              mem_rsp_fire,
    input  sst1_pkg::sst1_mem_rsp_t           mem_rsp,
    input  logic                              tmu_arb_wait,
    input  logic                              fbi_arb_wait,
    input  logic                              response_backpressure
);
    import sst1_pkg::*;

    localparam integer COUNTER_COUNT = 80;
    localparam logic [31:0] COUNTER_VERSION = 32'h0001_0000;

    logic [COUNTER_BITS-1:0] live [0:COUNTER_COUNT-1];
    logic [COUNTER_BITS-1:0] shadow [0:COUNTER_COUNT-1];
    logic snapshot_pending, clear_pending;
    integer index;

    function automatic logic [63:0] max_sample(
        input logic [63:0] old_value,
        input logic [6:0] sample
    );
        return old_value < sample ? {57'd0, sample} : old_value;
    endfunction

    assign pending = snapshot_pending || clear_pending;

    // 0 and 1 identify the implementation; event counters begin at 2.
    always_ff @(posedge clk) begin
        if (!reset_n) begin
            read_data <= '0;
        end else begin
            case (read_index)
                7'd0: read_data <= {32'd0, COUNTER_VERSION};
                7'd1: read_data <= {48'd0, 8'd7, COUNTER_COUNT[7:0]};
                default:
                    read_data <= read_index < COUNTER_COUNT ?
                                 shadow[read_index] : 64'd0;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            snapshot_pending <= 1'b0;
            clear_pending <= 1'b0;
            for (index = 0; index < COUNTER_COUNT; index = index + 1) begin
                live[index] <= '0;
                shadow[index] <= '0;
            end
        end else begin
            if (snapshot)
                snapshot_pending <= 1'b1;
            if (clear)
                clear_pending <= 1'b1;

            if ((clear || clear_pending) && !renderer_busy) begin
                for (index = 0; index < COUNTER_COUNT; index = index + 1)
                    live[index] <= '0;
                clear_pending <= 1'b0;
                // A clear supersedes a simultaneous snapshot request.
                if (snapshot || snapshot_pending)
                    snapshot_pending <= 1'b1;
            end else begin
                live[2] <= live[2] + 1'b1;
                if (renderer_busy) live[3] <= live[3] + 1'b1;
                if (fbi.raster_candidate) live[4] <= live[4] + 1'b1;
                if (fbi.pixel_issue) live[5] <= live[5] + 1'b1;
                if (fbi.pixel_retire) live[6] <= live[6] + 1'b1;
                if (tmu.sample_accept) live[7] <= live[7] + 1'b1;
                if (tmu.result_retire) live[8] <= live[8] + 1'b1;
                if (fbi.join_allocate) live[9] <= live[9] + 1'b1;
                if (fbi.join_complete) live[10] <= live[10] + 1'b1;
                if (fbi.pixel_pass) live[11] <= live[11] + 1'b1;
                if (fbi.chroma_fail) live[12] <= live[12] + 1'b1;
                if (fbi.depth_fail) live[13] <= live[13] + 1'b1;
                if (fbi.alpha_fail) live[14] <= live[14] + 1'b1;
                if (fbi.color_read) live[15] <= live[15] + 1'b1;
                if (fbi.aux_read) live[16] <= live[16] + 1'b1;
                if (fbi.color_update) live[17] <= live[17] + 1'b1;
                if (fbi.aux_update) live[18] <= live[18] + 1'b1;
                if (fbi.color_drain) live[19] <= live[19] + 1'b1;
                if (fbi.aux_drain) live[20] <= live[20] + 1'b1;
                if (fbi.color_forward) live[21] <= live[21] + 1'b1;
                if (fbi.aux_forward) live[22] <= live[22] + 1'b1;

                if (tmu.cache.lookup) live[23] <= live[23] + 1'b1;
                if (tmu.cache.hit) live[24] <= live[24] + 1'b1;
                if (tmu.cache.miss) live[25] <= live[25] + 1'b1;
                if (tmu.cache.replay) live[26] <= live[26] + 1'b1;
                if (tmu.cache.demand_allocation) live[27] <= live[27] + 1'b1;
                if (tmu.cache.prefetch_allocation) live[28] <= live[28] + 1'b1;
                if (tmu.cache.fill_request) live[29] <= live[29] + 1'b1;
                if (tmu.cache.fill_beat) live[30] <= live[30] + 1'b1;
                if (tmu.cache.fill_beat && mem_rsp.last)
                    live[31] <= live[31] + 1'b1;
                if (tmu.cache.fill_error) live[32] <= live[32] + 1'b1;
                if (tmu.cache.invalidation) live[33] <= live[33] + 1'b1;

                if (fbi.color_cache.lookup) live[34] <= live[34] + 1'b1;
                if (fbi.color_cache.hit) live[35] <= live[35] + 1'b1;
                if (fbi.color_cache.miss) live[36] <= live[36] + 1'b1;
                if (fbi.color_cache.replay) live[37] <= live[37] + 1'b1;
                if (fbi.color_cache.demand_allocation)
                    live[38] <= live[38] + 1'b1;
                if (fbi.color_cache.fill_request) live[39] <= live[39] + 1'b1;
                if (fbi.color_cache.fill_beat) live[40] <= live[40] + 1'b1;
                if (fbi.aux_cache.lookup) live[41] <= live[41] + 1'b1;
                if (fbi.aux_cache.hit) live[42] <= live[42] + 1'b1;
                if (fbi.aux_cache.miss) live[43] <= live[43] + 1'b1;
                if (fbi.aux_cache.replay) live[44] <= live[44] + 1'b1;
                if (fbi.aux_cache.demand_allocation)
                    live[45] <= live[45] + 1'b1;
                if (fbi.aux_cache.fill_request) live[46] <= live[46] + 1'b1;
                if (fbi.aux_cache.fill_beat) live[47] <= live[47] + 1'b1;

                if (mem_req_fire) begin
                    live[48] <= live[48] + 1'b1;
                    if (mem_req.write)
                        live[49] <= live[49] + 1'b1;
                    else
                        live[50] <= live[50] + mem_req.beats;
                    case (mem_req.source)
                        SST1_MEM_TEXTURE: live[55] <= live[55] + 1'b1;
                        SST1_MEM_FB_COLOR: live[56] <= live[56] + 1'b1;
                        SST1_MEM_FB_AUX: live[57] <= live[57] + 1'b1;
                        SST1_MEM_FB_WRITE: live[58] <= live[58] + 1'b1;
                        SST1_MEM_SCANOUT: live[59] <= live[59] + 1'b1;
                        SST1_MEM_TEX_UPLOAD: live[60] <= live[60] + 1'b1;
                        default: live[60] <= live[60];
                    endcase
                end
                if (mem_rsp_fire) live[51] <= live[51] + 1'b1;
                if (mem_rsp_fire && mem_rsp.last)
                    live[52] <= live[52] + 1'b1;
                if (mem_rsp_fire && mem_rsp.error)
                    live[53] <= live[53] + 1'b1;
                if (mem_req_fire && mem_req.write)
                    live[54] <= live[54] + $countones(mem_req.wstrb);
                if (tmu_arb_wait) live[61] <= live[61] + 1'b1;
                if (fbi_arb_wait) live[62] <= live[62] + 1'b1;
                if (response_backpressure) live[63] <= live[63] + 1'b1;

                live[64] <= live[64] + tmu.rob_occupancy;
                live[65] <= max_sample(live[65], tmu.rob_occupancy);
                live[66] <= live[66] + tmu.cache.wait_occupancy;
                live[67] <= max_sample(live[67], tmu.cache.wait_occupancy);
                live[68] <= live[68] + tmu.cache.mshr_occupancy;
                live[69] <= max_sample(live[69],
                                       {2'd0, tmu.cache.mshr_occupancy});
                live[70] <= live[70] + fbi.pending_occupancy;
                live[71] <= max_sample(live[71], fbi.pending_occupancy);
                live[72] <= live[72] + fbi.join_occupancy;
                live[73] <= max_sample(live[73], fbi.join_occupancy);
                live[74] <= max_sample(live[74],
                                       fbi.color_cache.wait_occupancy);
                live[75] <= max_sample(live[75],
                    {2'd0, fbi.color_cache.mshr_occupancy});
                live[76] <= max_sample(live[76],
                                       fbi.aux_cache.wait_occupancy);
                live[77] <= max_sample(live[77],
                    {2'd0, fbi.aux_cache.mshr_occupancy});
            end

            if ((snapshot || snapshot_pending) && (!renderer_busy || SNAPSHOT_WHILE_BUSY) &&
                !(clear || clear_pending)) begin
                for (index = 0; index < COUNTER_COUNT; index = index + 1)
                    shadow[index] <= live[index];
                snapshot_pending <= 1'b0;
            end
        end
    end
endmodule
