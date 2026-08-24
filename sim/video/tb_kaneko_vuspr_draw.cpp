// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for the VU-002 sprite bitmap renderer.
//
// Reference: the C++ sprite compositor inside the frame gate, which renders
// bitmaps that produce pixel-exact frames against MAME on explbrkr, blazeonj
// and wingforc. So the question here is narrow and worth asking on its own:
// does the RTL renderer produce the same bitmap, with the same
// first-writer-wins ordering, against the same table and ROM?
//
// The ordering is the whole point. MAME parses first-to-last (multisprite
// latches carry forward) but DRAWS last-to-first, first-writer-wins, so a
// higher table index is frontmost. An implementation that walked the table
// the other way would look plausible and be wrong wherever sprites overlap —
// which is most of a busy frame.

#include <verilated.h>
#include "Vkaneko_vuspr_draw.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <vector>

namespace {

// MUST MATCH the DUT's parameters. The bitmap is no longer square: 512x512
// was 4.19 Mbit of pixels on a part with 5.66 Mbit of block RAM in total, and
// it has to be double-buffered. 256x256 is this board's screen (MAME's
// set_size for bakubrkr and mgcrystl).
// 320 is the widest screen in the driver and is NOT a power of two, so the
// address is y*W + x throughout. Concatenating would agree with a DUT that
// concatenates, and both would be wrong on the Blaze On board.
constexpr int BMP_W = 320;
constexpr int BMP_H = 256;

Vkaneko_vuspr_draw* dut;

struct Spr { uint32_t code, colour, prio; bool fx, fy; int x, y; };

std::vector<uint64_t> table_mem;
std::vector<uint8_t>  rom;
long                  rom_oob = 0;   // fetches past the end of the region
std::vector<uint16_t> bmp;
std::vector<uint8_t>  mask;

uint64_t pack(const Spr& s)
{
    uint64_t w = 0;
    w |= (uint64_t)(s.code   & 0x1ffff);
    w |= (uint64_t)(s.colour & 0x3f)   << 17;
    w |= (uint64_t)(s.prio   & 3)      << 23;
    w |= (uint64_t)(s.fx ? 1 : 0)      << 25;
    w |= (uint64_t)(s.fy ? 1 : 0)      << 26;
    w |= (uint64_t)(s.x & 0x3ff)       << 27;
    w |= (uint64_t)(s.y & 0x3ff)       << 37;
    return w;
}

// Reference bitmap, matching the frame gate's compositor exactly.
void reference(const std::vector<Spr>& spr, std::vector<uint16_t>& out,
               int x0, int x1, int y0, int y1)
{
    out.assign((size_t)BMP_W * BMP_H, 0);
    std::vector<uint8_t> m((size_t)BMP_W * BMP_H, 0);
    const size_t elements = rom.size() / 128;
    for (int i = (int)spr.size() - 1; i >= 0; i--) {      // last to first
        const Spr& s = spr[i];
        for (int yy = 0; yy < 16; yy++) {
            const int py_ = s.y + yy;
            for (int xx = 0; xx < 16; xx++) {
                const int px_ = s.x + xx;
                if (px_ < x0 || px_ > x1 || py_ < y0 || py_ > y1) continue;
                uint32_t px = s.fx ? (15u - xx) : (uint32_t)xx;
                uint32_t py = s.fy ? (15u - yy) : (uint32_t)yy;
                const uint32_t tile = (uint32_t)(s.code % elements);
                const uint32_t a = tile * 128u + ((py & 8) ? 64u : 0u)
                                 + ((px & 8) ? 32u : 0u) + (py & 7) * 4u + ((px & 7) >> 1);
                const uint8_t byte = rom[a % rom.size()];
                const uint8_t c = (px & 1) ? (byte & 0xf) : (byte >> 4);  // MSB order
                if (c == 0) continue;
                if (px_ < 0 || px_ >= BMP_W || py_ < 0 || py_ >= BMP_H) continue;
                const size_t o = (size_t)py_ * BMP_W + (size_t)px_;
                if (!m[o]) out[o] = (uint16_t)(((s.prio & 3) << 14) | ((s.colour & 0x3f) << 4) | c);
                m[o] = 1;
            }
        }
    }
}

// Registered memories: address captured at an edge, data on the next cycle.
// Modelling them combinationally makes every stage see its own cycle's address
// instead of the previous one's — the same mistake that made the tmap fetch
// harness report near-total failure against already-verified logic.
uint32_t held_tbl = 0, held_rom = 0, held_mask = 0;
long n_bmp_we = 0, n_mask_we = 0, n_ticks = 0, n_stall = 0;

// Stall injector. The sprite ROM is in SDRAM, so `ce` is low whenever the
// feeder has not got the byte yet, and the module must freeze rather than lose
// or duplicate a pixel. stall_pct 0 reproduces the always-ready ROM the module
// was originally written against; anything else is the real case.
int stall_pct = 0;
std::mt19937* stall_rng = nullptr;

void tick()
{
    // `ce` is decided before the edge and held across it, as a feeder's hit
    // signal would be.
    bool ce = true;
    if (stall_pct && stall_rng)
        ce = ((int)((*stall_rng)() % 100) >= stall_pct);
    dut->ce = ce;
    if (!ce) n_stall++;

    dut->clk = 0; dut->eval();
    dut->tbl_data = table_mem[held_tbl % table_mem.size()];
    // NOT `% rom.size()`. Wrapping here would supply a plausible byte for an
    // address that ran off the end of the region and hide exactly the fault
    // this file is here to catch -- the same shape as every other default that
    // returned a plausible value. On hardware that address is SDRAM nothing
    // wrote, and it reads as transparent.
    if (held_rom >= rom.size()) {
        if (++rom_oob <= 5)
            printf("  FAIL: rom_addr %u is past the %zu-byte region"
                   " -- the sprite code was not reduced\n",
                   (unsigned)held_rom, rom.size());
        dut->rom_data = 0;
    } else {
        dut->rom_data = rom[held_rom];
    }
    dut->mask_q   = mask[held_mask % mask.size()];
    dut->eval();

    // The held addresses only advance on a cycle the module is allowed to
    // advance. Latching them while frozen would hand stage B the byte for an
    // address the pipeline has not reached.
    if (ce) {
        held_tbl  = dut->tbl_addr;
        held_rom  = dut->rom_addr;
        held_mask = dut->mask_raddr;
    }

    dut->clk = 1; dut->eval();
    // Writes take effect at the edge.
    n_ticks++;
    if (dut->bmp_we)  {
        bmp[dut->bmp_addr % bmp.size()] = dut->bmp_data; n_bmp_we++;
        if (getenv("TRACE") && n_bmp_we <= 6)
            printf("    bmp_we  addr=%05x (x=%d,y=%d) data=%04x\n",
                   (unsigned)dut->bmp_addr, (int)(dut->bmp_addr % BMP_W),
                   (int)(dut->bmp_addr / BMP_W), (unsigned)dut->bmp_data);
    }
    if (dut->mask_we) {
        mask[dut->mask_waddr % mask.size()] = 1; n_mask_we++;
        if (getenv("TRACE") && n_mask_we <= 6)
            printf("    mask_we addr=%05x (x=%d,y=%d)  mask_q was %d, raddr=%05x\n",
                   (unsigned)dut->mask_waddr, (int)(dut->mask_waddr % BMP_W),
                   (int)(dut->mask_waddr / BMP_W), (int)dut->mask_q,
                   (unsigned)dut->mask_raddr);
    }
}

} // namespace

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    dut = new Vkaneko_vuspr_draw;
    std::mt19937 rng(0x44524157u);   // 'DRAW'

    // Explosive Breaker's sprite region exactly: 0x240000 bytes, 18432
    // elements of 128. NOT a power of two, and that is the whole point -- at
    // 1<<18 the region held 2048 elements and a mask was indistinguishable
    // from the modulo kaneko_spr.cpp actually applies, so a core that never
    // reduced the code at all passed this test.
    rom.resize(18432u * 128u);
    for (auto& b : rom) b = (uint8_t)rng();

    long passes = 0, checks = 0, fails = 0, overlaps = 0;
    long total_bmp = 0, total_mask = 0;

    // Several sprite counts, including the Blaze On board's 512.
    const int counts[] = { 8, 64, 512, 1024 };

    std::mt19937 srng(0x5354414cu);   // 'STAL'
    stall_rng = &srng;
    long stall_cmp = 0, stall_diff = 0;

    for (int pass = 0; pass < 8; pass++) {
        const int n = counts[pass % 4];
        const int x0 = 0, x1 = 255, y0 = 16, y1 = 239;   // explbrkr visible area

        std::vector<Spr> spr(n);
        for (auto& s : spr) {
            // Half in range, half anywhere a 17-bit code can reach. MAME
            // reduces with `code % gfx->elements()`, so an out-of-range code
            // is a VALID sprite that must appear -- not a don't-care. The
            // generator only ever produced in-range codes before, which is
            // why the missing reduction survived every pass of this test.
            s.code   = (rng() & 1) ? (rng() % (rom.size() / 128))
                                   : (rng() & 0x1ffff);
            s.colour = rng() & 0x3f;
            s.prio   = rng() & 3;
            s.fx     = rng() & 1;
            s.fy     = rng() & 1;
            // Cluster them so sprites genuinely overlap — the ordering rule is
            // invisible on a scattered set.
            s.x = (int)(rng() % 200) + 20;
            s.y = (int)(rng() % 180) + 20;
        }

        table_mem.assign(1024, 0);
        for (int i = 0; i < n; i++) table_mem[i] = pack(spr[i]);

        // Run the same sprites twice: a ROM that always answers, and one that
        // stalls a third of the time. The two bitmaps must be identical — a
        // stall that lost or duplicated a pixel would show here even if both
        // runs happened to satisfy the reference in aggregate.
        std::vector<uint16_t> ready_bmp;
        const int stalls[2] = { 0, 33 };
        for (int run = 0; run < 2; run++) {
            stall_pct = stalls[run];

            bmp.assign((size_t)BMP_W * BMP_H, 0);
            mask.assign((size_t)BMP_W * BMP_H, 0);
            held_tbl = held_rom = held_mask = 0;

            dut->rst = 1; dut->start = 0; dut->ce = 1;
            dut->clip_x0 = x0; dut->clip_x1 = x1;
            dut->clip_y0 = y0; dut->clip_y1 = y1;
            dut->sprite_count = n;
            dut->spr_elements = (uint32_t)(rom.size() / 128);
            {   int save = stall_pct; stall_pct = 0;   // never stall in reset
                for (int i = 0; i < 4; i++) tick();
                dut->rst = 0;
                dut->start = 1; tick(); dut->start = 0;
                stall_pct = save;
            }

            long guard = 0;
            while (!dut->done && guard++ < (long)n * 3000 + 100000) tick();
            {   int save = stall_pct; stall_pct = 0;
                for (int i = 0; i < 8; i++) tick();     // drain
                stall_pct = save;
            }
            if (!dut->done && guard >= (long)n * 3000 + 100000) {
                printf("  TIMEOUT pass=%d n=%d stall=%d%%\n", pass, n, stall_pct);
                fails++;
            }

            if (run == 0) {
                ready_bmp = bmp;
            } else {
                for (size_t o = 0; o < bmp.size(); o++) {
                    stall_cmp++;
                    if (bmp[o] != ready_bmp[o]) {
                        stall_diff++; fails++;
                        if (stall_diff <= 10)
                            printf("  STALL DIFF pass=%d at (%zu,%zu) "
                                   "ready=%04x stalled=%04x\n",
                                   pass, o % BMP_W, o / BMP_W,
                                   ready_bmp[o], bmp[o]);
                    }
                }
            }
        }
        stall_pct = 0;

        if (getenv("TRACE"))
            printf("  pass=%d n=%d ticks=%ld bmp_we=%ld mask_we=%ld\n",
                   pass, n, n_ticks, n_bmp_we, n_mask_we);
        // Overlap is the point: with 1024 clustered sprites the mask is
        // written ~246k times but the bitmap only ~40k, because first-writer-
        // wins rejects the rest. With 8 sprites the two counts are equal.
        total_bmp += n_bmp_we; total_mask += n_mask_we;
        n_ticks = n_bmp_we = n_mask_we = 0;

        std::vector<uint16_t> ref;
        reference(spr, ref, x0, x1, y0, y1);

        long bad = 0;
        for (size_t o = 0; o < ref.size(); o++) {
            checks++;
            if (bmp[o] != ref[o]) {
                bad++; fails++;
                if (fails <= 15)
                    printf("  MISMATCH pass=%d n=%d at (%zu,%zu) dut=%04x ref=%04x\n",
                           pass, n, o % BMP_W, o / BMP_W, bmp[o], ref[o]);
            }
            if (ref[o]) overlaps++;
        }
        if (!bad) passes++;
    }

    printf("  stall-equivalence: %ld pixels compared, %ld differ, "
           "%ld stalled cycles\n", stall_cmp, stall_diff, n_stall);
    fails += rom_oob;
    printf("  region %zu bytes = %zu elements (not a power of two);"
           " %ld fetches past its end\n",
           rom.size(), rom.size() / 128, rom_oob);
    printf("kaneko_vuspr_draw: checks=%ld fails=%ld passes=%ld/8 "
           "bmp_writes=%ld mask_writes=%ld (rejected=%ld)\n",
           checks, fails, passes, total_bmp, total_mask, total_mask - total_bmp);

    dut->final();
    delete dut;
    return fails ? 1 : 0;
}
