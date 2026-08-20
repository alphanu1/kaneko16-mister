// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// VIEW2-CHIP tilemap address and attribute engine.
//
// Behaviour transcribed from MAME's kaneko_view2_tilemap_device
// (src/mame/kaneko/kaneko_tmap.cpp, BSD-3-Clause, Luca Elia and David
// Haywood) together with the tilemap scroll semantics in src/emu/tilemap.cpp
// and the tile layout gfx_8x8x4_row_2x2_group_packed_lsb in
// src/emu/video/generic.cpp. Retain that attribution on anything lifted.
//
// One VIEW2 chip drives two layers. MAME names them FG and BG in its register
// documentation but wires them the other way round in the device, which is a
// trap worth stating once:
//
//   tmap[0] is the "BG" of the register map: scroll at 0x04/0x06, VRAM 0x1000
//   tmap[1] is the "FG" of the register map: scroll at 0x00/0x02, VRAM 0x0000
//
// So layer 1's VRAM sits at the LOW half of the chip's VRAM window. See
// vram_map() in kaneko_tmap.cpp.
//
// Coordinate pipeline, per layer, per pixel:
//
//   map_y = (screen_y + dy + (scroll_y >> 6))                     mod 512
//   map_x = (screen_x + dx + ((scroll_x + linescroll[map_y]) >> 6)) mod 512
//
// Three details in that pair are easy to get wrong and each is load-bearing:
//
//  1. **linescroll is indexed by map_y, not screen_y.** MAME's rowscroll index
//     is a *tilemap* row: draw_instance() places tilemap row r at screen line
//     r + ypos, and the scroll for row r is rowscroll[r]. Indexing by the raw
//     scanline is only equivalent while scroll_y is zero.
//  2. **The scroll add happens before the >> 6**, not after. Both the register
//     and the line-scroll word are 10.6 fixed point and they are summed at full
//     precision, then truncated together.
//  3. **dx differs by 2 between the layers.** MAME sets scrolldx to -dx for
//     tmap[0] and -(dx+2) for tmap[1]; the caller passes the already-adjusted
//     value here.

