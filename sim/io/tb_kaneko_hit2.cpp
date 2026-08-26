// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fuzz kaneko_hit2 against a C transcription of MAME's type-2 handlers.
//
// The type-2 calculator is B.Rap Boys' collision device: three axes, a mode
// register that changes how each axis reads its position and size, and a flags
// word built from nine separate comparisons. Nothing here is guessable from a
// picture -- a wrong flag bit is a hit that does not register or one that
// registers through a wall, both of which look like game behaviour rather than
// a fault.
//
// EVERY REGISTER HAS TWO WRITE ADDRESSES and the pairs interleave: x1po at 0x00
// and 0x28, x1so at 0x04 and 0x2c, z1po at 0x38 and 0x50. The fuzz writes
// through both aliases at random so a decode that collapsed them into a range
// would land values in the wrong registers and show up here.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <random>
#include "Vkaneko_hit2.h"
#include "verilated.h"

namespace {

struct Hit {
  int x1po = 0, x1so = 0, y1po = 0, y1so = 0, z1po = 0, z1so = 0;
  int x2po = 0, x2so = 0, y2po = 0, y2so = 0, z2po = 0, z2so = 0;
  int mode = 0;

  int x1p, x1s, y1p, y1s, z1p, z1s;
  int x2p, x2s, y2p, y2s, z2p, z2s;
  int x_coll, y_coll, z_coll;
  uint16_t flags = 0;
  int x1tox2, y1toy2, z1toz2;
};

void calc_org(int mode, int x0, int s0, int* x1, int* s1) {
  switch (mode) {
    case 0: *x1 = x0;          *s1 = s0;     break;
    case 1: *x1 = x0 - s0 / 2; *s1 = s0;     break;
    case 2: *x1 = x0 - s0;     *s1 = s0;     break;
    case 3: *x1 = x0 - s0;     *s1 = 2 * s0; break;
  }
}

int compute(int x1, int w1, int x2, int w2) {
  if (x2 >= x1 && x2 + w2 <= (x1 + w1)) return w2;
  if (x1 >= x2 && x1 + w1 <= (x2 + w2)) return w1;
  if (x2 < x1) { int t = x1; x1 = x2; x2 = t; t = w1; w1 = w2; w2 = t; }
  return x1 + w1 - x2;
}

void recalc(Hit& h) {
  const int mode = h.mode;
  h.flags = 0;
  calc_org((mode >> 0) & 3,  h.x1po, h.x1so, &h.x1p, &h.x1s);
  calc_org((mode >> 2) & 3,  h.y1po, h.y1so, &h.y1p, &h.y1s);
  calc_org((mode >> 4) & 3,  h.z1po, h.z1so, &h.z1p, &h.z1s);
  calc_org((mode >> 8) & 3,  h.x2po, h.x2so, &h.x2p, &h.x2s);
  calc_org((mode >> 10) & 3, h.y2po, h.y2so, &h.y2p, &h.y2s);
  calc_org((mode >> 12) & 3, h.z2po, h.z2so, &h.z2p, &h.z2s);

  h.x1tox2 = abs(h.x2po - h.x1po);
  h.y1toy2 = abs(h.y2po - h.y1po);
  h.z1toz2 = abs(h.z2po - h.z1po);

  h.x_coll = compute(h.x1p, h.x1s, h.x2p, h.x2s);
  h.y_coll = compute(h.y1p, h.y1s, h.y2p, h.y2s);
  h.z_coll = compute(h.z1p, h.z1s, h.z2p, h.z2s);

  if      (h.y1p >  h.y2p) h.flags |= 0x2000;
  else if (h.y1p == h.y2p) h.flags |= 0x4000;
  else                     h.flags |= 0x8000;
  if (h.y_coll < 0)        h.flags |= 0x1000;

  if      (h.x1p >  h.x2p) h.flags |= 0x0200;
  else if (h.x1p == h.x2p) h.flags |= 0x0400;
  else                     h.flags |= 0x0800;
  if (h.x_coll < 0)        h.flags |= 0x0100;

  if      (h.z1p >  h.z2p) h.flags |= 0x0020;
  else if (h.z1p == h.z2p) h.flags |= 0x0040;
  else                     h.flags |= 0x0080;
  if (h.z_coll < 0)        h.flags |= 0x0010;

  if (h.x_coll >= 0 && h.y_coll >= 0 && h.z_coll >= 0) h.flags |= 0x0008;
  if (h.x_coll >= 0 && h.z_coll >= 0)                  h.flags |= 0x0004;
  if (h.y_coll >= 0 && h.z_coll >= 0)                  h.flags |= 0x0002;
  if (h.x_coll >= 0 && h.y_coll >= 0)                  h.flags |= 0x0001;
}

// Write address pairs, exactly as the C's case labels pair them.
struct Reg { int a, b; int Hit::*field; };
const Reg REGS[] = {
  {0x00, 0x28, &Hit::x1po}, {0x04, 0x2c, &Hit::x1so},
  {0x08, 0x30, &Hit::y1po}, {0x0c, 0x34, &Hit::y1so},
  {0x10, 0x58, &Hit::x2po}, {0x14, 0x5c, &Hit::x2so},
  {0x18, 0x60, &Hit::y2po}, {0x1c, 0x64, &Hit::y2so},
  {0x38, 0x50, &Hit::z1po}, {0x3c, 0x54, &Hit::z1so},
  {0x20, 0x68, &Hit::z2po}, {0x24, 0x6c, &Hit::z2so},
};

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_hit2;
  std::mt19937 rng(0x81720002u);
  long checks = 0, fails = 0, alias_writes = 0, overlaps = 0, misses = 0;

