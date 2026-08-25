// SPDX-License-Identifier: GPL-3.0-or-later
//
// Exhaustive check of kaneko_calc3_keys: every key byte, every index.
//
// This checks the PLUMBING -- that key_sel and key_idx reach the right byte
// through the slot index, and that a key with no data asserts `absent` rather
// than returning somebody else's. It reads the same .hex files the RTL loads,
// so it cannot show the data is correct; that is tools/gen_calc3_keys.py's
// round trip against MAME, and the whole-table check in `make calc3`.
//
// Which is the point worth stating: an off-by-one in the slot arithmetic would
// return a real, valid-looking key from the wrong row. Nothing downstream would
// notice, because the output is 68000 code that only fails when executed.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "Vkaneko_calc3_keys.h"
#include "verilated.h"

namespace {

constexpr int NONE = 0x3f;

std::vector<int> read_hex(const char* path) {
  FILE* f = fopen(path, "r");
  if (!f) { printf("  FAIL cannot open %s\n", path); exit(2); }
  std::vector<int> out;
  char line[512];
  while (fgets(line, sizeof line, f)) {
    if (char* c = strstr(line, "//")) *c = 0;
    char* p = line;
    while (*p == ' ' || *p == '\t') p++;
    if (*p == 0 || *p == '\n' || *p == '\r') continue;
    out.push_back((int)strtol(p, nullptr, 16));
  }
  fclose(f);
  return out;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_calc3_keys;
  long checks = 0, fails = 0, absent_seen = 0, present_seen = 0;

  const auto keys = read_hex("rtl/mcu/calc3_keys.hex");
  const auto idx  = read_hex("rtl/mcu/calc3_keyidx.hex");
  if (idx.size() != 256) {
    printf("  FAIL index has %zu entries, expected 256\n", idx.size());
    return 1;
  }

  auto tick = [&] { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  for (int k = 0; k < 256; k++) {
    for (int i = 0; i < 64; i++) {
      d->key_sel = k;
      d->key_idx = i;
      tick();

      const int slot = idx[k];
      checks++;
      if (slot == NONE) {
        absent_seen++;
        if (!d->absent) {
          if (fails < 10) printf("  FAIL key %02x idx %02x: absent not set\n", k, i);
          fails++;
        }
      } else {
        present_seen++;
        const int want = keys[slot * 64 + i];
        if (d->absent) {
          if (fails < 10) printf("  FAIL key %02x idx %02x: absent set for a real key\n", k, i);
          fails++;
        } else if (d->key_data != want) {
          if (fails < 10)
            printf("  FAIL key %02x idx %02x: got %02x want %02x (slot %d)\n",
                   k, i, d->key_data, want, slot);
          fails++;
        }
      }
    }
  }

  // Both outcomes must occur, or the run proves nothing about the one it missed.
  if (!absent_seen || !present_seen) {
    printf("  FAIL only one outcome exercised: absent=%ld present=%ld\n",
           absent_seen, present_seen);
    fails++;
  }

  printf("kaneko_calc3_keys: checks=%ld fails=%ld present=%ld absent=%ld\n",
         checks, fails, present_seen, absent_seen);
  delete d;
  return fails ? 1 : 0;
}
