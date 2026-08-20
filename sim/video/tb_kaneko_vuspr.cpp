// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Fuzz harness for the VU-002 sprite list parser.
//
// Reference model transcribed from MAME's kaneko16_sprite_device::draw_sprites
// and ::parse_sprite, plus kaneko_vu002_sprite_device::get_sprite_attributes
// (kaneko_spr.cpp, BSD-3-Clause, Luca Elia and David Haywood).
//
// Why whole-list comparison rather than per-record: the multisprite latches
// carry state forward, so a per-record check would pass on a model that
// latched at the wrong point in the sequence. Each pass drives a full random
// sprite list through the DUT and compares every resolved record in order. A
// latch updated one record early or late diverges on the record after it.
//
// SCOPE: proves the RTL agrees with a hand transcription of MAME, not that the
// transcription is right. The M0 frame diff against running MAME is still
// owed. What this catches is sequencing and arithmetic: latch update order,
// the pre-increment on latched code, the accumulate-before-offset ordering of
// X/Y, 16-bit wrap, and the signed 10-bit final transform.

#include <verilated.h>
#include "Vkaneko_vuspr.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <vector>

namespace {

constexpr int SPRITES = 1024;

struct Out {
    uint32_t code; uint32_t colour; uint32_t prio;
    bool flipx, flipy;
    int32_t x, y;
};

struct Cfg {
    uint16_t regs[16];
    uint16_t sprite_xoffs, sprite_yoffs;
    uint16_t visarea_min_y;
    bool wide_screen;
    bool fliptype;
};

// Whole-list reference. Mirrors draw_sprites()'s locals exactly.
std::vector<Out> model(const std::vector<uint16_t>& ram, const Cfg& cfg)
{
    std::vector<Out> out;
    out.reserve(SPRITES);

    const uint16_t max_val = cfg.wide_screen ? 0x8000u : 0x4000u;
    const bool glob_flipy = cfg.regs[0] & 1;
    const bool glob_flipx = (cfg.regs[0] >> 1) & 1;

    // Latched across records, initialised once per pass.
    uint16_t lat_x = 0, lat_y = 0;
    uint32_t lat_code = 0;
    uint32_t lat_colour = 0, lat_prio = 0;
    uint16_t lat_xoffs = 0, lat_yoffs = 0;
    bool lat_flipx = false, lat_flipy = false;

    for (int i = 0; i < SPRITES; i++) {
        const uint16_t attr = ram[i * 4 + 0];
        const uint16_t code_raw = ram[i * 4 + 1];
        const uint16_t x_raw = ram[i * 4 + 2];
        const uint16_t y_raw = ram[i * 4 + 3];

        // VU-002 attribute order
        const bool raw_flipy = attr & 1;
        const bool raw_flipx = (attr >> 1) & 1;
        const uint32_t raw_colour = (attr & 0x00fc) >> 2;
        const uint32_t raw_prio = (attr & 0x0300) >> 8;

        const uint32_t off_index = (attr & 0x1800) >> 11;
        uint16_t tbl_xoffs = cfg.regs[8 + off_index * 2 + 0];
        uint16_t tbl_yoffs = cfg.regs[8 + off_index * 2 + 1];

        // yoffs -= regs[1]; then +/- (min_y << 6) depending on global flip Y
        const uint16_t visy = (uint16_t)(cfg.visarea_min_y << 6);
        uint16_t adj_yoffs = glob_flipy
            ? (uint16_t)(tbl_yoffs - cfg.regs[1] - visy)
            : (uint16_t)(tbl_yoffs - cfg.regs[1] + visy);

        const bool use_lat_xy   = (attr >> 13) & 1;
        const bool use_lat_col  = (attr >> 14) & 1;
        const bool use_lat_code = (attr >> 15) & 1;

        // ++code, pre-increment: latch first, then use.
        const uint32_t r_code = use_lat_code ? (lat_code + 1) : code_raw;
        const uint32_t r_colour = use_lat_col ? lat_colour : raw_colour;
        const uint32_t r_prio   = use_lat_col ? lat_prio   : raw_prio;
        const uint16_t r_xoffs  = use_lat_col ? lat_xoffs  : tbl_xoffs;
        const uint16_t r_yoffs  = use_lat_col ? lat_yoffs  : adj_yoffs;

        bool r_flipx, r_flipy;
        if (cfg.fliptype) { r_flipx = raw_flipx; r_flipy = raw_flipy; }
        else {
            r_flipx = use_lat_col ? lat_flipx : raw_flipx;
            r_flipy = use_lat_col ? lat_flipy : raw_flipy;
        }

        const uint16_t p_x = use_lat_xy ? (uint16_t)(x_raw + lat_x) : x_raw;
        const uint16_t p_y = use_lat_xy ? (uint16_t)(y_raw + lat_y) : y_raw;

        uint16_t ox = (uint16_t)(p_x + r_xoffs + cfg.sprite_xoffs);
        uint16_t oy = (uint16_t)(p_y + r_yoffs + cfg.sprite_yoffs);

        bool f_flipx = r_flipx, f_flipy = r_flipy;
        if (glob_flipx) { ox = (uint16_t)(max_val - ox - (16 << 6)); f_flipx = !f_flipx; }
        if (glob_flipy) { oy = (uint16_t)(max_val - oy - (16 << 6)); f_flipy = !f_flipy; }

        // ((v & 0x7fc0) - (v & 0x8000)) / 0x40
        const int32_t fx = (int32_t)((ox & 0x7fc0) - (ox & 0x8000)) / 0x40;
        const int32_t fy = (int32_t)((oy & 0x7fc0) - (oy & 0x8000)) / 0x40;

        out.push_back(Out{ r_code, r_colour, r_prio, f_flipx, f_flipy, fx, fy });

        // Latch updates, in MAME's order.
        lat_code = r_code;
        lat_colour = r_colour; lat_prio = r_prio;
        lat_xoffs = r_xoffs;   lat_yoffs = r_yoffs;
        if (!cfg.fliptype) { lat_flipx = r_flipx; lat_flipy = r_flipy; }
        lat_x = p_x; lat_y = p_y;
    }
    return out;
}

Vkaneko_vuspr* dut;
std::vector<uint16_t> g_ram;

void tick()
{
    dut->clk = 0; dut->eval();
    // Synchronous read: data presented one clock after the address.
    dut->ram_data = g_ram[dut->ram_addr % g_ram.size()];
    dut->clk = 1; dut->eval();
}

} // namespace

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    dut = new Vkaneko_vuspr;
    std::mt19937 rng(0x53505200u);   // 'SPR\0'

    long checks = 0, fails = 0, passes = 0;
    long latched_code = 0, latched_xy = 0, latched_col = 0;

    const int PASSES = 40;
    for (int p = 0; p < PASSES; p++) {
        Cfg cfg{};
        for (int i = 0; i < 16; i++) cfg.regs[i] = (uint16_t)rng();
        // Pass 0 reproduces the real mgcrystl register set from MAME's
        // kaneko_spr.cpp comment block, which the live census also read.
        if (p == 0) {
            const uint16_t real_regs[16] = {
                0x4fcc, 0x0000, 0x0040, 0x00c0, 0x0000, 0x0001, 0x0001, 0x0001,
                0x0000, 0xfc40, 0xa000, 0x9c40, 0x1e00, 0x1a40, 0x0000, 0xfc40 };
            for (int i = 0; i < 16; i++) cfg.regs[i] = real_regs[i];
        }
        cfg.sprite_xoffs  = (uint16_t)rng();
        cfg.sprite_yoffs  = (uint16_t)rng();
        cfg.visarea_min_y = (uint16_t)(rng() & 0x1ff);
        cfg.wide_screen   = (rng() & 1) != 0;
        cfg.fliptype      = (p % 8) == 7;   // exercise the B.Rap Boys path too

        g_ram.assign(SPRITES * 4, 0);
        for (int i = 0; i < SPRITES; i++) {
            uint16_t attr = (uint16_t)rng();
            // Bias the multisprite bits hard: uniformly random gives 1-in-8
            // records with all three set, and long latched runs are what the
            // real data does (records 1-3 of the captured frame are 0xe300).
            if ((rng() % 3) == 0) attr |= 0xe000;
            if ((rng() % 5) == 0) attr &= ~0xe000;
            g_ram[i * 4 + 0] = attr;
            g_ram[i * 4 + 1] = (uint16_t)rng();
            g_ram[i * 4 + 2] = (uint16_t)rng();
            g_ram[i * 4 + 3] = (uint16_t)rng();
            if (attr & 0x8000) latched_code++;
            if (attr & 0x4000) latched_col++;
            if (attr & 0x2000) latched_xy++;
        }

        auto ref = model(g_ram, cfg);

        for (int i = 0; i < 16; i++)
            dut->regs_flat[i / 2] = (i % 2)
                ? ((dut->regs_flat[i / 2] & 0x0000ffffu) | ((uint32_t)cfg.regs[i] << 16))
                : ((dut->regs_flat[i / 2] & 0xffff0000u) | cfg.regs[i]);

        dut->sprite_xoffs  = cfg.sprite_xoffs;
        dut->sprite_yoffs  = cfg.sprite_yoffs;
        dut->visarea_min_y = cfg.visarea_min_y;
        dut->wide_screen   = cfg.wide_screen;
        dut->fliptype      = cfg.fliptype;

        dut->rst = 1; dut->start = 0; tick(); tick();
        dut->rst = 0; dut->start = 1; tick();
        dut->start = 0;

        size_t got = 0;
        long guard = 0;
        while (got < ref.size() && guard++ < SPRITES * 64) {
            tick();
            if (dut->out_valid) {
                const Out& r = ref[got];
                int32_t dx = (int32_t)(int16_t)((dut->out_x & 0x3ff) << 6) >> 6;
                int32_t dy = (int32_t)(int16_t)((dut->out_y & 0x3ff) << 6) >> 6;
                bool bad = ((uint32_t)dut->out_code   != r.code)   ||
                           ((uint32_t)dut->out_colour != r.colour) ||
                           ((uint32_t)dut->out_prio   != r.prio)   ||
                           ((bool)dut->out_flipx      != r.flipx)  ||
                           ((bool)dut->out_flipy      != r.flipy)  ||
                           (dx != r.x) || (dy != r.y);
                checks++;
                if (bad) {
                    fails++;
                    if (fails <= 20) {
                        printf("  MISMATCH pass=%d record=%zu attr=%04x\n",
                               p, got, g_ram[got * 4 + 0]);
                        printf("    dut: code=%05x col=%02x pri=%d fx=%d fy=%d x=%d y=%d\n",
                               (unsigned)dut->out_code, (unsigned)dut->out_colour,
                               (int)dut->out_prio, (int)dut->out_flipx,
                               (int)dut->out_flipy, dx, dy);
                        printf("    ref: code=%05x col=%02x pri=%d fx=%d fy=%d x=%d y=%d\n",
                               r.code, r.colour, r.prio, (int)r.flipx,
                               (int)r.flipy, r.x, r.y);
                    }
                }
                got++;
            }
        }
        if (got != ref.size()) {
            printf("  PASS %d PRODUCED %zu of %zu records\n", p, got, ref.size());
            fails++;
        }
        passes++;
    }

    printf("kaneko_vuspr: checks=%ld fails=%ld passes=%ld "
           "latched_code=%ld latched_color=%ld latched_xy=%ld\n",
           checks, fails, passes, latched_code, latched_col, latched_xy);

    dut->final();
    delete dut;
    return fails ? 1 : 0;
}
