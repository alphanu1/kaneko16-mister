// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fuzz kaneko_mcuram_arb with every master asking as hard as it can.
//
// Three properties, and the second is why this module exists rather than a
// port per master:
//
//   1. Every request is answered exactly once, with the data for ITS address.
//      A grant that returns another master's data is the failure that would
//      look like an MCU fault and be debugged as one.
//   2. NO MASTER IS STARVED. The CALC3 issues thousands of back-to-back
//      accesses while decompressing a table; a fixed order stops whoever sits
//      below it for the whole run, and the 68000 waits on DTACK, so starving it
//      stalls the game. Checked by holding every request high continuously and
//      requiring an even split.
//   3. Only one access is ever in flight, which is what makes ordering on the
//      shared RAM structural rather than hoped for.
//   4. A master that PULSES its request for one cycle is served. kaneko_bus
//      and kaneko_tilerom hold theirs until the acknowledge, but kaneko_calc3
//      clears ram_rd and ram_wr at the top of every cycle, so its requests are
//      one cycle wide. An arbiter that only looks when idle drops any pulse
//      that lands while it is busy, and the master then waits forever. Master 1
//      pulses here for exactly that reason -- when every master held its
//      request, this testbench passed while both games hung on hardware.
//
// Each master uses its own address range. Not to dodge a hard case: a shared
// address has no single right answer, since either master's write may
// legitimately land on either side of another's read, so a model that snapshots
// the expected value at issue time scores a correct read as a failure. Ordering
// is structural here anyway, and read/write racing on one port is what
// tb_kaneko_sdram covers.
#include <cstdio>
#include <cstdint>
#include <map>
#include <random>
#include <cstdlib>
#include "Vkaneko_mcuram_arb_harness.h"
#include "verilated.h"

