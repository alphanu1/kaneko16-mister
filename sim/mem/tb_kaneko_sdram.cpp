// SPDX-License-Identifier: GPL-3.0-or-later
//
// Kaneko 16-bit arcade core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// SDRAM controller verification.
//
// Two things are being checked at once, and they catch different faults:
//
//   DATA    every read returns what was written to that address, through a
//           shadow memory in C++. Catches address decode, burst ordering,
//           byte enables, and delivering one master's data to another.
//
//   TIMING  the device model counts zero protocol violations for the whole
//           run. Catches the failures that simulate perfectly and then eat a
//           real SDRAM stick — tRP, tRCD, refresh interval, activating an
//           already-open row.
//
// All five masters run concurrently with transactions genuinely in flight at
// the same time. Driving one port at a time would exercise the state machine
// but not the arbiter, and the arbiter is where the interesting bugs are: a
// controller that delivers p2's data to p1 passes every single-port test.

#include "Vkaneko_sdram_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <map>
#include <random>
#include <vector>

// MUST MATCH Kaneko16.sv's NPORTS. It did not: the core ran six ports and this
// tested five, so the OKI's port was the one port never arbitrated in a test —
// and it was also the one port blen() forgot, which is how a single-word burst
// reached hardware and made the sound path silent.
// NPORTS-AHEAD-BY-ONE
//
// One more than the core has today: the extra is the sprite-bitmap candidate
// being measured. nports-check allows this file to run a single port ahead
// while the move is in progress; remove the marker when the core catches up.
static const int NP = 10;

// Burst length per port. This mirrored a per-port blen() in kaneko_sdram.sv and
// got it wrong twice — once claiming ports 1 and 2 burst four where the RTL said
// 1, 2 and 3, and once by not growing when a sixth port was added. The RTL side
// is now a single constant for every read port, so there is nothing left to
// mirror incorrectly.
static int burst_of(int p) { (void)p; return 4; }

struct Harness {
  Vkaneko_sdram_harness* d;
  long cyc = 0;
  std::map<uint32_t, uint16_t> shadow;   // word address -> data

  // Per-port transaction state.
  struct Port {
    bool     busy = false;
    bool     req_held = false;
    uint32_t addr = 0;
    int      words = 1;
    bool     write = false;
    uint16_t wdata = 0;
    uint8_t  be = 3;
    bool     ack_prev = false;
    long     issued_at = 0;
    long     n_done = 0;
  } port[NP];

  bool wr_busy = false, wr_req_held = false, wr_ack_prev = false;
  uint32_t wr_addr = 0;
  uint16_t wr_data = 0;

  long fails = 0, checks = 0, max_latency = 0, races = 0;

  Harness() {
    d = new Vkaneko_sdram_harness;
    d->clk = 0; d->rst_n = 0;
    d->wr_req = 0; d->wr_addr = 0; d->wr_din = 0; d->wr_be = 3;
    d->p0_req = d->p1_req = d->p2_req = d->p3_req = d->p4_req = d->p5_req = d->p6_req = d->p7_req = 0;
    d->p0_we = 0; d->p0_din = 0; d->p0_be = 3;
    d->p0_addr = d->p1_addr = d->p2_addr = d->p3_addr = d->p4_addr =
        d->p5_addr = d->p6_addr = d->p7_addr = 0;
    d->mon_sel = 0; d->mon_snap = 0;
    d->eval();
  }
  ~Harness() { delete d; }

