// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The SDRAM controller at twice the core clock, with the requesters at the
// core clock behind kaneko_sdram_x2.
//
// The data check alone is not enough here, and that is the point of this
// harness. The adapter guards two hazards, and only one of them shows up as
// wrong data:
//
//   a MISSED acknowledge   the slow side never sees it and hangs — caught by
//                          the timeout, and by reads that never complete
//   a REPEATED request     the controller reads the same address twice. The
//                          data is identical, so nothing is wrong on screen;
//                          it silently costs half the bandwidth the faster
//                          clock was supposed to buy. Caught by comparing
//                          controller-side transactions with slow-side
//                          requests, which must be equal.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <random>
#include "Vkaneko_sdram_x2_harness.h"
#include "verilated.h"

namespace {

constexpr int NP = 11;
// The writing port, DERIVED from NP -- the CALC3 MCU RAM sits last.
constexpr int WRP = NP - 1;
Vkaneko_sdram_x2_harness* d;
long checks = 0, fails = 0;

void half() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

void set_addr(int p, uint32_t a) {
    switch (p) {
      case 0: d->a0 = a; break; case 1: d->a1 = a; break;
      case 2: d->a2 = a; break; case 3: d->a3 = a; break;
      case 4: d->a4 = a; break; case 5: d->a5 = a; break;
      case 6: d->a6 = a; break; case 7: d->a7 = a; break;
      case 8: d->a8 = a; break; case 9: d->a9 = a; break;
      case 10: d->a10 = a; break;
      default: printf("  FATAL: port %d out of range\n", p); std::abort();
    }
}
uint64_t get_dout(int p) {
    switch (p) {
      case 0: return d->d0; case 1: return d->d1; case 2: return d->d2;
      case 3: return d->d3; case 4: return d->d4; case 5: return d->d5;
      case 6: return d->d6; case 7: return d->d7;
      case 8: return d->d8; case 9: return d->d9;
      case 10: return d->d10;
      default: printf("  FATAL: port %d out of range\n", p); std::abort();
    }
    return 0;
}

// One SLOW cycle is two fast ones. Slow-side signals are driven just before a
// slow edge and held across both, which is what a 48 MHz register does.
void slow_tick() { half(); half(); }

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vkaneko_sdram_x2_harness;
    std::mt19937 rng(0x58320000u);   // 'X2'

    // THE CAPTURE DEPTH IS NOT A CONSTANT ACROSS CLOCK RATES.
    //
    // The device is clocked from the controller clock, so the round trip from
    // issuing a READ to the data being stable moves with the frequency. The
    // core already exposes four settings in the OSD for exactly this reason;
    // the right one at 48 MHz is not necessarily the right one at 96. Sweep it
    // rather than assume, which is what the OSD option is for on hardware.
    // DEFAULT 3, not 0. Against sdram_model at 96 MHz only 3 (CL+5) reads
    // correct data -- 0, 1 and 2 fail every check, so a default of 0 meant
    // this harness could never pass and was left out of the gate instead.
    // The BOARD wants 2; that divergence is real, documented in KanekoCALC3.sv,
    // and is the reason the capture depth is an OSD option at all. Sweep
    // with RDLAT=n.
    const int sel = getenv("RDLAT") ? atoi(getenv("RDLAT")) : 3;
    d->rd_lat_sel = sel;
    printf("== capture depth rd_lat_sel = %d\n", sel);

    d->rst_n = 0; d->wr_req = 0; d->wr_be = 3;
    d->pw_we = 0; d->pw_din = 0; d->pw_be = 3;
    for (int p = 0; p < NP; p++) { d->p_req = 0; }
    d->p_req = 0;
    for (int i = 0; i < 40; i++) half();
    d->rst_n = 1;

    long guard = 0;
    while (!d->ready && guard++ < 2000000) half();
    if (!d->ready) { printf("  controller never became ready\n"); return 1; }
    printf("== controller ready after %ld fast cycles\n", guard);

