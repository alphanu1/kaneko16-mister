// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Flattens kaneko_tilerom's packed request ports into individual signals, so
// the testbench can drive one layer at a time without unpacking a WData array.
`timescale 1ns/1ps
`default_nettype none

module kaneko_tilerom_harness #(
    parameter int unsigned SDR_AW = 25
) (
    input  wire clk,
    input  wire rst,

    input  wire [23:0] a0, a1, a2, a3,
    input  wire [SDR_AW:1] base0, base1, base2, base3,
    output wire [7:0]  d0, d1, d2, d3,
    output wire        ready,

    output wire            sdr_req,
    output wire [SDR_AW:1] sdr_addr,
    input  wire            sdr_ack,
    input  wire [63:0]     sdr_dout
);
    kaneko_tilerom #(.NREQ(4), .SDR_AW(SDR_AW)) u_dut (
        .clk(clk), .rst(rst),
        .req_addr({a3, a2, a1, a0}),
        .base_addr({base3, base2, base1, base0}),
        .req_data({d3, d2, d1, d0}),
        .ready(ready),
        .sdr_req(sdr_req), .sdr_addr(sdr_addr),
        .sdr_ack(sdr_ack), .sdr_dout(sdr_dout)
    );
endmodule
