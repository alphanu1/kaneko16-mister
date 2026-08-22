// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The Blaze On board's Z80 program ROM, held in block RAM and filled by
// SNOOPING THE LOADER rather than read back out of SDRAM.
//
// WHY NOT AN SDRAM PORT
//
// kaneko_z80snd's ROM contract is "data one clock after the address", which is
// what a Z80 fetch wants and what SDRAM cannot give. Every other consumer in
// this core either bursts (the tile and sprite fetchers, which have a whole
// scanline of slack) or stalls its CPU (the 68000, through DTACK). The Z80 has
// no wait state wired and would need one invented, plus a ninth SDRAM port and
// a cache, to serve 48 KB that fits in 39 M10K blocks.
//
// So it is copied once, while the ROM is downloading. The tap is the loader's
// SDRAM write port, which is already the final address and the final data, so
// nothing here has to know what the MRA emitted or in what order.
//
// BYTE ORDER, DERIVED AND NOT GUESSED
//
// The loader stores stream byte N at SDRAM byte N and does not swap. The 68000
// path then reads {W[7:0], W[15:8]} to get a big-endian word, and a big-endian
// word at even address A is {byte[A], byte[A+1]}. So:
//
//     byte[A]   (even) = W[7:0]
//     byte[A+1] (odd)  = W[15:8]
//
// which is what the byte select below uses. Getting this backwards yields a
// ROM that is the right size, checksums wrong, and hangs the Z80 in a way that
// looks like a bus fault.
//
// TWO CLOCKS, ON PURPOSE
//
// The loader runs on clk_sdram and the Z80 on clk_sys. Both are 48 MHz from
// the same PLL and this design already crosses between them freely, but a
// simple dual-port RAM with a clock per port costs nothing in an M10K and
// removes the question entirely. Nothing is written after the download ends
// and nothing is read before it, so the two ports never contend.
//
// SIZE
//
// 0x0000-0xBFFF is ROM on this board; MAME maps 0x8000-0xBFFF straight through
// with a note wondering whether it is supposed to be banked. Nothing is known
// to bank it, so 48 KB is stored and the region above is left to the decode in
// kaneko_z80snd. Wing Force's whole audiocpu region is only 64 KB, so 48 KB is
// all there is to take there either.
`timescale 1ns/1ps
`default_nettype none

module kaneko_z80rom #(
    parameter int SDR_AW = 25,
    parameter int BYTES  = 'hC000            // 48 KB
) (
    // ---- loader snoop. Word addresses, matching the SDRAM write port.
    input  wire                ld_clk,
    input  wire                ld_wr,
    input  wire [SDR_AW-1:0]   ld_addr,
    input  wire [15:0]         ld_din,
    input  wire [SDR_AW-1:0]   base,          // word address of audiocpu

    // ---- Z80 side, one clock of latency
    input  wire                clk,
    input  wire [15:0]         rom_addr,
    output logic [7:0]         rom_data
);
    localparam int WORDS = BYTES / 2;
    localparam int AW    = $clog2(WORDS);

    // The window test is done on the word address because that is what the
    // loader carries. An address below `base` must not wrap into the window,
    // so this is a subtraction guarded by a comparison, not a masked compare.
    wire [SDR_AW-1:0] off   = ld_addr - base;
    wire              in_wr = ld_wr && (ld_addr >= base) && (off < SDR_AW'(WORDS));

    // Plain 1-D array, plain address, unconditional read, no reset — the shape
    // that infers M10K. See the inference notes in docs/findings.md; an array
    // of arrays or a concatenated index silently becomes registers instead.
    logic [15:0] mem [0:WORDS-1];
    logic [15:0] q;
    logic        odd;

    always_ff @(posedge ld_clk)
        if (in_wr) mem[off[AW-1:0]] <= ld_din;

    always_ff @(posedge clk) begin
        q   <= mem[rom_addr[AW:1]];
        odd <= rom_addr[0];
    end

    assign rom_data = odd ? q[15:8] : q[7:0];
endmodule

`default_nettype wire
