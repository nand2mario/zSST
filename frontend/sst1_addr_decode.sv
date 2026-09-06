// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module sst1_addr_decode (
    input  logic [23:0]                   address,
    input  logic                          remap_enable,
    output sst1_pkg::sst1_bar_region_t    region,
    output logic [7:0]                    wrap,
    output logic [3:0]                    chip_select,
    output logic [11:0]                   register_address,
    output sst1_regs_pkg::zsst1_reg_access_t register_access,
    output logic                          register_fifo,
    output logic                          register_sync,
    output logic [3:0]                    register_chip_mask,
    output logic                          float_alias,
    output logic [11:0]                   float_target,
    output logic [5:0]                    float_fraction,
    output logic [5:0]                    float_width
);
    import sst1_pkg::*;
    import sst1_regs_pkg::*;

    logic [11:0] ordinary_address;

    always_comb begin
        region = sst1_decode_region(address);
        wrap = address[21:14];
        chip_select = address[13:10];
        ordinary_address = sst1_register_offset(address);
        if (region == SST1_REGION_REG && remap_enable && address[21])
            register_address = zsst1_remap_register(ordinary_address);
        else
            register_address = ordinary_address;
        register_access = zsst1_reg_access(register_address);
        register_fifo = zsst1_reg_fifo(register_address);
        register_sync = zsst1_reg_sync(register_address);
        register_chip_mask = zsst1_reg_chip_mask(register_address);
        float_alias = zsst1_is_float_alias(register_address);
        float_target = zsst1_float_target(register_address);
        float_fraction = zsst1_float_fraction(register_address);
        float_width = zsst1_float_width(register_address);
    end

endmodule
