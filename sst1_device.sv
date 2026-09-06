// SPDX-License-Identifier: Apache-2.0
//
// zSST: a Voodoo 1 (SST-1) chipset implementation in SystemVerilog
// nand2mario, September 2026
//
// Board-neutral integration of the SST-1 programming frontend and FBI engine.

`timescale 1ns/1ps

module sst1_device #(
    parameter integer PERF_COUNTER_BITS = 64,
    parameter bit PERF_SNAPSHOT_WHILE_BUSY = 0
) (
    input  logic                              clk,
    input  logic                              reset_n,
    input  logic                              init_write_enable,      // Permit writes to privileged FBI init registers
    input  logic                              init_remap_enable,      // Enable the alternate init-register address map
    input  logic                              memory_enable,          // PCI memory-space enable
    input  logic                              memory_writes_idle,     // All previously accepted external writes completed
    input  logic [39:0]                       fbi_memory_base,        // Physical base of framebuffer/auxiliary memory
    input  logic [23:0]                       fbi_memory_size,
    input  logic [39:0]                       texture_memory_base,    // Physical base of texture memory
    input  logic [23:0]                       texture_memory_size,
    input  logic                              v_retrace,
    input  logic [11:0]                       v_retrace_count,
    input  logic [15:0]                       scanout_rgb565,         // Front-buffer pixel fetched by the platform
    output logic [23:0]                       scanout_rgb888,         // Pixel after SST-1 gamma-CLUT conversion
    output logic [1:0]                        displayed_buffer,       // FBI buffer currently selected for scanout
    output logic [2:0]                        swaps_pending,
    output logic                              swap_event,             // One-cycle pulse when a buffer swap commits
    output logic [31:0]                       video_frame_count,
    output logic [31:0]                       video_hsync_register,
    output logic [31:0]                       video_vsync_register,
    output logic [31:0]                       video_backporch_register,
    output logic [31:0]                       video_dimensions_register,
    output logic                              video_active,           // SST-1 scanout is configured and unblanked
    output wire                               perf_fbi_active,

    input  logic                              host_req_valid,
    output logic                              host_req_ready,
    input  sst1_pkg::sst1_host_req_t          host_req,               // BAR address, write data, byte enables, and direction
    output logic                              host_rsp_valid,
    input  logic                              host_rsp_ready,
    output sst1_pkg::sst1_host_rsp_t          host_rsp,               // Read data and error status

    output logic                              mem_req_valid,
    input  logic                              mem_req_ready,
    output sst1_pkg::sst1_mem_req_t           mem_req,                // Tagged 128-bit FBI/TMU memory request
    input  logic                              mem_rsp_valid,
    output logic                              mem_rsp_ready,
    input  sst1_pkg::sst1_mem_rsp_t           mem_rsp,                // Tagged 128-bit read data and status

    output logic                              debug_host_event_valid, // One-cycle pulse for an accepted host transaction
    output sst1_pkg::sst1_debug_host_event_t  debug_host_event,
    output logic [6:0]                        fifo_free,
    output logic                              busy,                   // Frontend, renderer, memory, or swap work outstanding
    output logic [31:0]                       pixels_in,
    output logic [31:0]                       chroma_fail,
    output logic [31:0]                       zfunc_fail,
    output logic [31:0]                       afunc_fail,
    output logic [31:0]                       pixels_out,
    output logic [31:0]                       last_alpha,
    output logic [31:0]                       last_w,

    input  logic                              perf_snapshot,          // Request an atomic snapshot of live counters
    input  logic                              perf_clear,
    input  logic [6:0]                        perf_read_index,
    output logic [63:0]                       perf_read_data,         // Indexed snapshot value; one-cycle read latency
    output logic                              perf_pending            // Snapshot or clear is waiting for renderer idle
);
    import sst1_pkg::*;

    logic render_cmd_valid;
    logic render_cmd_ready;
    logic fbi_render_cmd_ready;
    sst1_render_command_t render_cmd;
    logic lfb_cmd_valid;
    logic lfb_cmd_ready;
    logic fbi_lfb_cmd_ready;
    sst1_lfb_command_t lfb_cmd;
    logic lfb_read_rsp_valid;
    logic lfb_read_rsp_ready;
    logic [31:0] lfb_read_rsp_data;
    logic lfb_read_rsp_error;
    logic fbi_idle;
    logic tmu_idle;
    logic frontend_busy;
    logic video_register_write_valid;
    logic [11:0] video_register_write_address;
    logic [31:0] video_register_write_data;
    logic [3:0] video_register_write_be;
    logic video_swap_valid, video_swap_ready;
    logic [31:0] current_stipple;
    logic [31:0] current_stipple_generation;
    logic texture_cmd_valid;
    logic texture_cmd_ready;
    logic tmu_texture_cmd_ready;
    logic tmu_texture_cmd_valid;
    logic fbi_render_cmd_valid;
    logic fbi_lfb_cmd_valid;
    sst1_texture_command_t texture_cmd;
    logic texture_sample_valid, texture_sample_ready;
    logic texture_result_valid, texture_result_ready;
    sst1_texture_sample_t texture_sample;
    sst1_texture_result_t texture_result;
    logic fbi_mem_req_valid, fbi_mem_req_ready, fbi_mem_rsp_valid, fbi_mem_rsp_ready;
    logic tmu_mem_req_valid, tmu_mem_req_ready, tmu_mem_rsp_valid, tmu_mem_rsp_ready;
    sst1_mem_req_t fbi_mem_req, tmu_mem_req;
    logic memory_select_tmu;
    logic last_memory_grant_tmu;
    sst1_fbi_perf_events_t fbi_perf_events;
    sst1_tmu_perf_events_t tmu_perf_events;

    assign busy = frontend_busy || !fbi_idle || !tmu_idle ||
                  !memory_writes_idle || swaps_pending != 0;
    assign render_cmd_ready = render_cmd.kind == SST1_COMMAND_SWAPBUFFER ?
                              (video_swap_ready && fbi_idle && tmu_idle &&
                               memory_writes_idle) :
                              (fbi_render_cmd_ready && tmu_idle &&
                               memory_writes_idle);
    assign lfb_cmd_ready = fbi_lfb_cmd_ready && tmu_idle;
    assign texture_cmd_ready = tmu_texture_cmd_ready && fbi_idle;

    // Valid and ready must describe the same transfer at each consumer.  The
    // cross-unit idle terms used to be applied only to ready; with a fast host
    // command ring, the TMU or FBI could therefore accept the same held FIFO
    // head on every cycle while the frontend correctly waited to pop it.
    assign fbi_render_cmd_valid = render_cmd_valid &&
                                  render_cmd.kind != SST1_COMMAND_SWAPBUFFER &&
                                  tmu_idle && memory_writes_idle;
    assign fbi_lfb_cmd_valid = lfb_cmd_valid && tmu_idle;
    assign tmu_texture_cmd_valid = texture_cmd_valid && fbi_idle;

    sst1_core frontend_core (
        .clk,
        .reset_n,
        .init_write_enable,
        .init_remap_enable,
        // AXI read and write channels are not mutually ordered.  Treat the
        // completion of all write responses as the SST-1 command boundary so
        // a following triangle's Z/blend reads cannot overtake writes from
        // the previous triangle.  Pixels within one triangle remain fully
        // pipelined; the FBI's local forwarding handles their dependencies.
        .pipeline_idle(fbi_idle && tmu_idle && memory_writes_idle &&
                       swaps_pending == 0),
        .v_retrace,
        .v_retrace_count,
        .mem_fifo_free(16'hffff),
        .displayed_buffer,
        .swaps_pending,
        .pci_interrupt(1'b0),
        .fbi_pixels_in(pixels_in),
        .fbi_chroma_fail(chroma_fail),
        .fbi_zfunc_fail(zfunc_fail),
        .fbi_afunc_fail(afunc_fail),
        .fbi_pixels_out(pixels_out),
        .fbi_current_stipple(current_stipple),
        .fbi_current_stipple_generation(current_stipple_generation),
        .host_req_valid,
        .host_req_ready,
        .host_req,
        .host_rsp_valid,
        .host_rsp_ready,
        .host_rsp,
        .render_cmd_valid,
        .render_cmd_ready,
        .render_cmd,
        .lfb_cmd_valid,
        .lfb_cmd_ready,
        .lfb_cmd,
        .lfb_read_rsp_valid,
        .lfb_read_rsp_ready,
        .lfb_read_rsp_data,
        .lfb_read_rsp_error,
        .texture_cmd_valid,
        .texture_cmd_ready,
        .texture_cmd,
        .debug_host_event_valid,
        .debug_host_event,
        .fifo_free,
        .frontend_busy,
        .register_write_valid(video_register_write_valid),
        .register_write_address(video_register_write_address),
        .register_write_data(video_register_write_data),
        .register_write_be(video_register_write_be)
    );

    assign video_swap_valid = render_cmd_valid &&
                              render_cmd.kind == SST1_COMMAND_SWAPBUFFER &&
                              fbi_idle && tmu_idle && memory_writes_idle;

    sst1_video_control video_control (
        .clk, .reset_n,
        .register_write_valid(video_register_write_valid),
        .register_write_address(video_register_write_address),
        .register_write_data(video_register_write_data),
        .register_write_be(video_register_write_be),
        .swap_valid(video_swap_valid), .swap_ready(video_swap_ready),
        .swap_data(render_cmd.command_data[8:0]), .v_retrace,
        .scanout_rgb565, .scanout_rgb888, .displayed_buffer,
        .swaps_pending, .swap_event, .frame_count(video_frame_count),
        .hsync_register(video_hsync_register),
        .vsync_register(video_vsync_register),
        .backporch_register(video_backporch_register),
        .dimensions_register(video_dimensions_register),
        .video_active
    );

    sst1_fbi fbi (
        .clk,
        .reset_n,
        .memory_enable,
        .memory_base(fbi_memory_base),
        .memory_size(fbi_memory_size),
        .command_valid(fbi_render_cmd_valid),
        .command_ready(fbi_render_cmd_ready),
        .command(render_cmd),
        .lfb_valid(fbi_lfb_cmd_valid),
        .lfb_ready(fbi_lfb_cmd_ready),
        .lfb(lfb_cmd),
        .lfb_read_rsp_valid,
        .lfb_read_rsp_ready,
        .lfb_read_rsp_data,
        .lfb_read_rsp_error,
        .texture_sample_valid,
        .texture_sample_ready,
        .texture_sample,
        .texture_result_valid,
        .texture_result_ready,
        .texture_result,
        .mem_req_valid(fbi_mem_req_valid),
        .mem_req_ready(fbi_mem_req_ready),
        .mem_req(fbi_mem_req),
        .mem_rsp_valid(fbi_mem_rsp_valid),
        .mem_rsp_ready(fbi_mem_rsp_ready),
        .mem_rsp,
        .idle(fbi_idle),
        .displayed_buffer,
        .pixels_in,
        .chroma_fail,
        .zfunc_fail,
        .afunc_fail,
        .pixels_out,
        .current_stipple,
        .current_stipple_generation,
        .last_alpha,
        .last_w,
        .perf_events(fbi_perf_events)
    );

    sst1_tmu tmu (
        .clk,
        .reset_n,
        .memory_enable,
        .memory_base(texture_memory_base),
        .memory_size(texture_memory_size),
        .command_valid(tmu_texture_cmd_valid),
        .command_ready(tmu_texture_cmd_ready),
        .command(texture_cmd),
        .sample_valid(texture_sample_valid),
        .sample_ready(texture_sample_ready),
        .sample(texture_sample),
        .result_valid(texture_result_valid),
        .result_ready(texture_result_ready),
        .result(texture_result),
        .mem_req_valid(tmu_mem_req_valid),
        .mem_req_ready(tmu_mem_req_ready),
        .mem_req(tmu_mem_req),
        .mem_rsp_valid(tmu_mem_rsp_valid),
        .mem_rsp_ready(tmu_mem_rsp_ready),
        .mem_rsp,
        .idle(tmu_idle),
        .perf_events(tmu_perf_events)
    );

    assign perf_fbi_active = !fbi_idle;
    sst1_perf_counters #(.COUNTER_BITS(PERF_COUNTER_BITS),
        .SNAPSHOT_WHILE_BUSY(PERF_SNAPSHOT_WHILE_BUSY)) performance_counters (
        .clk, .reset_n, .renderer_busy(busy),
        .snapshot(perf_snapshot), .clear(perf_clear),
        .read_index(perf_read_index), .read_data(perf_read_data),
        .pending(perf_pending), .fbi(fbi_perf_events), .tmu(tmu_perf_events),
        .mem_req_fire(mem_req_valid && mem_req_ready), .mem_req,
        .mem_rsp_fire(mem_rsp_valid && mem_rsp_ready), .mem_rsp,
        .tmu_arb_wait(tmu_mem_req_valid && !tmu_mem_req_ready),
        .fbi_arb_wait(fbi_mem_req_valid && !fbi_mem_req_ready),
        .response_backpressure(mem_rsp_valid && !mem_rsp_ready)
    );

    // TMU tags use bit 7; FBI tags keep it clear.  This remains valid when
    // the board backend returns independent streams out of order. Requests
    // use round-robin arbitration so sustained texture fills cannot starve
    // framebuffer reads or write-combine drains.
    always_comb begin
        memory_select_tmu = tmu_mem_req_valid &&
                            (!fbi_mem_req_valid || !last_memory_grant_tmu);
        mem_req_valid = tmu_mem_req_valid || fbi_mem_req_valid;
        mem_req = memory_select_tmu ? tmu_mem_req : fbi_mem_req;
        tmu_mem_req_ready = mem_req_ready && memory_select_tmu;
        fbi_mem_req_ready = mem_req_ready && !memory_select_tmu &&
                            fbi_mem_req_valid;
        tmu_mem_rsp_valid = mem_rsp_valid && mem_rsp.tag[7];
        fbi_mem_rsp_valid = mem_rsp_valid && !mem_rsp.tag[7];
        mem_rsp_ready = mem_rsp.tag[7] ? tmu_mem_rsp_ready : fbi_mem_rsp_ready;
    end

    always_ff @(posedge clk) begin
        if (!reset_n)
            last_memory_grant_tmu <= 1'b0;
        else if (mem_req_valid && mem_req_ready)
            last_memory_grant_tmu <= memory_select_tmu;
    end
endmodule
