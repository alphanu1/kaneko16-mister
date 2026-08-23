// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Per-game configuration, including the ioctl path that delivers the game id.
//
// That path selects the MEMORY MAP. A wrong byte here is a core that decodes
// nothing and shows a black screen, which is exactly what happened when this
// logic lived in the top level where no harness could reach it. It was pulled
// back out and hardwired until it could be tested. This is that test.
#include <cstdio>
#include <cstdint>
#include "Vkaneko_gamecfg.h"
#include "verilated.h"

namespace {

Vkaneko_gamecfg* d;
long checks = 0, fails = 0;

void tick(int n = 1) {
    for (int i = 0; i < n; i++) { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
}

void ioctl_byte(uint8_t index, uint8_t value) {
    d->ioctl_index = index;
    d->ioctl_dout  = value;
    d->ioctl_wr    = 1;
    tick();
    d->ioctl_wr    = 0;
    tick();
}

void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; printf("  FAIL: %s\n", what); }
}

// Every field, per game, taken from MAME's address_map and machine_config and
// from the frame gate's table. Written out rather than computed, so a wrong
// value in the RTL cannot be matched by the same wrong value here.
struct Cfg {
    const char* name;
    uint8_t id;
    uint8_t wram, v2w0, v2w1, spr, pal, wdog, in;
    int     dx, dy;
    bool    v2_2_pri, two_chips, wide;
    uint16_t pri, count, xoffs;
    uint16_t min_y;
    uint16_t h_vis, v_vis, v_start, hsync;   // set_visarea()
    bool     rot;                            // screen rotated at all
    bool     ccw;                            // and counter-clockwise if so
    uint8_t  okimb;                          // OKI max_bank, per region size
    bool     okiz80;                         // OKI hangs off the Z80's ports
    uint8_t  snd;                            // sound-latch page, 0xff = none
    bool     rom1mb;                         // 68000 program window size
    bool     z80;
    uint32_t z80base;                        // word address of audiocpu
};

const Cfg GAMES[] = {
  // name        id  wram v2w0 v2w1 spr  pal wdog  in    dx   dy  2pri 2chip wide   pri  count  xoffs min_y   geometry     rot ccw  okimb okiz80  snd  1mb  z80  z80base
  { "explbrkr",  0, 0x10,0x50,0x58,0x60,0x70,0xa8,0xe0,  91,  -8, true , true , false,0x8888,1024,0x0000, 16, 256,224,16,296, true ,false,7,false,0xff,false,false,0x200000 },
  { "mgcrystl",  1, 0x30,0x60,0x68,0x70,0x50,0xa0,0xc0,  91,  -8, false, true , false,0x7532,1024,0x0000, 16, 256,224,16,296, false,false,1,false,0xff,false,false,0x200000 },
  { "blazeonj",  2, 0x30,0x60,0xff,0x70,0x50,0xff,0xc0,  51,   8, false, false, true ,0x8821, 512,0xf980,  0, 320,232, 0,336, false,false,7,false,0xe0,true ,true ,0x200000 },
  { "wingforc",  3, 0x30,0x60,0xff,0x70,0x50,0xff,0xc0,  51,   9, false, false, true ,0x8821, 512,0xf980,  0, 320,224, 0,336, true ,true ,3,true ,0xe0,true ,true ,0x2c0000 },
};

