// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CALC3 over the REAL memory stack: device, ROM feeder and arbiter on one
// SDRAM port, through the 2:1 clock crossing, the controller and the device
// model -- the same path the board takes, with only the physical part missing.
//
// It exists because hardware hung with the MCU's checksum scan never
// finishing, while the same three modules over a behavioural memory completed
// it in 16,622 cycles. Port 10 is the MCU's, and no hardware run had ever used
// it in either direction, so the crossing and the controller were the two
// places left to look.
//
// WHAT IT CHECKS, AND WHAT IT DOES NOT
//
// It checks that the scan COMPLETES: that a byte read issued by the MCU, over
// the arbiter, across the crossing, through the controller and back, is
// acknowledged -- 131,072 times in a row while the 68000 competes for the same
// port. That is the question hardware asked and it is answered here.
//
// It does NOT check the bytes. The harness cannot yet preload the device
// model: writes through the loader port are issued and acknowledged, about
// three slow cycles each, and read back as zero, so something in that path is
// mismatched and it is the harness's problem rather than the core's. Until
// that is understood the scan runs over an empty memory, so the checksum it
// produces means nothing and is not asserted. The bytes are covered elsewhere,
// by `make calc3`, against what MAME actually wrote.
//
// Saying so here rather than asserting a checksum that happens to be stable is
// the point: a green test that checks the wrong thing is worse than no test.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <random>
#include <vector>
#include "Vkaneko_calc3_sys_harness.h"
#include "verilated.h"

namespace {
constexpr int ROM_BYTES  = 4096;
constexpr uint32_t BASE_ROM = 0x020000;
constexpr uint32_t BASE_RAM = 0x030000;   // inside the model's space
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_calc3_sys_harness;
  std::mt19937 rng(0xc3515u);
  long checks = 0, fails = 0;

  std::vector<uint8_t> rom(ROM_BYTES);
  for (int i = 0; i < ROM_BYTES; i++) rom[i] = (uint8_t)rng();
  uint16_t crc = 0;
  for (int i = 0; i < ROM_BYTES; i++) crc = (uint16_t)(crc + rom[i]);

  // Only the FAST clock is driven. The harness divides it for the slow side,
  // so the slow edges cannot drift out of phase with the crossing's own.
  auto half = [&] { d->clk_fast = 0; d->eval(); d->clk_fast = 1; d->eval(); };
  auto slow = [&] { half(); half(); };

  d->clk_fast = 0;
  d->rst = 1; d->com_w = 0; d->tick = 0; d->dsw = 0xe5;
  d->cpu_req = 0; d->cpu_we = 0; d->cpu_be = 3;
  d->ld_req = 0; d->eep_data = 0; d->port_gate = 0;
  d->base_mcuram = BASE_RAM; d->base_calc3rom = BASE_ROM;
  for (int i = 0; i < 40; i++) slow();
  // Reset comes off here, with the PORT still gated.
  //
  // The core does not hold the MCU in reset while the ROM downloads -- it gates
  // every SDRAM port on rom_loaded, so the MCU's reads simply go unacknowledged
  // and its scan cannot advance a byte. Modelling that faithfully matters: when
  // this testbench let the scan run during the load it finished against empty
  // memory with a checksum of 04cf, which is how it was found out that the
  // device starts scanning straight out of reset and only the gate stops it.
  d->rst = 0;

  long guard = 0;
  while (!d->mem_ready && guard++ < 200000) slow();
  checks++;
  if (!d->mem_ready) { printf("  FAIL controller never became ready\n"); fails++;
                       printf("kaneko_calc3_sys: checks=%ld fails=%ld\n", checks, fails);
                       return 1; }
  printf("controller ready after %ld slow cycles\n", guard);

  // Fill the data ROM through the loader port, two bytes a word, low first.
  long load_cyc = 0;
  for (int i = 0; i < ROM_BYTES; i += 2) {
    d->ld_addr = BASE_ROM + i / 2;
    d->ld_din  = (uint16_t)(rom[i] | (rom[i + 1] << 8));
    d->ld_req  = 1;
    long g = 0;
    while (!d->ld_ack && g++ < 100000) { slow(); load_cyc++; }
    if (!d->ld_ack) { printf("  FAIL load of word %d never acked\n", i / 2); fails++; break; }
    d->ld_req = 0;
    slow();
  }
  printf("loaded %d bytes of data ROM in %ld slow cycles (%.1f per word)\n",
         ROM_BYTES, load_cyc, (double)load_cyc / (ROM_BYTES / 2));
  d->port_gate = 1;                 // as rom_loaded does
  for (int i = 0; i < 8; i++) slow();

  d->port_gate = 1;

