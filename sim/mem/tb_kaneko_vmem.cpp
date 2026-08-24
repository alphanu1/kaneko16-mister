// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The memories the CPU writes and the video path reads.
//
// WHY THIS EXISTS NOW
//
// kaneko_vmem had no test. It is the most safety-critical memory in the core --
// every tilemap, every sprite and the whole palette come out of it -- and it is
// not in the frame gate either, which instantiates the renderer against a MAME
// VRAM dump rather than against this module. So the CPU read-back path, which
// the games use constantly, was verified by nothing but four games appearing to
// work.
//
// It is being written because the module has to CHANGE. Its arrays are read at
// two different addresses in the same cycle -- once for the CPU read-back and
// once for the video fetch -- which an M10K cannot do, so Quartus duplicates
// every one of them. That duplication costs about 32 blocks of a device that is
// at 94% and it is what stops Tier 2 fitting. Sharing the port means stealing a
// cycle from the video side, and nothing should touch this module until there
// is something to catch a mistake.
//
// WHAT IT CHECKS
//
//   1. Every window stores and returns what was written, byte enables included.
//   2. The four VIEW2 quarters are distinct spaces. Layer 1 is the FIRST block
//      and layer 0 the second, which is the reversal in kaneko_tmap.cpp that
//      the header warns about and is exactly the kind of thing a rewrite gets
//      backwards.
//   3. A tile entry read by the video side is {code, attr} in one 32-bit word.
//   4. The CPU and video sides see the same memory: write through the CPU port,
//      read through the video port, and vice versa where the port allows.
//   5. Simultaneous access at DIFFERENT addresses returns the right answer to
//      each side. This is the property the duplication currently provides for
//      free and the one a shared port has to preserve.
#include <cstdio>
#include <cstdint>
#include <random>
#include <map>
#include "Vkaneko_vmem.h"
#include "verilated.h"

namespace {

Vkaneko_vmem* d;
long checks = 0, fails = 0;

void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; if (fails <= 15) printf("  FAIL: %s\n", what); }
}

void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

// The window a CPU address selects, from the header: the VIEW2 window is
// 0x4000 bytes with vram_1 first. cpu_addr is a WORD address, so bits [12:11]
// pick the quarter.
enum Quarter { V1 = 0, V0 = 1, S1 = 2, S0 = 3 };

void cpu_write(int chip, uint16_t waddr, uint16_t v, bool hi = true, bool lo = true) {
    d->cpu_addr = waddr;
    d->cpu_din  = v;
    d->uds = hi; d->lds = lo;
    d->we_vram0 = (chip == 0); d->we_vram1 = (chip == 1);
    d->we_spr = 0; d->we_pal = 0;
    tick();
    d->we_vram0 = d->we_vram1 = 0;
}

uint16_t cpu_read(int chip, uint16_t waddr) {
    d->cpu_addr = waddr;
    d->we_vram0 = d->we_vram1 = d->we_spr = d->we_pal = 0;
    tick();                       // address registered, array read
    tick();                       // read-back mux registered
    return chip == 0 ? d->q_vram0 : d->q_vram1;
}

void spr_write(uint16_t waddr, uint16_t v, bool hi = true, bool lo = true) {
    d->cpu_addr = waddr; d->cpu_din = v; d->uds = hi; d->lds = lo;
    d->we_spr = 1; tick(); d->we_spr = 0;
}
void pal_write(uint16_t waddr, uint16_t v, bool hi = true, bool lo = true) {
    d->cpu_addr = waddr; d->cpu_din = v; d->uds = hi; d->lds = lo;
    d->we_pal = 1; tick(); d->we_pal = 0;
}

