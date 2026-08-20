// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The memories the CPU writes and the video path reads.
//
// All four are simple dual-port: the CPU side writes (and reads back), the
// video side reads. That is what an M10K gives natively, and it is why these
// live together rather than being scattered through the video modules — the
// CPU must reach every one of them through a single bus, and the video side
// must read them without contending for that bus.
//
//   VIEW2 window   0x4000 bytes each: vram_1 at 0x0000, vram_0 at 0x1000,
//                  scroll_1 at 0x2000, scroll_0 at 0x3000. One 8K x 16 block
//                  per chip holds the whole window, so the CPU's window
//                  address IS the memory address and no decode is needed here.
//   sprite RAM     0x2000 bytes, 4K x 16
//   palette        0x1000 bytes, 2K x 16, xGRB_555

`timescale 1ns/1ps
`default_nettype none

module kaneko_vmem (
    input  wire        clk,

    // ---- CPU side
    input  wire [12:0] cpu_addr,       // word address within the selected space
    input  wire [15:0] cpu_din,
    input  wire        we_vram0, we_vram1, we_spr, we_pal,
    input  wire        uds, lds,       // byte enables, active high
    output logic [15:0] q_vram0, q_vram1, q_spr, q_pal,

    // ---- video side, read only
    input  wire [12:0] v0_addr,
    output logic [15:0] v0_q,
    input  wire [12:0] v1_addr,
    output logic [15:0] v1_q,
    input  wire [11:0] spr_addr,
    output logic [15:0] spr_q,
    input  wire [10:0] pal_addr,
    output logic [15:0] pal_q
);
    // 8K x 16 per VIEW2 window covers VRAM and line scroll for both its layers.
    logic [15:0] view2_0 [0:8191];
    logic [15:0] view2_1 [0:8191];
    logic [15:0] sprram  [0:4095];
    logic [15:0] palram  [0:2047];

    // Byte enables matter: the 68000 writes single bytes, and a word-wide write
    // would clobber the neighbouring byte. The boot code does exactly this —
    // its first store is `move.b #$00, $900009`.
    always_ff @(posedge clk) begin
        if (we_vram0) begin
            if (uds) view2_0[cpu_addr][15:8] <= cpu_din[15:8];
            if (lds) view2_0[cpu_addr][7:0]  <= cpu_din[7:0];
        end
        if (we_vram1) begin
            if (uds) view2_1[cpu_addr][15:8] <= cpu_din[15:8];
            if (lds) view2_1[cpu_addr][7:0]  <= cpu_din[7:0];
        end
        if (we_spr) begin
            if (uds) sprram[cpu_addr[11:0]][15:8] <= cpu_din[15:8];
            if (lds) sprram[cpu_addr[11:0]][7:0]  <= cpu_din[7:0];
        end
        if (we_pal) begin
            if (uds) palram[cpu_addr[10:0]][15:8] <= cpu_din[15:8];
            if (lds) palram[cpu_addr[10:0]][7:0]  <= cpu_din[7:0];
        end

        q_vram0 <= view2_0[cpu_addr];
        q_vram1 <= view2_1[cpu_addr];
        q_spr   <= sprram[cpu_addr[11:0]];
        q_pal   <= palram[cpu_addr[10:0]];

        v0_q    <= view2_0[v0_addr];
        v1_q    <= view2_1[v1_addr];
        spr_q   <= sprram[spr_addr];
        pal_q   <= palram[pal_addr];
    end
endmodule

`default_nettype wire
