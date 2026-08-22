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
        scr |= (uint64_t)(mix(held_scr[g] * 4 + g) & 0xffff) << (g * 16);
    dut->scr_data_f = scr;

    for (int g = 0; g < 4; g++)
        dut->vram_data_f[g] = mix(held_vram[g] * 8 + g + 0x1000);

    uint32_t rd = 0;
    for (int g = 0; g < 4; g++)
        rd |= (mix(held_rom[g] + g * 0x555) & 0xff) << (g * 8);
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

struct Line { std::vector<uint64_t> px{std::vector<uint64_t>(256)}; };

// Fetch one line and read the buffer back. Returns the 56 bits per pixel,
// packed as the module presents them.
Line run_line(int y, bool stalls) {
    stall_enabled = stalls;
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
    for (int x = 0; x < 256; x++) {
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

    std::printf("kaneko_tmap_line: checks=%ld fails=%ld\n", checks, fails);
    delete dut;
    return fails ? 1 : 0;
}
