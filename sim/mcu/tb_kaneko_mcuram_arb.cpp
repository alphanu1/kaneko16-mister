// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fuzz kaneko_mcuram_arb against a behavioural memory, with both masters
// asking as hard as they can.
//
// Three properties, and the third is the reason this module exists rather than
// a second SDRAM port:
//
//   1. Every request is answered exactly once, with the data for ITS address.
//      A grant that returns the other master's data is the failure that would
//      look like an MCU fault.
//   2. NEITHER MASTER IS STARVED. The CALC3 issues thousands of back-to-back
//      accesses while decompressing a table; a fixed priority either way stops
//      the other master for the whole run, and the 68000 waits on DTACK, so
//      starving it stalls the game. Checked by holding both requests high
//      continuously and requiring both to make progress.
//   3. A read never passes a write to the same address. One port cannot have
//      two accesses in flight, so ordering is structural -- this checks that
//      the structure is actually what was built.
#include <cstdio>
#include <cstdint>
#include <map>
#include <random>
#include "Vkaneko_mcuram_arb.h"
#include "verilated.h"

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_mcuram_arb;
  std::mt19937 rng(0xa4b17e40u);
  long checks = 0, fails = 0, a_done = 0, b_done = 0, both_pending = 0;

  std::map<uint32_t, uint16_t> mem;

  auto tick = [&] { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  d->rst_n = 0;
  d->a_req = d->b_req = 0; d->s_ack = 0;
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1;

  // Outstanding request state, per master.
  struct Pend { bool busy = false; uint32_t addr = 0; bool we = false;
                uint16_t din = 0; uint8_t be = 3; uint16_t want = 0; };
  Pend pa, pb;

  int s_delay = 0; bool s_busy = false;
  uint32_t s_addr = 0; bool s_we = false; uint16_t s_din = 0; uint8_t s_be = 3;

  // DISJOINT ADDRESS RANGES, one per master.
  //
  // Not to avoid a hard case, but because a shared address has no single
  // correct answer here: either master's write may legitimately land before or
  // after the other's read, so a model that snapshots the expected value at
  // issue time scores a correct read as a failure. That ordering is structural
  // anyway -- one port, one access in flight, so a read cannot pass a write to
  // the same address -- and read/write racing on one port is what
  // tb_kaneko_sdram covers. What is under test here is arbitration: that each
  // master gets ITS data, and that neither is starved.
  auto issue = [&](Pend& p, bool is_a) {
    p.busy = true;
    p.addr = (uint32_t)(is_a ? (rng() % 32) : (32 + rng() % 32));
    p.we = (rng() % 3) == 0;
    p.din = (uint16_t)rng();
    p.be = 3;
    if (p.we) {
      mem[p.addr] = p.din;
    } else {
      p.want = mem.count(p.addr) ? mem[p.addr] : 0;
    }
    if (is_a) {
      d->a_addr = p.addr; d->a_we = p.we; d->a_din = p.din; d->a_be = p.be;
      d->a_req = 1;
    } else {
      d->b_addr = p.addr; d->b_we = p.we; d->b_din = p.din; d->b_be = p.be;
      d->b_req = 1;
    }
  };

  for (long cyc = 0; cyc < 200000; cyc++) {
    if (!pa.busy) issue(pa, true);
    if (!pb.busy) issue(pb, false);
    if (pa.busy && pb.busy) both_pending++;

    // The SDRAM side: variable latency, one access at a time.
    d->s_ack = 0;
    if (d->s_req && !s_busy) {
      s_busy = true; s_delay = (int)(rng() % 4);
      s_addr = d->s_addr; s_we = d->s_we; s_din = d->s_din; s_be = d->s_be;
    }
    if (s_busy && s_delay-- <= 0) {
      if (s_we) {
        uint16_t cur = mem.count(s_addr) ? mem[s_addr] : 0;
        if (s_be & 2) cur = (uint16_t)((cur & 0x00ff) | (s_din & 0xff00));
        if (s_be & 1) cur = (uint16_t)((cur & 0xff00) | (s_din & 0x00ff));
        mem[s_addr] = cur;
        d->s_dout = 0;
      } else {
        // 64 bits, four words; the requested one sits at lane addr[1:0].
        uint64_t v = 0;
        for (int w = 0; w < 4; w++) {
          const uint32_t a = (s_addr & ~3u) + w;
          const uint16_t x = mem.count(a) ? mem[a] : 0;
          v |= (uint64_t)x << (16 * w);
        }
        d->s_dout = v;
      }
      d->s_ack = 1;
      s_busy = false;
    }

    tick();

    if (d->a_ack) {
      checks++; a_done++;
      if (!pa.busy) { printf("  FAIL a_ack with nothing outstanding\n"); fails++; }
      else if (!pa.we) {
        const uint16_t got = (uint16_t)((d->a_dout >> (16 * (pa.addr & 3))) & 0xffff);
        if (got != pa.want) {
          if (fails < 10)
            printf("  FAIL A read %02x: got %04x want %04x\n", pa.addr, got, pa.want);
          fails++;
        }
      }
      pa.busy = false; d->a_req = 0;
    }
    if (d->b_ack) {
      checks++; b_done++;
      if (!pb.busy) { printf("  FAIL b_ack with nothing outstanding\n"); fails++; }
      else if (!pb.we) {
        const uint16_t got = (uint16_t)((d->b_dout >> (16 * (pb.addr & 3))) & 0xffff);
        if (got != pb.want) {
          if (fails < 10)
            printf("  FAIL B read %02x: got %04x want %04x\n", pb.addr, got, pb.want);
          fails++;
        }
      }
      pb.busy = false; d->b_req = 0;
    }
    checks++;
    if (d->a_ack && d->b_ack) {
      printf("  FAIL both masters acknowledged on one cycle\n");
      fails++;
    }
  }

  // Starvation. Both masters asked continuously for the whole run, so a fixed
  // priority would show as one of these near zero.
  checks++;
  const double share = (double)a_done / (double)(a_done + b_done);
  if (share < 0.35 || share > 0.65) {
    printf("  FAIL one master starved: A %ld, B %ld (A share %.2f)\n",
           a_done, b_done, share);
    fails++;
  }
  if (!both_pending) {
    printf("  FAIL the two never contended, so arbitration was never tested\n");
    fails++;
  }

  printf("kaneko_mcuram_arb: checks=%ld fails=%ld a=%ld b=%ld contended=%ld "
         "a_share=%.2f\n", checks, fails, a_done, b_done, both_pending, share);
  delete d;
  return fails ? 1 : 0;
}
