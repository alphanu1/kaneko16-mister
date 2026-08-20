// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Layer/sprite priority mixer for one pixel.
//
// Behaviour transcribed from MAME: kaneko16_v.cpp screen_update_common (the
// category passes), kaneko_tmap.cpp render_tilemap / render_tilemap_alt (which
// priority value each chip writes), and kaneko_spr.cpp copybitmap_common (the
// sprite comparison). BSD-3-Clause, Luca Elia and David Haywood.
//
// MAME draws in eight category passes, and within each pass in a fixed layer
// order:
//
//   for category 0..7:
//     view2[0] layer0, view2[0] layer1     -> priority bitmap := category
//     view2[1] layer0, view2[1] layer1     -> priority bitmap := category
//                                             or 0 when m_view2_2_pri is clear
//
// A later draw overwrites an earlier one, so for a single pixel the winner is
// simply the solid layer with the highest category, and among equal categories
// the highest layer index. That collapses the eight passes into one comparison
// and is why this module is combinational rather than a state machine.
//
// The priority bitmap value left behind is the WINNER's, not the highest
// category present — the last write is what stands. Then:
//
//   sprite wins  <=>  spr_pri[sprite_prio] > priority_bitmap
//
// with spr_pri supplied per game. Both halves are per-game and neither may be
// assumed: mgcrystl runs {2,3,5,7} with m_view2_2_pri clear, explbrkr {8,8,8,8}
// with it set. See hard rule 9.

`default_nettype none

module kaneko_mixer (
    // Four tile layers, in MAME's draw order: chip0 L0, chip0 L1, chip1 L0,
    // chip1 L1. Layers 2 and 3 are the second VIEW2 chip.
    // Packed rather than unpacked arrays, so the module works unchanged both
    // as a simulation top and through the harness wrapper. (Note: a comment
    // line must not begin with the word "verilator" — it is parsed as a
    // pragma, which is how this one first failed to lint.)
    input  wire [3:0]        layer_solid,     // pixel is non-transparent
    input  wire [11:0]       layer_cat_f,     // 4 x attr[10:8]
    input  wire [23:0]       layer_colour_f,  // 4 x attr[7:2]
    input  wire [15:0]       layer_pix_f,     // 4 x 4bpp pixel from tile ROM

    // Sprite pixel, already resolved and composited into the sprite bitmap.
    input  wire [13:0]       spr_pix,         // 0 = nothing here
    input  wire [1:0]        spr_prio,

    // Per-game configuration.
    input  wire              view2_2_pri,     // m_view2_2_pri
    input  wire [15:0]       spr_pri_f,       // 4 x set_priorities() value
    input  wire [10:0]       tile_colbase,    // gfx colour base for tiles
    input  wire [10:0]       spr_colbase,     // and for sprites

    output wire [10:0]       pen,             // final palette index
    output wire [2:0]        prio_out,        // priority bitmap value left
    output wire              sprite_won
);
    function automatic [2:0] cat_of(input [1:0] i);  cat_of    = layer_cat_f[i*3 +: 3];    endfunction
    function automatic [5:0] col_of(input [1:0] i);  col_of    = layer_colour_f[i*6 +: 6]; endfunction
    function automatic [3:0] pix_of(input [1:0] i);  pix_of    = layer_pix_f[i*4 +: 4];    endfunction
    function automatic [3:0] pri_of(input [1:0] i);  pri_of    = spr_pri_f[i*4 +: 4];      endfunction

    // ---- pick the winning tile layer: highest category, then highest index
    logic [1:0] win;
    logic       any_solid;
    always_comb begin
        win       = 2'd0;
        any_solid = 1'b0;
        for (int i = 0; i < 4; i++) begin
            if (layer_solid[i]) begin
                // >= on the category, because a later layer at the SAME
                // category overwrites an earlier one.
                if (!any_solid || cat_of(2'(i)) >= cat_of(win)) win = 2'(i);
                any_solid = 1'b1;
            end
        end
    end

    // Layers 2 and 3 are the second chip; it writes 0 unless view2_2_pri.
    wire winner_chip1 = win[1];
    wire [2:0] tile_prio = (winner_chip1 && !view2_2_pri) ? 3'd0 : cat_of(win);

    wire [10:0] tile_pen = tile_colbase
                         + {1'b0, col_of(win), 4'd0}    // colour * 16
                         + {7'd0, pix_of(win)};

    // Background is pen 0 — MAME's fill_bitmap uses pen 0 for sprite type 0.
    wire [10:0] under_pen  = any_solid ? tile_pen : 11'd0;
    wire [2:0]  under_prio = any_solid ? tile_prio : 3'd0;

    // ---- sprite comparison
    wire spr_here = |spr_pix;
    assign sprite_won = spr_here && (pri_of(spr_prio) > {1'b0, under_prio});

    assign pen      = sprite_won ? (spr_colbase + spr_pix[10:0]) : under_pen;
    assign prio_out = under_prio;
endmodule

`default_nettype wire