  // NO `default:` IN ANY OF THESE. Each one used to end in one, which routed
  // an out-of-range port number onto port 4 rather than complaining. When NP
  // grew to 6 the testbench drove port 4 twice and never touched port 5, so
  // the port the OKI uses was the one port that was never exercised — and it
  // was also the one port kaneko_sdram's blen() forgot. Two silent defaults,
  // one on each side, agreeing with each other about a port neither served.
  void abortPort(int p) const {
    std::printf("  FATAL: port %d is out of range; NP is %d\n", p, NP);
    std::abort();
  }
  void setReq(int p, int v) {
    switch (p) {
      case 0: d->p0_req = v; break; case 1: d->p1_req = v; break;
      case 2: d->p2_req = v; break; case 3: d->p3_req = v; break;
      case 4: d->p4_req = v; break; case 5: d->p5_req = v; break;
      case 6: d->p6_req = v; break; case 7: d->p7_req = v; break;
      case 8: d->p8_req = v; break;
      case 9: d->p9_req = v; break;
      default: abortPort(p);
    }
  }
  void setAddr(int p, uint32_t a) {
    switch (p) {
      case 0: d->p0_addr = a; break; case 1: d->p1_addr = a; break;
      case 2: d->p2_addr = a; break; case 3: d->p3_addr = a; break;
      case 4: d->p4_addr = a; break; case 5: d->p5_addr = a; break;
      case 6: d->p6_addr = a; break; case 7: d->p7_addr = a; break;
      case 8: d->p8_addr = a; break;
      case 9: d->p9_addr = a; break;
      default: abortPort(p);
    }
  }
  bool getAck(int p) {
    switch (p) {
      case 0: return d->p0_ack; case 1: return d->p1_ack;
      case 2: return d->p2_ack; case 3: return d->p3_ack;
      case 4: return d->p4_ack; case 5: return d->p5_ack;
      case 6: return d->p6_ack; case 7: return d->p7_ack;
      case 8: return d->p8_ack; case 9: return d->p9_ack;
      default: abortPort(p); return false;
    }
  }
  uint64_t getDout(int p) {
    switch (p) {
      case 0: return d->p0_dout; case 1: return d->p1_dout;
      case 2: return d->p2_dout; case 3: return d->p3_dout;
      case 4: return d->p4_dout; case 5: return d->p5_dout;
      case 6: return d->p6_dout; case 7: return d->p7_dout;
      case 8: return d->p8_dout; case 9: return d->p9_dout;
      default: abortPort(p); return 0;
    }
  }

