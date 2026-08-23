// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for the VIEW2 pixel fetch pipeline.
//
// The reference here is NOT a hand transcription of MAME. It is the
// combinational address engine in kaneko_tmap.sv, which the frame gate already
// checks against frames MAME actually rendered. So this asks one question
// only: does the pipelined version, driven against real memories, produce
// exactly what the verified combinational version produces?
//
// That is the right question. Pipelining bugs are their own species — a stage
// off by one, a signal that fails to travel with its pixel, a control input
// sampled at the wrong stage — and none of them are arithmetic mistakes the
// frame gate would catch.
//
// What is checked:
//   - every pixel matches the combinational result, back to back at 1/clock
//   - the pipeline is 4 deep and pix_valid tracks req_valid exactly
//   - results stay correct with bubbles (req_valid low) interleaved
//   - ce=0 freezes the pipeline without losing or duplicating a pixel

#include <verilated.h>
#include "Vkaneko_tmap_fetch.h"
#include <cstdio>
#include <cstdint>
#include <deque>
#include <random>
#include <vector>

namespace {

constexpr int LATENCY = 4;

Vkaneko_tmap_fetch* dut;

std::vector<uint16_t> scroll_ram(512);
std::vector<uint32_t> vram(1024);
std::vector<uint8_t>  tile_rom(1 << 20);

// Expected result for one pixel, computed the way the (verified)
// combinational blocks do. Kept deliberately in the same terms as the RTL so a
// divergence points at the pipeline, not at a re-derivation.
struct Expect { bool solid; uint8_t pix, colour, cat; };

Expect expected(uint32_t sx, uint32_t sy, int dx, int dy,
                uint16_t scroll_x, uint16_t scroll_y,
                bool ls_en, bool enable)
{
    const uint32_t map_y = (uint32_t)((int32_t)sy + dy + (int32_t)(scroll_y >> 6)) & 0x1ff;
    const uint16_t ls    = scroll_ram[map_y];
    const uint16_t sum   = (uint16_t)(scroll_x + (ls_en ? ls : 0));
    const uint32_t map_x = (uint32_t)((int32_t)sx + dx + (int32_t)(sum >> 6)) & 0x1ff;

    const uint32_t entry = vram[((map_y >> 4) << 5) | (map_x >> 4)];
    const uint16_t attr  = entry & 0xffff;
    const uint16_t code  = entry >> 16;

    const uint8_t colour = (attr >> 2) & 0x3f;
    const uint8_t cat    = (attr >> 8) & 7;
    const bool flip_x = (attr >> 1) & 1, flip_y = attr & 1;

    uint32_t px = map_x & 15, py = map_y & 15;
    if (flip_x) px = 15 - px;
    if (flip_y) py = 15 - py;

    const uint32_t addr = ((uint32_t)code * 128u
                        + ((py & 8) ? 64u : 0u) + ((px & 8) ? 32u : 0u)
                        + (py & 7) * 4u + ((px & 7) >> 1)) & (tile_rom.size() - 1);
    const uint8_t byte = tile_rom[addr];
    const uint8_t pix  = (px & 1) ? (byte >> 4) : (byte & 0xf);

    return Expect{ enable && pix != 0, pix, colour, cat };
}

struct Req { bool valid; uint32_t sx, sy; Expect e; };
std::deque<Req> inflight;

// Registered (M10K-style) memories: the address is captured at a clock edge
// and the data appears on the NEXT cycle. Modelling them combinationally —
// data in the same cycle as the address — is wrong, and was how this harness
// first failed: every stage saw its own cycle's address instead of the
// previous one's.
//
// The three reads are chained (vram_addr depends on scr_data, rom_addr on
// vram_data), so each must be presented and evaluated in order before the next
// address is meaningful.
uint32_t held_scr = 0, held_vram = 0;

void tick()
{
    dut->clk = 0; dut->eval();

    // THE TWO MEMORIES DO NOT HAVE THE SAME LATENCY, and modelling them the
    // same way is what let a real bug hide here.
    //
    //   kaneko_vmem   `va_h <= ta_hi[vr_t]`            REGISTERED, one cycle
    //   kaneko_tilerom `assign req_data = hit0 ? ...`  COMBINATIONAL
    //
    // Both were answered from the previous cycle's address. That agreed with
    // a kaneko_tmap_fetch which also consumed rom_data a cycle late -- two
    // errors that cancelled, so this test passed while the board drew every
    // tile two pixels off. The frame gate could not see it either, because it
    // scores kaneko_tmap_layer, which is combinational and has no such stage.
    dut->scr_data  = scroll_ram[held_scr & 0x1ff];   dut->eval();
    dut->vram_data = vram[held_vram & 0x3ff];        dut->eval();
    dut->rom_data  = tile_rom[dut->rom_addr & (tile_rom.size() - 1)]; dut->eval();

    // Capture the addresses this cycle presents, for the next one to answer.
    // Only when the pipeline is actually advancing. rom_addr is NOT captured:
    // its memory answers within the cycle.
    if (dut->ce) {
        held_scr  = dut->scr_addr;
        held_vram = dut->vram_addr;
    }

    dut->clk = 1; dut->eval();
}

} // namespace

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    dut = new Vkaneko_tmap_fetch;
    std::mt19937 rng(0x46455443u);   // 'FETC'

    for (auto& w : scroll_ram) w = (uint16_t)rng();
    for (auto& w : vram)       w = rng();
    for (auto& b : tile_rom)   b = (uint8_t)rng();

    long checks = 0, fails = 0, bubbles = 0, stalls = 0;

    struct Cfg { int dx, dy; uint16_t sx, sy; bool ls, en; };
    const Cfg cfgs[] = {
        { 0x5b, -0x8, 0x6940, 0x0200, true,  true  },   // mgcrystl chip1 L0
        { 0x5b + 2, -0x8, 0x68c0, 0x0200, true, true },
        { 0x33,  0x8, 0x72c0, 0x7e00, false, true  },   // blazeon
        { 0x33,  0x9, 0x0000, 0x0000, true,  true  },   // wingforc
        { 0,     0,   0x0000, 0x0000, false, false },   // disabled layer
    };

    for (const auto& c : cfgs) {
        dut->rst = 1; dut->ce = 1; dut->req_valid = 0;
        for (int i = 0; i < 8; i++) tick();
        dut->rst = 0;
        inflight.clear();

        dut->dx = (uint32_t)(c.dx & 0x7ff);
        dut->dy = (uint32_t)(c.dy & 0x7ff);
        dut->scroll_x = c.sx;
        dut->scroll_y = c.sy;
        dut->linescroll_en = c.ls;
        dut->layer_enable  = c.en;

        for (long i = 0; i < 200000; i++) {
            // Occasional bubbles and stalls, so the pipeline is not only ever
            // exercised back to back.
            const bool stall  = (rng() % 37) == 0;
            const bool bubble = (rng() % 11) == 0;
            dut->ce = !stall;
            if (stall) { stalls++; tick(); continue; }

            const uint32_t sx = rng() & 0x1ff, sy = rng() & 0x1ff;
            dut->req_valid = !bubble;
            dut->screen_x = sx;
            dut->screen_y = sy;
            if (bubble) bubbles++;

            inflight.push_back(Req{ !bubble, sx, sy,
                expected(sx, sy, c.dx, c.dy, c.sx, c.sy, c.ls, c.en) });

            tick();

            // Alignment: a request presented at tick i has its output visible
            // after tick i+3, i.e. LATENCY ticks including its own. After tick
            // i the queue holds requests 0..i, so the one whose result is on
            // the outputs is at the front exactly when size >= LATENCY.
            // Using `> LATENCY` compares each request against its SUCCESSOR's
            // output — which is how this first failed, with dut values matching
            // ref values from the adjacent check.
            if ((int)inflight.size() >= LATENCY) {
                const Req r = inflight.front(); inflight.pop_front();
                checks++;
                bool bad = ((bool)dut->pix_valid != r.valid);
                if (r.valid) {
                    bad |= ((bool)dut->solid  != r.e.solid)
                        || (dut->pix    != r.e.pix)
                        || (dut->colour != r.e.colour)
                        || (dut->cat    != r.e.cat);
                }
                if (bad) {
                    fails++;
                    if (fails <= 20)
                        printf("  MISMATCH sx=%03x sy=%03x dx=%d dy=%d "
                               "dut{v=%d s=%d pix=%x col=%02x cat=%d} "
                               "ref{v=%d s=%d pix=%x col=%02x cat=%d}\n",
                               r.sx, r.sy, c.dx, c.dy,
                               (int)dut->pix_valid, (int)dut->solid,
                               (unsigned)dut->pix, (unsigned)dut->colour, (int)dut->cat,
                               (int)r.valid, (int)r.e.solid,
                               r.e.pix, r.e.colour, r.e.cat);
                }
            }
        }
    }

    printf("kaneko_tmap_fetch: checks=%ld fails=%ld latency=%d bubbles=%ld stalls=%ld\n",
           checks, fails, LATENCY, bubbles, stalls);

    dut->final();
    delete dut;
    return fails ? 1 : 0;
}
