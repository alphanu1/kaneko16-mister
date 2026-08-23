// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The line-buffered tilemap path against the address engine the frame gate
// scores, pixel for pixel.
//
// WHY: `make gate` reports 100.0000% for blazeonj and wingforc while the board
// draws every one-pixel vertical stroke twice. Both are true, because the gate
// instantiates `kaneko_tmap_layer` and the core has run `kaneko_tmap_line` +
// `kaneko_tmap_fetch` since the line buffer replaced it. The path that draws
// the fault has never been compared against anything, which is why every
// upstream stage checked out clean while the picture stayed wrong.
//
// `kaneko_tmap_layer` is the oracle. It is the module the frame gate scores at
// 100% against MAME, so a disagreement here is a defect in the line-buffered
// path rather than an open question about the hardware.
//
// THE STALL IS THE SUSPECT, so it is swept rather than assumed.
// kaneko_tilerom's header claims kaneko_tmap_fetch's `ce` "is verified to
// freeze the pipeline without losing or duplicating a pixel". A duplicated
// pixel is EXACTLY the reported symptom, and that claim has no test behind it
// in this repository. So each line is run twice: once with the tile ROM always
// ready, once with it stalling pseudo-randomly. If the all-ready run matches
// and the stalling run does not, the fault is the stall path and nothing else.
#include <cstdio>
#include <cstdint>
#include <vector>
#include <cstdlib>
#include "Vkaneko_tline_harness.h"
#include "verilated.h"

namespace {

Vkaneko_tline_harness* d;
long checks = 0, fails = 0;
int  reported = 0;

void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; }
    (void)what;
}

constexpr int H_VIS = 320;

std::vector<uint16_t> vram;      // 2048 words: attr at 2i, code at 2i+1
std::vector<uint8_t>  rom;       // tile pixel bytes, two pixels each

// A cheap deterministic PRNG. Fixed seed, per the repository's rule that
// counts must not drift with the host or the toolchain.
uint32_t rng_s = 0x1234567u;
uint32_t rnd() { rng_s ^= rng_s << 13; rng_s ^= rng_s >> 17; rng_s ^= rng_s << 5; return rng_s; }

// THE TWO MEMORIES HAVE DIFFERENT LATENCY, AND MODELLING THEM THE SAME IS A
// TRAP. kaneko_vmem reads its tile arrays through a flop -- `va_h <= ta_hi[vr_t]`
// -- so vram_data arrives ONE CYCLE after vram_addr. kaneko_tilerom answers
// combinationally: `assign req_data = hit0 ? line0[...] : line1[...]`.
//
// Feeding both combinationally made this bench disagree with the RTL by a
// whole tile of colour, and the disagreement looked exactly like an RTL fault.
// It cost a wrong "fix" to kaneko_tmap_fetch that had to be reverted.
uint32_t held_vram = 0;

void tick() {
    d->clk = 0; d->eval();
    // Capture the address this cycle presents, for the next cycle to answer,
    // and only while the pipeline is advancing -- which is what a registered
    // read with a clock enable does.
    // Gated by the pipeline's clock enable. kaneko_vmem's read has no ce of its
    // own, but its ADDRESS comes from stage 1, which the enable freezes -- so
    // during a stall the address does not move and the registered data does
    // not either. Modelling it ungated lets the model recapture on a stalled
    // cycle, which is not what the frozen address does.
    uint32_t next_vram = (d->rom_ready0 ? (uint32_t)d->vram_addr0 : held_vram);
    d->clk = 1; d->eval();
    held_vram = next_vram;
}

// THE ORDER OF THESE TWO MATTERS, because there is a combinational chain
// through the design between them:
//
//   vram_data -> s2_code -> kaneko_tmap_pixaddr -> rom_addr -> rom_data
//
// Reading rom_addr before vram_data has been applied answers the ROM for the
// PREVIOUS address. That is invisible everywhere except the cycle a tile
// changes, which is precisely where this bench was reporting failures -- and
// flipped tiles made it show up more often by changing which addresses appear.
// It looked exactly like an RTL fault at tile boundaries.
void serve() {
    d->scr_data0  = 0;                                   // linescroll unused here
    uint32_t ix   = held_vram & 0x3ff;                   // REGISTERED read
    d->vram_data0 = ((uint32_t)vram[2*ix + 1] << 16) | vram[2*ix];
    d->eval();                                           // let rom_addr settle
    d->rom_data0  = rom[d->rom_addr0 % rom.size()];      // COMBINATIONAL read
    d->eval();
}

