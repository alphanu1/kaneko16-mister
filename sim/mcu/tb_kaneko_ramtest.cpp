// SPDX-License-Identifier: GPL-3.0-or-later
//
// kaneko_ramtest against an honest memory, and against three broken ones.
//
// A self-test that cannot fail is worse than no self-test: it will be deployed,
// come back green, and be taken as evidence that the path is sound. So this
// checks the pass case AND that each fault it was written for is caught --
// especially a byte enable that writes the wrong half, which is the case the
// game exercises 262,378 times before it will boot.
#include <cstdio>
#include <cstdint>
#include <map>
#include <random>
#include "Vkaneko_ramtest.h"
#include "verilated.h"

namespace {

enum Fault { NONE, BYTE_IGNORED, BYTE_SWAPPED, ADDR_ALIASED };

// Returns true if the test PASSED.
bool run(Vkaneko_ramtest* d, Fault fault, long* cycles, int* stage) {
  std::map<uint32_t, uint16_t> mem;
  std::mt19937 rng(0x8a5e1u);

  auto tick = [&] { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  d->rst = 1; d->enable = 0; d->ack = 0; d->base_mcuram = 0x30000;
  for (int i = 0; i < 4; i++) tick();
  d->rst = 0;
  d->enable = 1;

  bool busy = false; int delay = 0;
  uint32_t a = 0; bool we = false; uint16_t din = 0; uint8_t be = 3;
  long cyc = 0;

  while (!d->done && cyc++ < 2000000) {
    d->ack = 0;
    if (d->req && !busy) {
      busy = true; delay = (int)(rng() % 4);
      a = d->addr; we = d->we; din = d->din; be = d->be;
    }
    if (busy && delay-- <= 0) {
      uint32_t ea = a;
      // An address line that does not decode: bit 4 lost.
      if (fault == ADDR_ALIASED) ea &= ~0x10u;
      if (we) {
        uint16_t cur = mem.count(ea) ? mem[ea] : 0;
        uint8_t eb = be;
        // A byte enable ignored: every write becomes a whole word.
        if (fault == BYTE_IGNORED) eb = 3;
        // A byte enable swapped: the wrong half is written.
        if (fault == BYTE_SWAPPED && eb != 3) eb = (uint8_t)(eb ^ 3);
        if (eb & 2) cur = (uint16_t)((cur & 0x00ff) | (din & 0xff00));
        if (eb & 1) cur = (uint16_t)((cur & 0xff00) | (din & 0x00ff));
        mem[ea] = cur;
      } else {
        uint64_t v = 0;
        for (int w = 0; w < 4; w++) {
          // The controller starts its burst AT THE ADDRESS GIVEN -- it does not
        // align. Modelling it aligned made this testbench agree with the very
        // mistake it exists to catch: two readers picked a word by lane out of
        // an unaligned burst, and both passed here and failed on the board.
        const uint32_t q = ea + w;
          v |= (uint64_t)(mem.count(q) ? mem[q] : 0) << (16 * w);
        }
        d->dout = v;
      }
      d->ack = 1; busy = false;
    }
    tick();
  }
  *cycles = cyc;
  *stage = d->fail_stage;
  return d->done && d->pass;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_ramtest;
  long checks = 0, fails = 0, cyc = 0;
  int stage = 0;

  struct { Fault f; bool want_pass; const char* name; } CASES[] = {
    { NONE,         true,  "an honest memory" },
    { BYTE_IGNORED, false, "byte enable ignored: every write a whole word" },
    { BYTE_SWAPPED, false, "byte enable swapped: the wrong half written" },
    { ADDR_ALIASED, false, "an address line that does not decode" },
  };

  for (auto& c : CASES) {
    const bool passed = run(d, c.f, &cyc, &stage);
    checks++;
    if (passed != c.want_pass) {
      printf("  FAIL %s: self-test %s, expected %s\n", c.name,
             passed ? "PASSED" : "failed", c.want_pass ? "pass" : "failure");
      fails++;
    } else {
      printf("  %-52s %s%s\n", c.name, passed ? "pass" : "caught",
             passed ? "" : (stage >= 4 ? "  (at a byte stage)" : ""));
    }
  }

  printf("kaneko_ramtest: checks=%ld fails=%ld last_run=%ld cycles\n",
         checks, fails, cyc);
  delete d;
  return fails ? 1 : 0;
}