  auto tick = [&] { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  d->rst = 1; d->we = 0; d->uds = 1; d->lds = 1; d->rnd = 0;
  for (int i = 0; i < 4; i++) tick();
  d->rst = 0;

  Hit h;

  for (int trial = 0; trial < 60000; trial++) {
    // Values clustered small most of the time so the boxes actually meet;
    // a purely random 16-bit spread almost never overlaps, and then the
    // overlap paths would go untested.
    auto val = [&] {
      return (rng() % 4 == 0) ? (int)(rng() & 0xffff) : (int)(rng() % 600);
    };

    const int r = (int)(rng() % 13);
    if (r == 12) {
      h.mode = (int)(rng() & 0xffff);
      d->addr = 0x70 >> 2; d->din = h.mode; d->we = 1; tick(); d->we = 0;
    } else {
      const Reg& reg = REGS[r];
      const bool use_alias = (rng() & 1);
      if (use_alias) alias_writes++;
      const int v = val();
      h.*(reg.field) = v;
      d->addr = (use_alias ? reg.b : reg.a) >> 2;
      d->din = v; d->we = 1; tick(); d->we = 0;
    }
    recalc(h);

    struct { int idx; int want; const char* name; } rd[] = {
      {0x00, (uint16_t)h.x_coll, "x_coll"},
      {0x10, (uint16_t)h.x_coll, "x_coll alias"},
      {0x04, (uint16_t)h.y_coll, "y_coll"},
      {0x18, (uint16_t)h.z_coll, "z_coll"},
      {0x08, h.flags,            "flags"},
      {0x1c, h.flags,            "flags alias"},
      {0x40, h.x1po, "x1po"}, {0x44, h.x1so, "x1so"},
      {0x48, h.y1po, "y1po"}, {0x4c, h.y1so, "y1so"},
      {0x50, h.z1po, "z1po"}, {0x54, h.z1so, "z1so"},
      {0x58, h.x2po, "x2po"}, {0x5c, h.x2so, "x2so"},
      {0x60, h.y2po, "y2po"}, {0x64, h.y2so, "y2so"},
      {0x68, h.z2po, "z2po"}, {0x6c, h.z2so, "z2so"},
      {0x80, (uint16_t)h.x1tox2, "x1tox2"},
      {0x84, (uint16_t)h.y1toy2, "y1toy2"},
      {0x88, (uint16_t)h.z1toz2, "z1toz2"},
    };
    for (auto& x : rd) {
      d->addr = x.idx >> 2;
      d->eval();
      checks++;
      const uint16_t want = (uint16_t)x.want;
      if (d->dout != want) {
        if (fails < 12)
          printf("  FAIL trial %d %s at %02x: got %04x want %04x (mode %04x)\n",
                 trial, x.name, x.idx, d->dout, want, h.mode);
        fails++;
      }
    }
    if (h.flags & 0x0008) overlaps++;
    if (h.x_coll < 0) misses++;
  }

  // Both outcomes must occur or the run says nothing about the one it missed.
  if (!overlaps || !misses || !alias_writes) {
    printf("  FAIL a case was never reached: overlaps=%ld misses=%ld "
           "alias_writes=%ld\n", overlaps, misses, alias_writes);
    fails++;
  }

  printf("kaneko_hit2: checks=%ld fails=%ld overlaps=%ld misses=%ld "
         "alias_writes=%ld\n", checks, fails, overlaps, misses, alias_writes);
  delete d;
  return fails ? 1 : 0;
}