// A word address inside a quarter: quarter in [12:11], index below.
uint16_t addr_of(Quarter q, uint16_t idx) { return (uint16_t)((q << 11) | idx); }

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vkaneko_vmem;
    d->cpu_addr = 0; d->cpu_din = 0;
    d->we_vram0 = d->we_vram1 = d->we_spr = d->we_pal = 0;
    d->uds = 1; d->lds = 1;
    d->c0_t0_addr = d->c0_t1_addr = d->c1_t0_addr = d->c1_t1_addr = 0;
    d->c0_s0_addr = d->c0_s1_addr = d->c1_s0_addr = d->c1_s1_addr = 0;
    d->spr_addr = 0; d->pal_addr = 0;
    tick(); tick();

    // ------------------------------------------------------------------ 1
    printf("== sprite RAM and palette store and return\n");
    {
        std::mt19937 r(1u);
        std::map<uint16_t, uint16_t> sref, pref;
        for (int i = 0; i < 3000; i++) {
            uint16_t a = r() & 0x0fff, v = (uint16_t)r();
            spr_write(a, v); sref[a] = v;
        }
        for (int i = 0; i < 2000; i++) {
            uint16_t a = r() & 0x07ff, v = (uint16_t)r();
            pal_write(a, v); pref[a] = v;
        }
        for (auto& kv : sref) {
            d->spr_addr = kv.first; tick();
            check(d->spr_q == kv.second, "sprite RAM via the video port");
        }
        for (auto& kv : pref) {
            d->pal_addr = kv.first; tick();
            check(d->pal_q == kv.second, "palette via the video port");
        }
    }

    // ------------------------------------------------------------------ 2
    // Byte enables. The very first store the boot code makes is a byte write,
    // per the module header, so a broken enable breaks boot rather than
    // something subtle.
    printf("== byte enables leave the other half alone\n");
    {
        spr_write(0x100, 0xaa55);
        spr_write(0x100, 0x1234, true, false);      // high byte only
        d->spr_addr = 0x100; tick();
        check(d->spr_q == 0x1255, "UDS-only write kept the low byte");
        spr_write(0x100, 0x9876, false, true);      // low byte only
        d->spr_addr = 0x100; tick();
        check(d->spr_q == 0x1276, "LDS-only write kept the high byte");
    }

    // ------------------------------------------------------------------ 3
    // The four VIEW2 quarters are separate spaces, and layer 1 is FIRST.
    printf("== the four VIEW2 quarters do not alias, layer 1 first\n");
    for (int chip = 0; chip < 2; chip++) {
        cpu_write(chip, addr_of(V1, 0x10), 0x1111);
        cpu_write(chip, addr_of(V0, 0x10), 0x2222);
        cpu_write(chip, addr_of(S1, 0x10), 0x3333);
        cpu_write(chip, addr_of(S0, 0x10), 0x4444);
        check(cpu_read(chip, addr_of(V1, 0x10)) == 0x1111, "quarter V1 distinct");
        check(cpu_read(chip, addr_of(V0, 0x10)) == 0x2222, "quarter V0 distinct");
        check(cpu_read(chip, addr_of(S1, 0x10)) == 0x3333, "quarter S1 distinct");
        check(cpu_read(chip, addr_of(S0, 0x10)) == 0x4444, "quarter S0 distinct");
    }

    // ------------------------------------------------------------------ 4
    // A tile entry is attr then code at adjacent words, and the video side
    // wants both in one 32-bit read as {code, attr}.
    printf("== a tile entry reads as {code, attr} in one word\n");
    {
        // Within a quarter the tile index is the word address >> 1, with bit 0
        // choosing attr or code.
        cpu_write(0, addr_of(V0, 0x20 * 2 + 0), 0xa11e);   // attr
        cpu_write(0, addr_of(V0, 0x20 * 2 + 1), 0xc0de);   // code
        d->c0_t0_addr = 0x20; tick(); tick();
        check(d->c0_t0_q == 0xc0dea11e, "c0 layer0 tile is {code, attr}");

        cpu_write(1, addr_of(V1, 0x33 * 2 + 0), 0xbeef);
        cpu_write(1, addr_of(V1, 0x33 * 2 + 1), 0xf00d);
        d->c1_t1_addr = 0x33; tick(); tick();
        check(d->c1_t1_q == 0xf00dbeef, "c1 layer1 tile is {code, attr}");
    }

    printf("== scroll words reach the video side\n");
    {
        cpu_write(0, addr_of(S0, 0x55), 0x5a5a);
        d->c0_s0_addr = 0x55; tick(); tick();
        check(d->c0_s0_q == 0x5a5a, "c0 layer0 scroll");
        cpu_write(1, addr_of(S1, 0x77), 0xa5a5);
        d->c1_s1_addr = 0x77; tick(); tick();
        check(d->c1_s1_q == 0xa5a5, "c1 layer1 scroll");
    }

    // ------------------------------------------------------------------ 5
    // THE PROPERTY A SHARED READ PORT HAS TO PRESERVE.
    //
    // Both sides read the same array at DIFFERENT addresses in the same cycle
    // and both must get their own answer. The duplication provides this for
    // free today; a shared port has to arrange it, and this is the check that
    // will fail if it does not.
    printf("== both sides read different addresses at once\n");
    {
        for (int i = 0; i < 64; i++) {
            cpu_write(0, addr_of(V0, i * 2 + 0), (uint16_t)(0x0100 + i));
            cpu_write(0, addr_of(V0, i * 2 + 1), (uint16_t)(0x0200 + i));
        }
        for (int i = 0; i < 64; i++) {
            int other = 63 - i;
            d->c0_t0_addr = other;               // video reads one entry
            d->cpu_addr   = addr_of(V0, i * 2);  // CPU reads a different one
            d->we_vram0 = 0;
            tick(); tick();
            uint32_t vq = d->c0_t0_q;
            uint16_t cq = d->q_vram0;
            check(vq == (uint32_t)(((0x0200 + other) << 16) | (0x0100 + other)),
                  "video side got its own address");
            check(cq == (uint16_t)(0x0100 + i),
                  "CPU side got its own address");
        }
    }

    // ------------------------------------------------------------------ 6
    printf("== a large random pass over one chip\n");
    {
        std::mt19937 r(99u);
        std::map<uint16_t, uint16_t> ref;
        for (int i = 0; i < 8000; i++) {
            uint16_t a = r() & 0x1fff, v = (uint16_t)r();
            cpu_write(0, a, v); ref[a] = v;
        }
        for (auto& kv : ref)
            check(cpu_read(0, kv.first) == kv.second, "random read-back");
    }

    printf("\ntb_kaneko_vmem: %ld checks, %ld fails\n", checks, fails);
    delete d;
    return fails ? 1 : 0;
}
