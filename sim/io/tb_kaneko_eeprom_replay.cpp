// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Replay MAME's own EEPROM sequence against kaneko_eeprom93c46.
//
// tb_kaneko_eeprom.cpp checks the protocol as documented. This checks it
// against what the game actually does, which is a different question: a model
// can implement the datasheet correctly and still disagree with the part the
// game was written for. Every value the game reads back from port A is
// compared, so a dummy bit in the wrong place or a write that should have been
// refused shows up immediately.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include "Vkaneko_eeprom93c46.h"
#include "verilated.h"

static Vkaneko_eeprom93c46* dut;

static uint64_t ticks = 0;
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); ticks++; }
static void settle() { for (int i = 0; i < 3; i++) tick(); }

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    const char* path = (argc > 1) ? argv[1] : "build/bustrace/ee_stim.txt";
    FILE* f = std::fopen(path, "r");
    if (!f) { std::fprintf(stderr, "cannot open %s\n", path); return 2; }

    dut = new Vkaneko_eeprom93c46;
    dut->rst = 1; dut->cs = 0; dut->sk = 0; dut->di = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->rst = 0; settle();

    // The DUT clock is advanced by the gap between events so the busy window
    // behaves as it does on the machine being copied. The cap only exists to
    // bound a pathological gap; it must exceed the longest programming time,
    // which is erase-all at 8000 us — 384,000 ticks at 48 MHz. It was 8,000
    // ticks, which expired every busy period early and reported ready where
    // MAME still said busy.
    const double  CLK_MHZ  = 48.0;
    const uint64_t GAP_CAP = 500000;

    // ABSOLUTE TIME, NOT PER-EVENT GAPS
    //
    // Advancing by the gap between events looks equivalent and is not: each
    // event also costs settle() ticks, so the DUT creeps ahead of the machine
    // it is copying. Over nine thousand events that came to about 600 us of
    // drift, which expired every 1750 us programming timer roughly 190 us
    // early and reported ready while MAME was still busy — 414 mismatches that
    // looked like a modelling error in the EEPROM rather than in the harness.
    //
    // Clocking up to an absolute target derived from the timestamp is
    // self-correcting: whatever settle() spends is simply part of the budget.
    char kind; double t; int cs, sk, di, want;
    double   t0     = 0.0;
    bool     first  = true;
    uint64_t applied = 0, checked = 0, fails = 0;
    uint64_t first_fail = 0;
    char line[128];

    while (std::fgets(line, sizeof line, f)) {
        const int got = std::sscanf(line, "%c %lf %d %d %d %d",
                                    &kind, &t, &cs, &sk, &di, &want);
        if (got < 5) continue;
        if (first) { t0 = t; first = false; }
        const uint64_t target = (uint64_t)((t - t0) * CLK_MHZ);
        uint64_t adv = (target > ticks) ? (target - ticks) : 0;
        if (adv > GAP_CAP) adv = GAP_CAP;
        // tick() counts; adding adv here as well double-counted every
        // advance, so the DUT clock ran at half machine time and every
        // programming timer took twice as long to expire.
        for (uint64_t i = 0; i < adv; i++) tick();

        dut->cs = cs; dut->sk = sk; dut->di = di;
        settle();
        applied++;
        if (kind == 'R') {
            checked++;
            if (dut->do_out != want) {
                if (!fails) {
                    first_fail = checked;
                    std::printf("  at t=%.1f us, %llu ticks advanced "
                                "(%.1f us of DUT clock)\n",
                                t, (unsigned long long)ticks, ticks / 48.0);
                    std::printf("  dut state=%d busy=%u ticks wen=%d "
                                "lastcmd=%02x (op %d addr %d)\n",
                                dut->dbg_state, (unsigned)dut->dbg_busy, dut->dbg_wen,
                                dut->dbg_cmd, (dut->dbg_cmd >> 6) & 3,
                                dut->dbg_cmd & 0x3f);
                    std::printf("  first mismatch at checked read %llu: "
                                "cs=%d sk=%d di=%d  got %d want %d\n",
                                (unsigned long long)checked, cs, sk, di,
                                dut->do_out, want);
                }
                fails++;
            }
        }
    }
    std::fclose(f);

    std::printf("kaneko_eeprom_replay: events=%llu checked=%llu fails=%llu",
                (unsigned long long)applied, (unsigned long long)checked,
                (unsigned long long)fails);
    if (fails) std::printf(" (first at %llu)", (unsigned long long)first_fail);
    std::printf("\n");
    delete dut;
    return fails ? 1 : 0;
}
