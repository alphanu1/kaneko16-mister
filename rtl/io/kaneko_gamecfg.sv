// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Per-game configuration: every fact that differs between titles, in one place.
//
// WHY THIS IS A MODULE AND NOT A FEW TERNARIES IN THE TOP LEVEL
//
// It was a few ternaries in the top level, and the game id feeding them arrived
// over ioctl — a path no simulation exercised. It selected the MEMORY MAP, so a
// wrong byte there is a core that decodes nothing and shows a black screen. It
// was pulled back out and hardwired precisely because it could not be tested
// where it was.
//
// As a module it has a testbench: drive the ioctl stream, check the id lands,
// check every unrelated index is ignored, check reset. That is the difference
// between a mechanism that is trusted and one that is merely believed.
//
// EVERYTHING HERE IS READ FROM MAME
//
// Memory-map pages from each game's address_map, video constants from its
// machine_config and from the frame gate's table, which renders pixel-exact
// against MAME captures on three of the four. Hard rule 9: a per-game fact
// lives here, never wired into shared code, because a wrong one renders a
// plausible picture rather than failing.
`timescale 1ns/1ps
`default_nettype none

module kaneko_gamecfg #(
    parameter int unsigned SDR_AW = 25
) (
    input  wire        clk,
    input  wire        rst,          // power-on only: a core reset must not
                                     // forget which game is loaded

    // MRA <rom index="1">, one byte, delivered before the ROM stream.
    input  wire        ioctl_wr,
    // Only the low byte of each is used: the index is 8 bits of meaning in a
    // 16-bit bus, and the config value is one byte. Sliced at the port so the
    // unused halves are visible as a decision rather than a dangling warning.
    input  wire [7:0]  ioctl_index,
    input  wire [7:0]  ioctl_dout,

    output logic [7:0] game_id,

    // ---- memory map, a[23:16] of each window that moves
    output wire [7:0]  pg_wram, pg_v2w0, pg_v2w1, pg_spr, pg_pal,
    output wire [7:0]  pg_wdog,
    output wire [7:0]  pg_snd, pg_in,

    // ---- SDRAM region bases, WORD addresses (half the byte offset)
    output wire [SDR_AW:1] base_trom0, base_trom1, base_spr, base_oki,

    // ---- video
    output wire signed [10:0] v2_dx, v2_dy,
    output wire        view2_2_pri,
    output wire [15:0] spr_pri_f,
    output wire [10:0] tile_colbase, spr_colbase,
    output wire        two_chips,      // 0 = one VIEW2 chip

    // ---- sprites
    output wire [10:0] spr_count,
    output wire [15:0] spr_xoffs, spr_yoffs,
    output wire [8:0]  visarea_min_y,
    output wire        wide_screen,    // screen width > 0x100
    output wire        fliptype,

    // ---- screen geometry, from set_visarea(). The totals do not change:
    // 384 x 264 covers a 320-wide window as well as a 256-wide one.
    output wire [9:0]  h_vis, v_vis, v_start, h_sync_start,

    // The input words are ASSEMBLED differently, not merely relocated, so this
    // selects a wiring rather than supplying a number. See the note in the top
    // level.
    output wire        inputs_blazeon,

    // Z80 sound ROM, word address, and whether the board has a Z80 at all.
    output wire [SDR_AW-1:0] base_z80,
    output wire        has_z80
);

    localparam [7:0] CFG_INDEX = 8'd1;

    // Held through a core reset and cleared only by power-on. An OSD reset must
    // not lose which game is loaded, and the byte arrives once, before the ROM.
    always_ff @(posedge clk) begin
        if (rst)
            game_id <= 8'd0;
        else if (ioctl_wr && (ioctl_index == CFG_INDEX))
            game_id <= ioctl_dout;
    end

    // Unknown ids fall back to game 0 rather than decoding nothing. A core that
    // runs the wrong game is diagnosable; one that shows a black screen is what
    // cost a night.
    wire is_mg = (game_id == 8'd1);
    wire is_bz = (game_id == 8'd2);
    wire is_wf = (game_id == 8'd3);
    wire blazeon_board = is_bz | is_wf;

    // ------------------------------------------------- memory map pages
    //            explbrkr  mgcrystl  blazeon board
    assign pg_wram = blazeon_board ? 8'h30 : is_mg ? 8'h30 : 8'h10;
    assign pg_pal  = blazeon_board ? 8'h50 : is_mg ? 8'h50 : 8'h70;
    assign pg_v2w0 = blazeon_board ? 8'h60 : is_mg ? 8'h60 : 8'h50;
    assign pg_spr  = blazeon_board ? 8'h70 : is_mg ? 8'h70 : 8'h60;
    assign pg_in   = blazeon_board ? 8'hc0 : is_mg ? 8'hc0 : 8'he0;
    // The Blaze On board has one VIEW2 chip and no watchdog, so those windows
    // are parked on a page nothing uses rather than left aliasing a real one.
    assign pg_v2w1 = blazeon_board ? 8'hff : is_mg ? 8'h68 : 8'h58;
    assign pg_wdog = blazeon_board ? 8'hff : is_mg ? 8'ha0 : 8'ha8;

    // The sound latch to the Z80 exists on the Blaze On board only. 0xff is
    // "no such window" — the same sentinel pg_wdog and pg_v2w1 use.
    assign pg_snd  = blazeon_board ? 8'he0 : 8'hff;

    // --------------------------------------------------- SDRAM bases
    // explbrkr's are a FIXED CONTRACT: its shipped MRA already uses them.
    assign base_trom0 = blazeon_board ? SDR_AW'(25'h080000) : SDR_AW'(25'h040000);
    assign base_trom1 = SDR_AW'(25'h0c0000);          // two-chip games only
    assign base_spr   = blazeon_board ? SDR_AW'(25'h100000) : SDR_AW'(25'h140000);
    assign base_oki   = is_wf ? SDR_AW'(25'h280000)
                      : is_mg ? SDR_AW'(25'h280000) : SDR_AW'(25'h260000);

    // ---------------------------------------------------------- video
    // set_offset() from each machine config.
    assign v2_dx = blazeon_board ? 11'sd51 : 11'sd91;          // 0x33 : 0x5b
    assign v2_dy = is_wf ? 11'sd9 : is_bz ? 11'sd8 : -11'sd8;
    // m_view2_2_pri: chip 1 writes its category, or zero. Only explbrkr sets it.
    assign view2_2_pri = ~(is_mg | blazeon_board);
    // set_priorities(), nibble per layer, layer 0 in the low nibble.
    assign spr_pri_f = blazeon_board ? 16'h8821    // {1,2,8,8}
                     : is_mg         ? 16'h7532    // {2,3,5,7}
                                     : 16'h8888;   // {8,8,8,8}
    assign tile_colbase = 11'h400;
    assign spr_colbase  = 11'd0;
    assign two_chips    = ~blazeon_board;

    // -------------------------------------------------------- sprites
    assign spr_count     = blazeon_board ? 11'd512 : 11'd1024;
    // set_offsets(0x10000 - 0x680, 0) on the Blaze On board.
    assign spr_xoffs     = blazeon_board ? 16'hf980 : 16'd0;
    assign spr_yoffs     = 16'd0;
    // screen().visible_area().min_y
    assign visarea_min_y = blazeon_board ? 9'd0 : 9'd16;
    // (screen width > 0x100): 320 is, 256 is not.
    assign wide_screen   = blazeon_board;
    assign fliptype      = 1'b0;    // VU-002 default; none of these override it

    // -------------------------------------------------------- geometry
    //   explbrkr / mgcrystl  (0, 255, 16, 239)   256 x 224 from line 16
    //   blazeon              (0, 319,  0, 231)   320 x 232 from line 0
    //   wingforc             (0, 319,  0, 223)   320 x 224 from line 0
    assign h_vis   = blazeon_board ? 10'd320 : 10'd256;
    assign v_vis   = is_wf ? 10'd224 : is_bz ? 10'd232 : 10'd224;
    assign v_start = blazeon_board ? 10'd0   : 10'd16;
    // Sync sits centrally in what blanking is left, so it has to move with the
    // window: 296 is inside a 320-wide picture and would cut it in half.
    assign h_sync_start = blazeon_board ? 10'd336 : 10'd296;

    assign inputs_blazeon = blazeon_board;

    // audiocpu, from the SDRAM layout in tools/build_rom_regions.py. Byte
    // 0x400000 and 0x580000 respectively; these are word addresses, so half.
    assign base_z80 = is_wf ? SDR_AW'(25'h2c0000) : SDR_AW'(25'h200000);
    assign has_z80  = blazeon_board;
endmodule

`default_nettype wire