    // ------------------------------------------------------------- fill
    // A known pattern, written through the loader port at the slow rate.
    const int WORDS = 4096;
    std::vector<uint16_t> ref(WORDS);
    for (int i = 0; i < WORDS; i++) ref[i] = (uint16_t)(rng() & 0xffff);

    for (int i = 0; i < WORDS; i++) {
        d->wr_addr = i; d->wr_din = ref[i]; d->wr_req = 1;
        long g = 0;
        while (!d->wr_ack && g++ < 100000) slow_tick();
        if (!d->wr_ack) { printf("  write %d never acked\n", i); fails++; break; }
        d->wr_req = 0;
        slow_tick();
    }
    printf("== wrote %d words\n", WORDS);

    // ------------------------------------- write across the crossing
    // The adapter's write pass-through had NO test: this harness tied s_we to
    // zero and a comment sent the reader to tb_kaneko_sdram, which drives the
    // controller directly and never instantiates this adapter. The core's MCU
    // RAM writes through here, so the untested path was a live one.
    long byte_writes = 0;
    printf("== write pass-through on port %d\n", WRP);
    for (int t = 0; t < 64; t++) {
        const uint32_t a = (uint32_t)(rng() % WORDS);
        const uint16_t v = (uint16_t)(rng() & 0xffff);
        // BYTE writes as well as words, and this is the case that matters.
        //
        // Shogun Warriors verifies RAM before it does anything else: a loop at
        // 0x02222e writes a byte, reads it back and compares, and branches away
        // on a mismatch. MAME counts 262,378 BYTE writes into MCU RAM in the
        // first six seconds. That RAM is in SDRAM in this core, so every one of
        // them crosses here -- and this test only ever wrote whole words, so
        // the path the game leans on hardest was the one path never exercised.
        const int wmode = (int)(rng() % 3);       // 0 word, 1 low byte, 2 high
        const uint8_t be = (wmode == 0) ? 3 : (wmode == 1) ? 1 : 2;
        set_addr(WRP, a);
        d->pw_we = 1; d->pw_din = v; d->pw_be = be;
        d->p_req = (1u << WRP);
        long g = 0;
        while (!((d->p_ack >> WRP) & 1) && g++ < 100000) slow_tick();
        checks++;
        if (!((d->p_ack >> WRP) & 1)) {
            printf("  write to %05x never acked\n", a); fails++; break;
        }
        d->p_req = 0; d->pw_we = 0;
        slow_tick();
        // A byte write leaves the other half alone, so the model has to as
        // well or the readback compares against something that was never
        // written.
        if (be == 3)      ref[a] = v;
        else if (be == 1) ref[a] = (uint16_t)((ref[a] & 0xff00) | (v & 0x00ff));
        else              ref[a] = (uint16_t)((ref[a] & 0x00ff) | (v & 0xff00));

        // Read it back on a DIFFERENT port, so the check cannot be satisfied
        // by a value that never left the writing port's own registers.
        const uint32_t base = a & ~3u;
        set_addr(0, base);
        d->p_req = 1;
        g = 0;
        while (!(d->p_ack & 1) && g++ < 100000) slow_tick();
        if (!(d->p_ack & 1)) { printf("  readback never acked\n"); fails++; break; }
        const uint16_t got = (uint16_t)((get_dout(0) >> (16 * (a & 3))) & 0xffff);
        checks++;
        if (got != ref[a]) {
            if (fails < 10)
                printf("  WRITE LOST addr %05x be %d got %04x want %04x\n",
                       a, be, got, ref[a]);
            fails++;
        }
        if (be != 3) byte_writes++;
        d->p_req = 0;
        slow_tick();

        // AND ON THE SAME PORT, IMMEDIATELY. Reading back on a different port
        // proves the value reached memory; it does not exercise what the game
        // actually does, which is write and read the SAME port back to back --
        // the 68000's shared RAM is one port through one arbiter, and that
        // loop at 0x02222e writes a byte and reads it straight back.
        //
        // The lockstep harness has no crossing in it and passes this test, so
        // a fault here would be invisible everywhere except on the board.
        set_addr(WRP, base);
        d->p_req = (1u << WRP);
        g = 0;
        while (!((d->p_ack >> WRP) & 1) && g++ < 100000) slow_tick();
        checks++;
        if (!((d->p_ack >> WRP) & 1)) {
            printf("  same-port readback never acked\n"); fails++; break;
        }
        const uint16_t got_sp =
            (uint16_t)((get_dout(WRP) >> (16 * (a & 3))) & 0xffff);
        checks++;
        if (got_sp != ref[a]) {
            if (fails < 10)
                printf("  SAME-PORT READBACK addr %05x be %d got %04x want %04x\n",
                       a, be, got_sp, ref[a]);
            fails++;
        }
        d->p_req = 0;
        slow_tick();
    }

