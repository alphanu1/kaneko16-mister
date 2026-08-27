// SPDX-License-Identifier: GPL-3.0-or-later
//
// kaneko_volume: every gain, across the whole input range.
//
// The fault this guards against has already shipped once here: a multiply
// written into a target narrower than its product, which truncated silently and
// turned Wing Force's music to noise a second in. So this checks the extremes
// of the input at every gain, and that the result SATURATES rather than wraps
// -- a wrap inverts the waveform and sounds like a broken chip.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <random>
#include "Vkaneko_volume.h"
#include "verilated.h"

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_volume;
  std::mt19937 rng(0x5011u);
  long checks = 0, fails = 0, saturated = 0;

  constexpr int W = 17;                       // the module's default
  constexpr int32_t HI =  (1 << (W - 1)) - 1;
  constexpr int32_t LO = -(1 << (W - 1));

  auto sext = [](uint32_t v) {
    return (int32_t)(v & (1u << (W - 1)) ? (int32_t)(v | ~((1u << W) - 1))
                                         : (int32_t)v);
  };

  for (int g = 0; g <= 16; g++) {
    for (int n = 0; n < 4000; n++) {
      // The extremes every time, then random values: an overflow only appears
      // near the ends, and a purely random sweep hits them rarely.
      int32_t in;
      if (n == 0)      in = HI;
      else if (n == 1) in = LO;
      else if (n == 2) in = 0;
      else             in = (int32_t)(rng() % (uint32_t)(HI - LO + 1)) + LO;

      d->gain8 = g;
      d->din = (uint32_t)in & ((1u << W) - 1);
      d->eval();

      int64_t want = ((int64_t)in * g) >> 3;
      if (want > HI) { want = HI; saturated++; }
      if (want < LO) { want = LO; saturated++; }

      const int32_t got = sext(d->dout);
      checks++;
      if (got != want) {
        if (fails < 10)
          printf("  FAIL gain %d, in %d: got %d want %lld\n",
                 g, in, got, (long long)want);
        fails++;
      }
    }
  }

  // A run that never saturated would not have tested the thing most likely to
  // be wrong.
  if (!saturated) {
    printf("  FAIL nothing ever saturated\n");
    fails++;
  }

  printf("kaneko_volume: checks=%ld fails=%ld saturated=%ld\n",
         checks, fails, saturated);
  delete d;
  return fails ? 1 : 0;
}