// FOUR, matching the core: the 68000, the MCU's RAM port, its data ROM
// fetch, and the boot RAM self-test. It was fuzzed at three while the core
// ran four.
namespace { constexpr int NM = 4; }

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_mcuram_arb_harness;
  std::mt19937 rng(0xa4b17e40u);
  long checks = 0, fails = 0, inflight_max = 0, byte_writes = 0;
  long done[NM] = {0, 0, 0, 0};

  std::map<uint32_t, uint16_t> mem;

  auto tick = [&] { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  d->rst_n = 0; d->s_ack = 0;
  d->m0_req = d->m1_req = d->m2_req = d->m3_req = 0;
  d->m0_we = d->m1_we = d->m3_we = 0;
  d->m0_be = d->m1_be = d->m3_be = 3;
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1;

  struct Pend { bool busy = false; uint32_t addr = 0; bool we = false;
                uint16_t din = 0; uint16_t want = 0; bool raised = false;
                uint8_t be = 3; };
  Pend p[NM];

  // Verilator packs the flattened arrays; set each master's slice by index.
  // NO `default:`; an out-of-range master must be loud, not routed onto one
  // that happens to exist.
  auto set_master = [&](int i, uint32_t addr, bool we, uint16_t din, uint8_t be) {
    switch (i) {
      case 0: d->m0_addr = addr; d->m0_din = din; d->m0_we = we; d->m0_be = be; d->m0_req = 1; break;
      case 1: d->m1_addr = addr; d->m1_din = din; d->m1_we = we; d->m1_be = be; d->m1_req = 1; break;
      case 2: d->m2_addr = addr; d->m2_req = 1; break;
      case 3: d->m3_addr = addr; d->m3_din = din; d->m3_we = we; d->m3_be = be; d->m3_req = 1; break;
      default: printf("  FATAL master %d out of range\n", i); std::abort();
    }
  };
  auto ack_of = [&](int i) {
    switch (i) {
      case 0: return (int)d->m0_ack;
      case 1: return (int)d->m1_ack;
      case 2: return (int)d->m2_ack;
      case 3: return (int)d->m3_ack;
      default: printf("  FATAL master %d out of range\n", i); std::abort();
    }
  };
  auto clear_req = [&](int i) {
    switch (i) {
      case 0: d->m0_req = 0; break;
      case 1: d->m1_req = 0; break;
      case 2: d->m2_req = 0; break;
      case 3: d->m3_req = 0; break;
      default: printf("  FATAL master %d out of range\n", i); std::abort();
    }
  };

  // Master 1 pulses, as the CALC3 does; the others hold, as their real
  // counterparts do.
  auto pulses = [](int i) { return i == 1; };

  auto issue = [&](int i) {
    p[i].busy = true;
    p[i].addr = (uint32_t)(i * 32 + rng() % 32);   // one range per master
    // Master 2 is the data ROM fetch: a reader, never a writer.
    p[i].we = (i != 2) && ((rng() % 3) == 0);   // only the ROM fetch never writes
    p[i].din = (uint16_t)rng();
    // BYTE writes as often as words. A byte write that reaches memory as a
    // whole word destroys the half it should not touch, and nothing downstream
    // notices until a game reads that half back.
    p[i].be = p[i].we ? (uint8_t)(1 + rng() % 3) : (uint8_t)3;
    if (p[i].we) {
      uint16_t cur = mem.count(p[i].addr) ? mem[p[i].addr] : 0;
      if (p[i].be & 2) cur = (uint16_t)((cur & 0x00ff) | (p[i].din & 0xff00));
      if (p[i].be & 1) cur = (uint16_t)((cur & 0xff00) | (p[i].din & 0x00ff));
      mem[p[i].addr] = cur;
    } else {
      p[i].want = mem.count(p[i].addr) ? mem[p[i].addr] : 0;
    }
    set_master(i, p[i].addr, p[i].we, p[i].din, p[i].be);
  };

  int s_delay = 0; bool s_busy = false;
  uint32_t s_addr = 0; bool s_we = false; uint16_t s_din = 0; uint8_t s_be = 3;

  for (long cyc = 0; cyc < 200000; cyc++) {
    for (int i = 0; i < NM; i++) if (!p[i].busy) issue(i);
    // Drop the pulsing master's request one cycle after it was raised. If the
    // arbiter has not latched it by then it is gone, which is the bug.
    for (int i = 0; i < NM; i++)
      if (pulses(i) && p[i].busy && p[i].raised) clear_req(i);
    for (int i = 0; i < NM; i++) if (p[i].busy) p[i].raised = true;

    long inflight = 0;
    for (int i = 0; i < NM; i++) if (p[i].busy) inflight++;
    if (inflight > inflight_max) inflight_max = inflight;

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

    // At most one acknowledge a cycle: the port serves one master at a time.
    int acks = 0;
    for (int i = 0; i < NM; i++) if (ack_of(i)) acks++;
    checks++;
    if (acks > 1) { printf("  FAIL %d masters acknowledged on one cycle\n", acks); fails++; }

    for (int i = 0; i < NM; i++) {
      if (!ack_of(i)) continue;
      checks++; done[i]++;
      if (!p[i].busy) {
        printf("  FAIL master %d acknowledged with nothing outstanding\n", i);
        fails++;
      } else if (!p[i].we) {
        const uint16_t got =
            (uint16_t)((d->m_dout >> (16 * (p[i].addr & 3))) & 0xffff);
        if (got != p[i].want) {
          if (fails < 10)
            printf("  FAIL master %d read %02x: got %04x want %04x\n",
                   i, p[i].addr, got, p[i].want);
          fails++;
        }
      }
      if (p[i].we && p[i].be != 3) byte_writes++;
      p[i].busy = false;
      p[i].raised = false;
      clear_req(i);
    }
  }

  const long total = done[0] + done[1] + done[2] + done[3];
  for (int i = 0; i < NM; i++) {
    checks++;
    const double share = (double)done[i] / (double)total;
    if (share < 0.18 || share > 0.32) {
      printf("  FAIL master %d starved or favoured: %ld of %ld (%.2f)\n",
             i, done[i], total, share);
      fails++;
    }
  }
  checks++;
  if (!byte_writes) {
    printf("  FAIL no byte writes were exercised\n");
    fails++;
  }
  checks++;
  if (inflight_max < NM) {
    printf("  FAIL the masters never all contended, so arbitration was "
           "never tested\n");
    fails++;
  }

  printf("kaneko_mcuram_arb: checks=%ld fails=%ld served=%ld/%ld/%ld/%ld "
         "max_contending=%ld byte_writes=%ld\n", checks, fails, done[0],
         done[1], done[2], done[3], inflight_max, byte_writes);
  delete d;
  return fails ? 1 : 0;
}
