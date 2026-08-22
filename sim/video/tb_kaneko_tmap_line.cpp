// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// kaneko_tmap_line: a line of four layers fetched ahead into a buffer.
//
// The pixel arithmetic is not retested here — tb_kaneko_tmap_fetch and the
// frame gate cover that. What this checks is everything the line stage adds,
// which is where a picture goes subtly wrong rather than obviously wrong:
//
//   * the buffer holds the fetched pixels IN ORDER, one per x
//   * stalls neither lose nor duplicate a pixel, however they fall
//   * the double buffer hands the display the finished line, not the one
//     being written
//
// The memories are deterministic functions of their addresses, so the same
// line must produce the same bytes no matter how the stalls land. That makes
// the stall test a comparison against the core's own unstalled run rather
// than against a reimplementation of the address engine.
#include <cstdio>
#include <cstdint>
#include <vector>
#include <random>
#include "Vkaneko_tmap_line.h"
#include "verilated.h"

namespace {

Vkaneko_tmap_line* dut;
long checks = 0, fails = 0;
std::mt19937 rng(0x7A31C0DEu);

// Deterministic memories: every read is a hash of its address, so a given
// line always yields the same pixels.
// When set, the memories ignore the layer index so every layer sees identical
// contents. Blaze On puts the same tiles on both layers of chip 0 and lines
// them up exactly; that only works if two layers given coincident parameters
// produce the same pixels, which is what this lets a test assert.
bool same_for_all_layers = false;

uint32_t mix(uint32_t v) {
    v ^= v >> 16; v *= 0x7feb352d; v ^= v >> 15; v *= 0x846ca68b; v ^= v >> 16;
    return v;
}

bool stall_enabled = false;

// THE MEMORIES ARE REGISTERED, AND MODELLING THEM AS COMBINATIONAL IS A BUG
//
// kaneko_tmap_fetch chains three reads: vram_addr comes off scr_data and
// rom_addr off vram_data, both combinationally. The real memories answer one
// clock after the address — vmem's read port and the tile ROM feeder are both
// registered — so the address a cycle presents must be answered by the NEXT
// cycle, and only when the pipeline actually advanced.
//
// Answering in the same tick makes a zero-latency memory. Without stalls that
// is a consistent shift and the line still looks self-consistent; with stalls
// the two disagree, which is how it was caught.
uint32_t held_scr[4] = {0}, held_vram[4] = {0}, held_rom[4] = {0};

void feed() {
    uint64_t scr = 0;
    for (int g = 0; g < 4; g++)
        scr |= (uint64_t)(mix(held_scr[g] * 4 + (same_for_all_layers ? 0 : g)) & 0xffff) << (g * 16);
    dut->scr_data_f = scr;

    for (int g = 0; g < 4; g++)
        dut->vram_data_f[g] = mix(held_vram[g] * 8 + (same_for_all_layers ? 0 : g) + 0x1000);

    uint32_t rd = 0;
    for (int g = 0; g < 4; g++)
        rd |= (mix(held_rom[g] + (same_for_all_layers ? 0 : g) * 0x555) & 0xff) << (g * 8);
    dut->rom_data_f = rd;

    // Four bits now, one per layer, stalled independently. That independence
    // is the point of the change under test: the layers no longer share a
    // clock enable, so a miss in one must not hold up the other three.
    if (!stall_enabled) dut->rom_ready = 0xf;
    else {
        uint8_t r = 0;
        for (int g = 0; g < 4; g++) if ((rng() % 5) != 0) r |= 1u << g;
        dut->rom_ready = r;
    }
}

// Capture what this cycle asked for, so the next one can answer it — and only
// when the pipeline advanced, which is what makes a stall transparent.
void capture() {
    for (int g = 0; g < 4; g++) {
        if (!((dut->rom_ready >> g) & 1)) continue;
        held_scr[g]  = (uint32_t)((dut->scr_addr_f  >> (g * 9))  & 0x1ff);
        held_vram[g] = (uint32_t)((dut->vram_addr_f >> (g * 10)) & 0x3ff);
        const int lo = g * 24;
        uint64_t w = (uint64_t)dut->rom_addr_f[lo / 32];
        if ((lo % 32) + 24 > 32) w |= (uint64_t)dut->rom_addr_f[lo / 32 + 1] << 32;
        held_rom[g] = (uint32_t)((w >> (lo % 32)) & 0xffffff);
    }
}

void tick() {
    feed();
    dut->clk = 0; dut->eval();
    capture();
    dut->clk = 1; dut->eval();
}

void ck(const char* what, uint64_t got, uint64_t want) {
    checks++;
    if (got != want && fails < 8) {
        fails++;
        std::printf("  FAIL %-40s got %llx want %llx\n", what,
                    (unsigned long long)got, (unsigned long long)want);
    } else if (got != want) fails++;
}

// Sized for the widest screen in the driver, not for the first one tested.
struct Line { std::vector<uint64_t> px{std::vector<uint64_t>(512)}; };

// Fetch one line and read the buffer back. Returns the 56 bits per pixel,
// packed as the module presents them.
Line run_line(int y, bool stalls, int width = 256) {
    stall_enabled = stalls;
    dut->h_active = width;
    dut->line_y = y;
    dut->start = 1; tick();
    dut->start = 0;

    int guard = 0;
    while (dut->busy && guard++ < 40000) tick();
    if (guard >= 40000) { std::printf("  FAIL line never completed\n"); fails++; }

    // Swap banks so the line just written becomes the readable one, then walk
    // it. The read port is registered, so present the address a clock early.
    dut->start = 1; dut->line_y = y + 1; tick();
    dut->start = 0;

    Line L;
    for (int x = 0; x < width; x++) {
        dut->rd_x = x; tick();
        L.px[x] = ((uint64_t)dut->out_solid << 52) | ((uint64_t)dut->out_cat_f << 40)
                | ((uint64_t)dut->out_colour_f << 16) | (uint64_t)dut->out_pix_f;
    }
    while (dut->busy) tick();
    return L;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vkaneko_tmap_line;

    dut->h_active = 256;   // the visible width under test
    dut->rst = 1; dut->start = 0; dut->rom_ready = 0xf; dut->rd_x = 0;
    dut->layer_en = 0xf; dut->linescroll_en = 0xf;
    dut->dx_f = 0; dut->dy_f = 0; dut->scroll_x_f = 0; dut->scroll_y_f = 0;
    for (int i = 0; i < 8; i++) tick();
    dut->rst = 0;

    // ------------------------------------------------ a line is reproducible
    Line a = run_line(40, false);
    Line b = run_line(40, false);
    for (int x = 0; x < 256; x++) ck("same line twice", a.px[x], b.px[x]);

    // Something must actually be there — a buffer of zeros would pass every
    // comparison above and mean nothing.
    int nonzero = 0;
    for (int x = 0; x < 256; x++) if (a.px[x]) nonzero++;
    ck("line is not all zeros", nonzero > 200, 1);

    // ---------------------------------------------- stalls change nothing
    // The memories are functions of their addresses, so a stalled fetch must
    // produce the identical line. This is the check that a miss cannot shear
    // the picture or drop a column.
    Line s = run_line(40, true);
    for (int x = 0; x < 256; x++) ck("stalled line matches", s.px[x], a.px[x]);

    // ------------------------------------------------- different lines differ
    Line c = run_line(41, false);
    int differ = 0;
    for (int x = 0; x < 256; x++) if (c.px[x] != a.px[x]) differ++;
    ck("a different scanline differs", differ > 100, 1);

    // ------------------------------------------- disabled layers read blank
    dut->layer_en = 0x0;
    Line d = run_line(40, false);
    int solid = 0;
    for (int x = 0; x < 256; x++) solid += (int)((d.px[x] >> 52) & 0xf);
    ck("no layer is solid when all are disabled", solid, 0);

    // ------------------------------------------------ 320 IS NOT A NEW LINE
    //
    // The visible width must not change WHICH pixels land in 0..255. Same
    // tilemap, same scroll; widening the fetch only ADDS pixels 256..319. If
    // the wide path duplicates a column or shifts by a pixel, the first 256
    // stop matching the narrow run.
    //
    // Everything above this point is self-consistency — same line twice,
    // stalls change nothing, a different y differs. A buffer that duplicated
    // every column would satisfy all of it. This is the check that says the
    // pixels are in the RIGHT PLACE, and it is the one the module never had
    // while the Blaze On board, which is the only 320-wide screen in the
    // driver, drew every glyph with a two-pixel ghost.
    dut->layer_en = 0xf;
    Line n256 = run_line(40, false, 256);
    Line n320 = run_line(40, false, 320);
    int wide_diff = 0;
    for (int x = 0; x < 256; x++) if (n320.px[x] != n256.px[x]) wide_diff++;
    ck("320-wide line matches the 256-wide one over 0..255", wide_diff, 0);

    int wide_nonzero = 0;
    for (int x = 256; x < 320; x++) if (n320.px[x]) wide_nonzero++;
    ck("the extra columns 256..319 are actually fetched", wide_nonzero > 40, 1);

    // And the same under stalls, which is where a shared clock enable or a
    // mis-sized counter shows up.
    Line s320 = run_line(40, true, 320);
    int wide_stall_diff = 0;
    for (int x = 0; x < 320; x++) if (s320.px[x] != n320.px[x]) wide_stall_diff++;
    ck("a stalled 320-wide line matches the unstalled one", wide_stall_diff, 0);

    // ------------------------------- TWO LAYERS THAT SHOULD COINCIDE, DO
    //
    // Blaze On draws the same tiles on both layers of VIEW2 chip 0 and lines
    // them up exactly: the hardware gives layer 1 a dx two greater, and the
    // game writes layer 1's scroll two LOWER to cancel it.
    //
    //   layer 0   dx 51 + (0x7340 >> 6 = 461) = 512
    //   layer 1   dx 53 + (0x72c0 >> 6 = 459) = 512
    //
    // With identical tile data the two layers must therefore emit identical
    // pixels. If they do not, every edge in the picture is drawn twice two
    // pixels apart — which is what the board shows, on static backgrounds and
    // on text alike.
    same_for_all_layers = true;
    dut->layer_en = 0xf;
    dut->linescroll_en = 0;
    // dx: 4 x signed 11, layer 0 = 51, layer 1 = 53
    dut->dx_f = ((uint64_t)53 << 11) | (uint64_t)51;
    dut->dy_f = 0;
    // scroll x: 4 x 16, layer 0 = 0x7340, layer 1 = 0x72c0
    dut->scroll_x_f = ((uint64_t)0x72c0 << 16) | (uint64_t)0x7340;
    dut->scroll_y_f = 0;

    Line co = run_line(40, false, 320);
    int coincide_diff = 0, first_bad = -1;
    for (int x = 0; x < 320; x++) {
        unsigned l0 = (unsigned)( co.px[x]        & 0xf);
        unsigned l1 = (unsigned)((co.px[x] >> 4)  & 0xf);
        if (l0 != l1) { coincide_diff++; if (first_bad < 0) first_bad = x; }
    }
    if (coincide_diff)
        std::printf("  layers disagree at %d of 320 columns, first at x=%d\n",
                    coincide_diff, first_bad);
    ck("layer 1 with dx+2 and scroll-2 coincides with layer 0", coincide_diff, 0);

    std::printf("kaneko_tmap_line: checks=%ld fails=%ld\n", checks, fails);
    delete dut;
    return fails ? 1 : 0;
}
