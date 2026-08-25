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
#include "Vkaneko_calc3_dec.h"
#include "verilated.h"

namespace {

const uint8_t EXTRA[31] = {
    0x14,0xf0,0xf8,0xd2,0xbe,0xfc,0xac,0x86,0x64,0x08,0x0c,0x74,0xd6,0x6a,
    0x24,0x12,0x1a,0x72,0xba,0x48,0x76,0x66,0x4a,0x7c,0x5c,0x82,0x0a,0x86,
    0x82,0x02,0xe6 };
const uint8_t EXTRA2[30] = {
    0x2f,0x04,0xd1,0x69,0xad,0xeb,0x10,0x95,0xb0,0x2f,0x0a,0x83,0x7d,0x4e,
    0x2a,0x07,0x89,0x52,0xca,0x41,0xf1,0x4f,0xaf,0x1c,0x01,0xe9,0x89,0xd2,
    0xaf,0xcd };

// calc3_rotate_bits, verbatim in behaviour: a left rotate by bits & 7.
uint8_t rot(uint8_t d, int bits) {
  bits &= 7;
  if (!bits) return d;
  return (uint8_t)((d << bits) | (d >> (8 - bits)));
}

uint8_t ref_inline(uint8_t dat, int shift, int sub, int alt,
                   uint8_t inlinet, int ii, bool half) {
  if (sub == 3 && alt == 0) {
    dat -= inlinet;
    if (!(ii & 1)) dat -= EXTRA[ii >> 1];
    return dat;
  }
  if (!half) {
    if (ii & 1) return rot((uint8_t)(dat - inlinet), shift);
    if (sub != 2) dat = (uint8_t)(dat - inlinet - EXTRA[ii >> 1]);
    else          dat = (uint8_t)(dat + inlinet + EXTRA[ii >> 1]);
    return rot(dat, 8 - shift);
  }
  if (!(ii & 1)) return rot((uint8_t)(dat - inlinet), shift);
  if (sub != 2) dat = (uint8_t)(dat - EXTRA2[ii >> 1]);
  else          dat = (uint8_t)(dat + EXTRA2[ii >> 1]);
  return rot(dat, 8 - shift);
}

uint8_t ref_keyed(uint8_t dat, int shift, int sub, int alt,
                  uint8_t keydat, bool odd) {
  if (sub == 1)      dat = odd ? (uint8_t)(dat + keydat) : (uint8_t)(dat - keydat);
  else if (sub == 2) dat = odd ? (uint8_t)(dat - keydat) : (uint8_t)(dat + keydat);
  else if (sub == 3) dat = (uint8_t)(dat - keydat);

  if (alt == 0 || alt == 3) return odd ? rot(dat, shift) : rot(dat, 8 - shift);
  if (alt == 1)             return rot(dat, 8 - shift);
  return rot(dat, shift);
}

}  // namespace

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
      want = ref_inline(dat, shift, sub, alt, inl, ii, half);
      inline_paths++;
      if (sub == 3 && alt == 0) special++;
    } else {
      want = ref_keyed(dat, shift, sub, alt, key, odd);
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
