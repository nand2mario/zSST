// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module sst1_pci_fifo #(
    parameter int DEPTH = 64
) (
    input  logic                       clk,
    input  logic                       reset_n,
    input  logic                       push_valid,
    output logic                       push_ready,
    input  sst1_pkg::sst1_fifo_entry_t push_entry,
    output logic                       pop_valid,
    input  logic                       pop_ready,
    output sst1_pkg::sst1_fifo_entry_t pop_entry,
    output logic [$clog2(DEPTH+1)-1:0] occupancy
);
    localparam int POINTER_WIDTH = $clog2(DEPTH);
    localparam int COUNT_WIDTH = $clog2(DEPTH+1);
    localparam int ENTRY_WIDTH = $bits(sst1_pkg::sst1_fifo_entry_t);
    localparam logic [COUNT_WIDTH-1:0] DEPTH_COUNT = COUNT_WIDTH'(DEPTH);

`ifdef ZSST_XILINX
    logic full, empty;
    logic push_fire, pop_fire;
    logic [ENTRY_WIDTH-1:0] fifo_data;

    assign pop_valid = !empty;
    assign pop_entry = sst1_pkg::sst1_fifo_entry_t'(fifo_data);
    // In FWFT mode XPM_FIFO_SYNC has two output-prefetch slots in addition to
    // FIFO_WRITE_DEPTH.  Its physical `full` therefore does not describe the
    // DEPTH-entry queue exported by this module.  Gate writes with our logical
    // occupancy so the public free count never wraps at DEPTH+1/DEPTH+2.  A
    // simultaneous pop still permits a replacement write at logical full.
    assign push_ready = occupancy != DEPTH_COUNT || (pop_valid && pop_ready);
    assign push_fire = push_valid && push_ready;
    assign pop_fire = pop_valid && pop_ready;

    xpm_fifo_sync #(
        .CASCADE_HEIGHT(0),
        .DOUT_RESET_VALUE("0"),
        .ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE("block"),
        .FIFO_READ_LATENCY(0),
        .FIFO_WRITE_DEPTH(DEPTH),
        .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(10),
        .PROG_FULL_THRESH(10),
        .RD_DATA_COUNT_WIDTH(1),
        .READ_DATA_WIDTH(ENTRY_WIDTH),
        .READ_MODE("fwft"),
        .SIM_ASSERT_CHK(0),
        .USE_ADV_FEATURES("0000"),
        .WAKEUP_TIME(0),
        .WRITE_DATA_WIDTH(ENTRY_WIDTH),
        .WR_DATA_COUNT_WIDTH(1)
    ) storage (
        .almost_empty(), .almost_full(), .data_valid(), .dbiterr(),
        .dout(fifo_data), .empty, .full, .overflow(), .prog_empty(),
        .prog_full(), .rd_data_count(), .rd_rst_busy(), .sbiterr(),
        .underflow(), .wr_ack(), .wr_data_count(), .wr_rst_busy(),
        .din(push_entry), .injectdbiterr(1'b0), .injectsbiterr(1'b0),
        .rd_en(pop_fire), .rst(!reset_n), .sleep(1'b0),
        .wr_clk(clk), .wr_en(push_fire)
    );

    always_ff @(posedge clk) begin
        if (!reset_n)
            occupancy <= '0;
        else begin
            case ({push_fire, pop_fire})
                2'b10: occupancy <= occupancy + 1'b1;
                2'b01: occupancy <= occupancy - 1'b1;
                default: ;
            endcase
        end
    end
`else
    // The externally visible head is prefetched into a register.  Everything
    // behind it is a synchronous tail RAM, which removes the old wide
    // asynchronous 64:1 read mux while retaining a zero-latency ready/valid
    // head and one push plus one pop per cycle.
    (* ram_style = "block" *)
    logic [ENTRY_WIDTH-1:0] storage [0:DEPTH-1];
    logic [ENTRY_WIDTH-1:0] head_entry;
    logic head_valid;
    logic [COUNT_WIDTH-1:0] tail_count;
    logic [POINTER_WIDTH-1:0] read_pointer;
    logic [POINTER_WIDTH-1:0] write_pointer;
    logic push_fire;
    logic pop_fire;

    assign occupancy = head_valid ? tail_count + 1'b1 : '0;
    assign push_ready = !head_valid || tail_count != DEPTH_COUNT - 1'b1 ||
                        (pop_valid && pop_ready);
    assign pop_valid  = head_valid;
    assign pop_entry  = head_entry;
    assign push_fire  = push_valid && push_ready;
    assign pop_fire   = pop_valid && pop_ready;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            read_pointer  <= '0;
            write_pointer <= '0;
            head_entry    <= '0;
            head_valid    <= 1'b0;
            tail_count    <= '0;
        end else begin
            case ({push_fire, pop_fire})
                2'b10: begin
                    if (!head_valid) begin
                        head_entry <= push_entry;
                        head_valid <= 1'b1;
                    end else begin
                        storage[write_pointer] <= push_entry;
                        write_pointer <= write_pointer + 1'b1;
                        tail_count <= tail_count + 1'b1;
                    end
                end
                2'b01: begin
                    if (tail_count != 0) begin
                        head_entry <= storage[read_pointer];
                        read_pointer <= read_pointer + 1'b1;
                        tail_count <= tail_count - 1'b1;
                    end else begin
                        head_valid <= 1'b0;
                    end
                end
                2'b11: begin
                    if (tail_count == 0) begin
                        // Replace a lone consumed head directly; no RAM cycle.
                        head_entry <= push_entry;
                    end else begin
                        head_entry <= storage[read_pointer];
                        read_pointer <= read_pointer + 1'b1;
                        storage[write_pointer] <= push_entry;
                        write_pointer <= write_pointer + 1'b1;
                    end
                end
                default: begin end
            endcase
        end
    end
`endif

`ifndef SYNTHESIS
    property p_stable_while_stalled;
        @(posedge clk) disable iff (!reset_n)
            pop_valid && !pop_ready |=>
                pop_ready || (pop_valid && $stable(pop_entry));
    endproperty
    assert property (p_stable_while_stalled);

    property p_no_overflow;
        @(posedge clk) disable iff (!reset_n)
            occupancy <= DEPTH_COUNT;
    endproperty
    assert property (p_no_overflow);
`endif

endmodule
