// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The OKI M6295 exactly as Kaneko16.sv wires it: jt6295 fed from SDRAM
// through kaneko_tilerom, with the bank arithmetic in between. jt6295 itself
// is jotego's and is not under test; the integration around it is ours and
// was not covered by anything until the core reached hardware with no sound.
//
// The SDRAM side is modelled rather than instantiated: kaneko_sdram needs a
// real part model and a 100 MHz domain, and none of that bears on the
// question here, which is whether a byte requested ever arrives.
`timescale 1ns/1ps
`default_nettype none

module kaneko_oki_harness #(
    parameter int unsigned SDR_AW = 25,
    // Clocks between sdr_req and sdr_ack. Real latency is ~20 at 96 MHz; the
    // testbench sweeps this to check nothing depends on a particular value.
    parameter int unsigned LATENCY = 20
) (
    input  wire clk,
    input  wire rst,

    // CPU side, as kaneko_bus presents it.
    input  wire        oki_we,
    input  wire [7:0]  oki_din,
    output wire [7:0]  oki_dout,

    input  wire        cen,           // 2 MHz enable from Kaneko16.sv
    input  wire [7:0]  ym0_iob_out,   // bank select, YM2149 chip 0 port B

    output wire signed [13:0] oki_snd,

    // Observation only.
    output wire [17:0] rom_addr,
    output wire        rom_ok,
    output wire [23:0] region_addr,

    // Bank-map probe: drives a second kaneko_oki_bank directly.
    input  wire [17:0] probe_addr,
    input  wire [2:0]  probe_bank,
    output wire [23:0] probe_region,
    output wire        sdr_req,
    output wire [SDR_AW:1] sdr_addr
);
    localparam [SDR_AW:1] OKI_BASE = SDR_AW'(24'h200000 >> 1);

    // The same module Kaneko16.sv instantiates, so the bank map under test is
    // the one that ships rather than a restatement of it.
    kaneko_oki_bank #(.MAX_BANK(7)) u_bank (
        .chip_addr(rom_addr),
        .bank(ym0_iob_out[2:0]),
        .region_addr(region_addr)
    );

    // A second copy driven straight from the testbench, so the bank map can be
    // checked at chosen addresses instead of only wherever jt6295 happens to
    // be reading.
    kaneko_oki_bank #(.MAX_BANK(7)) u_bank_probe (
        .chip_addr(probe_addr),
        .bank(probe_bank),
        .region_addr(probe_region)
    );

    wire [7:0] rom_data;
    wire [0:0] ready;
    wire [0:0] ack;
    wire [63:0] dout;

    assign rom_ok = ready[0];

    kaneko_tilerom #(.NREQ(1), .SDR_AW(SDR_AW)) u_okirom (
        .clk(clk), .rst(rst),
        .req_addr(region_addr),
        .base_addr(OKI_BASE),
        .req_data(rom_data),
        .port_ready(ready),
        .sdr_req(sdr_req), .sdr_addr(sdr_addr),
        .sdr_ack(ack), .sdr_dout(dout)
    );

    // SDRAM stand-in: acknowledges LATENCY clocks after a request, returning
    // eight bytes generated from the word address so the testbench can check
    // the byte that came back is the byte that was asked for.
    logic [$clog2(LATENCY+1)-1:0] cnt;
    logic ack_r;
    logic [63:0] dout_r;
    assign ack = ack_r;
    assign dout = dout_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            cnt <= '0; ack_r <= 1'b0;
        end else begin
            ack_r <= 1'b0;
            if (sdr_req && !ack_r) begin
                if (cnt == LATENCY[$clog2(LATENCY+1)-1:0]) begin
                    // Byte k of the block = (word address + k) & 0xff, so
                    // every byte is distinct within a block and predictable
                    // outside it.
                    for (int k = 0; k < 8; k++)
                        dout_r[8*k +: 8] <= 8'((sdr_addr << 1) + k);
                    ack_r <= 1'b1;
                    cnt   <= '0;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end else begin
                cnt <= '0;
            end
        end
    end

    jt6295 u_oki (
        .rst(rst), .clk(clk), .cen(cen),
        .ss(1'b1),
        .wrn(~oki_we), .din(oki_din), .dout(oki_dout),
        .rom_addr(rom_addr), .rom_data(rom_data), .rom_ok(rom_ok),
        .sound(oki_snd), .sample()
    );
endmodule
