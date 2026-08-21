// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Sixteen 16-bit registers with byte enables, written by the 68000 and read
// back both by it and by the video side.
//
// Used for both VIEW2 chips and the VU-002. Until now these windows decoded but
// stored nothing: kaneko_bus raised a write strobe that went nowhere and read
// back a hardwired zero. That cost nothing while the video path was not driven
// from them — every register access explbrkr makes in its first 300,000 bus
// cycles is a write, so the traces still matched MAME exactly — and it costs
// everything the moment the pixel path needs the scroll values.
//
// WHAT THE VIEW2 REGISTERS MEAN (kaneko_tmap.cpp:214-227)
//
//     reg 0   layer 1 scroll X          byte 0x00
//     reg 1   layer 1 scroll Y, >> 6    byte 0x02
//     reg 2   layer 0 scroll X          byte 0x04
//     reg 3   layer 0 scroll Y, >> 6    byte 0x06
//     reg 4   layer control             byte 0x08
//
// Note the layer numbering runs opposite to the byte order: the FIRST pair of
// registers belongs to layer 1. The scroll Y values are shifted down by six;
// the X values are not, because line scroll is added before the shift.
//
// Layer control bits (reg 4), from kaneko_tmap.cpp prepare_common():
//
//     12  layer 0 DISABLE       enable(BIT(~layers_flip_0, 12))
//      4  layer 1 DISABLE       enable(BIT(~layers_flip_0,  4))
//     11  layer 0 line scroll   selects m_vscroll[0] (the 0x3000 window)
//      3  layer 1 line scroll   selects m_vscroll[1] (the 0x2000 window)
//      9  flip X                BOTH layers
//      8  flip Y                BOTH layers
//
// Two traps here, and an earlier version of this comment fell into both. The
// disable bits are 12 and 4, not 15 and 4 — bit 15 does nothing. And flip is
// shared by the two layers at bits 8/9; there is no second pair at bits 0/1.
//
// Note also that the numbering keeps running opposite to the byte order: bit 12
// belongs to layer 0 while the register pair at byte 0x00 belongs to layer 1.
module kaneko_regs16 (
    input  wire        clk,

    input  wire        we,
    input  wire [3:0]  addr,
    input  wire [15:0] din,
    input  wire        uds,       // upper byte enable
    input  wire        lds,       // lower byte enable

    input  wire [3:0]  rd_addr,
    output wire [15:0] rd_q,

    // The whole bank, for the video side to decode without a read port.
    output wire [255:0] regs_flat
);

    logic [15:0] regs [0:15];

    // Byte enables: the 68000 writes single bytes, and a register bank that
    // ignores that turns `move.b` into a word write of a half-formed value.
    always_ff @(posedge clk) begin
        if (we) begin
            if (uds) regs[addr][15:8] <= din[15:8];
            if (lds) regs[addr][7:0]  <= din[7:0];
        end
    end

    assign rd_q = regs[rd_addr];

    genvar g;
    generate
        for (g = 0; g < 16; g = g + 1) begin : g_flat
            assign regs_flat[g*16 +: 16] = regs[g];
        end
    endgenerate

endmodule
