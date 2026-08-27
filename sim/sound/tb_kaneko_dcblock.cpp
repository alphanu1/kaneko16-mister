// SPDX-License-Identifier: GPL-3.0-or-later
//
// kaneko_dcblock: does it remove a constant, and does it pass a signal?
//
// Both halves matter. A filter that removes the offset but eats the audio is
// worse than the offset, and one that passes the audio but leaves the DC does
// not fix what it was written for -- Explosive Breaker's permanent -1024,
// which ate the headroom and made anything above 140% music pin the rail.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include "Vkaneko_dcblock.h"
#include "verilated.h"

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_dcblock;
  long checks = 0, fails = 0;

  constexpr int W = 17;
  auto sext = [](uint32_t v) {
    return (v & (1u << (W - 1))) ? (int32_t)(v | ~((1u << W) - 1)) : (int32_t)v;
  };
  auto tick = [&](int32_t in) {
    d->din = (uint32_t)in & ((1u << W) - 1);
    d->clk = 0; d->eval(); d->clk = 1; d->eval();
    return sext(d->dout);
  };

  // --------------------------------------------- a constant must go to zero
  d->rst = 1; tick(0); tick(0); d->rst = 0;
  const int32_t DC = -4096;                 // EB's offset, after the shift
  int32_t last = 0;
  for (long i = 0; i < (1L << 24); i++) last = tick(DC);
  checks++;
  if (std::abs(last) > 4) {
    printf("  FAIL a constant %d settled at %d, not near zero\n", DC, last);
    fails++;
  } else {
    printf("  constant %d settles to %d\n", DC, last);
  }

  // ------------------------------------------- a tone must come through
  // 1 kHz at 48 MHz: well above the ~7 Hz corner, so amplitude must survive.
  d->rst = 1; tick(0); tick(0); d->rst = 0;
  const double F = 1000.0, FS = 48000000.0;
  int32_t peak = 0;
  for (long i = 0; i < 400000; i++) {
    const int32_t s = (int32_t)std::lround(20000.0 * std::sin(2 * M_PI * F * i / FS));
    const int32_t o = tick(s + DC);          // the tone ON the offset
    if (i > 200000 && std::abs(o) > peak) peak = std::abs(o);
  }
  checks++;
  // Allow a little loss; what matters is that it is not attenuated away.
  if (peak < 19000) {
    printf("  FAIL a 1 kHz tone came out at %d of 20000\n", peak);
    fails++;
  } else {
    printf("  1 kHz tone survives at %d of 20000, riding a %d offset\n",
           peak, DC);
  }

  printf("kaneko_dcblock: checks=%ld fails=%ld\n", checks, fails);
  delete d;
  return fails ? 1 : 0;
}
