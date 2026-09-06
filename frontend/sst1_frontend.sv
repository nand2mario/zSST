// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module sst1_frontend (
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
    import sst1_pkg::*;
    import sst1_regs_pkg::*;

    localparam int RENDER_STATE_WIDTH = $bits(sst1_render_state_t);
    localparam int RENDER_STATE_CHUNK_WIDTH = 256;
    localparam int RENDER_STATE_CHUNKS =
        (RENDER_STATE_WIDTH + RENDER_STATE_CHUNK_WIDTH - 1) /
        RENDER_STATE_CHUNK_WIDTH;

    sst1_bar_region_t decoded_region;
    logic [7:0] decoded_wrap;
    logic [3:0] decoded_chip_select;
    logic [11:0] decoded_register;
    zsst1_reg_access_t decoded_access;
    logic decoded_fifo;
    logic decoded_sync;
    logic [3:0] decoded_chip_mask;
    logic decoded_float;
    logic [11:0] decoded_float_target;
    logic [5:0] decoded_float_fraction;
    logic [5:0] decoded_float_width;

    logic remap_enable;
    logic [31:0] reg_read_data;
    logic reg_read_initialized;
    sst1_render_state_t current_render_state;

    logic fifo_push_valid;
    logic fifo_push_ready;
    sst1_fifo_entry_t fifo_push_entry;
    logic fifo_pop_valid;
    logic fifo_pop_ready;
    sst1_fifo_entry_t fifo_pop_entry;
    logic [6:0] fifo_occupancy;
    logic fifo_empty;

    logic response_slot_available;
    logic request_fire;
    logic register_region;
    logic register_write_allowed;
    logic register_read_allowed;
    logic direct_write_valid;
    logic selected_chip;
    logic popped_command;
    logic popped_lfb;
    logic popped_texture;
    logic popped_texture_table;
    logic pop_allowed;
    logic pop_fire;
    logic dispatch_write_valid;
    logic [11:0] dispatch_write_address;
    logic [31:0] dispatch_write_data;
    logic [31:0] converted_float;
    logic [63:0] converted_float_extended;
    logic float_overflow;
    logic float_invalid;
    logic regfile_write_valid;
    logic [11:0] regfile_write_address;
    logic [31:0] regfile_write_data;
    logic [3:0] regfile_write_be;
    logic regfile_read_enable;
    logic register_read_pending;
    logic register_read_override;
    logic pending_register_read_override;
    logic [31:0] pending_register_read_data;
    sst1_debug_host_event_t pending_register_read_event;
    logic [31:0] read_result;
    logic [31:0] status_value;
    logic [31:0] transaction_id;
    logic [6:0] raw_fifo_free;
    logic lfb_read_request;
    logic lfb_read_pending;
    logic render_capture;
    (* keep = "true", max_fanout = 256 *)
    logic [RENDER_STATE_CHUNKS:0] render_capture_enable;
    logic [RENDER_STATE_WIDTH-1:0] current_render_state_bits;
    logic [RENDER_STATE_WIDTH-1:0] render_state_snapshot_bits;
    logic [31:0] render_transaction_id;
    logic [31:0] render_command_data;
    sst1_command_kind_t render_command_kind;
    logic [3:0] dac_read_address;
    logic [3:0] dac_write_address;
    logic [7:0] dac_read_data;
    logic [7:0] dac_pll_register [0:15];
    integer dac_index;

    sst1_addr_decode decode (
        .address(host_req.addr),
        .remap_enable,
        .region(decoded_region),
        .wrap(decoded_wrap),
        .chip_select(decoded_chip_select),
        .register_address(decoded_register),
        .register_access(decoded_access),
        .register_fifo(decoded_fifo),
        .register_sync(decoded_sync),
        .register_chip_mask(decoded_chip_mask),
        .float_alias(decoded_float),
        .float_target(decoded_float_target),
        .float_fraction(decoded_float_fraction),
        .float_width(decoded_float_width)
    );

    sst1_pci_fifo fifo (
        .clk,
        .reset_n,
        .push_valid(fifo_push_valid),
        .push_ready(fifo_push_ready),
        .push_entry(fifo_push_entry),
        .pop_valid(fifo_pop_valid),
        .pop_ready(fifo_pop_ready),
        .pop_entry(fifo_pop_entry),
        .occupancy(fifo_occupancy)
    );

    sst1_float_to_fixed float_converter (
        .ieee754(fifo_pop_entry.data),
        .fraction_bits(fifo_pop_entry.float_fraction),
        .result_width(fifo_pop_entry.float_width),
        .fixed(converted_float),
        .extended_fixed(converted_float_extended),
        .overflow(float_overflow),
        .invalid(float_invalid)
    );

    sst1_regfile regfile (
        .clk,
        .reset_n,
        .write_valid(regfile_write_valid),
        .write_address(regfile_write_address),
        .write_data(regfile_write_data),
        .write_extended_valid(!direct_write_valid && fifo_pop_entry.float_alias),
        .write_extended_data(converted_float_extended),
        .write_byte_enable(regfile_write_be),
        .read_enable(regfile_read_enable),
        .read_address(decoded_register),
        .read_data(reg_read_data),
        .read_initialized(reg_read_initialized),
        .remap_enable,
        .render_state(current_render_state)
    );

    assign register_region = decoded_region == SST1_REGION_REG;
    assign register_write_allowed = decoded_access inside {ZSST1_REG_WO, ZSST1_REG_RW};
    assign register_read_allowed = decoded_access inside {ZSST1_REG_RO, ZSST1_REG_RW};
    assign response_slot_available = !host_rsp_valid || host_rsp_ready;
    assign fifo_empty = fifo_occupancy == 0;

    always_comb begin
        host_req_ready = response_slot_available && !lfb_read_pending &&
                         !register_read_pending;
        if (host_req.write) begin
            if ((register_region && register_write_allowed && decoded_fifo) ||
                (decoded_region == SST1_REGION_LFB) ||
                (decoded_region inside {SST1_REGION_TEXTURE0,
                                        SST1_REGION_TEXTURE1}))
                host_req_ready = response_slot_available && fifo_push_ready;
            else if (register_region && register_write_allowed)
                host_req_ready = response_slot_available;
        end else if (decoded_region == SST1_REGION_LFB) begin
            host_req_ready = response_slot_available && !lfb_read_pending &&
                             !register_read_pending &&
                             fifo_empty && pipeline_idle && !render_cmd_valid &&
                             lfb_cmd_ready;
        end else if (register_region && decoded_register != ZSST1_REG_STATUS) begin
            // Register reads other than status are synchronization points.
            // Status is intentionally observable while work remains queued.
            host_req_ready = response_slot_available && !lfb_read_pending &&
                             !register_read_pending &&
                             fifo_empty && pipeline_idle && !render_cmd_valid;
        end
    end
    assign request_fire = host_req_valid && host_req_ready;
    assign regfile_read_enable = request_fire && !host_req.write && register_region;

    assign fifo_push_valid = host_req_valid && response_slot_available && host_req.write &&
                             ((register_region && register_write_allowed && decoded_fifo) ||
                              (decoded_region == SST1_REGION_LFB) ||
                              (decoded_region inside {SST1_REGION_TEXTURE0,
                                                      SST1_REGION_TEXTURE1}));
    always_comb begin
        fifo_push_entry = '0;
        fifo_push_entry.transaction_id = transaction_id;
        fifo_push_entry.region = decoded_region;
        fifo_push_entry.region_offset = sst1_region_offset(host_req.addr);
        fifo_push_entry.register_address = decoded_register;
        fifo_push_entry.chip_select = decoded_chip_select;
        fifo_push_entry.data = host_req.wdata;
        fifo_push_entry.byte_enable = host_req.be;
        fifo_push_entry.sync_required = decoded_sync;
        fifo_push_entry.float_alias = decoded_float;
        fifo_push_entry.float_target = decoded_float_target;
        fifo_push_entry.float_fraction = decoded_float_fraction;
        fifo_push_entry.float_width = decoded_float_width;
    end

    assign direct_write_valid = request_fire && host_req.write && register_region &&
                                register_write_allowed && !decoded_fifo && init_write_enable &&
                                ((decoded_chip_select == 0) ||
                                 ((decoded_chip_select & decoded_chip_mask) != 0));

    assign popped_command = fifo_pop_entry.region == SST1_REGION_REG &&
                            zsst1_is_command(fifo_pop_entry.register_address);
    assign popped_lfb = fifo_pop_entry.region == SST1_REGION_LFB;
    assign popped_texture = fifo_pop_entry.region inside {
                                SST1_REGION_TEXTURE0, SST1_REGION_TEXTURE1};
    assign popped_texture_table = fifo_pop_entry.region == SST1_REGION_REG &&
                                  fifo_pop_entry.register_address >= ZSST1_REG_NCCTABLE0_00 &&
                                  fifo_pop_entry.register_address <= ZSST1_REG_NCCTABLE1_11;
    assign selected_chip = (fifo_pop_entry.chip_select == 0) ||
                           ((fifo_pop_entry.chip_select &
                             zsst1_reg_chip_mask(fifo_pop_entry.register_address)) != 0);
    assign pop_allowed = !fifo_pop_entry.sync_required ||
                         (pipeline_idle && !render_cmd_valid);
    assign fifo_pop_ready = fifo_pop_valid && pop_allowed &&
                            (!popped_command || !render_cmd_valid || render_cmd_ready) &&
                            (!popped_lfb || lfb_cmd_ready) &&
                            (!(popped_texture || popped_texture_table) || texture_cmd_ready);
    assign pop_fire = fifo_pop_valid && fifo_pop_ready;
    assign render_capture = pop_fire && popped_command && selected_chip;
    assign render_capture_enable = {RENDER_STATE_CHUNKS+1{render_capture}};
    assign dispatch_write_valid = pop_fire &&
                                  fifo_pop_entry.region == SST1_REGION_REG &&
                                  !popped_command && selected_chip;
    assign dispatch_write_address = fifo_pop_entry.float_alias ?
                                    fifo_pop_entry.float_target :
                                    fifo_pop_entry.register_address;
    assign dispatch_write_data = zsst1_canonical_fixed(
        fifo_pop_entry.float_alias ? fifo_pop_entry.float_target :
                                     fifo_pop_entry.register_address,
        fifo_pop_entry.float_alias ? converted_float : fifo_pop_entry.data);

    assign regfile_write_valid = direct_write_valid || dispatch_write_valid;
    assign regfile_write_address = direct_write_valid ? decoded_register : dispatch_write_address;
    assign regfile_write_data = direct_write_valid ? host_req.wdata : dispatch_write_data;
    assign regfile_write_be = direct_write_valid ? host_req.be :
                              (fifo_pop_entry.float_alias ? 4'hf : fifo_pop_entry.byte_enable);
    assign register_write_valid = regfile_write_valid;
    assign register_write_address = regfile_write_address;
    assign register_write_data = regfile_write_data;
    assign register_write_be = regfile_write_be;

    assign current_render_state_bits = current_render_state;

    always_comb begin
        render_cmd = '0;
        render_cmd.transaction_id = render_transaction_id;
        render_cmd.kind = render_command_kind;
        render_cmd.command_data = render_command_data;
        render_cmd.state = sst1_render_state_t'(render_state_snapshot_bits);
    end

    for (genvar chunk = 0; chunk < RENDER_STATE_CHUNKS; chunk = chunk + 1) begin : snapshot_chunk
        localparam int OFFSET = chunk * RENDER_STATE_CHUNK_WIDTH;
        localparam int WIDTH =
            OFFSET + RENDER_STATE_CHUNK_WIDTH <= RENDER_STATE_WIDTH ?
            RENDER_STATE_CHUNK_WIDTH : RENDER_STATE_WIDTH - OFFSET;

        always_ff @(posedge clk) begin
            if (!reset_n)
                render_state_snapshot_bits[OFFSET +: WIDTH] <= '0;
            else if (render_capture_enable[chunk])
                render_state_snapshot_bits[OFFSET +: WIDTH] <=
                    current_render_state_bits[OFFSET +: WIDTH];
        end
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            render_transaction_id <= '0;
            render_command_data <= '0;
            render_command_kind <= SST1_COMMAND_NOP;
        end else if (render_capture_enable[RENDER_STATE_CHUNKS]) begin
            render_transaction_id <= fifo_pop_entry.transaction_id;
            render_command_data <= fifo_pop_entry.data;
            case (fifo_pop_entry.register_address)
                ZSST1_REG_TRIANGLECMD:
                    render_command_kind <= SST1_COMMAND_TRIANGLE_FIXED;
                ZSST1_REG_FTRIANGLECMD:
                    render_command_kind <= SST1_COMMAND_TRIANGLE_FLOAT;
                ZSST1_REG_NOPCMD:
                    render_command_kind <= SST1_COMMAND_NOP;
                ZSST1_REG_FASTFILLCMD:
                    render_command_kind <= SST1_COMMAND_FASTFILL;
                default:
                    render_command_kind <= SST1_COMMAND_SWAPBUFFER;
            endcase
        end
    end

    assign lfb_read_request = host_req_valid && !host_req.write &&
                              decoded_region == SST1_REGION_LFB &&
                              response_slot_available &&
                              !lfb_read_pending && fifo_empty && pipeline_idle &&
                              !render_cmd_valid;
    assign lfb_read_rsp_ready = !host_rsp_valid || host_rsp_ready;

    always_comb begin
        lfb_cmd_valid = (fifo_pop_valid && popped_lfb && pop_allowed) ||
                        lfb_read_request;
        lfb_cmd = '0;
        lfb_cmd.transaction_id = lfb_read_request ? transaction_id :
                                                  fifo_pop_entry.transaction_id;
        lfb_cmd.offset = lfb_read_request ? sst1_region_offset(host_req.addr) :
                                           fifo_pop_entry.region_offset;
        lfb_cmd.data = fifo_pop_entry.data;
        lfb_cmd.byte_enable = lfb_read_request ? host_req.be :
                                                fifo_pop_entry.byte_enable;
        lfb_cmd.write = !lfb_read_request;
        lfb_cmd.state = current_render_state;
    end

    always_comb begin
        texture_cmd_valid = fifo_pop_valid && pop_allowed &&
                            (popped_texture || (popped_texture_table && selected_chip));
        texture_cmd = '0;
        texture_cmd.transaction_id = fifo_pop_entry.transaction_id;
        texture_cmd.table_write = popped_texture_table;
        texture_cmd.aperture_offset = {fifo_pop_entry.region[0],
                                       fifo_pop_entry.region_offset};
        texture_cmd.register_address = fifo_pop_entry.register_address;
        texture_cmd.data = fifo_pop_entry.data;
        texture_cmd.byte_enable = fifo_pop_entry.byte_enable;
        texture_cmd.state = current_render_state;
    end

    always_comb begin
        raw_fifo_free = 7'd64 - fifo_occupancy;
        fifo_free = raw_fifo_free > 63 ? 7'd63 : raw_fifo_free;
        frontend_busy = !fifo_empty || render_cmd_valid || !pipeline_idle;
        status_value = 32'd0;
        status_value[5:0] = fifo_free[5:0];
        status_value[6] = v_retrace;
        status_value[7] = frontend_busy;
        status_value[8] = frontend_busy;
        status_value[9] = frontend_busy;
        status_value[11:10] = displayed_buffer;
        status_value[27:12] = mem_fifo_free;
        status_value[30:28] = swaps_pending;
        status_value[31] = pci_interrupt;
        register_read_override = 1'b1;
        read_result = 32'd0;
        if (register_region && decoded_register == ZSST1_REG_STATUS)
            read_result = status_value;
        else if (register_region && decoded_register == ZSST1_REG_VRETRACE)
            read_result = {20'd0, v_retrace_count};
        else if (register_region && decoded_register == ZSST1_REG_FBIPIXELSIN)
            read_result = fbi_pixels_in;
        else if (register_region && decoded_register == ZSST1_REG_FBICHROMAFAIL)
            read_result = fbi_chroma_fail;
        else if (register_region && decoded_register == ZSST1_REG_FBIZFUNCFAIL)
            read_result = fbi_zfunc_fail;
        else if (register_region && decoded_register == ZSST1_REG_FBIAFUNCFAIL)
            read_result = fbi_afunc_fail;
        else if (register_region && decoded_register == ZSST1_REG_FBIPIXELSOUT)
            read_result = fbi_pixels_out;
        else if (register_region && decoded_register == ZSST1_REG_FBIINIT2 &&
                 init_remap_enable)
            // initEnable[2] remaps fbiInit2[7:0] to the external DAC read latch.
            read_result = {24'd0, dac_read_data};
        else if (register_region && decoded_register == ZSST1_REG_FBIINIT3 &&
                 init_remap_enable)
            // The companion remap exposes the video checksum.  zSST does not
            // calculate it yet, but it must not leak the stored fbiInit3 value.
            read_result = 32'd0;
        else if (register_region && decoded_register == ZSST1_REG_STIPPLE &&
                 fbi_current_stipple_generation ==
                 current_render_state.stipple_generation)
            read_result = fbi_current_stipple;
        else if (register_region && register_read_allowed)
            register_read_override = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            host_rsp_valid <= 1'b0;
            host_rsp <= '0;
            debug_host_event_valid <= 1'b0;
            debug_host_event <= '0;
            render_cmd_valid <= 1'b0;
            transaction_id <= 32'd0;
            lfb_read_pending <= 1'b0;
            register_read_pending <= 1'b0;
            pending_register_read_override <= 1'b0;
            pending_register_read_data <= '0;
            pending_register_read_event <= '0;
            dac_read_address <= 4'd0;
            dac_write_address <= 4'd0;
            dac_read_data <= 8'd0;
            for (dac_index = 0; dac_index < 16; dac_index = dac_index + 1)
                dac_pll_register[dac_index] <= 8'd0;
            // Reference ICS5342 power-on values used by SST-1 Glide detection.
            dac_pll_register[4'h1] <= 8'h55;
            dac_pll_register[4'h7] <= 8'h71;
            dac_pll_register[4'hb] <= 8'h79;
        end else begin
            debug_host_event_valid <= 1'b0;
            if (host_rsp_valid && host_rsp_ready)
                host_rsp_valid <= 1'b0;
            if (render_cmd_valid && render_cmd_ready)
                render_cmd_valid <= 1'b0;

            if (register_read_pending) begin
                host_rsp_valid <= 1'b1;
                host_rsp.rdata <= pending_register_read_override ?
                                  pending_register_read_data : reg_read_data;
                host_rsp.error <= 1'b0;
                register_read_pending <= 1'b0;
                debug_host_event_valid <= 1'b1;
                debug_host_event <= pending_register_read_event;
                debug_host_event.data <= pending_register_read_override ?
                                         pending_register_read_data : reg_read_data;
            end

            if (request_fire) begin
                if (!host_req.write && register_region) begin
                    register_read_pending <= 1'b1;
                    pending_register_read_override <= register_read_override;
                    pending_register_read_data <= read_result;
                    pending_register_read_event.transaction_id <= transaction_id;
                    pending_register_read_event.region <= decoded_region;
                    pending_register_read_event.region_offset <=
                        sst1_region_offset(host_req.addr);
                    pending_register_read_event.wrap <= decoded_wrap;
                    pending_register_read_event.chip_select <= decoded_chip_select;
                    pending_register_read_event.register_offset <= decoded_register;
                    pending_register_read_event.data <= 32'd0;
                    pending_register_read_event.be <= host_req.be;
                    pending_register_read_event.write <= 1'b0;
                    pending_register_read_event.accepted <= 1'b1;
                end else if (!host_req.write && decoded_region == SST1_REGION_LFB) begin
                    lfb_read_pending <= 1'b1;
                end else begin
                    host_rsp_valid <= 1'b1;
                    host_rsp.rdata <= read_result;
                    host_rsp.error <= 1'b0;
                end
                if (host_req.write || !register_region) begin
                    debug_host_event_valid <= 1'b1;
                    debug_host_event.transaction_id <= transaction_id;
                    debug_host_event.region <= decoded_region;
                    debug_host_event.region_offset <= sst1_region_offset(host_req.addr);
                    debug_host_event.wrap <= decoded_wrap;
                    debug_host_event.chip_select <= decoded_chip_select;
                    debug_host_event.register_offset <= decoded_register;
                    debug_host_event.data <= host_req.write ? host_req.wdata : read_result;
                    debug_host_event.be <= host_req.be;
                    debug_host_event.write <= host_req.write;
                    debug_host_event.accepted <= 1'b1;
                end
                transaction_id <= transaction_id + 1'b1;
            end

            // dacData is a command port.  A read command captures the selected
            // external DAC byte; software obtains it through the fbiInit2 remap
            // above.  Model the ICS5342 address/data ports used by DOS Glide.
            if (direct_write_valid && decoded_register == ZSST1_REG_DACDATA) begin
                if (host_req.wdata[11]) begin
                    if (host_req.wdata[10:8] == 3'd5)
                        dac_read_data <= dac_pll_register[dac_read_address];
                    else
                        dac_read_data <= 8'd0;
                end else begin
                    case (host_req.wdata[10:8])
                        3'd4: dac_write_address <= host_req.wdata[3:0];
                        3'd5: dac_pll_register[dac_write_address] <=
                                  host_req.wdata[7:0];
                        3'd7: dac_read_address <= host_req.wdata[3:0];
                        default: begin end
                    endcase
                end
            end

            if (lfb_read_rsp_valid && lfb_read_rsp_ready) begin
                host_rsp_valid <= 1'b1;
                host_rsp.rdata <= lfb_read_rsp_data;
                host_rsp.error <= lfb_read_rsp_error;
                lfb_read_pending <= 1'b0;
            end

            if (render_capture) begin
                render_cmd_valid <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    property p_response_stable;
        @(posedge clk) disable iff (!reset_n)
            host_rsp_valid && !host_rsp_ready |=> host_rsp_valid && $stable(host_rsp);
    endproperty
    assert property (p_response_stable);

    property p_command_stable;
        @(posedge clk) disable iff (!reset_n)
            render_cmd_valid && !render_cmd_ready |=> render_cmd_valid && $stable(render_cmd);
    endproperty
    assert property (p_command_stable);
`endif

    logic unused;
    assign unused = reg_read_initialized ^ float_overflow ^ float_invalid;

endmodule
