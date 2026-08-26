// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CALC3 in the topology the core actually wires: device, ROM feeder and
// arbiter over one SDRAM port, with the 68000 competing for that port.
//
// The first thing it has to answer is the one hardware asked: does the
// checksum scan finish? The device sums its whole data ROM at reset, and on
// the board crc_ready never set and both games hung. Nothing before this
// simulated the three together, so nothing before this could have said why.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <random>
#include <vector>
#include "Vkaneko_calc3_sys_harness.h"
#include "verilated.h"

namespace {
constexpr int ROM_BYTES  = 4096;         // matches the harness parameter
constexpr uint32_t BASE_ROM = 0x020000;  // word addresses, as the core uses
constexpr uint32_t BASE_RAM = 0x0bb0000;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_calc3_sys_harness;
  std::mt19937 rng(0xc3515u);
  long checks = 0, fails = 0;

  // A behavioural SDRAM: word addressed, four-word bursts, variable latency,
  // and it serves ONE access at a time -- which is the whole point.
  std::map<uint32_t, uint16_t> mem;
  std::vector<uint8_t> rom(ROM_BYTES);
  for (int i = 0; i < ROM_BYTES; i++) rom[i] = (uint8_t)rng();
  // The data ROM lives in that memory, two bytes per word, low byte first --
  // the loader's byte order for a byte-addressed region.
  for (int i = 0; i < ROM_BYTES; i += 2)
    mem[BASE_ROM + i / 2] = (uint16_t)(rom[i] | (rom[i + 1] << 8));

  uint16_t crc = 0;
  for (int i = 0; i < ROM_BYTES; i++) crc = (uint16_t)(crc + rom[i]);

  auto tick = [&] { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  d->rst = 1; d->com_w = 0; d->tick = 0; d->dsw = 0xe5;
  d->cpu_req = 0; d->cpu_we = 0; d->cpu_be = 3; d->s_ack = 0;
  d->base_mcuram = BASE_RAM; d->base_calc3rom = BASE_ROM;
  d->eep_data = 0;
  for (int i = 0; i < 8; i++) tick();
  d->rst = 0;

  bool sb = false; int sd = 0;
  uint32_t sa = 0; bool sw = false; uint16_t sdin = 0; uint8_t sbe = 3;
  long sdram_reads = 0, sdram_writes = 0;

  auto serve = [&] {
    d->s_ack = 0;
    if (d->s_req && !sb) {
      sb = true; sd = (int)(rng() % 6);
      sa = d->s_addr; sw = d->s_we; sdin = d->s_din; sbe = d->s_be;
    }
    if (sb && sd-- <= 0) {
      if (sw) {
        uint16_t cur = mem.count(sa) ? mem[sa] : 0;
        if (sbe & 2) cur = (uint16_t)((cur & 0x00ff) | (sdin & 0xff00));
        if (sbe & 1) cur = (uint16_t)((cur & 0xff00) | (sdin & 0x00ff));
        mem[sa] = cur; sdram_writes++;
      } else {
        uint64_t v = 0;
        for (int w = 0; w < 4; w++) {
          const uint32_t a = (sa & ~3u) + w;
          const uint16_t x = mem.count(a) ? mem[a] : 0;
          v |= (uint64_t)x << (16 * w);
        }
        d->s_dout = v; sdram_reads++;
      }
      d->s_ack = 1; sb = false;
    }
  };

  // The 68000 hammers the shared RAM throughout, HOLDING each request until
  // acknowledged, exactly as kaneko_bus does. Without a competitor the arbiter
  // is never busy and the interesting case never arises.
  bool cpu_out = false;
  long cpu_done = 0;

  printf("waiting for the checksum scan...\n");
  long cyc = 0;
  const long LIMIT = 4000000;
  while (!d->crc_ready && cyc++ < LIMIT) {
    if (!cpu_out) {
      d->cpu_addr = BASE_RAM + (rng() % 64);
      d->cpu_we = 0; d->cpu_req = 1; cpu_out = true;
    }
    serve();
    tick();
    if (d->cpu_ack) { cpu_out = false; d->cpu_req = 0; cpu_done++; }
  }

  checks++;
  if (!d->crc_ready) {
    printf("  FAIL crc_ready never set after %ld cycles "
           "(sdram reads %ld, cpu served %ld)\n", cyc, sdram_reads, cpu_done);
    fails++;
  } else {
    printf("  scan finished after %ld cycles, %ld sdram reads, "
           "%ld cpu accesses served\n", cyc, sdram_reads, cpu_done);
    checks++;
    if (d->dbg_crc != crc) {
      printf("  FAIL checksum %04x, expected %04x\n", d->dbg_crc, crc);
      fails++;
    } else {
      printf("  checksum %04x matches\n", d->dbg_crc);
    }
  }

  printf("kaneko_calc3_sys: checks=%ld fails=%ld reads=%ld writes=%ld\n",
         checks, fails, sdram_reads, sdram_writes);
  delete d;
  return fails ? 1 : 0;
}
