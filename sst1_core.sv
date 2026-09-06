// SPDX-License-Identifier: Apache-2.0
//
// zSST: a Voodoo 1 (SST-1) chipset implementation in SystemVerilog
// nand2mario, September 2026

`timescale 1ns/1ps

module sst1_core (
    input  logic                              clk,
    input  logic                              reset_n,
    input  logic                              init_write_enable,
    input  logic                              init_remap_enable,
    input  logic                              pipeline_idle,
    input  logic                              v_retrace,
    input  logic [11:0]                       v_retrace_count,
    input  logic [15:0]                       mem_fifo_free,
    input  logic [1:0]                        displayed_buffer,
    input  logic [2:0]                        swaps_pending,
    input  logic                              pci_interrupt,
    input  logic [31:0]                       fbi_pixels_in,
    input  logic [31:0]                       fbi_chroma_fail,
    input  logic [31:0]                       fbi_zfunc_fail,
    input  logic [31:0]                       fbi_afunc_fail,
    input  logic [31:0]                       fbi_pixels_out,
    input  logic [31:0]                       fbi_current_stipple,
    input  logic [31:0]                       fbi_current_stipple_generation,

    input  logic                              host_req_valid,
    output logic                              host_req_ready,
    input  sst1_pkg::sst1_host_req_t          host_req,

    output logic                              host_rsp_valid,
    input  logic                              host_rsp_ready,
    output sst1_pkg::sst1_host_rsp_t          host_rsp,

    output logic                              render_cmd_valid,
    input  logic                              render_cmd_ready,
    output sst1_pkg::sst1_render_command_t    render_cmd,

    output logic                              lfb_cmd_valid,
    input  logic                              lfb_cmd_ready,
    output sst1_pkg::sst1_lfb_command_t       lfb_cmd,
    input  logic                              lfb_read_rsp_valid,
    output logic                              lfb_read_rsp_ready,
    input  logic [31:0]                       lfb_read_rsp_data,
    input  logic                              lfb_read_rsp_error,

    output logic                              texture_cmd_valid,
    input  logic                              texture_cmd_ready,
    output sst1_pkg::sst1_texture_command_t   texture_cmd,

    output logic                              debug_host_event_valid,
    output sst1_pkg::sst1_debug_host_event_t  debug_host_event,
    output logic [6:0]                        fifo_free,
    output logic                              frontend_busy,
    output logic                              register_write_valid,
    output logic [11:0]                       register_write_address,
    output logic [31:0]                       register_write_data,
    output logic [3:0]                        register_write_be
);

    sst1_frontend frontend (.*);

endmodule
