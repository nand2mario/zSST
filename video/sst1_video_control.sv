// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// SST-1-visible video state.  Pixel timing and framebuffer fetching remain
// platform-neutral inputs: the board shell may generate them directly or use
// a scaler, but buffer swaps and the gamma CLUT obey the SST-1 register model.
module sst1_video_control (
    input  logic         clk,
    input  logic         reset_n,

    input  logic         register_write_valid,
    input  logic [11:0]  register_write_address,
    input  logic [31:0]  register_write_data,
    input  logic [3:0]   register_write_be,

    input  logic         swap_valid,
    output logic         swap_ready,
    input  logic [8:0]   swap_data,
    input  logic         v_retrace,

    input  logic [15:0]  scanout_rgb565,
    output logic [23:0]  scanout_rgb888,

    output logic [1:0]   displayed_buffer,
    output logic [2:0]   swaps_pending,
    output logic         swap_event,
    output logic [31:0]  frame_count,
    output logic [31:0]  hsync_register,
    output logic [31:0]  vsync_register,
    output logic [31:0]  backporch_register,
    output logic [31:0]  dimensions_register,
    output logic         video_active
);
    import sst1_regs_pkg::*;

    localparam integer SWAP_DEPTH = 7;
    logic [8:0] swap_fifo [0:SWAP_DEPTH-1];
    logic [2:0] swap_head, swap_tail;
    logic [7:0] retraces_waited;
    logic previous_retrace;
    logic [31:0] fbi_init0, fbi_init1;
    logic [23:0] clut [0:32];
    logic swap_push, swap_pop, retrace_rise, swap_due;
    logic [8:0] active_swap;
    integer index;

    function automatic logic [31:0] merge_bytes(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0] byte_enable
    );
        logic [31:0] result;
        integer lane;
        begin
            result = old_value;
            for (lane = 0; lane < 4; lane = lane + 1)
                if (byte_enable[lane])
                    result[lane*8 +: 8] = new_value[lane*8 +: 8];
            return result;
        end
    endfunction

    function automatic logic [7:0] interpolate(
        input logic [7:0] low,
        input logic [7:0] high,
        input logic [2:0] fraction
    );
        logic [11:0] weighted;
        logic [3:0] inverse;
        begin
            inverse = 4'd8 - {1'b0, fraction};
            weighted = low * inverse + high * fraction;
            return weighted[10:3];
        end
    endfunction

    logic [7:0] red, green, blue;
    logic [5:0] red_index, green_index, blue_index;
    logic [2:0] red_fraction, green_fraction, blue_fraction;
    always_comb begin
        red = {scanout_rgb565[15:11], scanout_rgb565[15:13]};
        green = {scanout_rgb565[10:5], scanout_rgb565[10:9]};
        blue = {scanout_rgb565[4:0], scanout_rgb565[4:2]};
        red_index = {1'b0, red[7:3]};
        green_index = {1'b0, green[7:3]};
        blue_index = {1'b0, blue[7:3]};
        red_fraction = red[2:0];
        green_fraction = green[2:0];
        blue_fraction = blue[2:0];
        scanout_rgb888[23:16] = interpolate(clut[red_index][23:16],
                                            clut[red_index + 1'b1][23:16],
                                            red_fraction);
        scanout_rgb888[15:8] = interpolate(clut[green_index][15:8],
                                           clut[green_index + 1'b1][15:8],
                                           green_fraction);
        scanout_rgb888[7:0] = interpolate(clut[blue_index][7:0],
                                          clut[blue_index + 1'b1][7:0],
                                          blue_fraction);
    end

    assign swap_ready = swaps_pending < 3'd7;
    assign swap_push = swap_valid && swap_ready;
    assign retrace_rise = v_retrace && !previous_retrace;
    assign active_swap = swap_fifo[swap_head];
    assign swap_due = swaps_pending != 0 &&
                      ((!active_swap[0]) ||
                       (retrace_rise && retraces_waited >= active_swap[8:1]));
    assign swap_pop = swap_due;
    // On the reference SST-1 board fbiInit0[0]=1 disconnects VGA pass-through.
    // Keep VGA selected while the SST video unit is reset or blanked.
    assign video_active = fbi_init0[0] && !fbi_init1[8] &&
                          !fbi_init1[12] && dimensions_register[21:0] != 0;

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            displayed_buffer <= 2'd0;
            swaps_pending <= 3'd0;
            swap_head <= 3'd0;
            swap_tail <= 3'd0;
            retraces_waited <= 8'd0;
            previous_retrace <= 1'b0;
            swap_event <= 1'b0;
            frame_count <= 32'd0;
            hsync_register <= 32'd0;
            vsync_register <= 32'd0;
            backporch_register <= 32'd0;
            dimensions_register <= 32'd0;
            fbi_init0 <= 32'd0;
            fbi_init1 <= 32'd0;
            for (index = 0; index < 33; index = index + 1) begin
                clut[index][23:16] <= index == 32 ? 8'hff : {index[4:0], 3'b000};
                clut[index][15:8] <= index == 32 ? 8'hff : {index[4:0], 3'b000};
                clut[index][7:0] <= index == 32 ? 8'hff : {index[4:0], 3'b000};
            end
        end else begin
            previous_retrace <= v_retrace;
            swap_event <= 1'b0;
            if (retrace_rise)
                frame_count <= frame_count + 1'b1;

            if (register_write_valid) begin
                case (register_write_address)
                    ZSST1_REG_FBIINIT0:
                        fbi_init0 <= merge_bytes(fbi_init0,
                                                register_write_data,
                                                register_write_be);
                    ZSST1_REG_HSYNC:
                        hsync_register <= merge_bytes(hsync_register,
                                                      register_write_data,
                                                      register_write_be);
                    ZSST1_REG_VSYNC:
                        vsync_register <= merge_bytes(vsync_register,
                                                      register_write_data,
                                                      register_write_be);
                    ZSST1_REG_BACKPORCH:
                        backporch_register <= merge_bytes(backporch_register,
                                                          register_write_data,
                                                          register_write_be);
                    ZSST1_REG_VIDEODIMENSIONS:
                        dimensions_register <= merge_bytes(dimensions_register,
                                                           register_write_data,
                                                           register_write_be);
                    ZSST1_REG_FBIINIT1:
                        fbi_init1 <= merge_bytes(fbi_init1,
                                                register_write_data,
                                                register_write_be);
                    ZSST1_REG_CLUTDATA: if (!fbi_init1[8] &&
                                             register_write_data[29:24] <= 32)
                        clut[register_write_data[29:24]] <=
                            register_write_data[23:0];
                    default: ;
                endcase
            end

            if (swap_push) begin
                swap_fifo[swap_tail] <= swap_data;
                swap_tail <= swap_tail == 3'd6 ? 3'd0 : swap_tail + 1'b1;
            end

            if (swap_pop) begin
                displayed_buffer <= {1'b0, ~displayed_buffer[0]};
                swap_head <= swap_head == 3'd6 ? 3'd0 : swap_head + 1'b1;
                retraces_waited <= 8'd0;
                swap_event <= 1'b1;
            end else if (retrace_rise && swaps_pending != 0 && active_swap[0]) begin
                retraces_waited <= retraces_waited + 1'b1;
            end

            case ({swap_push, swap_pop})
                2'b10: swaps_pending <= swaps_pending + 1'b1;
                2'b01: swaps_pending <= swaps_pending - 1'b1;
                default: ;
            endcase
        end
    end
endmodule
