// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module tb_sst1_core;
    import sst1_pkg::*;

    logic clk = 1'b0;
    logic reset_n = 1'b0;
    logic host_req_valid = 1'b0;
    logic host_req_ready;
    sst1_host_req_t host_req = '0;
    logic host_rsp_valid;
    logic host_rsp_ready = 1'b1;
    sst1_host_rsp_t host_rsp;
    logic debug_host_event_valid;
    sst1_debug_host_event_t debug_host_event;
    logic init_write_enable = 1'b1;
    logic init_remap_enable = 1'b0;
    logic pipeline_idle = 1'b1;
    logic v_retrace = 1'b0;
    logic [11:0] v_retrace_count = 12'd0;
    logic [15:0] mem_fifo_free = 16'hffff;
    logic [1:0] displayed_buffer = 2'd0;
    logic [2:0] swaps_pending = 3'd0;
    logic pci_interrupt = 1'b0;
    logic [31:0] fbi_pixels_in = 32'd0;
    logic [31:0] fbi_chroma_fail = 32'd0;
    logic [31:0] fbi_zfunc_fail = 32'd0;
    logic [31:0] fbi_afunc_fail = 32'd0;
    logic [31:0] fbi_pixels_out = 32'd0;
    logic [31:0] fbi_current_stipple = 32'd0;
    logic [31:0] fbi_current_stipple_generation = 32'd0;
    logic render_cmd_valid;
    logic render_cmd_ready = 1'b1;
    sst1_render_command_t render_cmd;
    logic lfb_cmd_valid;
    logic lfb_cmd_ready = 1'b1;
    sst1_lfb_command_t lfb_cmd;
    logic lfb_read_rsp_valid = 1'b0;
    logic lfb_read_rsp_ready;
    logic [31:0] lfb_read_rsp_data = 32'd0;
    logic lfb_read_rsp_error = 1'b0;
    logic texture_cmd_valid;
    logic texture_cmd_ready = 1'b1;
    sst1_texture_command_t texture_cmd;
    logic [6:0] fifo_free;
    logic frontend_busy;
    logic register_write_valid;
    logic [11:0] register_write_address;
    logic [31:0] register_write_data;
    logic [3:0] register_write_be;

    always #5 clk = ~clk;

    sst1_core dut (.*);

    task automatic transact_be(
        input logic [23:0] addr,
        input logic write,
        input logic [31:0] data,
        input logic [31:0] expected_read,
        input sst1_bar_region_t expected_region,
        input logic [31:0] expected_sequence,
        input logic [3:0] byte_enable
    );
        if ($test$plusargs("CORE_DEBUG"))
            $display("begin sequence=%0d address=%06x write=%0b be=%x",
                     expected_sequence, addr, write, byte_enable);
        @(negedge clk);
        host_req.addr = addr;
        host_req.write = write;
        host_req.wdata = data;
        host_req.be = byte_enable;
        host_req_valid = 1'b1;
        // Allow ready to settle after changing the request class/address.
        #1;
        while (!host_req_ready)
            @(negedge clk);
        @(posedge clk);
        #1;
        host_req_valid = 1'b0;
        while (!host_rsp_valid)
            @(posedge clk);
        if (!host_rsp_valid || host_rsp.error)
            $fatal(1, "request %06x did not complete successfully", addr);
        if (!write && host_rsp.rdata !== expected_read)
            $fatal(1, "read %06x returned %08x, expected %08x",
                   addr, host_rsp.rdata, expected_read);
        if (!debug_host_event_valid || debug_host_event.region !== expected_region)
            $fatal(1, "request %06x decoded to the wrong BAR region", addr);
        if (debug_host_event.transaction_id !== expected_sequence)
            $fatal(1, "request %06x has sequence %0d, expected %0d",
                   addr, debug_host_event.transaction_id, expected_sequence);
        if ($test$plusargs("CORE_DEBUG"))
            $display("done sequence=%0d response=%08x", expected_sequence,
                     host_rsp.rdata);
    endtask

    task automatic transact(
        input logic [23:0] addr,
        input logic write,
        input logic [31:0] data,
        input logic [31:0] expected_read,
        input sst1_bar_region_t expected_region,
        input logic [31:0] expected_sequence
    );
        transact_be(addr, write, data, expected_read, expected_region,
                    expected_sequence, 4'hf);
    endtask

    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset_n = 1'b1;

        transact(24'h000000, 1'b0, 32'd0, 32'h0ffff03f,
                 SST1_REGION_REG, 32'd0);
        transact(24'h200088, 1'b1, 32'h3f800000, 32'd0,
                 SST1_REGION_REG, 32'd1);
        transact(24'h400004, 1'b1, 32'h11223344, 32'd0,
                 SST1_REGION_LFB, 32'd2);
        transact(24'h800008, 1'b1, 32'h55667788, 32'd0,
                 SST1_REGION_TEXTURE0, 32'd3);
        transact(24'hc0000c, 1'b1, 32'h99aabbcc, 32'd0,
                 SST1_REGION_TEXTURE1, 32'd4);

        // Initialization registers are silently locked when initWrEnable=0.
        init_write_enable = 1'b0;
        transact(24'h000214, 1'b1, 32'hdeadbeef, 32'd0,
                 SST1_REGION_REG, 32'd5);
        transact(24'h000214, 1'b0, 32'd0, 32'd0,
                 SST1_REGION_REG, 32'd6);
        init_write_enable = 1'b1;

        // Glide detects an ICS5342 through dacData commands and the PCI
        // initEnable[2] fbiInit2 read remap.
        init_remap_enable = 1'b1;
        transact(24'h00022c, 1'b1, 32'h0000070b, 32'd0,
                 SST1_REGION_REG, 32'd7);
        transact(24'h00022c, 1'b1, 32'h00000d00, 32'd0,
                 SST1_REGION_REG, 32'd8);
        transact(24'h000218, 1'b0, 32'd0, 32'h00000079,
                 SST1_REGION_REG, 32'd9);
        init_remap_enable = 1'b0;

        // Fixed and floating aliases must reach the same canonical bank.
        transact(24'h000008, 1'b1, 32'hfffffff0, 32'd0,
                 SST1_REGION_REG, 32'd10);
        // Glide's splash screen uses the SST-1 SNAP_BIAS trick.  Float alias
        // conversion must wrap to the low 12.4 bits rather than saturating.
        transact(24'h000088, 1'b1, 32'h49401377, 32'd0,
                 SST1_REGION_REG, 32'd11); // 786743.4375 * 16 -> ...001377
        transact(24'h0000a0, 1'b1, 32'hbfc00000, 32'd0,
                 SST1_REGION_REG, 32'd12); // fstartR=-1.5 -> -1.5 * 2^12
        // The synchronous register-read mirror must preserve byte writes.
        transact(24'h000144, 1'b1, 32'h11223344, 32'd0,
                 SST1_REGION_REG, 32'd13);
        transact_be(24'h000144, 1'b1, 32'haabbccdd, 32'd0,
                    SST1_REGION_REG, 32'd14, 4'b0101);
        transact(24'h000144, 1'b0, 32'd0, 32'h11bb33dd,
                 SST1_REGION_REG, 32'd15);
        render_cmd_ready = 1'b0;
        transact(24'h000100, 1'b1, 32'h80000000, 32'd0,
                 SST1_REGION_REG, 32'd16);
        while (!render_cmd_valid)
            @(posedge clk);
        #1;
        if (render_cmd.kind !== SST1_COMMAND_TRIANGLE_FLOAT ||
            render_cmd.command_data !== 32'h80000000)
            $fatal(1, "ftriangleCMD was converted instead of preserving its sign word");
        if (render_cmd.state.triangle_parameters[0] !== 32'h00001377)
            $fatal(1, "SNAP_BIAS float vertex did not wrap to 12.4: %08x",
                   render_cmd.state.triangle_parameters[0]);
        if (render_cmd.state.triangle_parameters[6] !== 32'hffffe800)
            $fatal(1, "floating 12.12 alias conversion mismatch: %08x",
                   render_cmd.state.triangle_parameters[6]);
        render_cmd_ready = 1'b1;

        // LFB traffic shares the ordered PCI FIFO and must obey backpressure.
        lfb_cmd_ready = 1'b0;
        transact(24'h400000, 1'b1, 32'h11111111, 32'd0,
                 SST1_REGION_LFB, 32'd17);
        transact(24'h400004, 1'b1, 32'h22222222, 32'd0,
                 SST1_REGION_LFB, 32'd18);
        transact(24'h400008, 1'b1, 32'h33333333, 32'd0,
                 SST1_REGION_LFB, 32'd19);
        transact(24'h000000, 1'b0, 32'd0, 32'h0ffff3bd,
                 SST1_REGION_REG, 32'd20);
        if (host_rsp.rdata[5:0] !== 6'd61 || !host_rsp.rdata[9])
            $fatal(1, "status did not report FIFO pressure/busy: %08x", host_rsp.rdata);
        lfb_cmd_ready = 1'b1;
        while (frontend_busy)
            @(posedge clk);

        // A completed response must remain stable under arbitrary host stalls.
        host_rsp_ready = 1'b0;
        transact(24'h000000, 1'b0, 32'd0, 32'h0ffff03f,
                 SST1_REGION_REG, 32'd21);
        repeat (3) begin
            @(posedge clk);
            if (!host_rsp_valid || host_rsp.rdata !== 32'h0ffff03f)
                $fatal(1, "host response changed while stalled");
        end
        @(negedge clk);
        host_rsp_ready = 1'b1;
        @(posedge clk);

        // Complete Glide's three-value ICS detection, not just its first
        // GCLK1 probe.  Disabling the remap must restore normal fbiInit2.
        init_remap_enable = 1'b1;
        transact(24'h00022c, 1'b1, 32'h00000701, 32'd0,
                 SST1_REGION_REG, 32'd22);
        transact(24'h00022c, 1'b1, 32'h00000d00, 32'd0,
                 SST1_REGION_REG, 32'd23);
        transact(24'h000218, 1'b0, 32'd0, 32'h00000055,
                 SST1_REGION_REG, 32'd24);
        transact(24'h00022c, 1'b1, 32'h00000707, 32'd0,
                 SST1_REGION_REG, 32'd25);
        transact(24'h00022c, 1'b1, 32'h00000d00, 32'd0,
                 SST1_REGION_REG, 32'd26);
        transact(24'h000218, 1'b0, 32'd0, 32'h00000071,
                 SST1_REGION_REG, 32'd27);
        init_remap_enable = 1'b0;
        transact(24'h000218, 1'b0, 32'd0, 32'd0,
                 SST1_REGION_REG, 32'd28);

        // Tomb Raider supplies W=81.92: keeping only the canonical low
        // 32 bits wraps it to 1.92 and corrupts perspective division.
        transact(24'h0000bc, 1'b1, 32'h42a3d70a, 32'd0,
                 SST1_REGION_REG, 32'd29);
        transact(24'h0000b4, 1'b1, 32'h47000000, 32'd0,
                 SST1_REGION_REG, 32'd30); // S=32768 exceeds signed 14.18
        render_cmd_ready = 1'b0;
        transact(24'h000100, 1'b1, 32'd0, 32'd0,
                 SST1_REGION_REG, 32'd31);
        while (!render_cmd_valid) @(posedge clk);
        #1;
        if (stw_parameter(render_cmd.state, 13) !== 64'h000000147ae14000 ||
            stw_parameter(render_cmd.state, 11) !== 64'h0000000200000000)
            $fatal(1, "floating STW range was truncated");
        render_cmd_ready = 1'b1;
        transact(24'h00003c, 1'b1, 32'hc0000000, 32'd0,
                 SST1_REGION_REG, 32'd32); // fixed W=-1 clears float extension
        render_cmd_ready = 1'b0;
        transact(24'h000080, 1'b1, 32'd0, 32'd0,
                 SST1_REGION_REG, 32'd33);
        while (!render_cmd_valid) @(posedge clk);
        #1;
        if (stw_parameter(render_cmd.state, 13) !== -64'sh40000000)
            $fatal(1, "fixed STW write retained stale floating high bits");
        render_cmd_ready = 1'b1;

        $display("PASS: M1 decode, locking, Glide DAC detection, ordering, status, and wide STW");
        $finish;
    end

endmodule
