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
    d->cpu_rd = 1;                // claim the shared read port
    tick();                       // address registered, array read
    d->cpu_rd = 0;
    tick();                       // data in the video register
    tick();                       // CPU copies it, read-back mux registered
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
    // The VIEW2 read port is now shared: cpu_rd asks for the cycle. Held low
    // except where a CPU read is being made.
    d->cpu_rd = 0;
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
    // THE CONTRACT OF THE SHARED PORT.
    //
    // Before the ports were shared, both sides read different addresses in the
    // same cycle and both got their own answer -- the duplication gave that
    // for free. It is now bought with a stolen cycle, and the contract is:
    //
    //   the CPU gets its answer, always;
    //   the video side's registered data is WRONG the cycle after a steal;
    //   vid_stall marks exactly that cycle so the fetch does not sample it;
    //   with no steal, the video side is undisturbed.
    //
    // Both halves are checked. A vid_stall that were always low would pass the
    // first and corrupt the picture, which is the failure this is guarding.
    printf("== the shared read port: CPU answered, video stall flagged\n");
    {
        for (int i = 0; i < 64; i++) {
            cpu_write(0, addr_of(V0, i * 2 + 0), (uint16_t)(0x0100 + i));
            cpu_write(0, addr_of(V0, i * 2 + 1), (uint16_t)(0x0200 + i));
        }
        for (int i = 0; i < 64; i++) {
            int other = 63 - i;
            // No steal: the video side reads undisturbed and is NOT stalled.
            d->c0_t0_addr = other; d->cpu_rd = 0;
            d->we_vram0 = 0;
            tick();
            check(d->vid_stall == 0, "no steal, no stall");
            tick();
            check(d->c0_t0_q == (uint32_t)(((0x0200 + other) << 16) | (0x0100 + other)),
                  "video side undisturbed when the CPU is quiet");

            // Steal: the CPU gets its own address, and the cycle after is
            // flagged so the fetch ignores what it sees.
            d->cpu_addr = addr_of(V0, i * 2); d->cpu_rd = 1;
            tick();
            d->cpu_rd = 0;
            check(d->vid_stall == 1, "the stolen cycle is flagged");
            tick();
            check(d->vid_stall == 0, "the stall lasts exactly one cycle");
            tick();
            check(d->q_vram0 == (uint16_t)(0x0100 + i),
                  "CPU got its own address from the shared port");
        }
    }

    // ------------------------------------------------------------------ 5b
    // THE VIDEO SIDE MUST NOT LOSE A FETCH.
    //
    // Section 5 checks that the CPU gets its answer and that the steal is
    // flagged. It does NOT check the thing the video side actually needs,
    // which is that every address it presents comes back to it exactly once.
    // That gap shipped: Magical Crystals reads VIEW2 about 724 times a frame
    // against Explosive Breaker's 1.4, and on hardware its tilemap came back
    // in corrupted horizontal bands while every other game looked right.
    //
    // This models the real consumer. kaneko_tmap_line freezes on vid_stall and
    // otherwise advances, so a fetcher is simulated that does exactly that:
    //
    //   holds its address while vid_stall is high,
    //   advances to the next address when it is low,
    //   and samples the data register one cycle after presenting an address.
    //
    // Then every address it walked must have yielded that address's contents.
    // A stall asserted one cycle too late lets the fetcher step past a read
    // that was given to the CPU instead, and one tile fetch is lost per steal.
    printf("== the video side loses no fetch across a steal\n");
    {
        for (int i = 0; i < 128; i++) {
            cpu_write(0, addr_of(V0, i * 2 + 0), (uint16_t)(0x1000 + i));
            cpu_write(0, addr_of(V0, i * 2 + 1), (uint16_t)(0x2000 + i));
        }
        d->cpu_rd = 0; d->we_vram0 = 0;

        // Walk the video address forward, stealing on a fixed pattern so the
        // steal lands at every phase relative to the fetch.
        // period 0 means NEVER steal. It validates the model itself: if the
        // expected-data bookkeeping here is wrong, this case fails too and the
        // failures below say nothing about the RTL.
        for (int period = 0; period <= 5; period++) {
            if (period == 1) continue;
            int  idx = 0;               // address the fetcher is presenting
            long got = 0, bad = 0;
            d->c0_t0_addr = idx;

            for (int t = 0; t < 600; t++) {
                const bool steal = period && ((t % period) == 0) && (t > 0);
                d->cpu_addr = addr_of(V0, (t * 7) & 0xfe);
                d->cpu_rd   = steal;
                // A stolen cycle reads the CPU's address, so whatever the
                // fetcher presented this cycle yields nothing for it.
                // A stolen cycle reads the CPU's address instead, so the
                // fetcher gets nothing for what it presented.
                const int due = steal ? -1 : idx;
                tick();
                const bool stalled = d->vid_stall != 0;

                if (due >= 0 && !stalled) {
                    const uint32_t want =
                        (uint32_t)(((0x2000 + due) << 16) | (0x1000 + due));
                    if (d->c0_t0_q != want) bad++;
                    got++;
                }
                // The line fetcher holds its address while stalled.
                if (!stalled) idx = (idx + 1) & 0x7f;
                d->c0_t0_addr = idx;
            }
            check(bad == 0, "the video side got data for an address it did not present");
            if (bad) printf("    period=%d: %ld of %ld fetches wrong\n", period, bad, got);
            check(got > 100, "the fetcher made too little progress to be a test");
        }
        d->cpu_rd = 0;
    }

    // ------------------------------------------------------------------ 5c
    // THE READ-BACK LATENCY IS A CONTRACT, AND THE BUS HAS TO HONOUR IT.
    //
    // Sharing the port put three registers between cpu_rd and q_vram0: the
    // array reads into the video register, the CPU's copy is taken from that
    // register a cycle later, and the read-back mux registers it again.
    // kaneko_bus was still answering DTACK on the cycle it raised vram_rd,
    // which handed the 68000 whatever the previous VIEW2 read left behind.
    //
    // Explosive Breaker reads VIEW2 1.4 times a frame and never showed it.
    // Magical Crystals reads it 724 times a frame and read-modify-writes its
    // tilemap, so it wrote the stale value back and the picture came apart in
    // horizontal bands on hardware.
    //
    // This measures the latency rather than assuming it, and prints it, so
    // that if it ever changes the number to put in kaneko_bus's S_VRAM wait is
    // right here instead of being rediscovered.
    printf("== the CPU read-back latency, which kaneko_bus must wait out\n");
    {
        cpu_write(0, addr_of(V0, 0x40), 0xfeed);
        cpu_write(0, addr_of(V0, 0x41), 0x0bad);   // a neighbour, to catch off-by-one
        // Prime the pipeline with a DIFFERENT address so a stale answer is
        // distinguishable from the right one.
        (void)cpu_read(0, addr_of(V0, 0x41));

        d->cpu_addr = addr_of(V0, 0x40);
        d->cpu_rd   = 1;
        tick();                       // cycle 1: cpu_rd high
        d->cpu_rd   = 0;
        int valid_at = -1;
        for (int c = 2; c <= 8; c++) {
            tick();
            if (valid_at < 0 && d->q_vram0 == 0xfeed) valid_at = c;
        }
        printf("  q_vram0 valid %d cycles after cpu_rd\n", valid_at);
        check(valid_at > 0, "the CPU read-back never became valid at all");
        // kaneko_bus spends vwait=2 in S_VRAM and then one more edge reaching
        // S_DONE, so it samples on cycle 4. Anything later than that is a bug
        // in the RTL or a wait that needs lengthening -- and this says which.
        check(valid_at <= 4,
              "read-back is slower than kaneko_bus's S_VRAM wait -- raise vwait");
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
