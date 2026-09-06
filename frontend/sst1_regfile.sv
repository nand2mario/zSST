// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module sst1_regfile (
    input  logic                          clk,
    input  logic                          reset_n,
    input  logic                          write_valid,
    input  logic [11:0]                   write_address,
    input  logic [31:0]                   write_data,
    input  logic                          write_extended_valid,
    input  logic [63:0]                   write_extended_data,
    input  logic [3:0]                    write_byte_enable,
    input  logic                          read_enable,
    input  logic [11:0]                   read_address,
    output logic [31:0]                   read_data,
    output logic                          read_initialized,
    output logic                          remap_enable,
    output sst1_pkg::sst1_render_state_t  render_state
);
    import sst1_regs_pkg::*;
    import sst1_pkg::*;

    // Render consumers need constant-address taps from the SST state, while
    // software needs a dynamically addressed readback window.  Combining
    // those jobs in one 256-word flip-flop array built a very large 32-bit
    // asynchronous read mux.  Keep the actively interpreted state explicit
    // and mirror all writes into one synchronous byte-write BRAM instead.
    (* ram_style = "block" *)
    logic [31:0] readback [0:255];
    logic [255:0] initialized;
    integer byte_index;
    integer state_index;

    function automatic logic [31:0] merge_bytes(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0] byte_enable
    );
        logic [31:0] result;
        integer index;
        begin
            result = old_value;
            for (index = 0; index < 4; index = index + 1)
                if (byte_enable[index])
                    result[index*8 +: 8] = new_value[index*8 +: 8];
            return result;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!reset_n) begin
            initialized <= '0;
            read_data <= '0;
            read_initialized <= 1'b0;
            remap_enable <= 1'b0;
            render_state <= '0;
        end else begin
            if (read_enable) begin
                read_initialized <= initialized[read_address[9:2]];
                read_data <= initialized[read_address[9:2]] ?
                             readback[read_address[9:2]] : 32'd0;
            end

            if (write_valid) begin
                for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                    if (write_byte_enable[byte_index])
                        readback[write_address[9:2]][byte_index*8 +: 8] <=
                            write_data[byte_index*8 +: 8];
                initialized[write_address[9:2]] <= 1'b1;

                for (state_index = 0; state_index < 30; state_index = state_index + 1)
                    if (write_address == 12'h008 + 12'(state_index * 4)) begin
                        render_state.triangle_parameters[state_index] <=
                            merge_bytes(render_state.triangle_parameters[state_index],
                                        write_data, write_byte_enable);
                        if (stw_slot(state_index) >= 0) begin
                            render_state.stw_extended[stw_slot(state_index)] <=
                                write_extended_valid;
                            render_state.stw_high[stw_slot(state_index)] <=
                                write_extended_data[63:32];
                        end
                    end

                for (state_index = 0; state_index < 32; state_index = state_index + 1)
                    if (write_address == 12'(ZSST1_REG_FOGTABLE00 + state_index * 4))
                        render_state.fog_table[state_index] <=
                            merge_bytes(render_state.fog_table[state_index],
                                        write_data, write_byte_enable);

                for (state_index = 0; state_index < 9; state_index = state_index + 1)
                    if (write_address == 12'h300 + 12'(state_index * 4))
                        render_state.tmu_state[state_index] <=
                            merge_bytes(render_state.tmu_state[state_index],
                                        write_data, write_byte_enable);

                case (write_address)
                    ZSST1_REG_FBZCOLORPATH:
                        render_state.fbz_color_path <= merge_bytes(
                            render_state.fbz_color_path, write_data,
                            write_byte_enable);
                    ZSST1_REG_FOGMODE:
                        render_state.fog_mode <= merge_bytes(
                            render_state.fog_mode, write_data,
                            write_byte_enable);
                    ZSST1_REG_ALPHAMODE:
                        render_state.alpha_mode <= merge_bytes(
                            render_state.alpha_mode, write_data,
                            write_byte_enable);
                    ZSST1_REG_FBZMODE:
                        render_state.fbz_mode <= merge_bytes(
                            render_state.fbz_mode, write_data,
                            write_byte_enable);
                    ZSST1_REG_LFBMODE:
                        render_state.lfb_mode <= merge_bytes(
                            render_state.lfb_mode, write_data,
                            write_byte_enable);
                    ZSST1_REG_CLIPLEFTRIGHT:
                        render_state.clip_left_right <= merge_bytes(
                            render_state.clip_left_right, write_data,
                            write_byte_enable);
                    ZSST1_REG_CLIPLOWYHIGHY:
                        render_state.clip_low_y_high_y <= merge_bytes(
                            render_state.clip_low_y_high_y, write_data,
                            write_byte_enable);
                    ZSST1_REG_FOGCOLOR:
                        render_state.fog_color <= merge_bytes(
                            render_state.fog_color, write_data,
                            write_byte_enable);
                    ZSST1_REG_ZACOLOR:
                        render_state.za_color <= merge_bytes(
                            render_state.za_color, write_data,
                            write_byte_enable);
                    ZSST1_REG_CHROMAKEY:
                        render_state.chroma_key <= merge_bytes(
                            render_state.chroma_key, write_data,
                            write_byte_enable);
                    ZSST1_REG_STIPPLE: begin
                        render_state.stipple <= merge_bytes(
                            render_state.stipple, write_data,
                            write_byte_enable);
                        render_state.stipple_generation <=
                            render_state.stipple_generation + 1'b1;
                    end
                    ZSST1_REG_COLOR0:
                        render_state.color0 <= merge_bytes(
                            render_state.color0, write_data,
                            write_byte_enable);
                    ZSST1_REG_COLOR1:
                        render_state.color1 <= merge_bytes(
                            render_state.color1, write_data,
                            write_byte_enable);
                    ZSST1_REG_FBIINIT1:
                        render_state.fbi_init1 <= merge_bytes(
                            render_state.fbi_init1, write_data,
                            write_byte_enable);
                    ZSST1_REG_FBIINIT2:
                        render_state.fbi_init2 <= merge_bytes(
                            render_state.fbi_init2, write_data,
                            write_byte_enable);
                    ZSST1_REG_FBIINIT3:
                        if (write_byte_enable[0])
                            remap_enable <= write_data[0];
                    ZSST1_REG_VIDEODIMENSIONS:
                        render_state.video_dimensions <= merge_bytes(
                            render_state.video_dimensions, write_data,
                            write_byte_enable);
                    default: begin end
                endcase
            end
        end
    end

endmodule
