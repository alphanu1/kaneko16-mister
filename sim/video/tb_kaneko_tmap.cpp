// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Fuzz harness for the VIEW2 tilemap address engine.
//
// The reference model below is transcribed from MAME's
// kaneko_view2_tilemap_device (kaneko_tmap.cpp), the tilemap scroll semantics
// in src/emu/tilemap.cpp, and gfx_8x8x4_row_2x2_group_packed_lsb in
// src/emu/video/generic.cpp. BSD-3-Clause, Luca Elia and David Haywood.
//
// SCOPE, stated so a passing run is not read as more than it is: this proves
// the RTL agrees with a model transcribed from MAME. It does NOT prove the
// transcription is right — that is what the M0 frame diff against a running
// MAME is for, and it is still owed. What this catches is the class of bug
// that actually bites in this layer: width truncation, sign extension, wrap
// at the wrong power of two, and fixed-point shifts applied in the wrong
// order.
//
// Global flip (layerctl bits 9:8) is NOT exercised. MAME applies it through
// tilemap_t::set_flip, whose interaction with scrolldx/dx_flipped is a
// separate transform this module does not yet implement. The attract frames
// M0 gates on have it clear (layerctl = 0x0c0c). Not a silent gap: it is
// named here, in the RTL header, and in docs/findings.md.

#include <verilated.h>
#include "Vkaneko_tmap_layer.h"
#include <cstdio>
#include <cstdint>
#include <random>

