// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fuzz kaneko_calc3_dec against a C reference, exhaustively over the mode
// space and randomly over the data.
//
// WHAT THIS CAN AND CANNOT SHOW
//
// The reference here is a second transcription of the same C in
// kaneko_calc3.cpp, so on its own this proves the RTL agrees with a
// transcription -- not that either agrees with the hardware. It is still worth
// having: it covers every combination of subtract type, alternate swap, shift
// and index parity, including the ones the two games never exercise, and it
// runs with no ROM data so it belongs in `make test`.
//
// The check that closes the gap is `make calc3`, which runs the SAME algorithm
// (via tools/calc3_ref.py) against what MAME's CALC3 actually wrote into MCU
// RAM on shogwarr and brapboys, byte for byte, addresses included. Neither
// check is sufficient alone: that one uses real data but only the paths those
// two games take, and this one takes every path but invents the data.
#include <cstdio>
#include <cstdint>
#include <random>
#include "calc3_model.h"
#include "Vkaneko_calc3_dec.h"
#include "verilated.h"

// The C reference lives in calc3_model.h, shared with the table testbench.
// It was duplicated here first; two transcriptions of an algorithm this fiddly
// drift, and the drift reads as an RTL bug.
using calc3::rot;
using calc3::inline_path;
using calc3::keyed_path;

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_calc3_dec;
  std::mt19937 rng(0xca1c3000u);
  long checks = 0, fails = 0;
  long inline_paths = 0, keyed_paths = 0, special = 0;

  // Exhaustive over the modes, random over the bytes. The mode space is only
  // 3 * 4 * 4 * 8 * 2, so there is no reason to sample it.
  for (int sub = 0; sub < 4; sub++)
  for (int alt = 0; alt < 4; alt++)
  for (int shift = 0; shift < 8; shift++)
  for (int odd = 0; odd < 2; odd++)
  for (int half = 0; half < 2; half++)
  for (int isize = 0; isize < 3; isize++)     // 0 = keyed path, else inline
  for (int n = 0; n < 400; n++) {
    const uint8_t dat  = (uint8_t)rng();
    const uint8_t key  = (uint8_t)rng();
    const uint8_t inl  = (uint8_t)rng();
    // inline_idx must stay inside the magic arrays, as it does in the C:
    // it is always below inline_size, and no real block's inline table is
    // longer than 30.
    const int     ii   = (int)(rng() % 30);
    const int     size = isize == 0 ? 0 : (isize == 1 ? 7 : 30);

    d->dat_in      = dat;
    d->idx_odd     = odd;
    d->shift       = shift;
    d->subtracttype = sub;
    d->alternateswaps = alt;
    d->inline_size = size;
    d->inline_byte = inl;
    d->inline_idx  = size ? ii : 0;
    d->inline_half = half;
    d->key_byte    = key;
    d->eval();

    uint8_t want;
    if (size) {
      want = inline_path(dat, shift, sub, alt, inl, ii, half);
      inline_paths++;
      if (sub == 3 && alt == 0) special++;
    } else {
      want = keyed_path(dat, shift, sub, alt, key, odd);
      keyed_paths++;
    }

    checks++;
    if (d->dat_out != want) {
      if (fails < 12)
        printf("  FAIL dat=%02x sub=%d alt=%d shift=%d odd=%d half=%d "
               "isize=%d ii=%d inl=%02x key=%02x got=%02x want=%02x\n",
               dat, sub, alt, shift, odd, half, size, ii, inl, key,
               d->dat_out, want);
      fails++;
    }
  }

  // A count of zero on any path means the loop above stopped reaching it and
  // the pass says nothing about that path -- the failure mode this project has
  // hit repeatedly, where a gate goes green on a case it never ran.
  if (!inline_paths || !keyed_paths || !special) {
    printf("  FAIL a path was never exercised: inline=%ld keyed=%ld special=%ld\n",
           inline_paths, keyed_paths, special);
    fails++;
  }

  printf("kaneko_calc3_dec: checks=%ld fails=%ld inline=%ld keyed=%ld "
         "shogwarr_special=%ld\n", checks, fails, inline_paths, keyed_paths,
         special);
  delete d;
  return fails ? 1 : 0;
}
