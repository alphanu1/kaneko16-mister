// SPDX-License-Identifier: GPL-3.0-or-later
//
// End-to-end check of kaneko_calc3: drive it exactly as the 68000 does and
// compare the whole 64 KB of MCU RAM against the C model afterwards.
//
// This is the test that covers the parts the piece-wise ones cannot: the
// command handshake, the init parameter block, the ROM checksum, the EEPROM
// copy, the rolling write pointer across several transfers, the header and
// pointer writeback, and the mode 6 pointer reset.
//
// Comparing the WHOLE image matters. Checking only the bytes the model expects
// to change would pass a device that also wrote somewhere it should not, and
// the destination here is RAM the 68000 is using for everything else.
//
// The model is the same one tools/calc3_ref.py carries, and that copy is
// checked against MAME's real output by `make calc3` on both games. So the
// chain is: RTL against C model here, C model against MAME there.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <random>
#include <vector>
#include "calc3_model.h"
#include "Vkaneko_calc3_harness.h"
#include "verilated.h"

namespace {

// MUST match kaneko_calc3_harness's ROM_BYTES. It did not, once: the
// harness ran on the device's 128 KB default and every trial timed out.
constexpr int ROM_BYTES = 4096;

// Read the .hex pair the device's key ROM loads, so the model and the device
// agree about which keys exist.
std::vector<std::vector<int>> read_keys() {
  auto slurp = [](const char* path) {
    std::vector<int> out;
    FILE* f = fopen(path, "r");
    if (!f) { printf("  FAIL cannot open %s\n", path); exit(2); }
    char line[512];
    while (fgets(line, sizeof line, f)) {
      if (char* c = strstr(line, "//")) *c = 0;
      char* q = line;
      while (*q == ' ' || *q == '\t') q++;
      if (*q == 0 || *q == '\n' || *q == '\r') continue;
      out.push_back((int)strtol(q, nullptr, 16));
    }
    fclose(f);
    return out;
  };
  const auto kd = slurp("rtl/mcu/calc3_keys.hex");
  const auto ki = slurp("rtl/mcu/calc3_keyidx.hex");
  std::vector<std::vector<int>> keys(256, std::vector<int>(64, -1));
  for (int k = 0; k < 256 && k < (int)ki.size(); k++) {
    if (ki[k] == 0x3f) continue;
    for (int i = 0; i < 64; i++) keys[k][i] = kd[ki[k] * 64 + i];
  }
  return keys;
}

std::vector<int> g_present;

std::vector<uint8_t> make_rom(std::mt19937& rng, int n,
                              std::vector<int>& lengths) {
  std::vector<uint8_t> rom;
  rom.push_back((uint8_t)n);
  for (int i = 0; i < n; i++) {
    const bool inl = (rng() & 1);
    const int isize = inl ? (int)(1 + rng() % 12) : 0;
    const int bso = inl ? isize + 3 : 3;
    // Zero length appears often enough to reach the control-operation path,
    // and mode 6 among those to reach the pointer reset.
    const int length = (rng() % 6 == 0) ? 0 : (int)(1 + rng() % 120);
    rom.push_back((uint8_t)bso);
    rom.push_back((length == 0 && (rng() & 1)) ? 0x06 : (uint8_t)(rng() & 0xff));
    rom.push_back((uint8_t)(rng() & 0xff));
    // Always a key that EXISTS.
    //
    // A missing key has no defined behaviour to match: MAME calls
    // fatalerror() and stops the machine, so no real data ROM contains one --
    // if one did, the game would never have run. Fuzzing it only compares two
    // arbitrary choices about what to do instead. The device's refusal is
    // checked directly further down, where the expected outcome is stated
    // rather than guessed at.
    rom.push_back((uint8_t)g_present[rng() % g_present.size()]);
    for (int k = 0; k < isize; k++) rom.push_back((uint8_t)rng());
    rom.push_back((uint8_t)(length & 0xff));
    rom.push_back((uint8_t)((length >> 8) & 0xff));
    for (int k = 0; k < length; k++) rom.push_back((uint8_t)rng());
    lengths.push_back(length);
  }
  rom.resize(ROM_BYTES, 0);
  return rom;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vkaneko_calc3_harness;
  std::mt19937 rng(0xca1c3333u);
  long checks = 0, fails = 0;
  long inits = 0, transfers = 0, resets = 0;

  // THE REAL KEY TABLE, read from the same files the device's key ROM loads.
  //
  // A synthetic table here was wrong, and it looked exactly like an RTL fault.
  // Only 36 of the 256 key bytes name a key that exists; the generator was
  // drawing from 0..31, where most do not; so the device correctly refused
  // tables the model happily decoded. Whichever tables happened to draw a real
  // key passed, which read as alternate transfers being silently dropped.
  auto keys = read_keys();
  std::vector<int> present;
  for (int k = 0; k < 256; k++) if (keys[k][0] != -1) present.push_back(k);
  if (present.empty()) { printf("  FAIL no keys loaded\n"); return 2; }
  printf("keys: %zu present\n", present.size());

  uint16_t eeprom[64];
  for (auto& e : eeprom) e = (uint16_t)rng();

  auto tick = [&] { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  for (int trial = 0; trial < 40; trial++) {
    std::vector<int> lengths;
    const int ntab = 4 + (int)(rng() % 8);
    g_present = present;
    auto rom = make_rom(rng, ntab, lengths);

    uint16_t crc = 0;
    for (int i = 0; i < ROM_BYTES; i++) crc = (uint16_t)(crc + rom[i]);

    std::vector<uint8_t> ram(0x10000, 0);
    calc3::Sequencer model;
    model.rom = &rom; model.keys = &keys; model.crc = crc;

    // The init parameter block, laid out as the game lays it out.
    const uint16_t dsw_addr = 0x0059, eep_base = 0x019e, cmd_base = 0x030a;
    const uint16_t poll = 0xfffe, csum = 0x0042;
    const uint32_t wbase = 0x00207fe0;
    auto poke16 = [&](std::vector<uint8_t>& m, int off, uint16_t v) {
      m[off] = (uint8_t)(v >> 8); m[off + 1] = (uint8_t)v;
    };
    for (auto* m : {&ram, &model.ram}) {
      poke16(*m, 2, dsw_addr);  poke16(*m, 4, eep_base);
      poke16(*m, 6, cmd_base);  poke16(*m, 8, poll);
      poke16(*m, 10, csum);
      poke16(*m, 12, (uint16_t)(wbase >> 16));
      poke16(*m, 14, (uint16_t)wbase);
      poke16(*m, 0, 0x00ff);
    }

    const uint8_t dsw = (uint8_t)rng();
    d->dsw = dsw;
    d->rst_n = 0; d->com_w = 0; d->tick = 0;
    d->rom_valid = 0; d->ram_valid = 0; d->eep_data = 0;
    for (int i = 0; i < 4; i++) tick();
    d->rst_n = 1;

    // Serve memory until the checksum scan finishes and the device idles.
    int rom_pend = -1, rom_delay = 0, ram_pend = -1, ram_delay = 0;
    bool ram_is_write = false;
    uint16_t ram_wd = 0; uint8_t ram_be = 0;

    auto serve = [&] {
      if (d->rom_rd) { rom_pend = d->rom_addr; rom_delay = (int)(rng() % 3); }
      d->rom_valid = 0;
      if (rom_pend >= 0 && rom_delay-- <= 0) {
        d->rom_data = (rom_pend < (int)rom.size()) ? rom[rom_pend] : 0;
        d->rom_valid = 1;
        rom_pend = -1;
      }
      if (d->ram_rd || d->ram_wr) {
        ram_pend = d->ram_addr; ram_delay = (int)(rng() % 3);
        ram_is_write = d->ram_wr; ram_wd = d->ram_wdata; ram_be = d->ram_be;
      }
      d->ram_valid = 0;
      if (ram_pend >= 0 && ram_delay-- <= 0) {
        const int a = ram_pend & 0xfffe;
        if (ram_is_write) {
          if (ram_be & 2) ram[a]     = (uint8_t)(ram_wd >> 8);
          if (ram_be & 1) ram[a + 1] = (uint8_t)ram_wd;
        } else {
          d->ram_rdata = (uint16_t)((ram[a] << 8) | ram[a + 1]);
        }
        d->ram_valid = 1;
        ram_pend = -1;
      }
      d->eep_data = eeprom[d->eep_addr & 0x3f];
    };

    std::vector<uint8_t> stream;
    long starts = 0, vcount = 0;
    size_t last_stream = 0;
    long guard = 0;
    while (!d->crc_ready && guard++ < 200000) { serve(); tick(); }
    checks++;
    if (!d->crc_ready) { printf("  FAIL trial %d: checksum never finished\n", trial); fails++; continue; }

    // All four command registers, then a frame tick.
    d->com_w = 0xf; serve(); tick(); d->com_w = 0;

    auto run_one = [&](uint16_t cmdval) {
      stream.clear();
      starts = 0; vcount = 0; last_stream = 0;
      d->tick = 1; serve(); tick(); d->tick = 0;
      long g = 0;
      while (d->busy && g++ < 2000000) {
        serve();
        // The byte the core is offering, taken on the edge where the
        // sequencer is ready for it.
        if (d->dbg_start) starts++;
        if (d->dbg_out_valid) vcount++;
        if (d->dbg_done && getenv("C3DBG")) {
          printf("        core done: tab=%02x len=%d taken=%zu tbytes=%d "
                 "wcur=%08x\n", d->dbg_tab, d->dbg_len,
                 stream.size() - last_stream, d->dbg_tbytes, d->dbg_wcur);
          vcount = 0; last_stream = stream.size();
        }
        const bool took = d->dbg_out_valid && d->dbg_out_ready;
        const uint8_t b = d->dbg_out_byte;
        tick();
        if (took) stream.push_back(b);
      }
      if (g >= 2000000)
        printf("    stuck: ram_addr=%04x rd=%d wr=%d be=%d wdata=%04x "
               "eep=%02x busy=%d\n", d->ram_addr, d->ram_rd, d->ram_wr,
               d->ram_be, d->ram_wdata, d->eep_addr, d->busy);
      // Let any trailing write drain.
      for (int i = 0; i < 8; i++) { serve(); tick(); }
      model.run_dsw(dsw);
      model.command(cmdval, eeprom);
      if (getenv("C3DBG"))
        printf("      cmd %04x: %ld starts, %zu bytes, tbusy=%d, model write_cur=%08x\n",
               cmdval, starts, stream.size(), d->dbg_tbusy, model.write_cur);
      return g < 2000000;
    };

    if (!run_one(0x00ff)) { printf("  FAIL trial %d: init hung\n", trial); fails++; continue; }
    inits++;

    // Two or three transfer commands, so the write pointer has to roll.
    const int rounds = 2 + (int)(rng() % 2);
    bool hung = false;
    for (int r = 0; r < rounds && !hung; r++) {
      const int count = 1 + (int)(rng() % 3);
      // Draw the table numbers ONCE and poke both memories with the same
      // values. Drawing them inside the loop over the two gave the device and
      // the model different commands, and the mismatch it produced looked
      // exactly like the device writing the wrong table.
      std::vector<uint16_t> tabs(count);
      for (int i = 0; i < count; i++) tabs[i] = (uint16_t)((rng() % ntab) << 8);
      for (auto* m : {&ram, &model.ram}) {
        for (int i = 0; i < count; i++) {
          poke16(*m, cmd_base + 2 + 4 * i, tabs[i]);
          poke16(*m, cmd_base + 4 + 4 * i, (uint16_t)(0x0400 + 8 * i));
        }
        poke16(*m, cmd_base, (uint16_t)count);
      }
      hung = !run_one((uint16_t)count);
      transfers += count;
    }
    if (hung) { printf("  FAIL trial %d: transfer hung\n", trial); fails++; continue; }
    if (model.write_cur == 0x00202000) resets++;

    checks++;
    if (ram != model.ram) {
      size_t first = 0;
      while (first < ram.size() && ram[first] == model.ram[first]) first++;
      size_t ndiff = 0;
      for (size_t i = 0; i < ram.size(); i++) if (ram[i] != model.ram[i]) ndiff++;
      if (fails < 4) {
        printf("  FAIL trial %d: RAM differs from %04zx (got %02x want %02x), "
               "%zu bytes differ\n", trial, first, ram[first], model.ram[first],
               ndiff);
        printf("    model placed:");
        for (auto& pl : model.placements) printf(" t%02x@%06x", pl.first, pl.second);
        printf("\n    model write_cur=%08x key_missing=%d\n",
               model.write_cur, (int)model.key_missing);
        for (int a : {0x7fe0, 0x7ff4, 0x2000}) {
          printf("    @%04x got", a);
          for (int k = 0; k < 8; k++) printf(" %02x", ram[a + k]);
          printf("  want");
          for (int k = 0; k < 8; k++) printf(" %02x", model.ram[a + k]);
          printf("\n");
        }
        for (auto& pl : model.placements) {
          calc3::Block b{};
          std::vector<uint8_t> h, o;
          calc3::decode(rom, pl.first, keys, h, o, b);
          printf("      t%02x len=%d isize=%d mode=%02x out=%zu\n",
                 pl.first, b.length, b.inline_size, b.mode, o.size());
        }
      }
      fails++;
    }
  }

  // ------------------------------------------------ the refusal, directly
  //
  // A block naming a key that does not exist. MAME calls fatalerror() here and
  // stops the machine, so no real data ROM contains one -- which is why this
  // is stated rather than fuzzed. A core cannot stop, so the device must skip
  // the transfer: raise key_missing, write nothing, and leave the write
  // pointer where it was. Advancing it would put every later table in the
  // wrong place and hand the game a pointer to the wrong address.
  {
    int absent = -1;
    for (int k = 0; k < 256 && absent < 0; k++) if (keys[k][0] == -1) absent = k;

    std::vector<int> lengths;
    g_present = present;
    auto rom = make_rom(rng, 3, lengths);
    // Force table 0's block to name the missing key. Byte 4 of the image is
    // its key byte: 1 for the count, then bso, mode, packed, key.
    rom[4] = (uint8_t)absent;
    // ...and make sure it is a KEYED block, not an inline one.
    rom[1] = 3;

    uint16_t crc = 0;
    for (int i = 0; i < ROM_BYTES; i++) crc = (uint16_t)(crc + rom[i]);
    std::vector<uint8_t> ram(0x10000, 0);
    auto poke16 = [&](std::vector<uint8_t>& m, int off, uint16_t v) {
      m[off] = (uint8_t)(v >> 8); m[off + 1] = (uint8_t)v;
    };
    poke16(ram, 2, 0x0059);  poke16(ram, 4, 0x019e);
    poke16(ram, 6, 0x030a);  poke16(ram, 8, 0xfffe);
    poke16(ram, 10, 0x0042);
    poke16(ram, 12, 0x0020); poke16(ram, 14, 0x7fe0);
    poke16(ram, 0, 0x00ff);

    d->dsw = 0;
    d->rst_n = 0; d->com_w = 0; d->tick = 0;
    d->rom_valid = 0; d->ram_valid = 0;
    for (int i = 0; i < 4; i++) { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
    d->rst_n = 1;

    int rp = -1, rd = 0, ap = -1, ad = 0; bool aw = false;
    uint16_t awd = 0; uint8_t abe = 0;
    auto serve2 = [&] {
      if (d->rom_rd) { rp = d->rom_addr; rd = 0; }
      d->rom_valid = 0;
      if (rp >= 0 && rd-- <= 0) {
        d->rom_data = (rp < (int)rom.size()) ? rom[rp] : 0;
        d->rom_valid = 1; rp = -1;
      }
      if (d->ram_rd || d->ram_wr) {
        ap = d->ram_addr; ad = 0; aw = d->ram_wr; awd = d->ram_wdata; abe = d->ram_be;
      }
      d->ram_valid = 0;
      if (ap >= 0 && ad-- <= 0) {
        const int a = ap & 0xfffe;
        if (aw) {
          if (abe & 2) ram[a] = (uint8_t)(awd >> 8);
          if (abe & 1) ram[a + 1] = (uint8_t)awd;
        } else {
          d->ram_rdata = (uint16_t)((ram[a] << 8) | ram[a + 1]);
        }
        d->ram_valid = 1; ap = -1;
      }
      d->eep_data = eeprom[d->eep_addr & 0x3f];
    };
    auto tick2 = [&] { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

    long g = 0;
    while (!d->crc_ready && g++ < 400000) { serve2(); tick2(); }
    d->com_w = 0xf; serve2(); tick2(); d->com_w = 0;
    d->tick = 1; serve2(); tick2(); d->tick = 0;
    g = 0; while (d->busy && g++ < 2000000) { serve2(); tick2(); }

    // Now a transfer of table 0, the one with the missing key.
    poke16(ram, 0x030a + 2, 0x0000);
    poke16(ram, 0x030a + 4, 0x0400);
    poke16(ram, 0x030a, 1);
    std::vector<uint8_t> before = ram;
    d->tick = 1; serve2(); tick2(); d->tick = 0;
    g = 0; while (d->busy && g++ < 2000000) { serve2(); tick2(); }
    for (int i = 0; i < 8; i++) { serve2(); tick2(); }

    checks++;
    if (!d->key_missing) { printf("  FAIL missing key not reported\n"); fails++; }

    // Two writes are correct and expected: the command word cleared as the
    // handshake, and the DSW, which the device writes at the top of EVERY run
    // whatever the command turns out to be. Nothing else may move.
    before[0x030a] = ram[0x030a]; before[0x030b] = ram[0x030b];
    before[0x0059] = ram[0x0059];
    checks++;
    if (ram != before) {
      size_t first = 0;
      while (first < ram.size() && ram[first] == before[first]) first++;
      printf("  FAIL refused transfer wrote at %04zx (%02x -> %02x)\n",
             first, before[first], ram[first]);
      fails++;
    }
    printf("  refusal: key %02x, key_missing=%d, RAM untouched=%d\n",
           absent, (int)d->key_missing, (int)(ram == before));
  }

  if (!inits || !transfers) {
    printf("  FAIL a path was never reached: inits=%ld transfers=%ld\n",
           inits, transfers);
    fails++;
  }

  printf("kaneko_calc3: checks=%ld fails=%ld inits=%ld transfers=%ld "
         "ptr_resets=%ld\n", checks, fails, inits, transfers, resets);
  delete d;
  return fails ? 1 : 0;
}