namespace {

struct Ref {
    uint32_t map_x, map_y;
    uint32_t attr_addr, code_addr;
    uint32_t rom_addr;
    uint32_t nibble_hi;
    uint32_t colour, prio;
};

Ref model(uint32_t screen_x, uint32_t screen_y,
          int32_t dx, int32_t dy,
          uint16_t scroll_x, uint16_t scroll_y,
          uint16_t linescroll, bool linescroll_en,
          uint16_t attr, uint16_t code)
{
    Ref r{};

    // Vertical first: its result indexes the line-scroll RAM.
    r.map_y = (uint32_t)((int32_t)screen_y + dy + (int32_t)(scroll_y >> 6)) & 0x1ff;

    // u16 addition, then >> 6. Order matters: summing at full precision and
    // truncating once is not the same as truncating each term.
    uint16_t scroll_sum = (uint16_t)(scroll_x + (linescroll_en ? linescroll : 0));
    r.map_x = (uint32_t)((int32_t)screen_x + dx + (int32_t)(scroll_sum >> 6)) & 0x1ff;

    uint32_t tile_index = ((r.map_y >> 4) * 32) + (r.map_x >> 4);
    r.attr_addr = tile_index * 2;
    r.code_addr = tile_index * 2 + 1;

    r.colour = (attr >> 2) & 0x3f;
    r.prio   = (attr >> 8) & 7;
    bool flip_x = (attr >> 1) & 1;   // TILE_FLIPXY swaps the bits
    bool flip_y = (attr >> 0) & 1;

    uint32_t px = flip_x ? (15u - (r.map_x & 15)) : (r.map_x & 15);
    uint32_t py = flip_y ? (15u - (r.map_y & 15)) : (r.map_y & 15);

    // 16x16 as four 8x8 sub-tiles: 0 / 32 / 64 / 96, rows of 4 bytes,
    // low nibble is the left pixel of the pair.
    r.rom_addr  = (uint32_t)code * 128u
                + ((py & 8) ? 64u : 0u)
                + ((px & 8) ? 32u : 0u)
                + (py & 7) * 4u
                + ((px & 7) >> 1);
    r.nibble_hi = px & 1;
    return r;
}

} // namespace

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    auto* dut = new Vkaneko_tmap_layer;

    // Fixed seed: counts must be reproducible across hosts and toolchains.
    std::mt19937 rng(0x4b414e45u);   // 'KANE'

    const long N = 3000000;
    long checks = 0, fails = 0;

    // Real configurations seen in the driver, plus randoms. mgcrystl and
    // explbrkr both use set_offset(0x5b, -0x8); blazeon uses (0x33, 0x8);
    // wingforc (0x33, 0x9). Layer 1 adds +2 to dx.
    const int dx_pool[] = { 0x5b, 0x5b + 2, 0x33, 0x33 + 2, 0, -1, 0x1ff, -0x200 };
    const int dy_pool[] = { -8, 8, 9, 0, 1, -1, 0x100, -0x100 };

    for (long i = 0; i < N; i++) {
        uint32_t screen_x = rng() & 0x1ff;
        uint32_t screen_y = rng() & 0x1ff;
        int32_t  dx = dx_pool[rng() % (sizeof(dx_pool) / sizeof(dx_pool[0]))];
        int32_t  dy = dy_pool[rng() % (sizeof(dy_pool) / sizeof(dy_pool[0]))];
        uint16_t scroll_x = (uint16_t)rng();
        uint16_t scroll_y = (uint16_t)rng();
        uint16_t lscroll  = (uint16_t)rng();
        bool     ls_en    = (rng() & 1) != 0;
        uint16_t attr     = (uint16_t)rng();
        uint16_t code     = (uint16_t)rng();

        dut->screen_x      = screen_x;
        dut->screen_y      = screen_y;
        dut->dx            = (uint32_t)(dx & 0x7ff);
        dut->dy            = (uint32_t)(dy & 0x7ff);
        dut->scroll_x      = scroll_x;
        dut->scroll_y      = scroll_y;
        dut->linescroll    = lscroll;
        dut->linescroll_en = ls_en;
        dut->attr          = attr;
        dut->code          = code;
        dut->eval();

        Ref r = model(screen_x, screen_y, dx, dy, scroll_x, scroll_y,
                      lscroll, ls_en, attr, code);

        bool bad =
            dut->map_x          != r.map_x     ||
            dut->map_y          != r.map_y     ||
            dut->vram_attr_addr != r.attr_addr ||
            dut->vram_code_addr != r.code_addr ||
            dut->rom_addr       != r.rom_addr  ||
            dut->nibble_hi      != r.nibble_hi ||
            dut->colour         != r.colour    ||
            dut->prio           != r.prio;

        checks++;
        if (bad) {
            fails++;
            if (fails <= 20) {
                printf("  MISMATCH #%ld\n", fails);
                printf("    in : sx=%03x sy=%03x dx=%d dy=%d scrx=%04x scry=%04x "
                       "ls=%04x lsen=%d attr=%04x code=%04x\n",
                       screen_x, screen_y, dx, dy, scroll_x, scroll_y,
                       lscroll, (int)ls_en, attr, code);
                printf("    dut: mx=%03x my=%03x aa=%03x ca=%03x rom=%06x nib=%d col=%02x pri=%d\n",
                       (unsigned)dut->map_x, (unsigned)dut->map_y,
                       (unsigned)dut->vram_attr_addr, (unsigned)dut->vram_code_addr,
                       (unsigned)dut->rom_addr, (int)dut->nibble_hi,
                       (unsigned)dut->colour, (int)dut->prio);
                printf("    ref: mx=%03x my=%03x aa=%03x ca=%03x rom=%06x nib=%d col=%02x pri=%d\n",
                       r.map_x, r.map_y, r.attr_addr, r.code_addr,
                       r.rom_addr, r.nibble_hi, r.colour, r.prio);
            }
        }
    }

    // Exhaustive sweep of the pixel-within-tile address for both flips, at a
    // fixed code. 16x16x2x2 = 1024 cases; random sampling would leave corners
    // of the sub-tile selection to chance.
    long exhaustive = 0;
    for (uint32_t fy = 0; fy < 16; fy++)
        for (uint32_t fx = 0; fx < 16; fx++)
            for (uint32_t fl = 0; fl < 4; fl++) {
                uint16_t attr = (uint16_t)(((fl & 1) << 1) | ((fl >> 1) & 1));
                dut->screen_x = fx; dut->screen_y = fy;
                dut->dx = 0; dut->dy = 0;
                dut->scroll_x = 0; dut->scroll_y = 0;
                dut->linescroll = 0; dut->linescroll_en = 0;
                dut->attr = attr; dut->code = 0x1234;
                dut->eval();
                Ref r = model(fx, fy, 0, 0, 0, 0, 0, false, attr, 0x1234);
                exhaustive++; checks++;
                if (dut->rom_addr != r.rom_addr || dut->nibble_hi != r.nibble_hi) {
                    fails++;
                    if (fails <= 20)
                        printf("  MISMATCH exhaustive fx=%u fy=%u attr=%04x "
                               "dut rom=%06x nib=%d ref rom=%06x nib=%d\n",
                               fx, fy, attr, (unsigned)dut->rom_addr,
                               (int)dut->nibble_hi, r.rom_addr, r.nibble_hi);
                }
            }

    printf("kaneko_tmap: checks=%ld fails=%ld exhaustive_pixaddr=%ld "
           "(global flip not covered)\n", checks, fails, exhaustive);

    dut->final();
    delete dut;
    return fails ? 1 : 0;
}
