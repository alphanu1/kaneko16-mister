// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// OKI M6295 sample-ROM banking.
//
// The chip addresses 256 KB. The board gives it a larger region through a
// bank register, and MAME sets that up with
//
//     common_oki_bank_install(0, 0x20000, 0x20000)
//
// which means: the low 128 KB of the chip's window is the low 128 KB of the
// region, fixed; the high 128 KB is a window onto region offset
// 0x20000 * (bank + 1).
//
// THE ALIAS AT THE TOP IS NOT A ROUNDING ERROR
//
// MAME computes max_bank = (length - fixedsize) / bankedsize and then fills
// every entry from max_bank up to length/bankedsize with the LAST banked
// block:
//
//     int i = max_bank;
//     while (i < length / bankedsize)
//         configure_entry(i++, &sample[length - bankedsize]);
//
// For a 1 MB region that is max_bank = 7, so banks 0-6 map normally and bank 7
// repeats bank 6. The register is three bits wide (MAME masks the port write
// with 7), so bank 7 is reachable and games do select it.
//
// MAX_BANK IS PER GAME — HARD RULE 9
//
// It follows from the region length, and the region length differs across the
// driver, so it is a parameter and the game table sets it:
//
//     explbrkr   ROM_REGION 0x100000   max_bank 7   bank 7 aliases 6
//     wingforc   ROM_REGION 0x080000   max_bank 3   banks 4-7 alias 3
//     mgcrystl   ROM_REGION 0x040000   max_bank 1   banks 2-7 alias 1
//     blazeonj   no oki1 region at all — that board is Z80 + YM2151
//
// Wiring the 1 MB answer in as a constant puts six wrong banks on Magical
// Crystals, which plays the wrong sample rather than failing.
`timescale 1ns/1ps
`default_nettype none

module kaneko_oki_bank #(
    // (region length - 0x20000) / 0x20000, i.e. MAME's max_bank.
    parameter int unsigned MAX_BANK = 7
) (
    input  wire [17:0] chip_addr,   // what jt6295 asks for
    input  wire [2:0]  bank,        // YM2149 chip 0 port B, masked to 3 bits
    output wire [23:0] region_addr  // byte offset within the oki1 region
);
    // Banks at or above max_bank all resolve to the last banked block.
    wire [2:0] max_b = 3'(MAX_BANK);
    wire [2:0] bank_c = (bank >= max_b) ? (max_b - 3'd1) : bank;

    assign region_addr = chip_addr[17]
        ? (24'h20000 + ({21'd0, bank_c} << 17) + {7'd0, chip_addr[16:0]})
        : {6'd0, chip_addr};
endmodule