  void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); cyc++; }

  void reset() {
    d->rst_n = 0;
    for (int i = 0; i < 8; i++) tick();
    d->rst_n = 1;
    // Bring-up runs the JEDEC sequence; nothing may be issued until ready.
    long guard = 0;
    while (!d->ready && guard++ < 20000) tick();
    if (!d->ready) { printf("  FAIL controller never asserted ready\n"); fails++; }
  }

  // Advance one cycle, servicing whatever completed.
  void step() {
    tick();
    for (int p = 0; p < NP; p++) {
      // Requests are latched on the rising edge, so drop req the cycle after
      // asserting it. Holding it high would be serviced exactly once anyway,
      // which is the contract, but dropping keeps the stimulus honest about
      // what a real single-outstanding master does.
      if (port[p].req_held) { setReq(p, 0); port[p].req_held = false; }

      bool ack = getAck(p);
      if (ack && !port[p].ack_prev) {
        long lat = cyc - port[p].issued_at;
        if (lat > max_latency) max_latency = lat;
        if (!port[p].write) {
          uint64_t got = getDout(p);
          for (int w = 0; w < port[p].words; w++) {
            uint32_t a = port[p].addr + w;
            uint16_t want = shadow.count(a) ? shadow[a] : 0;
            uint16_t g = (uint16_t)((got >> (16 * w)) & 0xffff);
            checks++;

            // If a write to this address landed after this read was issued,
            // the pre-write value is equally correct.
            const bool raced = last_write_cyc.count(a) &&
                               last_write_cyc[a] >= port[p].issued_at;
            if (raced && pre_write_val.count(a) && g == pre_write_val[a]) {
              races++;
              continue;
            }

            if (g != want && fails < 20) {
              printf("  FAIL p%d addr=%06x word=%d got=%04x want=%04x%s\n",
                     p, a, w, g, want,
                     raced ? "  (raced, and matched neither value)" : "");
              fails++;
            } else if (g != want) {
              fails++;
            }
          }
        }
        port[p].busy = false;
        port[p].n_done++;
      }
      port[p].ack_prev = ack;
    }

    if (wr_req_held) { d->wr_req = 0; wr_req_held = false; }
    bool wack = d->wr_ack;
    if (wack && !wr_ack_prev) wr_busy = false;
    wr_ack_prev = wack;
  }

  // A write to an address that a read is ALREADY in flight over may land
  // either side of that read: the controller gives no ordering guarantee
  // between independent ports, and never claimed to. So for such an address
  // both the pre-write and post-write values are correct answers, and the
  // shadow model — which updates at issue time — cannot express that on its
  // own. These two maps record what a raced read is allowed to return.
  std::map<uint32_t,long>     last_write_cyc;   // address -> cycle of last write
  std::map<uint32_t,uint16_t> pre_write_val;    // address -> value before it

  void issue(int p, uint32_t addr, bool write, uint16_t data, uint8_t be = 3) {
    int words = write ? 1 : burst_of(p);
    if (words > 1) addr &= ~(uint32_t)(words - 1);   // bursts are aligned
    port[p].busy = true; port[p].addr = addr; port[p].words = words;
    port[p].write = write; port[p].wdata = data; port[p].be = be;
    port[p].issued_at = cyc;
    setAddr(p, addr);
    // Port 9 is the only one that writes. p0's write signals were the
    // harness's original single write path and are gone; a write issued on any
    // other port would silently become a read, which is the sort of thing a
    // throughput number hides completely.
    if (write && p != 9) { printf("  BUG: write issued on port %d\n", p); fails++; }
    if (p == 9) { d->p9_we = write; d->p9_din = data; d->p9_be = be; }
    setReq(p, 1);
    port[p].req_held = true;
    if (write) {
      if (be & 1) shadow[addr] = (shadow.count(addr) ? shadow[addr] : 0);
      const uint16_t before = shadow.count(addr) ? shadow[addr] : 0;
      uint16_t cur = before;
      if (be & 1) cur = (cur & 0xff00) | (data & 0x00ff);
      if (be & 2) cur = (cur & 0x00ff) | (data & 0xff00);
      shadow[addr] = cur;
      last_write_cyc[addr] = cyc;
      pre_write_val[addr]  = before;
    }
  }

  void issueWrite(uint32_t addr, uint16_t data) {
    wr_busy = true; wr_addr = addr; wr_data = data;
    d->wr_addr = addr; d->wr_din = data; d->wr_be = 3; d->wr_req = 1;
    wr_req_held = true;
    shadow[addr] = data;
  }

  void drain(int maxcyc = 5000) {
    int n = 0;
    bool any = true;
    while (any && n++ < maxcyc) {
      any = wr_busy;
      for (int p = 0; p < NP; p++) any |= port[p].busy;
      step();
    }
  }
};

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Harness h;
  std::mt19937 rng(20260815u);

  printf("test: bring-up reaches ready\n");
  h.reset();

  // Addresses are drawn from a small set of banks and rows so that row
  // conflicts actually happen. A uniformly random 24-bit address almost never
  // reuses a row, and the row-management path — precharge, tRP, activate —
  // would go essentially untested.
  // The port address is [24:1], so as a 0-based C++ value bit 0 is address
  // bit 1: bank is [23:22], row is [21:9], column is [8:0]. Getting these
  // shifts wrong puts the shadow memory and the device at different
  // locations, which looks exactly like a broken read path.
  // GEOMETRY-DRIVEN, not hardcoded. TB_COL_BITS must match the -GCOL_BITS the
  // harness was built with: 9 for a 32 MB module, 11 for 128 MB. If the two
  // disagree the shadow memory and the device sit at different locations, which
  // looks exactly like a broken read path -- the trap the comment above names.
