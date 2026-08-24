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

    // An OSD override, applied inside the table so every derived output moves
    // together. Exists because the MRA's config byte does not arrive on
    // hardware and nothing in the per-game table has ever been exercised there
    // — see findings.md, 2026-08-22.
    input  wire        id_force_en,
    input  wire [7:0]  id_force,

    output wire  [7:0] game_id,

    // ---- memory map, a[23:16] of each window that moves
    output wire [7:0]  pg_wram, pg_v2w0, pg_v2w1, pg_spr, pg_pal,
    output wire [7:0]  pg_wdog,
    output wire [7:0]  pg_snd, pg_in,

    // The 68000 program ROM window: 1 MB on the Blaze On board, 512 KB on the
    // rest. blazeon_map is map(0x000000, 0x0fffff).rom(); bakubrkr_map and
    // mgcrystl_map both stop at 0x07ffff.
    output wire        rom_1mb,
    output wire        blazeon_io,

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
    // Sprite tiles in the ROM region, which is the MODULUS the sprite code is
    // reduced by. See the note where it is assigned.
    output wire [17:0] spr_elements,
    output wire [15:0] spr_xoffs, spr_yoffs,
    output wire [8:0]  visarea_min_y,
    output wire        wide_screen,    // screen width > 0x100
    output wire        fliptype,

    // ---- screen geometry, from set_visarea(). The totals do not change:
    // 384 x 264 covers a 320-wide window as well as a 256-wide one.
    output wire [9:0]  h_vis, v_vis, v_start, h_sync_start,
    output wire [8:0]  h_start,

    // The input words are ASSEMBLED differently, not merely relocated, so this
    // selects a wiring rather than supplying a number. See the note in the top
    // level.
    output wire        inputs_blazeon,

    // Z80 sound ROM, word address, and whether the board has a Z80 at all.
    output wire [SDR_AW-1:0] base_z80,
    output wire        has_z80,

    // The OKI's banking limit, (region - 0x20000) / 0x20000, and WHERE its
    // control comes from. Blaze On has no OKI; Wing Force has one on the Z80's
    // I/O ports rather than the 68000's bus, which is the only sound
    // difference between two games that share a PCB.
    output wire [2:0]  oki_max_bank,
    output wire        oki_on_z80,
    // The fourth input word, PER GAME. It is not a constant and it is not zero.
    //
    //   bakubrkr  e00006  high byte IPT_UNKNOWN, low byte NOT DECLARED -> ff00
    //   blazeon   c00004  PORT_BIT(0xffff, IP_ACTIVE_LOW, IPT_UNKNOWN) -> ffff
    //   wingforc  c00004  the same declaration                         -> ffff
    //   mgcrystl          NO SUCH PORT -- its map stops at c00004/SYSTEM
    //
    // The core drove 0x0000 for all four. Undefined bits in a MAME port read
    // zero, which is where that came from, but these bits are NOT undefined --
    // they are declared IPT_UNKNOWN and active low, so they read as ones.
    output wire [15:0] in_unk_val,

    // The OKI's input clock, which is also per-game: 12MHz/6 = 2 MHz on the
    // bakubrkr and mgcrystl boards, 16MHz/16 = 1 MHz on Wing Force. PIN7 is
    // high on all three so the internal divider is 132 either way, and the
    // entire difference is this bit.
    output wire        oki_cen_half,

    // SCREEN ROTATION, and it is per-game in BOTH senses -- whether, and which
    // way. MAME's GAME() lines: explbrkr ROT90, wingforc ROT270, mgcrystl and
    // blazeon ROT0. Two of the four rotate, in OPPOSITE directions, so a
    // single "rotate" flag would put one of them upside down.
    output wire        rot_en,
    output wire        rot_ccw
);

    localparam [7:0] CFG_INDEX = 8'd1;

    // Held through a core reset and cleared only by power-on. An OSD reset must
    // not lose which game is loaded, and the byte arrives once, before the ROM.
    // The latch holds what the MRA said; game_id is what the core ACTS on.
    // Keeping them separate matters: the override must move every derived
    // output AND the reported id together, or the core runs a chimera of two
    // boards and the readout lies about which.
    logic [7:0] id_latched;
    always_ff @(posedge clk) begin
        if (rst)
            id_latched <= 8'd0;
        else if (ioctl_wr && (ioctl_index == CFG_INDEX))
            id_latched <= ioctl_dout;
    end

    assign game_id = id_force_en ? id_force : id_latched;

    // Unknown ids fall back to game 0 rather than decoding nothing. A core that
    // runs the wrong game is diagnosable; one that shows a black screen is what
    // cost a night.
    wire is_mg = (game_id == 8'd1);
    wire is_bz = (game_id == 8'd2);
    wire is_wf = (game_id == 8'd3);
    wire blazeon_board = is_bz | is_wf;

    // Tier 2, the CALC3 board: Shogun Warriors and B.Rap Boys. One VIEW2 chip
    // like the Blaze On board, VU-002 sprites like everything in Tier 1, two
    // OKIs which are new, and a memory map that shares no page with either
    // board already here.
    wire is_sw = (game_id == 8'd4);
    wire is_bb = (game_id == 8'd5);
    wire calc3_board = is_sw | is_bb;

    // ------------------------------------------------- memory map pages
    //            explbrkr  mgcrystl  blazeon board  calc3 board
    // shogwarr_map, transcribed: work RAM 100000, palette 380000, sprite RAM
    // 580000, VIEW2 VRAM 600000, watchdog a80000, inputs b80000. Nothing it
    // uses lands where another board puts the same thing.
    assign pg_wram = calc3_board ? 8'h10
                   : blazeon_board ? 8'h30 : is_mg ? 8'h30 : 8'h10;
    assign pg_pal  = calc3_board ? 8'h38
                   : blazeon_board ? 8'h50 : is_mg ? 8'h50 : 8'h70;
    assign pg_v2w0 = calc3_board ? 8'h60
                   : blazeon_board ? 8'h60 : is_mg ? 8'h60 : 8'h50;
    assign pg_spr  = calc3_board ? 8'h58
                   : blazeon_board ? 8'h70 : is_mg ? 8'h70 : 8'h60;
    assign pg_in   = calc3_board ? 8'hb8
                   : blazeon_board ? 8'hc0 : is_mg ? 8'hc0 : 8'he0;
    // The Blaze On board has one VIEW2 chip and no watchdog, so those windows
    // are parked on a page nothing uses rather than left aliasing a real one.
    assign pg_v2w1 = (blazeon_board | calc3_board) ? 8'hff
                   : is_mg ? 8'h68 : 8'h58;
    assign pg_wdog = calc3_board ? 8'ha8
                   : blazeon_board ? 8'hff : is_mg ? 8'ha0 : 8'ha8;

    // The sound latch to the Z80 exists on the Blaze On board only. 0xff is
    // "no such window" — the same sentinel pg_wdog and pg_v2w1 use.
    assign pg_snd  = blazeon_board ? 8'he0 : 8'hff;
    assign rom_1mb = blazeon_board;
    assign blazeon_io = blazeon_board;

    // --------------------------------------------------- SDRAM bases
    // explbrkr's are a FIXED CONTRACT: its shipped MRA already uses them.
    // Tier 2's stream is a different shape: 256 KB of code and 128 KB of MCU
    // data ahead of the tiles, so view2_0 starts at byte 0x060000.
    assign base_trom0 = calc3_board   ? SDR_AW'(25'h030000)
                      : blazeon_board ? SDR_AW'(25'h080000) : SDR_AW'(25'h040000);
    assign base_trom1 = SDR_AW'(25'h0c0000);          // two-chip games only
    // PER GAME, NOT PER BOARD. Blaze On and Wing Force share a PCB but not an
    // SDRAM layout: Wing Force's view2_0 is twice the size, so its kan_spr
    // starts at byte 0x300000 where Blaze On's starts at 0x200000. Selecting
    // this on `blazeon_board` pointed Wing Force's sprite fetcher into the
    // middle of its own tile ROM, and it drew no sprites at all on hardware
    // while Blaze On drew them. Hard rule 9: the board is not the game.
    assign base_spr   = calc3_board ? SDR_AW'(25'h3b0000)  // byte 0x760000
                      : is_wf ? SDR_AW'(25'h180000)     // byte 0x300000
                      : is_bz ? SDR_AW'(25'h100000)     // byte 0x200000
                              : SDR_AW'(25'h140000);    // byte 0x280000
    assign base_oki   = calc3_board ? SDR_AW'(25'h230000)  // byte 0x460000
                      : is_wf ? SDR_AW'(25'h280000)
                      : is_mg ? SDR_AW'(25'h280000) : SDR_AW'(25'h260000);

    // ---------------------------------------------------------- video
    // set_offset() from each machine config.
    // set_offset(0x33, -0x8) on the CALC3 board, the same dx as Blaze On.
    assign v2_dx = (blazeon_board | calc3_board) ? 11'sd51 : 11'sd91;
    assign v2_dy = is_wf ? 11'sd9 : is_bz ? 11'sd8 : -11'sd8;
    // m_view2_2_pri: chip 1 writes its category, or zero. Only explbrkr sets it.
    // MACHINE_RESET_OVERRIDE(kaneko16_shogwarr_state, mgcrystl) -- the CALC3
    // board takes mgcrystl's reset, so m_view2_2_pri is 0 here too.
    assign view2_2_pri = ~(is_mg | blazeon_board | calc3_board);
    // set_priorities(), nibble per layer, layer 0 in the low nibble.
    // set_priorities(1, 3, 5, 7) on the CALC3 board, layer 0 in the low nibble.
    assign spr_pri_f = calc3_board   ? 16'h7531    // {1,3,5,7}
                     : blazeon_board ? 16'h8821    // {1,2,8,8}
                     : is_mg         ? 16'h7532    // {2,3,5,7}
                                     : 16'h8888;   // {8,8,8,8}
    assign tile_colbase = 11'h400;
    assign spr_colbase  = 11'd0;
    assign two_chips    = ~(blazeon_board | calc3_board);

    // -------------------------------------------------------- sprites
    assign spr_count     = blazeon_board ? 11'd512 : 11'd1024;

    // ------------------------------------------- the sprite code modulus
    //
    // kaneko_spr.cpp bounds every sprite code before it fetches:
    //
    //     const u8 *source_base = gfx->get_data(code % gfx->elements());
    //
    // `elements` is the ROM region divided by the size of one sprite. A VU-002
    // sprite is gfx_8x8x4_row_2x2_group_packed_msb, whose gfx_layout ends
    // `16*16*4` -- BITS, so 128 bytes per 16x16 sprite, not the 256 an 8bpp
    // tile would take.
    //
    // Without this the fetch runs off the end of the region. Measured on the
    // Explosive Breaker attract loop, 283 on-screen sprites in 7081 frames
    // carry a code past its 18432 -- 0x6c3a, 0x7d0d and 0x9e00. At base
    // 0x280000 a code of 0x6c3a addresses byte 0x5e1d00, which is past the end
    // of the OKI region above it and into SDRAM nothing ever wrote. Zero
    // nibbles are transparent, so the sprite silently does not appear while
    // its game logic goes on running.
    //
    // PER GAME, and hard rule 9 in its sharpest form: two of these are not
    // powers of two, so no mask can stand in for the division.
    //
    //   explbrkr  0x240000 / 128 =  18432   NOT a power of two
    //   mgcrystl  0x280000 / 128 =  20480   NOT a power of two
    //   blazeonj  0x200000 / 128 =  16384
    //   wingforc  0x200000 / 128 =  16384
    //   shogwarr  0x1000000 / 128 = 131072
    //   brapboys  0x800000 / 128 =  65536
    //
    // These must track SDRAM_MAPS in tools/build_rom_regions.py: the region
    // the MRA builds is the region this divides by, and `make lint` checks
    // the pair agree.
    assign spr_elements  = is_sw ? 18'd131072
                         : is_bb ? 18'd65536
                         : blazeon_board ? 18'd16384
                         : is_mg ? 18'd20480
                                 : 18'd18432;
    // set_offsets(0xa00, -0x40) on the CALC3 board.
    // set_offsets(0x10000 - 0x680, 0) on the Blaze On board.
    assign spr_xoffs     = calc3_board ? 16'h0a00
                         : blazeon_board ? 16'hf980 : 16'd0;
    assign spr_yoffs     = calc3_board ? 16'hffc0 : 16'd0;
    // screen().visible_area().min_y
    // set_visarea(40, 295, 16, 239) on the CALC3 board.
    assign visarea_min_y = blazeon_board ? 9'd0 : 9'd16;
    // (screen width > 0x100): 320 is, 256 is not.
    assign wide_screen   = blazeon_board | calc3_board;   // 320 wide
    assign fliptype      = 1'b0;    // VU-002 default; none of these override it

    // -------------------------------------------------------- geometry
    //   explbrkr / mgcrystl  (0, 255, 16, 239)   256 x 224 from line 16
    //   blazeon              (0, 319,  0, 231)   320 x 232 from line 0
    //   wingforc             (0, 319,  0, 223)   320 x 224 from line 0
    //   shogwarr / brapboys  (40, 295, 16, 239)  256 x 224 from line 16,
    //                                               offset 40 into a 320 screen
    assign h_vis   = blazeon_board ? 10'd320 : 10'd256;
    assign v_vis   = is_wf ? 10'd224 : is_bz ? 10'd232 : 10'd224;
    assign v_start = blazeon_board ? 10'd0   : 10'd16;
    // Only the CALC3 board's window starts anywhere but zero.
    assign h_start = calc3_board ? 9'd40 : 9'd0;
    // Sync sits centrally in what blanking is left, so it has to move with the
    // window: 296 is inside a 320-wide picture and would cut it in half.
    assign h_sync_start = blazeon_board ? 10'd336 : 10'd296;

    assign inputs_blazeon = blazeon_board;

    // audiocpu, from the SDRAM layout in tools/build_rom_regions.py. Byte
    // 0x400000 and 0x580000 respectively; these are word addresses, so half.
    assign base_z80 = is_wf ? SDR_AW'(25'h2c0000) : SDR_AW'(25'h200000);
    assign has_z80  = blazeon_board;

    //   explbrkr  oki1 0x100000 -> 7      mgcrystl  oki1 0x040000 -> 1
    //   wingforc  oki1 0x080000 -> 3      blazeonj  no OKI at all
    assign oki_max_bank = is_wf ? 3'd3 : is_mg ? 3'd1 : 3'd7;
    assign oki_on_z80   = is_wf;
    // mgcrystl has no fourth input word at all, so nothing it reads can be
    // right or wrong here; it keeps the value it has always been given rather
    // than being handed a new one that might disturb a game that now works.
    // shogwarr's UNK at b80006 declares its HIGH byte only, like bakubrkr's,
    // so it reads 0xff00 and takes the same branch.
    assign in_unk_val   = blazeon_board ? 16'hffff
                        : is_mg         ? 16'h0000
                                        : 16'hff00;
    assign oki_cen_half = is_wf;

    // ROT90 is clockwise, ROT270 is the same thing counter-clockwise, which is
    // what screen_rotate's rotate_ccw selects.
    wire is_eb = (game_id == 8'd0);
    assign rot_en  = is_eb | is_wf;
    assign rot_ccw = is_wf;
endmodule

`default_nettype wire
