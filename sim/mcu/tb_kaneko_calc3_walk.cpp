// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fuzz kaneko_calc3_walk against a C walk, over synthetic data ROMs.
//
// The walk has no arithmetic that depends on the CONTENT of a table, only on
// its structure, so a generated ROM exercises it as well as a real one and
// needs no romset -- which is what lets this run in `make test`. The generator
// builds well-formed chains with random block sizes, random inline-table
// presence and sizes, and random lengths including zero.
//
// The fault this exists to catch is the offset base. Every offset in the
// device's walk is against ROM+1, because the C steps its pointer past the
// table-count byte before it starts. Reading one byte low yields a header that
// still looks entirely plausible -- a length, a mode, a key -- and decodes to
// rubbish, so nothing downstream would flag it.
//
// The ROM read here answers with a DELIBERATELY VARIABLE latency. On hardware
// this sits on SDRAM behind an arbiter and the latency is whatever the arbiter
// gives it; a testbench that always answered next cycle would pass on a state
// machine that only works at a fixed latency.
#include <cstdio>
#include <cstdint>
#include <random>
#include <vector>
#include "Vkaneko_calc3_walk.h"
#include "verilated.h"

namespace {

struct Block {
  int bso, mode, alt, key, inline_size, length;
  int hdr_at;          // offset of the block, against ROM+1
  int data_at;         // offset of its data, absolute in the image
};

struct Image {
  std::vector<uint8_t> rom;
  std::vector<Block> blocks;
};

// Build a chain of `n` blocks exactly as the device's ROM is laid out.
Image make_image(std::mt19937& rng, int n) {
  Image im;
  im.rom.push_back((uint8_t)n);            // byte 0: the table count
  int offset = 0;                          // against ROM+1

  for (int i = 0; i < n; i++) {
    Block b{};
    b.hdr_at = offset;
    // blocksize_offset is 3 for no inline table, or 4..33 for one of 1..30.
    const bool inl = (rng() & 1);
    b.bso = inl ? (int)(4 + rng() % 30) : 3;
    b.inline_size = inl ? b.bso - 3 : 0;
    b.mode = (int)(rng() & 0xff);
    b.alt  = (int)(rng() & 0xff);
    b.key  = (int)(rng() & 0xff);
    // Zero length is a real case -- a control operation, not a table.
    b.length = (rng() % 8 == 0) ? 0 : (int)(1 + rng() % 300);

    im.rom.push_back((uint8_t)b.bso);
    im.rom.push_back((uint8_t)b.mode);
    im.rom.push_back((uint8_t)b.alt);
    im.rom.push_back((uint8_t)b.key);
    for (int k = 0; k < b.inline_size; k++) im.rom.push_back((uint8_t)rng());
    im.rom.push_back((uint8_t)(b.length & 0xff));
    im.rom.push_back((uint8_t)((b.length >> 8) & 0xff));
    b.data_at = (int)im.rom.size();
    for (int k = 0; k < b.length; k++) im.rom.push_back((uint8_t)rng());

    im.blocks.push_back(b);
    offset += b.bso + 1 + b.length + 2;
  }
  return im;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_calc3_walk;
  std::mt19937 rng(0xca1c3111u);
  long checks = 0, fails = 0, zero_len = 0, inlines = 0, rejects = 0;

  auto tick = [&] { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  d->rst_n = 0; d->start = 0; d->rom_valid = 0; d->rom_data = 0;
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1;

  for (int trial = 0; trial < 400; trial++) {
    const int n = 1 + (int)(rng() % 12);
    Image im = make_image(rng, n);
    // Ask for a real table most of the time, and past the end sometimes, so
    // the rejection path is exercised rather than assumed.
    const bool overrun = (rng() % 10 == 0);
    const int want = overrun ? n + 1 + (int)(rng() % 4)
                             : (int)(rng() % n);

    d->tabnum = want;
    d->start = 1; tick(); d->start = 0;

    int pending = -1, delay = 0;
    long guard = 0;
    bool finished = false;
    while (!finished && guard++ < 200000) {
      if (d->rom_rd) { pending = d->rom_addr; delay = (int)(rng() % 4); }
      d->rom_valid = 0;
      if (pending >= 0) {
        if (delay-- <= 0) {
          d->rom_data = (pending < (int)im.rom.size()) ? im.rom[pending] : 0;
          d->rom_valid = 1;
          pending = -1;
        }
      }
      tick();
      if (d->done) finished = true;
    }

    checks++;
    if (!finished) { printf("  FAIL trial %d never completed\n", trial); fails++; continue; }

    if (overrun) {
      rejects++;
      if (!d->bad_table) {
        if (fails < 10) printf("  FAIL table %d of %d accepted\n", want, n);
        fails++;
      }
      continue;
    }

    if (d->bad_table) {
      if (fails < 10) printf("  FAIL table %d of %d rejected\n", want, n);
      fails++;
      continue;
    }

    const Block& b = im.blocks[want];
    if (b.length == 0) zero_len++;
    if (b.inline_size) inlines++;

    struct { const char* name; int got, exp; } f[] = {
      {"blocksize_offset", d->blocksize_offset, b.bso},
      {"mode",             d->mode,             b.mode},
      {"shift",            d->shift,            (b.alt >> 4) & 7},
      {"subtracttype",     d->subtracttype,     b.alt & 3},
      {"alternateswaps",   d->alternateswaps,   (b.alt >> 2) & 3},
      {"key_byte",         d->key_byte,         b.key},
      {"inline_size",      d->inline_size,      b.inline_size},
      {"length",           (int)d->length,      b.length},
      {"data_base",        (int)d->data_base,   b.data_at},
      {"inline_base",      (int)d->inline_base,
                           b.inline_size ? 1 + b.hdr_at + 4 : (int)d->inline_base},
    };
    for (auto& x : f) {
      checks++;
      if (x.got != x.exp) {
        if (fails < 16)
          printf("  FAIL trial %d table %d: %s got %d want %d\n",
                 trial, want, x.name, x.got, x.exp);
        fails++;
      }
    }
  }

  // Each of these is a distinct path; a zero means the run says nothing about it.
  if (!zero_len || !inlines || !rejects) {
    printf("  FAIL a path was never reached: zero_len=%ld inline=%ld reject=%ld\n",
           zero_len, inlines, rejects);
    fails++;
  }

  printf("kaneko_calc3_walk: checks=%ld fails=%ld zero_len=%ld inline=%ld "
         "rejected=%ld\n", checks, fails, zero_len, inlines, rejects);
  delete d;
  return fails ? 1 : 0;
}
