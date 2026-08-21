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

constexpr int NP = 8;
Vkaneko_sdram_x2_harness* d;
long checks = 0, fails = 0;

void half() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

void set_addr(int p, uint32_t a) {
    switch (p) {
      case 0: d->a0 = a; break; case 1: d->a1 = a; break;
      case 2: d->a2 = a; break; case 3: d->a3 = a; break;
      case 4: d->a4 = a; break; case 5: d->a5 = a; break;
      case 6: d->a6 = a; break; case 7: d->a7 = a; break;
      default: printf("  FATAL: port %d out of range\n", p); std::abort();
    }
}
uint64_t get_dout(int p) {
    switch (p) {
      case 0: return d->d0; case 1: return d->d1; case 2: return d->d2;
      case 3: return d->d3; case 4: return d->d4; case 5: return d->d5;
      case 6: return d->d6; case 7: return d->d7;
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
    const int sel = getenv("RDLAT") ? atoi(getenv("RDLAT")) : 0;
    d->rd_lat_sel = sel;
    printf("== capture depth rd_lat_sel = %d\n", sel);

    d->rst_n = 0; d->wr_req = 0; d->wr_be = 3;
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
                            if (fails < 10)
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

    printf("\ntb_kaneko_sdram_x2: %ld checks, %ld fails, %u violations\n",
           checks, fails, d->violations);
    delete d;
    return fails ? 1 : 0;
}