// Run one scanline into the spare bank, optionally stalling the tile ROM.
void run_line(int y, bool stall) {
    d->line_y = y;
    d->start  = 1;
    d->rom_ready0 = 1;
    serve(); tick();
    d->start = 0;

    for (int guard = 0; guard < 200000; guard++) {
        d->rom_ready0 = stall ? ((rnd() & 3) != 0) : 1;
        serve();
        tick();
        if (!d->busy) break;
    }
    check(!d->busy, "the line finished");
}

// What the oracle says pixel x of line y should be.
struct Ref { int pix, colour, cat, solid; };

Ref reference(int x, int y) {
    d->o_screen_x = x;
    d->o_screen_y = y;
    d->eval();
    uint16_t attr = vram[d->o_vram_attr_addr & 0x7ff];
    uint16_t code = vram[d->o_vram_code_addr & 0x7ff];
    d->o_attr = attr;
    d->o_code = code;
    d->eval();
    uint8_t byte = rom[d->o_rom_addr % rom.size()];
    int pix = d->o_nibble_hi ? (byte >> 4) : (byte & 0xf);
    return Ref{ pix, (int)d->o_colour, (int)d->o_prio, pix != 0 };
}

// Compare the buffer the pipeline filled against the oracle, pixel by pixel.
// THE BUFFER IS DOUBLE-BANKED, so the line just fetched is not the line being
// displayed: kaneko_tmap_line reads the bank the fetch is NOT writing. A line
// becomes visible only once the next start has flipped the banks. Reading
// straight after the fetch returns the other, empty bank -- which reads as
// "every pixel is zero" and looks exactly like a dead pipeline.
// Fetch the SAME line a second time, in full. The banks alternate on every
// start, so after two complete fetches of line y the displayed bank holds
// line y and the other one does too -- no partially-filled bank left over to
// confuse a mismatch with a harness artefact.
int compare_line(int y, const char* what) {
    int bad = 0;
    for (int x = 0; x < H_VIS; x++) {
        d->rd_x = x;
        serve();
        d->eval();
        tick();                       // the display read is registered
        d->eval();
        Ref r = reference(x, y);
        bool ok = (d->out_pix0 == r.pix) && (d->out_colour0 == r.colour)
               && (d->out_cat0 == r.cat) && (d->out_solid0 == r.solid);
        check(ok, "pixel matches the oracle");
        if (!ok) {
            bad++;
            if (reported < 16) {
                reported++;
                printf("    %s y=%3d x=%3d  got pix=%x col=%02x  want pix=%x col=%02x"
                       "   oracle rom=%06x nib=%d byte=%02x  attr=%04x code=%04x\n",
                       what, y, x, d->out_pix0, d->out_colour0, r.pix, r.colour,
                       (uint32_t)d->o_rom_addr, (int)d->o_nibble_hi,
                       rom[d->o_rom_addr % rom.size()],
                       (uint32_t)d->o_attr, (uint32_t)d->o_code);
            }
        }
    }
    return bad;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vkaneko_tline_harness;

    // Content chosen so a duplicated or shifted pixel cannot hide: every
    // adjacent pair of pixels differs, and single-pixel vertical strokes exist
    // -- which is the actual reported artefact, "in" drawn as "iin".
    rom.resize(0x40000);
    for (size_t i = 0; i < rom.size(); i++) {
        // low nibble non-zero and varying, high nibble a lone stroke every
        // eighth byte, so isolated single-pixel columns appear.
        uint8_t lo = (uint8_t)((i * 5 + 1) & 0xf);
        uint8_t hi = ((i & 7) == 3) ? 0xf : 0x0;
        rom[i] = (uint8_t)((hi << 4) | (lo ? lo : 1));
    }
    vram.resize(2048);
    for (size_t i = 0; i < vram.size(); i += 2) {
        vram[i]     = (uint16_t)(rnd() & (getenv("TL_NOFLIP") ? 0x00fc : 0x00ff));  // bits 1:0 are flip_x/flip_y
        vram[i + 1] = (uint16_t)(rnd() & 0x0fff);      // code
    }

    d->rst = 1; d->start = 0; d->h_active = H_VIS;
    d->dx0 = 0; d->dy0 = 0; d->scroll_x0 = 0; d->scroll_y0 = 0;
    d->linescroll_en0 = 0; d->rom_ready0 = 1; d->rd_x = 0;
    d->o_screen_x = 0; d->o_screen_y = 0; d->o_attr = 0; d->o_code = 0;
    serve(); tick(); tick();
    d->rst = 0;
    serve(); tick();

    // ---- DIAGNOSTIC: what was presented on the cycle each slot was written.
    if (getenv("TL_WRITES")) {
        printf("== writes for line 0, layer 0\n");
        d->line_y = 0; d->start = 1; d->rom_ready0 = 1; serve(); tick(); d->start = 0;
        for (int g = 0; g < 2000 && (g < 8 || d->busy); g++) {
            serve();
            // Sample BEFORE the edge: this is what the write will latch.
            int      v  = d->dbg_valid;
            uint32_t xw = d->dbg_xwr;
            uint32_t ra = d->rom_addr0;
            uint8_t  rd = d->rom_data0;
            uint32_t px = d->dbg_pix;
            tick();
            if (v && xw >= 12 && xw <= 20)
                printf("   x_wr=%2u  pix=%x   rom_addr=%06x data=%02x  rom[addr]=%02x%s\n",
                       xw, px, ra, rd, rom[ra % rom.size()],
                       rd == rom[ra % rom.size()] ? "" : "   <-- INCONSISTENT");
        }
        for (int x = 12; x <= 20; x++) {
            Ref r = reference(x, 0);
            printf("   oracle x=%2d pix=%x  rom=%06x nib=%d byte=%02x\n",
                   x, r.pix, (uint32_t)d->o_rom_addr, (int)d->o_nibble_hi,
                   rom[d->o_rom_addr % rom.size()]);
        }
    }

    // ---- DIAGNOSTIC: the ROM address sequence, ours against the oracle's.
    if (getenv("TL_TRACE")) {
        printf("== rom_addr sequence, layer 0, line 0\n");
        std::vector<uint32_t> seen;
        d->line_y = 0; d->start = 1; d->rom_ready0 = 1; serve(); tick(); d->start = 0;
        for (int g = 0; g < 400 && (g < 8 || d->busy); g++) {
            serve();
            seen.push_back((uint32_t)d->rom_addr0);
            tick();
        }
        printf("   ours  :");
        for (int i = 0; i < 24 && i < (int)seen.size(); i++) printf(" %06x", seen[i]);
        printf("\n   oracle:");
        for (int x = 0; x < 22; x++) {
            Ref r = reference(x, 0); (void)r;
            printf(" %06x", (uint32_t)d->o_rom_addr);
        }
        printf("\n");
    }

    printf("== the tile ROM always ready\n");
    long bad_clean = 0;
    for (int y = 0; y < 8; y++) { run_line(y, false); run_line(y, false);
        int b = compare_line(y, "ready"); bad_clean += b;
        printf("   y=%d: %d bad\n", y, b); }
    printf("   %ld pixel(s) differ from the oracle\n", bad_clean);

    printf("== the tile ROM stalling\n");
    long bad_stall = 0;
    for (int y = 8; y < 16; y++) { run_line(y, true); run_line(y, true); bad_stall += compare_line(y, "stall"); }
    printf("   %ld pixel(s) differ from the oracle\n", bad_stall);

    // ---- A LINE THAT FOLLOWS A DIFFERENT LINE.
    //
    // Every case above fetches the same line twice, so anything left in the
    // pipeline from the previous fetch carries the SAME data and cannot be
    // seen. The fetch pipeline's valid chain is only cleared by `rst`, never
    // by `start`, while x_wr restarts at zero -- so whatever was still in
    // flight from the previous line's tail is written over the new line's
    // FIRST pixels. On a real screen that is the leftmost few pixels of every
    // scanline carrying the line above's right-hand edge.
    printf("== a line preceded by a DIFFERENT line\n");
    long bad_prev = 0;
    // The banks alternate on every start and the display reads the one NOT
    // being written, so after two full fetches the visible bank holds the
    // FIRST of them. A third start flips it to the second without needing that
    // fetch to complete.
    for (int y = 20; y < 26; y++) {
        run_line(y + 37, false);      // something else entirely, fetched in full
        run_line(y, false);
        d->start = 1; serve(); tick(); d->start = 0; serve(); tick();
        bad_prev += compare_line(y, "afterprev");
    }
    printf("   %ld pixel(s) differ from the oracle\n", bad_prev);

    if (bad_clean == 0 && bad_stall > 0)
        printf("\n   >> the arithmetic is right and the STALL path is not.\n");
    if (bad_clean > 0)
        printf("\n   >> wrong even with the ROM always ready: not a stall problem.\n");

    printf("\ntb_kaneko_tline: %ld checks, %ld fails\n", checks, fails);
    delete d;
    return fails ? 1 : 0;
}
