// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The OKI M6295 path, driven with the byte sequence Explosive Breaker
// actually writes.
//
// The core reached hardware with the CPU issuing a correct play command 99
// times a second and no sound coming out, so the question this answers is
// narrow and specific: given the exact writes seen on the bus, does jt6295
// start a channel and produce a sample? jt6295 is jotego's and is assumed
// correct; what is under test is our side of it — the write strobe, the
// bank arithmetic and the kaneko_tilerom feeder that answers its ROM reads.
//
// The sequence is from build/bustrace/soundtail.txt, captured on a 300M-tick
// run of the real ROM:
//
//   W 08   stop channel 0
//   W 88   select phrase 0x08
//   W 13   play it on channel 0 at attenuation 3
//   R      status: the game polls this and re-issues while it reads back 0
#include <cstdio>
#include <cstdint>
#include "Vkaneko_oki_harness.h"
#include "verilated.h"

namespace {

Vkaneko_oki_harness* dut;
long checks = 0, fails = 0;
long cen_div = 0;

void tick(int n = 1) {
    for (int i = 0; i < n; i++) {
        // 2 MHz enable against a 48 MHz clock, as Kaneko16.sv generates it.
        dut->cen = (cen_div == 0);
        cen_div  = (cen_div + 1) % 24;
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
    }
}

void write_oki(uint8_t v) {
    dut->oki_din = v;
    dut->oki_we  = 1;
    tick();                 // one-clock strobe, exactly as kaneko_bus makes it
    dut->oki_we  = 0;
    tick(4);
}

void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; printf("  FAIL: %s\n", what); }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vkaneko_oki_harness;

    dut->rst = 1; dut->oki_we = 0; dut->oki_din = 0; dut->ym0_iob_out = 0;
    tick(16);
    dut->rst = 0;
    tick(16);

    // ---------------------------------------------------------------- 1
    // The ROM feeder answers at all. jt6295 cannot start a channel until it
    // has read the six-byte phrase header, and it advances only on rom_ok.
    printf("== rom feeder\n");
    long ok_clocks = 0;
    for (int i = 0; i < 2000; i++) { tick(); if (dut->rom_ok) ok_clocks++; }
    check(ok_clocks > 0, "rom_ok never asserts with a static address");
    printf("  rom_ok high on %ld of 2000 idle clocks\n", ok_clocks);

    // ---------------------------------------------------------------- 2
    // The captured sequence. After it, a channel must be busy: the status
    // read is what the game is waiting on.
    printf("== explbrkr play sequence\n");
    write_oki(0x08);
    write_oki(0x88);
    write_oki(0x13);

    int  first_busy = -1;
    long addr_moves = 0;
    uint32_t last_addr = dut->rom_addr;
    for (int i = 0; i < 200000; i++) {
        tick();
        if (dut->rom_addr != last_addr) { addr_moves++; last_addr = dut->rom_addr; }
        if (first_busy < 0 && (dut->oki_dout & 0x0f)) first_busy = i;
    }
    check(first_busy >= 0, "status never reports a channel busy");
    printf("  status = %02x, first busy at clock %d, rom_addr moved %ld times\n",
           dut->oki_dout & 0xff, first_busy, addr_moves);

    // ---------------------------------------------------------------- 3
    // Sound actually comes out. A started channel that decodes to silence is
    // the same symptom from the speaker.
    printf("== sample output\n");
    long nonzero = 0;
    int16_t peak = 0;
    for (int i = 0; i < 400000; i++) {
        tick();
        // Verilator returns the 14-bit port zero-extended; sign-extend it or
        // every negative sample reads as a large positive one.
        int16_t s = (int16_t)((dut->oki_snd & 0x2000) ? (dut->oki_snd | 0xc000)
                                                     : dut->oki_snd);
        if (s) nonzero++;
        if (s >  peak) peak = s;
        if (-s > peak) peak = -s;
    }
    check(nonzero > 0, "sound output is stuck at zero");
    printf("  %ld non-zero samples of 400000 clocks, peak |%d|\n", nonzero, peak);

    // ---------------------------------------------------------------- 4
    // Bank arithmetic, driven through the same kaneko_oki_bank the core
    // instantiates. The expected column is MAME's rule written out by hand
    // from common_oki_bank_install(0, 0x20000, 0x20000) on a 1 MB region:
    // low 128 KB fixed, bank b at 0x20000*(b+1), and bank 7 aliasing bank 6
    // because max_bank is 7 and MAME fills entry 7 with the last block.
    printf("== bank map\n");
    struct { uint32_t addr; uint8_t bank; uint32_t want; } bt[] = {
        {0x00000, 0, 0x00000},   // below 0x20000: fixed, bank ignored
        {0x00000, 3, 0x00000},
        {0x1ffff, 7, 0x1ffff},
        {0x20000, 0, 0x20000},   // bank 0 -> 0x20000*1
        {0x20000, 1, 0x40000},
        {0x20000, 5, 0xc0000},
        {0x20000, 6, 0xe0000},   // 0x20000*7, the last block
        {0x20000, 7, 0xe0000},   // aliases 6
        {0x31234, 2, 0x71234},
        {0x3ffff, 6, 0xfffff},   // last byte of the last block = end of 1 MB
    };
    dut->probe_max_bank = 7;          // Explosive Breaker's 1 MB region
    for (auto& t : bt) {
        dut->probe_addr = t.addr;
        dut->probe_bank = t.bank;
        dut->eval();
        uint32_t got = dut->probe_region;
        if (got != t.want) {
            printf("  addr %05x bank %d -> %06x, want %06x\n",
                   t.addr, t.bank, got, t.want);
        }
        check(got == t.want, "bank map");
    }
    printf("  bank map matches MAME at %zu points\n", sizeof(bt)/sizeof(bt[0]));

    // max_bank IS PER GAME, so the aliasing must be checked at each game's
    // value and not only Explosive Breaker's. MAME fills every entry from
    // max_bank up to the end with the LAST banked block, so a bank above the
    // limit plays the wrong sample rather than failing — the quietest possible
    // way to get this wrong.
    struct MB { uint8_t max_bank; uint8_t bank; uint32_t want; } mbt[] = {
        // The map is min(bank+1, max_bank) * 0x20000: bank 0 is the FIRST
        // banked block, not the fixed one at the bottom, and everything at or
        // above max_bank aliases the last block.
        //
        // wingforc: 0x80000 region -> max_bank 3, three banked blocks ending
        // at 0x60000. 0x80000 would be past the end of the region.
        {3, 0, 0x20000}, {3, 1, 0x40000}, {3, 2, 0x60000},
        {3, 3, 0x60000}, {3, 7, 0x60000},
        // mgcrystl: 0x40000 region -> max_bank 1, ONE banked block at 0x20000.
        {1, 0, 0x20000}, {1, 1, 0x20000}, {1, 7, 0x20000},
    };
    for (auto& t : mbt) {
        dut->probe_addr     = 0x20000;
        dut->probe_max_bank = t.max_bank;
        dut->probe_bank     = t.bank;
        dut->eval();
        uint32_t got = dut->probe_region;
        if (got != t.want)
            printf("  max_bank %d bank %d -> %06x, want %06x\n",
                   t.max_bank, t.bank, got, t.want);
        check(got == t.want, "per-game bank limit");
    }
    printf("  per-game bank limits check out for wingforc (3) and mgcrystl (1)\n");

    printf("\ntb_kaneko_oki: %ld checks, %ld fails\n", checks, fails);
    delete dut;
    return fails ? 1 : 0;
}
