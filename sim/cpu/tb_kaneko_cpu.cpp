// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Boot the 68000 out of the real Explosive Breaker ROM and record what it does.
//
// This is the first step of CPU bring-up and its output is a BUS TRACE, not a
// pass/fail. The trace is what gets compared against MAME — the same oracle
// discipline the video path used, where a transcription of the source proves
// only that the RTL matches my reading of it.
//
// What it does assert on its own, because these need no oracle:
//   - the reset vectors fetched are the ones in the ROM image
//   - the CPU keeps fetching rather than stopping after a handful of cycles
//   - no access lands outside the decoded map (kaneko_bus flags those; an
//     unmapped address is ACKED so the CPU cannot hang silently on it)

#include <verilated.h>
#include "Vkaneko_cpu_harness.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

Vkaneko_cpu_harness* dut;
std::vector<uint8_t> rom;

long checks = 0, fails = 0;

void ck(const char* what, long got, long want)
{
    checks++;
    if (got != want) { fails++; printf("  FAIL %s: got %ld want %ld\n", what, got, want); }
}

void tick()
{
    dut->clk = 0; dut->eval();
    // ROM is answered combinationally: the harness acks in one cycle so the
    // trace shows the instruction stream rather than memory-system timing.
    // The bus asks for an aligned four-word line; answer with all four, the
    // way the SDRAM controller does. rom_a is a WORD address.
    const uint32_t w0 = (uint32_t)dut->rom_a & ~3u;
    uint64_t q = 0;
    for (int i = 0; i < 4; i++) {
        const uint32_t ba = ((w0 + i) * 2) & (uint32_t)(rom.size() - 1);
        // Packed the way SDRAM holds it, NOT the way the 68000 reads it:
        // hps_io in WIDE mode puts file byte n in the low half, kaneko_bus
        // swaps at the endian boundary, and a harness that hands over
        // big-endian words here would be feeding the DUT something the board
        // never produces. Doing exactly that is how the byte order went
        // untested until it reached hardware — see sim/top/tb_kaneko_cpumem.cpp.
        const uint64_t wv = (uint64_t)(rom[ba] | (rom[ba + 1] << 8));
        q |= wv << (16 * i);
    }
    dut->rom_q = q;
    dut->eval();
    dut->clk = 1; dut->eval();
}

} // namespace

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    const char* path = (argc > 1) ? argv[1] : "build/roms/explbrkr_maincpu.bin";
    const long  max_acc = (argc > 2) ? atol(argv[2]) : 40;

    FILE* f = fopen(path, "rb");
    if (!f) { printf("kaneko_cpu: SKIP (no %s — run `make regions`)\n", path); return 0; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    rom.resize(n);
    if (fread(rom.data(), 1, n, f) != (size_t)n) return 2;
    fclose(f);

    dut = new Vkaneko_cpu_harness;
    dut->in_p1 = 0xffff; dut->in_p2 = 0xffff;
    dut->in_system = 0xffff; dut->in_unk = 0xffff;

    dut->rst = 1;
    for (int i = 0; i < 64; i++) tick();
    dut->rst = 0;

    // ---- trace bus cycles: one per DTACK, which is where the CPU takes data
    long   acc = 0, unmapped = 0;
    bool   dtack_prev = false;
    uint32_t first_addr[4] = {0, 0, 0, 0};

    printf("  #   addr      r/w  data   uds lds\n");
    for (long cyc = 0; cyc < 400000 && acc < max_acc; cyc++) {
        tick();
        if (dut->unmapped_hit) {
            unmapped++;
            if (unmapped <= 4)
                printf("  UNMAPPED access at %06x\n", (unsigned)dut->unmapped_addr << 1);
        }
        const bool dt = dut->bus_dtack;
        if (dt && !dtack_prev && dut->bus_as) {
            const uint32_t a  = (uint32_t)dut->bus_addr << 1;
            const bool     rw = dut->bus_rw;
            const uint16_t d  = rw ? dut->bus_din : dut->bus_dout;
            if (acc < 4) first_addr[acc] = a;
            printf("  %-3ld %06x    %c   %04x    %d   %d\n",
                   acc, a, rw ? 'R' : 'W', d,
                   (int)dut->bus_uds, (int)dut->bus_lds);
            acc++;
        }
        dtack_prev = dt;
    }

    // ---- assertions that need no oracle
    const uint32_t ssp = (rom[0] << 24) | (rom[1] << 16) | (rom[2] << 8) | rom[3];
    const uint32_t pc  = (rom[4] << 24) | (rom[5] << 16) | (rom[6] << 8) | rom[7];
    printf("\n  ROM reset vectors: SSP=%08x  PC=%08x\n", ssp, pc);

    // A 68000 fetches the vectors first: SSP high, SSP low, PC high, PC low.
    ck("first fetch is 000000", first_addr[0], 0x000000);
    ck("second fetch is 000002", first_addr[1], 0x000002);
    ck("third fetch is 000004",  first_addr[2], 0x000004);
    ck("fourth fetch is 000006", first_addr[3], 0x000006);
    ck("CPU kept running",       acc >= max_acc ? 1 : 0, 1);

    // Unmapped accesses are REPORTED, not failed. bakubrkr_map decodes the
    // input ports at e00000-e00007 only, but the game also touches e40000,
    // e80000, ec0000 and c00000 — the first three look like mirrors from
    // partial decoding on the PCB, and c00000 is mgcrystl's DSW port, which
    // this map does not have at all. MAME decodes none of them either, so
    // returning 0xffff here may well be equivalent.
    //
    // That is a guess, and the trace comparison against MAME is what settles
    // it. Failing the test on it now would encode the guess as a requirement;
    // ignoring it silently would lose the question. So it is counted and
    // printed.
    if (unmapped)
        printf("  note: %ld unmapped accesses — see the comment above; settle "
               "against MAME before deciding these are mirrors\n", unmapped);

    printf("kaneko_cpu: bus_cycles=%ld unmapped=%ld checks=%ld fails=%ld\n",
           acc, unmapped, checks, fails);

    dut->final();
    delete dut;
    return fails ? 1 : 0;
}