`default_nettype none

// ---------------------------------------------------------------- vertical
// Produces the tilemap row for a screen line. Must be evaluated before the
// horizontal stage, because its result indexes the line-scroll RAM.
module kaneko_tmap_vscroll (
    input  wire  [8:0]         screen_y,
    input  wire signed [10:0]  dy,        // kaneko set_offset dy
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire  [15:0]        scroll_y,  // 10.6 fixed point; [5:0] is the
                                          // fraction and is discarded by >> 6
    /* verilator lint_on UNUSEDSIGNAL */
    output wire  [8:0]         map_y
);
    // 14 bits so the three-term sum cannot itself overflow; only the final
    // truncation to 9 bits is meant to lose information, and that truncation
    // IS the mod 512 (two's complement wrap gives the same answer as MAME's
    // clamp-into-range in effective_colscroll for every reachable input).
    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [13:0] sum;
    /* verilator lint_on UNUSEDSIGNAL */
    assign sum = $signed({5'd0, screen_y}) + $signed({{3{dy[10]}}, dy})
               + $signed({4'd0, scroll_y[15:6]});
    assign map_y = sum[8:0];
endmodule

// -------------------------------------------------------------- horizontal
module kaneko_tmap_hscroll (
    input  wire  [8:0]         screen_x,
    input  wire signed [10:0]  dx,            // already +2 for layer 1
    input  wire  [15:0]        scroll_x,      // 10.6 fixed point
    input  wire  [15:0]        linescroll,    // 10.6, from scroll RAM at map_y
    input  wire                linescroll_en, // layerctl bit 11 (L0) / 3 (L1)
    output wire  [8:0]         map_x
);
    // Full-precision sum, then truncate. Wraps at 16 bits exactly as MAME's
    // u16 addition does.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [15:0] scroll_sum;    // low 6 bits are the fraction, discarded by >> 6
    wire signed [13:0] sum;    // see the width note in kaneko_tmap_vscroll
    /* verilator lint_on UNUSEDSIGNAL */
    assign scroll_sum = scroll_x + (linescroll_en ? linescroll : 16'd0);
    assign sum = $signed({5'd0, screen_x}) + $signed({{3{dx[10]}}, dx})
               + $signed({4'd0, scroll_sum[15:6]});
    assign map_x = sum[8:0];
endmodule

// ------------------------------------------------------------ tile lookup
// 32 x 32 tiles of 16 x 16 pixels = 512 x 512. Two words per tile entry:
// word 0 attribute, word 1 code.
module kaneko_tmap_tileaddr (
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [8:0]   map_x,   // [3:0] is the pixel within the tile
    input  wire [8:0]   map_y,   // and is consumed by kaneko_tmap_pixaddr
    /* verilator lint_on UNUSEDSIGNAL */
    output wire [10:0]  vram_attr_addr,  // word address within the layer
    output wire [10:0]  vram_code_addr
);
    wire [9:0] tile_index = {map_y[8:4], map_x[8:4]};   // row-major, 32 wide
    assign vram_attr_addr = {tile_index, 1'b0};
    assign vram_code_addr = {tile_index, 1'b1};
endmodule

// --------------------------------------------------------- attribute decode
//
// Tile attribute word, from kaneko_tmap.cpp:
//
//   fedc b--- ---- ----   unused
//   ---- -a9- ---- ----   High Priority (vs Sprites)
//   ---- ---8 ---- ----   High Priority (vs Tiles)
//   ---- ---- 7654 32--   Colour
//   ---- ---- ---- --1-   Flip X
//   ---- ---- ---- ---0   Flip Y
//
// The device reads the priority as (attr >> 8) & 7, i.e. bits 10:8 together.
// Note the flip assignment: MAME writes TILE_FLIPXY(attr & 3), and TILE_FLIPXY
// SWAPS the two bits (tilemap.h: ((xy & 2) >> 1) | ((xy & 1) << 1)). So attr
// bit 1 is Flip X and bit 0 is Flip Y, matching the comment above and NOT the
// order a naive reading of the macro call suggests.
module kaneko_tmap_attr (
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [15:0]  attr,   // [15:11] documented "unused?" in MAME and
                                // never read by the device
    /* verilator lint_on UNUSEDSIGNAL */
    output wire [5:0]   colour,
    output wire [2:0]   prio,
    output wire         flip_x,
    output wire         flip_y
);
    assign colour = attr[7:2];
    assign prio   = attr[10:8];
    assign flip_x = attr[1];
    assign flip_y = attr[0];
endmodule

// ------------------------------------------------------------- pixel address
//
// gfx_8x8x4_row_2x2_group_packed_lsb: a 16x16 tile is four 8x8 sub-tiles of
// 4bpp, 32 bytes each, laid out
//
//     byte  0  top-left       byte 32  top-right
//     byte 64  bottom-left    byte 96  bottom-right
//
// Within a sub-tile, each row is 4 bytes; within a byte the LOW nibble is the
// LEFT pixel of the pair (that is what "packed_lsb" names). 128 bytes per tile.
module kaneko_tmap_pixaddr (
    input  wire [15:0]  code,
    input  wire [3:0]   fine_x,     // map_x[3:0]
    input  wire [3:0]   fine_y,     // map_y[3:0]
    input  wire         flip_x,
    input  wire         flip_y,
    output wire [23:0]  rom_addr,   // byte address into tile ROM
    output wire         nibble_hi   // 0 = low nibble, 1 = high nibble
);
    wire [3:0] px = flip_x ? ~fine_x : fine_x;
    wire [3:0] py = flip_y ? ~fine_y : fine_y;

    // code * 128 + sub-tile + row*4 + column
    wire [23:0] tile_base = {1'b0, code, 7'd0};
    wire [6:0]  in_tile   = {py[3], px[3], py[2:0], px[2:1]};

    assign rom_addr  = tile_base | {17'd0, in_tile};
    assign nibble_hi = px[0];
endmodule

// ------------------------------------------------------------------- layer
// Composition of the above. Split into two combinational phases because the
// line-scroll RAM read sits between them: drive screen_y, use map_y to address
// the scroll RAM, present the word back as linescroll.
module kaneko_tmap_layer (
    input  wire [8:0]          screen_x,
    input  wire [8:0]          screen_y,
    input  wire signed [10:0]  dx,
    input  wire signed [10:0]  dy,
    input  wire [15:0]         scroll_x,
    input  wire [15:0]         scroll_y,
    input  wire [15:0]         linescroll,
    input  wire                linescroll_en,
    input  wire [15:0]         attr,          // VRAM word at vram_attr_addr
    input  wire [15:0]         code,          // VRAM word at vram_code_addr

    output wire [8:0]          map_x,
    output wire [8:0]          map_y,
    output wire [10:0]         vram_attr_addr,
    output wire [10:0]         vram_code_addr,
    output wire [23:0]         rom_addr,
    output wire                nibble_hi,
    output wire [5:0]          colour,
    output wire [2:0]          prio
);
    kaneko_tmap_vscroll u_v (
        .screen_y(screen_y), .dy(dy), .scroll_y(scroll_y), .map_y(map_y));

    kaneko_tmap_hscroll u_h (
        .screen_x(screen_x), .dx(dx), .scroll_x(scroll_x),
        .linescroll(linescroll), .linescroll_en(linescroll_en), .map_x(map_x));

    kaneko_tmap_tileaddr u_t (
        .map_x(map_x), .map_y(map_y),
        .vram_attr_addr(vram_attr_addr), .vram_code_addr(vram_code_addr));

    wire flip_x, flip_y;
    kaneko_tmap_attr u_a (
        .attr(attr), .colour(colour), .prio(prio),
        .flip_x(flip_x), .flip_y(flip_y));

    kaneko_tmap_pixaddr u_p (
        .code(code), .fine_x(map_x[3:0]), .fine_y(map_y[3:0]),
        .flip_x(flip_x), .flip_y(flip_y),
        .rom_addr(rom_addr), .nibble_hi(nibble_hi));
endmodule

`default_nettype wire