    // ------------------------------------------------------- read back
    // Every port reads a distinct span, all at the slow rate, all concurrent.
    long requests = 0;
    uint32_t fast0 = d->fast_acks;
    for (int round = 0; round < 200; round++) {
        uint32_t addr[NP];
        for (int p = 0; p < NP; p++) {
            addr[p] = (uint32_t)((rng() % (WORDS / 4)) * 4);
            set_addr(p, addr[p]);
        }
        d->p_req = (1u << NP) - 1;
        requests += NP;

        uint32_t got_mask = 0;
        long g = 0;
        while (got_mask != ((1u << NP) - 1) && g++ < 200000) {
            slow_tick();
            for (int p = 0; p < NP; p++) {
                if ((got_mask >> p) & 1) continue;
                if ((d->p_ack >> p) & 1) {
                    // Four words per burst, low word first.
                    for (int w = 0; w < 4; w++) {
                        const uint16_t v =
                            (uint16_t)((get_dout(p) >> (16 * w)) & 0xffff);
                        checks++;
                        if (v != ref[addr[p] + w]) {
                            static int shown = 0;
                            if (shown++ < 8)
                                printf("  MISMATCH p%d addr %05x word %d "
                                       "got %04x want %04x\n",
                                       p, addr[p], w, v, ref[addr[p] + w]);
                            fails++;
                        }
                    }
                    got_mask |= (1u << p);
                    d->p_req &= ~(1u << p);
                }
            }
        }
        if (got_mask != ((1u << NP) - 1)) {
            printf("  ROUND %d: ports still waiting, mask %02x — a missed "
                   "acknowledge\n", round, got_mask ^ ((1u << NP) - 1));
            fails++;
            break;
        }
        d->p_req = 0;
        slow_tick();
    }

    const uint32_t fast_n = d->fast_acks - fast0;
    printf("== %ld requests from the slow side, %u transactions at the "
           "controller\n", requests, fast_n);
    printf("   controller acknowledge was held beyond one cycle on %u cycles\n",
           d->ack_width);
    checks++;
    if ((long)fast_n != requests) {
        printf("  FAIL: the adapter let %ld request(s) through more than once "
               "— half the bandwidth of the faster clock is being spent "
               "re-reading\n", (long)fast_n - requests);
        fails++;
    }

    checks++;
    if (d->violations) {
        printf("  FAIL: %u device timing violations, flags %04x\n",
               d->violations, d->v_flags);
        fails++;
    }

    checks++;
    if (!byte_writes) {
        printf("  FAIL no BYTE writes were exercised\n");
        fails++;
    }
    printf("   %ld byte writes crossed\n", byte_writes);

    printf("\ntb_kaneko_sdram_x2: %ld checks, %ld fails, %u violations\n",
           checks, fails, d->violations);
    delete d;
    return fails ? 1 : 0;
}
