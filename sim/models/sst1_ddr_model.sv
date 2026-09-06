// SPDX-License-Identifier: Apache-2.0
//
// zSST: a Voodoo 1 (SST-1) chipset implementation in SystemVerilog
// nand2mario, September 2026
//
// Deterministic memory model for integration and throughput simulation.

`timescale 1ns/1ps

// Deterministic DDR timing model for throughput experiments.  The defaults
// approximate measured KV260 DDR behavior at 100 MHz: 26 cycles minimum to
// the first read beat, about 28 cycles on average, one 128-bit beat per cycle,
// and an occasional long-latency request.  Independent tagged requests may
// become ready and complete out of issue order.
module sst1_ddr_model #(
    parameter integer MAX_OUTSTANDING = 16,
    parameter integer MIN_READ_LATENCY = 26,
    parameter integer READ_JITTER = 4,
    parameter integer LONG_DELAY_PERIOD = 64,
    parameter integer LONG_DELAY_CYCLES = 48,
    parameter integer WRITE_QUEUE_DEPTH = 8,
    parameter integer WRITE_SERVICE_CYCLES = 2,
    parameter bit REORDER_RESPONSES = 1'b1,
    parameter bit STORE_MEMORY = 1'b0,
    parameter integer MEMORY_BYTES = 16
) (
    input  logic                    clk,
    input  logic                    reset_n,
    input  logic                    req_valid,
    output logic                    req_ready,
    input  sst1_pkg::sst1_mem_req_t req,
    output logic                    rsp_valid,
    input  logic                    rsp_ready,
    output sst1_pkg::sst1_mem_rsp_t rsp,

    output logic [63:0]             cycles,
    output logic [63:0]             read_requests,
    output logic [63:0]             read_beats,
    output logic [63:0]             write_requests,
    output logic [31:0]             outstanding_reads,
    output logic [31:0]             max_outstanding_reads,
    output logic [31:0]             outstanding_writes,
    output logic                    idle
);
    import sst1_pkg::*;

    logic slot_valid [0:MAX_OUTSTANDING-1];
    logic [39:0] slot_address [0:MAX_OUTSTANDING-1];
    logic [7:0] slot_tag [0:MAX_OUTSTANDING-1];
    logic [7:0] slot_beats [0:MAX_OUTSTANDING-1];
    logic [63:0] slot_ready_cycle [0:MAX_OUTSTANDING-1];
    logic [31:0] slot_sequence [0:MAX_OUTSTANDING-1];
    logic [31:0] next_sequence;
    logic [31:0] request_lfsr;

    localparam integer MEMORY_LINES = MEMORY_BYTES / 16;
    logic [127:0] stored_memory [0:MEMORY_LINES-1];

    logic free_found, eligible_found;
    integer free_slot, eligible_slot;
    logic [31:0] eligible_sequence;
    logic serving;
    integer serving_slot;
    integer write_service_counter;

    function automatic logic [127:0] memory_data(input logic [39:0] address);
        logic [127:0] value;
        integer lane;
        integer line_index;
        begin
            line_index = int'(address >> 4);
            if (STORE_MEMORY && address < 40'(MEMORY_BYTES))
                value = stored_memory[line_index];
            else
                for (lane = 0; lane < 16; lane = lane + 1)
                    value[lane*8 +: 8] = address[7:0] + lane[7:0] ^
                                               address[15:8] ^ address[23:16];
            return value;
        end
    endfunction

    initial begin : initialize_memory
        integer line;
        if (MEMORY_BYTES < 16 || MEMORY_BYTES % 16 != 0)
            $fatal(1, "MEMORY_BYTES must be a positive multiple of 16");
        if (STORE_MEMORY)
            for (line = 0; line < MEMORY_LINES; line = line + 1)
                stored_memory[line] = '0;
    end

    always_comb begin
        integer comb_slot;
        free_found = 1'b0;
        free_slot = 0;
        eligible_found = 1'b0;
        eligible_slot = 0;
        eligible_sequence = REORDER_RESPONSES ? 32'd0 : 32'hffff_ffff;
        outstanding_reads = 32'd0;
        for (comb_slot = 0; comb_slot < MAX_OUTSTANDING; comb_slot++) begin
            if (!slot_valid[comb_slot] && !free_found) begin
                free_found = 1'b1;
                free_slot = comb_slot;
            end
            if (slot_valid[comb_slot]) begin
                outstanding_reads = outstanding_reads + 1'b1;
                if (slot_ready_cycle[comb_slot] <= cycles &&
                    (!eligible_found ||
                     (REORDER_RESPONSES &&
                      slot_sequence[comb_slot] > eligible_sequence) ||
                     (!REORDER_RESPONSES &&
                      slot_sequence[comb_slot] < eligible_sequence))) begin
                    eligible_found = 1'b1;
                    eligible_slot = comb_slot;
                    eligible_sequence = slot_sequence[comb_slot];
                end
            end
        end
        req_ready = req.write ? outstanding_writes < WRITE_QUEUE_DEPTH :
                                free_found;
        idle = outstanding_reads == 0 && outstanding_writes == 0 &&
               !rsp_valid && !serving;
    end

    always_ff @(posedge clk) begin : model
        integer jitter;
        integer extra_delay;
        integer active_slot;
        integer reset_slot;
        integer write_lane;
        integer write_line;
        if (!reset_n) begin
            rsp_valid <= 1'b0;
            rsp <= '0;
            cycles <= '0;
            read_requests <= '0;
            read_beats <= '0;
            write_requests <= '0;
            max_outstanding_reads <= '0;
            outstanding_writes <= '0;
            write_service_counter <= 0;
            next_sequence <= '0;
            request_lfsr <= 32'h3141_5926;
            serving <= 1'b0;
            serving_slot <= 0;
            for (reset_slot = 0; reset_slot < MAX_OUTSTANDING; reset_slot++) begin
                slot_valid[reset_slot] <= 1'b0;
                slot_address[reset_slot] <= '0;
                slot_tag[reset_slot] <= '0;
                slot_beats[reset_slot] <= '0;
                slot_ready_cycle[reset_slot] <= '0;
                slot_sequence[reset_slot] <= '0;
            end
        end else begin
            logic write_enqueue;
            logic write_dequeue;

            cycles <= cycles + 1'b1;
            if (outstanding_reads > max_outstanding_reads)
                max_outstanding_reads <= outstanding_reads;

            write_enqueue = req_valid && req_ready && req.write;
            write_dequeue = outstanding_writes != 0 &&
                            write_service_counter == 0;
            case ({write_enqueue, write_dequeue})
                2'b10: outstanding_writes <= outstanding_writes + 1'b1;
                2'b01: outstanding_writes <= outstanding_writes - 1'b1;
                default: outstanding_writes <= outstanding_writes;
            endcase
            if (write_dequeue)
                write_service_counter <= WRITE_SERVICE_CYCLES - 1;
            else if (write_service_counter != 0)
                write_service_counter <= write_service_counter - 1;

            if (req_valid && req_ready) begin
                if (req.write) begin
                    write_requests <= write_requests + 1'b1;
                    if (STORE_MEMORY && req.addr < 40'(MEMORY_BYTES)) begin
                        write_line = int'(req.addr >> 4);
                        for (write_lane = 0; write_lane < 16;
                             write_lane = write_lane + 1)
                            if (req.wstrb[write_lane])
                                stored_memory[write_line][write_lane*8 +: 8] <=
                                    req.wdata[write_lane*8 +: 8];
                    end
                end else begin
                    jitter = READ_JITTER == 0 ? 0 : request_lfsr % (READ_JITTER + 1);
                    extra_delay = 0;
                    if (LONG_DELAY_PERIOD != 0 &&
                        request_lfsr % LONG_DELAY_PERIOD == 0)
                        extra_delay = LONG_DELAY_CYCLES;
                    slot_valid[free_slot] <= 1'b1;
                    slot_address[free_slot] <= req.addr;
                    slot_tag[free_slot] <= req.tag;
                    slot_beats[free_slot] <= req.beats;
                    slot_ready_cycle[free_slot] <= cycles + MIN_READ_LATENCY +
                                                   jitter + extra_delay;
                    slot_sequence[free_slot] <= next_sequence;
                    next_sequence <= next_sequence + 1'b1;
                    read_requests <= read_requests + 1'b1;
                    request_lfsr <= {request_lfsr[30:0],
                                     request_lfsr[31] ^ request_lfsr[21] ^
                                     request_lfsr[1] ^ request_lfsr[0]};
                end
            end

            if (!rsp_valid || rsp_ready) begin
                rsp_valid <= 1'b0;
                if (serving || eligible_found) begin
                    active_slot = serving ? serving_slot : eligible_slot;
                    rsp <= '0;
                    rsp.rdata <= memory_data(slot_address[active_slot]);
                    rsp.tag <= slot_tag[active_slot];
                    rsp.last <= slot_beats[active_slot] == 1;
                    rsp_valid <= 1'b1;
                    read_beats <= read_beats + 1'b1;
                    if (slot_beats[active_slot] == 1) begin
                        slot_valid[active_slot] <= 1'b0;
                        serving <= 1'b0;
                    end else begin
                        slot_address[active_slot] <= slot_address[active_slot] + 16;
                        slot_beats[active_slot] <= slot_beats[active_slot] - 1'b1;
                        serving <= 1'b1;
                        serving_slot <= active_slot;
                    end
                end
            end
        end
    end
endmodule