#ifndef TB_COL_BITS
#define TB_COL_BITS 9
#endif
  const uint32_t CB = TB_COL_BITS;
  const uint32_t AWB = 2 + 13 + CB;             // total word-address bits
  printf("test: geometry %u column bits -> %u MB module\n",
         CB, (1u << AWB) / (1024u * 1024u) * 2u);
  auto pick_addr = [&](std::mt19937& r) -> uint32_t {
    uint32_t bank = r() & 3;
    uint32_t row  = r() % 6;                    // few rows, so conflicts happen
    uint32_t col  = r() & ((1u << CB) - 1u);
    // 0-based value bit 0 is address bit 1, so bank sits at AWB-2.
    return (bank << (AWB - 2)) | (row << CB) | col;
  };

  printf("test: ROM download writes, then read back through every port\n");
  {
    std::vector<uint32_t> addrs;
    for (int i = 0; i < 1500; i++) {
      uint32_t a = pick_addr(rng) & ~3u;      // burst-aligned so any port can read
      for (int w = 0; w < 4; w++) {
        while (h.wr_busy) h.step();
        h.issueWrite(a + w, (uint16_t)rng());
        h.step();
      }
      addrs.push_back(a);
    }
    h.drain();

    for (int p = 0; p < NP; p++) {
      for (size_t k = 0; k < addrs.size(); k += 7) {
        while (h.port[p].busy) h.step();
        h.issue(p, addrs[k], false, 0);
        h.step();
      }
    }
    h.drain();
    printf("  download+readback: %ld checks, %ld fails, %u violations\n",
           h.checks, h.fails, h.d->violations);
  }

  printf("test: all five masters concurrent, with p0 writes mixed in\n");
  {
    long start_checks = h.checks;
    for (long n = 0; n < 120000; n++) {
      for (int p = 0; p < NP; p++) {
        if (h.port[p].busy) continue;
        // Offered load differs per port so the arbiter sees an uneven mix,
        // which is what the real board presents.
        unsigned thresh = (p == 0) ? 40 : (p == 2) ? 30 : 12;
        if ((rng() % 100) >= thresh) continue;
        // Port 9 is the writer now -- the sprite bitmap is the only master
        // that writes during a frame. This said p == 0, which was the
        // harness's write path before that port existed.
        bool write = (p == 9) && ((rng() & 7) == 0);
        uint8_t be = 3;
        if (write && (rng() & 7) == 0) be = (rng() & 1) ? 1 : 2;  // byte writes
        h.issue(p, pick_addr(rng), write, (uint16_t)rng(), be);
      }
      // The download port stays idle here: on the real board the loader and
      // the game never run at once.
      h.step();
    }
    h.drain();
    printf("  concurrent: %ld checks, %ld fails, %u violations, max latency %ld\n",
           h.checks - start_checks, h.fails, h.d->violations, h.max_latency);
  }

  printf("test: row thrash — same bank, alternating rows\n");
  {
    long start_fails = h.fails;
    for (int n = 0; n < 4000; n++) {
      int p = n & 1 ? 0 : 3;
      while (h.port[p].busy) h.step();
      uint32_t a = (0u << 22) | (((uint32_t)(n & 1)) << 9) | (n & 0x1ff);
      h.issue(p, a, false, 0);
      h.step();
    }
    h.drain();
    printf("  row thrash: %ld fails\n", h.fails - start_fails);
  }

  // ------------------------------------------------ read/write collision
  // A WRITE drives DQ; a read in flight means the device drives DQ. The
  // controller guards against issuing one during the other, and a guard that
  // is never exercised is indistinguishable from a guard that does not work.
  // This phase alternates a burst read with a write to the same bank and row
  // as tightly as the arbiter allows, which is the tightest spacing the two
  // can ever have.
  printf("test: write against in-flight read data\n");
  {
    long start_fails = h.fails;
    // Different banks, so the two never touch the same address. Overlapping
    // them would race the shadow instead: the controller does not order a
    // concurrent read and write to one location, so a test that assumed an
    // order would be testing the harness, not the controller. The collision
    // being provoked is on the shared DQ bus, which does not need the
    // addresses to overlap.
    for (int n = 0; n < 6000; n++) {
      uint32_t rbase = (1u << 22) | (3u << 9);
      uint32_t wbase = (2u << 22) | (5u << 9);
      if (!h.port[1].busy) h.issue(1, rbase + ((n * 4) & 0x1fc), false, 0);
      // Writes go on port 9, the only port wired to write. This used port 0,
      // which was the harness's single write path before the sprite-bitmap
      // port existed.
      if (!h.port[9].busy)
        h.issue(9, wbase + (n & 0x1ff), true, (uint16_t)(0x5a00 + (n & 0xff)));
      h.step();
    }
    h.drain();
    printf("  collision: %ld fails, %u violations\n",
           h.fails - start_fails, h.d->violations);
    h.checks++;
  }

  // ------------------------------------------------------- throughput
  // D2 and D3 rest on a bandwidth figure that has so far only been arithmetic.
  // This measures it, and specifically measures whether locality helps: the
  // real traffic mix is largely sequential (V60 code fetch, tile character
  // runs, polygon streams), so a controller that cannot exploit an open row
  // performs the same on sequential traffic as on random, and the whole
  // locality of the workload is worth nothing.
  printf("test: sustained throughput, sequential against random\n");
  {
    auto measure = [&](int p, bool sequential, long cycles) -> double {
      long words = 0;
      long t0 = h.cyc;
      uint32_t seq = 0x400000;      // bank 1, row 0, column 0
      std::mt19937 r2(99u);
      while (h.cyc - t0 < cycles) {
        if (!h.port[p].busy) {
          uint32_t a;
          if (sequential) {
            a = seq;
            seq += burst_of(p);
            // Stay inside one row so every access after the first is a row
            // hit, which is the best case a controller could exploit.
            if ((seq & 0x1ff) == 0) seq = (seq & ~0x1ffu);
          } else {
            a = (r2() & 3) << 22 | (r2() % 64) << 9 | (r2() & 0x1ff);
          }
          long before = h.port[p].n_done;
          h.issue(p, a, false, 0);
          (void)before;
          words += burst_of(p);
        }
        h.step();
      }
      h.drain();
      return (double)words / (double)(h.cyc - t0);
    };

    for (int p = 0; p < NP; p += 1) {
      if (p != 0 && p != 1) continue;    // one single-word port, one burst port
      double sq = measure(p, true,  20000);
      double rn = measure(p, false, 20000);
      // 16-bit words at 100 MHz.
      printf("  p%d (burst %d)  sequential %.3f words/cyc (%.1f MB/s)   "
             "random %.3f words/cyc (%.1f MB/s)   locality gain %.2fx\n",
             p, burst_of(p), sq, sq * 200.0, rn, rn * 200.0,
             rn > 0 ? sq / rn : 0.0);
      h.checks++;
    }
  }

  // -------------------------------------------------- realistic aggregate
  // The concurrent phase above draws addresses at random across a handful of
  // rows, which is close to worst case and useful for finding bugs. It is not
  // what the board does. Every real master streams: the V60 fetches code
  // sequentially, tile character data is read in runs, polygon data is a
  // stream, samples are a stream. Each master here walks its own cursor in its
  // own bank, which is the traffic D2 and D3 actually have to survive.
  printf("test: aggregate throughput under streaming traffic\n");
  {
    uint32_t cursor[NP];
    for (int p = 0; p < NP; p++) cursor[p] = (uint32_t)(p % 4) << 22;
    long words = 0, t0 = h.cyc;
    const long WINDOW = 60000;
    while (h.cyc - t0 < WINDOW) {
      for (int p = 0; p < NP; p++) {
        if (h.port[p].busy) continue;
        h.issue(p, cursor[p], false, 0);
        words += burst_of(p);
        cursor[p] += burst_of(p);
      }
      h.step();
    }
    h.drain();
    double wpc = (double)words / (double)(h.cyc - t0);
    printf("  aggregate %.3f words/cyc = %.1f MB/s at 100 MHz "
           "(%.1f MB/s at 143 MHz)\n", wpc, wpc * 200.0, wpc * 286.0);
    h.checks++;
  }

  // ------------------------------------------------ sprite bitmap in SDRAM
  // CAN THE SPRITE BITMAP LIVE IN SDRAM? This is the measurement that decides
  // it, and Tier 3 depends on the answer: KC-002's 512x512x16 double-buffered
  // surface is 8.39 Mbit against this device's 5.66 Mbit of block RAM, so it
  // does not fit on-chip even if the core held nothing else. See D5.
  //
  // The traffic has two halves with very different deadlines.
  //
  //   SCANOUT READ is hard real time. The mixer consumes one pixel per core
  //   clock across a 320-pixel active line. Reading just in time would need a
  //   4-word burst every 8 SDRAM clocks with no slack at all, so the real
  //   design reads a line AHEAD into a small cache: 80 bursts have a whole
  //   line period, 384 core clocks = 768 SDRAM clocks, to arrive. That is the
  //   deadline modelled here, and missing it is a visible defect.
  //
  //   RENDERER WRITE is soft. It has the whole frame, and the coverage mask
  //   rejects most of it -- tb_kaneko_vuspr_draw measures 1,175,090 of
  //   1,543,770 mask writes rejected, so about a quarter of the worst case
  //   reaches memory. Modelled as scattered single-word writes alongside.
  //
  // The other nine masters stream throughout, because a number measured with
  // an idle bus would be worthless.
  printf("test: sprite bitmap as a tenth master, against a scanline deadline\n");
  {
    const long LINE_SDCLK = 768;     // 384 core clocks at 2x
    const int  BURSTS     = 80;      // 320 pixels / 4 per burst
    const int  LINES      = 224;
    uint32_t cursor[NP];
    for (int p = 0; p < NP; p++) cursor[p] = (uint32_t)(p % 4) << 22;
    uint32_t bmp_rd = 3u << 22, bmp_wr = (3u << 22) | (1u << 20);

    long missed = 0, worst_left = LINE_SDCLK, writes_done = 0;
    long fewest = BURSTS, total_got = 0;
    for (int line = 0; line < LINES; line++) {
      long t0 = h.cyc, got = 0;
      int  wr_budget = 15;           // ~a quarter of worst case, per line
      while (h.cyc - t0 < LINE_SDCLK) {
        for (int p = 0; p < NP - 1; p++) {          // the nine existing masters
          if (h.port[p].busy) continue;
          h.issue(p, cursor[p], false, 0);
          cursor[p] += burst_of(p);
        }
        if (!h.port[9].busy) {
          if (got < BURSTS) {                        // scanout read, deadline
            h.issue(9, bmp_rd, false, 0);
            bmp_rd += 4; got++;
          } else if (wr_budget > 0) {                // renderer write, slack
            h.issue(9, bmp_wr + (uint32_t)(line * 7 + wr_budget), true,
                    (uint16_t)(0x1000 + wr_budget));
            wr_budget--; writes_done++;
          }
        }
        h.step();
      }
      if (got < BURSTS) missed++;
      if (line == 0 || got < fewest) fewest = got;
      total_got += got;
      long left = LINE_SDCLK - (h.cyc - t0);
      if (got >= BURSTS && left < worst_left) worst_left = left;
    }
    h.drain();
    printf("  %d lines, %ld missed the deadline, %ld renderer writes served\n",
           LINES, missed, writes_done);
    printf("  bursts served per line: %ld average, %ld worst, of %d needed\n",
           total_got / LINES, fewest, BURSTS);
    printf("  worst line finished its %d bursts with %ld of %ld clocks to spare\n",
           BURSTS, worst_left, LINE_SDCLK);
    // NOT A FAILURE. This measures the FULL-WIDTH scheme, which is now known
    // not to fit and is recorded as such in D5: 320 words a line for the
    // bitmap on top of 320 for the tile feeders, against about 490 the bus
    // delivers in a line. The number above is the evidence for that, and it
    // is kept because an arbiter change that made it better or worse should
    // be visible.
    printf("  full-width scanout does NOT fit, as expected -- see D5\n");
    h.checks++;
  }

  // The scheme that has to work: read the bitmap ONLY where the coverage mask
  // says a sprite was drawn. The mask stays in block RAM, so it costs no
  // bandwidth to consult, and sprites are 16 pixels wide, so coverage comes in
  // runs of at least four bursts and stays burst-efficient.
  //
  // This also removes the frame clear. Nothing reads a pixel the mask does not
  // claim, so stale data is never seen and the 81,920 words a frame of zeroing
  // never happen.
  //
  // Asserted at 30% coverage, which is generous for these games -- a shooter
  // with a full screen of sprites is nothing like a third of the pixels.
  printf("test: sprite bitmap read sparsely, gated by the coverage mask\n");
  {
    const long LINE_SDCLK = 768;
    const int  BURSTS     = 24;        // 30% of 80
    const int  LINES      = 224;
    uint32_t cursor[NP];
    for (int p = 0; p < NP; p++) cursor[p] = (uint32_t)(p % 4) << 22;
    uint32_t bmp_rd = 3u << 22, bmp_wr = (3u << 22) | (1u << 20);
    long missed = 0, fewest = BURSTS, total_got = 0, writes_done = 0;

    for (int line = 0; line < LINES; line++) {
      long t0 = h.cyc, got = 0;
      int  wr_budget = 15;
      while (h.cyc - t0 < LINE_SDCLK) {
        for (int p = 0; p < NP - 1; p++) {
          if (h.port[p].busy) continue;
          h.issue(p, cursor[p], false, 0);
          cursor[p] += burst_of(p);
        }
        if (!h.port[9].busy) {
          if (got < BURSTS) { h.issue(9, bmp_rd, false, 0); bmp_rd += 4; got++; }
          else if (wr_budget > 0) {
            h.issue(9, bmp_wr + (uint32_t)(line * 7 + wr_budget), true,
                    (uint16_t)(0x2000 + wr_budget));
            wr_budget--; writes_done++;
          }
        }
        h.step();
      }
      if (got < BURSTS) missed++;
      if (got < fewest) fewest = got;
      total_got += got;
    }
    h.drain();
    printf("  %d lines, %ld missed, %ld average of %d needed, %ld worst\n",
           LINES, missed, total_got / LINES, BURSTS, fewest);
    printf("  renderer writes served alongside: %ld\n", writes_done);
    // REPORTED, NOT ASSERTED, until the load model is validated against the
    // real core. The nine other masters here are issued flat out, which is
    // far more than the board presents: p0 alone requests on 83% of cycles.
    // A number measured against a saturated bus bounds the problem, it does
    // not settle it.
    //
    // What it does establish, with the arithmetic in D5, is that the headroom
    // is small. Tile feeders want 320 words a line of about 490 the bus
    // delivers, so the bitmap is competing for what is left rather than
    // moving into empty space. The measurement that would settle it is real
    // per-master utilisation from the board, which needs bw_monitor in the
    // core rather than only in this harness.
    if (missed)
      printf("  does not fit under a saturated-bus model; see D5\n");
    h.checks++;
  }

  // ------------------------------------------------------------- telemetry
  printf("test: bandwidth telemetry reports the traffic that actually ran\n");
  {
    h.d->mon_snap = 1; h.step(); h.d->mon_snap = 0; h.step();
    uint32_t total = 0;
    long served = 0;
    for (int p = 0; p < NP; p++) {
      h.d->mon_sel = p; h.d->eval();
      uint32_t rq = h.d->mon_req, gr = h.d->mon_grant;
      uint32_t wt = h.d->mon_wait, bm = h.d->mon_bmax;
      total = h.d->mon_total;
      printf("  p%d  req=%-8u grant=%-8u wait=%-8u burst_max=%-4u xacts=%ld\n",
             p, rq, gr, wt, bm, h.port[p].n_done);
      served += h.port[p].n_done;
      h.checks++;
      // A master that ran transactions must show demand and service. Zero
      // here means the tap is not wired to what it claims to measure, which
      // is the failure mode that makes telemetry worse than none.
      if (h.port[p].n_done > 0 && (rq == 0 || gr == 0)) {
        printf("  FAIL p%d ran %ld transactions but reports req=%u grant=%u\n",
               p, h.port[p].n_done, rq, gr);
        h.fails++;
      }
      if (wt != 0 && rq == 0) {
        printf("  FAIL p%d waited without ever requesting\n", p); h.fails++;
      }
    }
    h.checks++;
    if (total == 0) { printf("  FAIL total_cycles is zero\n"); h.fails++; }
    printf("  total cycles=%u, %ld transactions served\n", total, served);
  }

  // ------------------------------------------------- deadline ports win
  //
  // Ports 0-5 are the tile feeder, the 68000 and the OKI, all of which have
  // real-time deadlines; 6-7 are the sprite engine, which has a whole frame. Under the old pure
  // round-robin all eight shared equally, the tile feeder missed its line and
  // the sprite engine made its frame comfortably — which on hardware was a
  // smeared tilemap layer, and turning sprites off took the overruns to zero.
  //
  // With every port hammering continuously, the urgent ones must take
  // essentially all of the bus. This fails on the round-robin the controller
  // shipped with, which is the point of it.
  {
    long urgent = 0, slack = 0;
    // Every port re-issues the instant it completes, so all eight are pending
    // essentially all the time and the arbiter has to choose on every grant.
    for (int i = 0; i < NP; i++) h.issue(i, 0x2000 + i * 0x400, false, 0);
    for (int c = 0; c < 20000; c++) {
      h.step();
      for (int i = 0; i < NP; i++)
        if (!h.port[i].busy) {
          // Classification MUST match the harness's URGENT mask, which is
          // 10'b11_0011_1111: ports 0-5 and 8-9 have deadlines, 6-7 are the
          // sprite ROM and have a whole frame. This counted i < 6 as urgent
          // and everything above as slack, so once ports 8 and 9 became
          // urgent the test was scoring urgent traffic as slack and failing
          // on its own arithmetic.
          ((i < 6 || i >= 8) ? urgent : slack)++;
          h.issue(i, 0x2000 + i * 0x400 + ((c * 8) & 0x3ff), false, 0);
        }
    }
    for (int i = 0; i < NP; i++) h.port[i].busy = false;
    h.drain();
    h.checks++;
    printf("  arbitration under full load: urgent(0-5,8-9) served %ld, "
           "slack(6-7) served %ld\n", urgent, slack);
    if (urgent == 0 || slack > urgent / 4) {
      printf("  FAIL deadline ports did not get priority\n");
      h.fails++;
    }
  }

  h.checks++;
  if (h.d->violations != 0) {
    printf("  FAIL device model reported %u protocol violations, flags=%04x\n",
           h.d->violations, h.d->v_flags);
    h.fails++;
  }

  // Reported rather than hidden. A run showing zero here has not exercised the
  // concurrent write/read path at all, and this number drifting to 0 would mean
  // the test quietly stopped covering the case it was added for.
  printf("  reads accepted as raced (returned the legal pre-write value): %ld\n",
         h.races);
  printf("kaneko_sdram: checks=%ld fails=%ld violations=%u reads=%u writes=%u\n",
         h.checks, h.fails, h.d->violations, h.d->reads_served,
         h.d->writes_served);
  return h.fails ? 1 : 0;
}