void verify(const Cfg& g) {
    char msg[160];
    #define CK(expr, field) do { \
        snprintf(msg, sizeof msg, "%s: %s", g.name, field); \
        check(expr, msg); } while (0)

    CK(d->game_id == g.id,            "game_id");
    CK(d->pg_wram == g.wram,          "pg_wram");
    CK(d->pg_v2w0 == g.v2w0,          "pg_v2w0");
    CK(d->pg_v2w1 == g.v2w1,          "pg_v2w1");
    CK(d->pg_spr  == g.spr,           "pg_spr");
    CK(d->pg_pal  == g.pal,           "pg_pal");
    CK(d->pg_wdog == g.wdog,          "pg_wdog");
    CK(d->pg_in   == g.in,            "pg_in");

    // 11-bit signed, so sign-extend before comparing.
    int dx = d->v2_dx; if (dx & 0x400) dx -= 0x800;
    int dy = d->v2_dy; if (dy & 0x400) dy -= 0x800;
    CK(dx == g.dx,                    "v2_dx");
    CK(dy == g.dy,                    "v2_dy");

    CK(d->view2_2_pri == g.v2_2_pri,  "view2_2_pri");
    CK(d->two_chips   == g.two_chips, "two_chips");
    CK(d->wide_screen == g.wide,      "wide_screen");
    CK(d->spr_pri_f   == g.pri,       "spr_pri_f");
    CK(d->spr_count   == g.count,     "spr_count");
    CK(d->spr_xoffs   == g.xoffs,     "spr_xoffs");
    CK(d->visarea_min_y == g.min_y,   "visarea_min_y");

    CK(d->h_vis   == g.h_vis,         "h_vis");
    CK(d->v_vis   == g.v_vis,         "v_vis");
    CK(d->v_start == g.v_start,       "v_start");
    // Sync must sit OUTSIDE the picture. 296 is inside a 320-wide window and
    // would cut it in half, so this is not a cosmetic constant.
    CK(d->h_sync_start == g.hsync,    "h_sync_start");
    CK(d->h_sync_start >= d->h_vis,   "sync starts after the visible width");
    CK(d->h_sync_start + 32 <= 384,   "sync ends inside the horizontal total");
    CK(d->v_start + d->v_vis <= 264,  "the window fits the vertical total");
    CK(d->pg_snd  == g.snd,           "pg_snd");
    // The OKI's bank limit is (region - 0x20000) / 0x20000 and differs per
    // game. A bank above the limit aliases the last block, so a wrong limit
    // plays the wrong sample rather than failing — the quietest way to be
    // wrong, and why it is checked here rather than trusted.
    CK(d->oki_max_bank == g.okimb,    "oki_max_bank");
    CK(d->oki_on_z80   == g.okiz80,   "oki_on_z80");
    // Same board, same OKI, different crystal — 2 MHz vs Wing Force's 1 MHz.
    CK(d->oki_cen_half == g.okiz80,   "oki_cen_half");
    // Two of the four rotate and in opposite directions, so a single flag
    // would put one of them upside down.
    CK(d->rot_en  == g.rot,           "rot_en");
    CK(d->rot_ccw == g.ccw,           "rot_ccw");
    // The 68000 program window is a per-game SIZE, and getting it wrong is
    // what blacked out Blaze On: blazeon_map is 1 MB, bakubrkr_map and
    // mgcrystl_map are 512 KB. Widening it for everyone blacks out Explosive
    // Breaker instead, because its view2_0 sits at byte 0x080000.
    CK(d->rom_1mb == g.rom1mb,        "rom_1mb");
    CK(d->has_z80 == g.z80,           "has_z80");
    CK(d->base_z80 == g.z80base,      "base_z80");
    // The sound-latch window must not collide with a real one. On this board
    // 0xff is the "no such window" sentinel and pg_wdog uses it too, but a
    // board WITH a latch must place it somewhere nothing else claims.
    if (g.z80) {
        CK(d->pg_snd != d->pg_wram && d->pg_snd != d->pg_pal &&
           d->pg_snd != d->pg_v2w0 && d->pg_snd != d->pg_spr &&
           d->pg_snd != d->pg_in,     "pg_snd collides with another window");
    }
    #undef CK
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vkaneko_gamecfg;

    d->rst = 1; d->ioctl_wr = 0; d->ioctl_index = 0; d->ioctl_dout = 0;
    d->id_force_en = 0; d->id_force = 0;
    tick(4);
    d->rst = 0; tick(2);

    // ---------------------------------------------------------------- 1
    printf("== reset selects game 0\n");
    check(d->game_id == 0, "game_id is 0 out of reset");
    verify(GAMES[0]);

    // ---------------------------------------------------------------- 2
    printf("== each game id selects its whole configuration\n");
    for (const auto& g : GAMES) {
        ioctl_byte(1, g.id);
        verify(g);
    }

    // ---------------------------------------------------------------- 3
    // The ROM stream is index 0 and the save is index 2. Neither may touch the
    // game id — a stray write here re-maps memory under a running game.
    printf("== other ioctl indices are ignored\n");
    ioctl_byte(1, 2);                       // Blaze On
    check(d->game_id == 2, "id set before the interference test");
    for (uint8_t idx : {0, 2, 3, 255}) {
        ioctl_byte(idx, 0x7e);
        char m[64]; snprintf(m, sizeof m, "index %u left the game id alone", idx);
        check(d->game_id == 2, m);
    }
    verify(GAMES[2]);

    // ---------------------------------------------------------------- 4
    // An id nobody has defined must fall back to game 0, not decode nothing.
    printf("== an unknown id falls back to Explosive Breaker's map\n");
    ioctl_byte(1, 0x5a);
    check(d->pg_wram == 0x10, "unknown id uses game 0's work RAM page");
    check(d->pg_in   == 0xe0, "unknown id uses game 0's input page");
    check(d->spr_count == 1024, "unknown id uses game 0's sprite count");

    // ---------------------------------------------------------------- 5
    // A core reset must NOT forget the game; only power-on may.
    printf("== the id survives a core reset\n");
    ioctl_byte(1, 3);
    check(d->game_id == 3, "Wing Force selected");
    d->rst = 1; tick(4); d->rst = 0; tick(2);
    check(d->game_id == 0, "power-on reset clears it to game 0");

    // ---------------------------------------------------------------- 5
    // The OSD override must move EVERY derived output, not just game_id. It
    // exists because the MRA's config byte does not arrive on hardware, so it
    // is the only thing that has ever exercised the per-game table there — if
    // it moved only some outputs the core would run a chimera of two boards.
    printf("== the OSD override drives the whole table\n");
    ioctl_byte(1, 0);                      // MRA says game 0
    for (const auto& g : GAMES) {
        if (g.id == 0) continue;
        d->id_force_en = 1; d->id_force = g.id; tick(2);
        verify(g);                          // every output must match that game
    }
    d->id_force_en = 0; tick(2);
    verify(GAMES[0]);                       // and release restores the MRA's id

    printf("\ntb_kaneko_gamecfg: %ld checks, %ld fails\n", checks, fails);
    delete d;
    return fails ? 1 : 0;
}
