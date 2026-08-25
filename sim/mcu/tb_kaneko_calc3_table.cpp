// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fuzz kaneko_calc3_table: walk a block, stream its decoded bytes, over
// generated data ROMs and a generated key table.
//
// This is where the two index counters get exercised, and they are the part
// most likely to be subtly wrong. The inline table can be ANY length, odd or
// even, so the device indexes it with a counter that wraps rather than a
// modulo, and `inline_half` -- the C's (i / size) & 1 -- is a toggle on each
// wrap. An off-by-one in either produces a table that is right for its first
// few bytes and wrong afterwards, which is exactly the shape that survives a
// short test.
//
// The header split is checked too: the FIRST TWO decoded bytes are the data
// header and do not belong to the table. Getting that wrong shifts every byte
// by two, and the bytes are 68000 instructions.
#include <cstdio>
#include <cstdint>
#include <random>
#include <vector>
#include "calc3_model.h"
#include "Vkaneko_calc3_table.h"
#include "verilated.h"

namespace {

struct Gen {
  std::vector<uint8_t> rom;
  std::vector<int> lengths;
};

Gen make_image(std::mt19937& rng, int n, bool force_inline) {
  Gen g;
  g.rom.push_back((uint8_t)n);
  for (int i = 0; i < n; i++) {
    const bool inl = force_inline ? true : (rng() & 1);
    // Inline sizes deliberately include odd ones and 1: the wrap counter and
    // the half toggle behave differently for odd sizes, and a size of 1 makes
    // the toggle flip on every byte.
    const int isize = inl ? (int)(1 + rng() % 30) : 0;
    const int bso = inl ? isize + 3 : 3;
    const int length = (rng() % 12 == 0) ? 0 : (int)(1 + rng() % 400);

    g.rom.push_back((uint8_t)bso);
    g.rom.push_back((uint8_t)(rng() & 0xff));           // mode
    g.rom.push_back((uint8_t)(rng() & 0xff));           // packed shift/sub/alt
    g.rom.push_back((uint8_t)(rng() & 0x3f));           // key byte, kept small
    for (int k = 0; k < isize; k++) g.rom.push_back((uint8_t)rng());
    g.rom.push_back((uint8_t)(length & 0xff));
    g.rom.push_back((uint8_t)((length >> 8) & 0xff));
    for (int k = 0; k < length; k++) g.rom.push_back((uint8_t)rng());
    g.lengths.push_back(length);
  }
  return g;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_calc3_table;
  std::mt19937 rng(0xca1c3222u);
  long checks = 0, fails = 0;
  long inline_tabs = 0, keyed_tabs = 0, zero_tabs = 0, odd_inline = 0;
  long total_bytes = 0;

  // A generated key table: 64 rows present, the rest absent, so the refusal
  // path is reachable.
  std::vector<std::vector<int>> keys(256, std::vector<int>(64, -1));
  for (int k = 0; k < 64; k++)
    for (int i = 0; i < 64; i++) keys[k][i] = (int)(rng() & 0xff);

  auto tick = [&] { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  d->rst_n = 0; d->start = 0; d->rom_valid = 0; d->key_data = 0; d->key_absent = 0;
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1;

  for (int trial = 0; trial < 300; trial++) {
    const int n = 1 + (int)(rng() % 8);
    Gen g = make_image(rng, n, (trial % 3) == 0);
    const int want = (int)(rng() % n);

    calc3::Block ref{};
    std::vector<uint8_t> ref_hdr, ref_out;
    const bool ref_ok = calc3::decode(g.rom, want, keys, ref_hdr, ref_out, ref);

    d->tabnum = want;
    d->start = 1; tick(); d->start = 0;

    std::vector<uint8_t> got_hdr, got_out;
    int pending = -1, delay = 0;
    long guard = 0;
    bool finished = false;

    while (!finished && guard++ < 2000000) {
      // Variable ROM latency: this rides SDRAM behind an arbiter on hardware.
      if (d->rom_rd) { pending = d->rom_addr; delay = (int)(rng() % 3); }
      d->rom_valid = 0;
      if (pending >= 0 && delay-- <= 0) {
        d->rom_data = (pending < (int)g.rom.size()) ? g.rom[pending] : 0;
        d->rom_valid = 1;
        pending = -1;
      }
      // The key ROM is registered: answer the address presented last cycle.
      const int ks = d->key_sel, ki = d->key_idx;
      d->key_absent = (keys[ks][0] == -1);
      d->key_data = (keys[ks][0] == -1) ? 0 : (uint8_t)keys[ks][ki];

      tick();
      if (d->hdr_valid) got_hdr.push_back(d->out_byte);
      if (d->out_valid) got_out.push_back(d->out_byte);
      if (d->done) finished = true;
    }

    checks++;
    if (!finished) { printf("  FAIL trial %d hung\n", trial); fails++; continue; }

    if (!ref_ok) {                       // the model refused: a missing key
      if (!d->key_missing && !d->bad_table) {
        if (fails < 10) printf("  FAIL trial %d: missing key accepted\n", trial);
        fails++;
      }
      continue;
    }
    if (d->key_missing) {
      if (fails < 10) printf("  FAIL trial %d: key wrongly reported missing\n", trial);
      fails++;
      continue;
    }

    if (ref.length == 0) {
      zero_tabs++;
      checks++;
      if (d->mode != ref.mode) {
        if (fails < 10)
          printf("  FAIL trial %d: zero-length mode got %02x want %02x\n",
                 trial, d->mode, ref.mode);
        fails++;
      }
      if (!got_out.empty() || !got_hdr.empty()) {
        printf("  FAIL trial %d: zero-length table emitted bytes\n", trial);
        fails++;
      }
      continue;
    }

    if (ref.inline_size) { inline_tabs++; if (ref.inline_size & 1) odd_inline++; }
    else                 { keyed_tabs++; }
    total_bytes += (long)ref_out.size();

    checks++;
    if (got_hdr != ref_hdr) {
      if (fails < 10)
        printf("  FAIL trial %d table %d: header %zu bytes, expected %zu\n",
               trial, want, got_hdr.size(), ref_hdr.size());
      fails++;
    }
    checks++;
    if (got_out.size() != ref_out.size()) {
      if (fails < 10)
        printf("  FAIL trial %d table %d: %zu bytes out, expected %zu\n",
               trial, want, got_out.size(), ref_out.size());
      fails++;
    } else {
      for (size_t i = 0; i < got_out.size(); i++) {
        checks++;
        if (got_out[i] != ref_out[i]) {
          if (fails < 10)
            printf("  FAIL trial %d table %d byte %zu: got %02x want %02x "
                   "(isize %d)\n", trial, want, i, got_out[i], ref_out[i],
                   ref.inline_size);
          fails++;
          break;
        }
      }
    }
  }

  if (!inline_tabs || !keyed_tabs || !zero_tabs || !odd_inline) {
    printf("  FAIL a path was never reached: inline=%ld keyed=%ld zero=%ld "
           "odd_inline=%ld\n", inline_tabs, keyed_tabs, zero_tabs, odd_inline);
    fails++;
  }

  printf("kaneko_calc3_table: checks=%ld fails=%ld bytes=%ld inline=%ld "
         "keyed=%ld zero=%ld odd_inline=%ld\n",
         checks, fails, total_bytes, inline_tabs, keyed_tabs, zero_tabs,
         odd_inline);
  delete d;
  return fails ? 1 : 0;
}
