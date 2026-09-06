// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

// One synchronous read port and one fill-write port. Four instances replicate
// the cache data for TREX's four simultaneous bilinear neighbors; the caller
// includes the associative way in each address.
module sst1_texture_cache_ram #(
    parameter integer ADDRESS_BITS = 8
) (
    input  logic                      clk,
    input  logic                      write_enable,
    input  logic [ADDRESS_BITS-1:0]   write_address,
    input  logic [127:0]              write_data,
    input  logic                      read_enable,
    input  logic [ADDRESS_BITS-1:0]   read_address,
    output logic [127:0]              read_data
);
    (* ram_style = "block" *) logic [127:0] storage [0:(1<<ADDRESS_BITS)-1];

    always_ff @(posedge clk) begin
        if (write_enable)
            storage[write_address] <= write_data;
        if (read_enable)
            read_data <= storage[read_address];
    end
endmodule