  // ---------------------------------------------- BYTE WRITES TO MCU RAM
  //
  // The single most load-bearing untested path in the core. Shogun Warriors
  // verifies RAM before it does anything else: a loop at 0x02222e writes a
  // byte, reads it back and compares, and branches away on a mismatch. MAME
  // counts 262,378 BYTE writes into MCU RAM in the first six seconds. That RAM
  // is in SDRAM here, on port 10, through a write path that has never run on
  // hardware -- and if a byte does not read back, the game never leaves that
  // loop and the screen stays black with a perfectly healthy 68000.
  //
  // Write through the CPU master and read back through the CPU master, so this
  // depends on nothing but the path under test.
  {
    // WORD writes first. If these fail too, the fault is the write path as a
    // whole rather than the byte enables, and the two want different fixes.
    printf("word writes to MCU RAM through the real stack:\n");
    long wbad = 0;
    for (int t = 0; t < 16; t++) {
      const uint32_t word = BASE_RAM + (rng() % 32);
      const uint16_t val  = (uint16_t)rng();
      d->cpu_addr = word; d->cpu_we = 1; d->cpu_din = val; d->cpu_be = 3;
      d->cpu_req = 1;
      long g = 0;
      while (!d->cpu_ack && g++ < 100000) slow();
      d->cpu_req = 0; d->cpu_we = 0;
      slow();
      d->cpu_addr = word; d->cpu_req = 1;
      g = 0;
      while (!d->cpu_ack && g++ < 100000) slow();
      const uint16_t got = (uint16_t)((d->cpu_dout >> (16 * (word & 3))) & 0xffff);
      d->cpu_req = 0;
      slow();
      checks++;
      if (got != val) {
        if (wbad < 4)
          printf("  FAIL word %06x: wrote %04x read %04x\n", word, val, got);
        wbad++; fails++;
      }
    }
    printf("  %ld of 16 word writes read back wrong\n", wbad);
    printf("  device model: %u reads, %u writes served\n",
           d->dbg_reads, d->dbg_writes);

    printf("byte writes to MCU RAM through the real stack:\n");
    long bad = 0;
    for (int t = 0; t < 64; t++) {
      const uint32_t word = BASE_RAM + (rng() % 32);
      const int      lane = (int)(rng() & 1);      // 0 = low byte, 1 = high
      const uint8_t  val  = (uint8_t)rng();
      const uint16_t din  = (uint16_t)(val | (val << 8));
      // be[1] is the HIGH half, matching kaneko_bus's {~UDSn, ~LDSn}.
      const uint8_t  be   = lane ? 2 : 1;

      d->cpu_addr = word; d->cpu_we = 1; d->cpu_din = din; d->cpu_be = be;
      d->cpu_req = 1;
      long g = 0;
      while (!d->cpu_ack && g++ < 100000) slow();
      if (!d->cpu_ack) { printf("  FAIL byte write never acked\n"); fails++; break; }
      d->cpu_req = 0; d->cpu_we = 0; d->cpu_be = 3;
      slow();

      d->cpu_addr = word; d->cpu_req = 1;
      g = 0;
      while (!d->cpu_ack && g++ < 100000) slow();
      if (!d->cpu_ack) { printf("  FAIL readback never acked\n"); fails++; break; }
      const uint16_t got16 =
          (uint16_t)((d->cpu_dout >> (16 * (word & 3))) & 0xffff);
      const uint8_t  got = lane ? (uint8_t)(got16 >> 8) : (uint8_t)got16;
      d->cpu_req = 0;
      slow();

      checks++;
      if (got != val) {
        if (bad < 6)
          printf("  FAIL word %06x %s byte: wrote %02x read %02x (word %04x)\n",
                 word, lane ? "high" : "low", val, got, got16);
        bad++; fails++;
      }
    }
    printf("  %ld of 64 byte writes read back wrong\n", bad);
  }

  int shown = 0;
  bool cpu_out = false;
  long cpu_done = 0, cyc = 0;
  const long LIMIT = 8000000;
  printf("waiting for the checksum scan over the real memory stack...\n");
  while (!d->crc_ready && cyc++ < LIMIT) {
    if (!cpu_out) {
      d->cpu_addr = BASE_RAM + (rng() % 64);
      d->cpu_we = 0; d->cpu_req = 1; cpu_out = true;
    }
    const bool took = d->dbg_rom_valid;
    const int  a = d->dbg_rom_addr;
    const int  b = d->dbg_rom_byte;
    slow();
    if (took && shown < 12) {
      printf("    read addr %05x -> %02x  (rom[%05x] = %02x)\n",
             a, b, a, a < ROM_BYTES ? rom[a] : 0);
      shown++;
    }
    if (d->cpu_ack) { cpu_out = false; d->cpu_req = 0; cpu_done++; }
  }

  checks++;
  if (!d->crc_ready) {
    printf("  FAIL crc_ready never set after %ld slow cycles "
           "(cpu served %ld)\n", cyc, cpu_done);
    fails++;
  } else {
    printf("  scan finished after %ld slow cycles, cpu served %ld\n",
           cyc, cpu_done);
    // The checksum is NOT asserted; see the header. Printed so a future run
    // that fixes the preload can see it change.
    printf("  checksum %04x (over empty memory -- not asserted)\n",
           d->dbg_crc);
  }

  printf("kaneko_calc3_sys: checks=%ld fails=%ld\n", checks, fails);
  delete d;
  return fails ? 1 : 0;
}
