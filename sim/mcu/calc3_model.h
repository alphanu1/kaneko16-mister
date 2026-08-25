// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CALC3 decode, in C, for testbenches to check the RTL against.
//
// ONE copy, shared. It started as a copy inside tb_kaneko_calc3_dec.cpp and
// the table testbench needed the same thing; two transcriptions of an
// algorithm this fiddly would drift, and the drift would look like an RTL bug.
//
// Transcribed from MAME's kaneko_calc3.cpp. It is checked against MAME's actual
// output, not just read across, by tools/calc3_ref.py and `make calc3` -- the
// Python carries the same algorithm and reproduces every table shogwarr and
// brapboys pull, byte for byte, addresses included.
#pragma once
#include <cstdint>
#include <vector>
#include <utility>

namespace calc3 {

inline const uint8_t EXTRA[31] = {
    0x14,0xf0,0xf8,0xd2,0xbe,0xfc,0xac,0x86,0x64,0x08,0x0c,0x74,0xd6,0x6a,
    0x24,0x12,0x1a,0x72,0xba,0x48,0x76,0x66,0x4a,0x7c,0x5c,0x82,0x0a,0x86,
    0x82,0x02,0xe6 };
inline const uint8_t EXTRA2[30] = {
    0x2f,0x04,0xd1,0x69,0xad,0xeb,0x10,0x95,0xb0,0x2f,0x0a,0x83,0x7d,0x4e,
    0x2a,0x07,0x89,0x52,0xca,0x41,0xf1,0x4f,0xaf,0x1c,0x01,0xe9,0x89,0xd2,
    0xaf,0xcd };

// calc3_rotate_bits: a left rotate by bits & 7.
inline uint8_t rot(uint8_t d, int bits) {
  bits &= 7;
  if (!bits) return d;
  return (uint8_t)((d << bits) | (d >> (8 - bits)));
}

inline uint8_t inline_path(uint8_t dat, int shift, int sub, int alt,
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

inline uint8_t keyed_path(uint8_t dat, int shift, int sub, int alt,
                          uint8_t keydat, bool odd) {
  if (sub == 1)      dat = odd ? (uint8_t)(dat + keydat) : (uint8_t)(dat - keydat);
  else if (sub == 2) dat = odd ? (uint8_t)(dat - keydat) : (uint8_t)(dat + keydat);
  else if (sub == 3) dat = (uint8_t)(dat - keydat);

  if (alt == 0 || alt == 3) return odd ? rot(dat, shift) : rot(dat, 8 - shift);
  if (alt == 1)             return rot(dat, 8 - shift);
  return rot(dat, shift);
}

// A block's parameters, as the walk reports them. Offsets are ABSOLUTE in the
// image; the device's own arithmetic is against ROM+1 and that is folded in
// here, because the +1 is a property of the layout and not of the caller.
struct Block {
  int bso, mode, shift, sub, alt, key;
  int inline_base, inline_size;
  int data_base, length;
};

// Walk the linked list to block `tabnum`. Returns false past the end.
inline bool walk(const std::vector<uint8_t>& rom, int tabnum, Block& b) {
  if (rom.empty() || tabnum > rom[0]) return false;
  int offset = 0;
  for (int x = 0; x < tabnum; x++) {
    if (1 + offset >= (int)rom.size()) return false;
    offset += rom[1 + offset] + 1;
    if (1 + offset + 1 >= (int)rom.size()) return false;
    const int len = rom[1 + offset] | (rom[1 + offset + 1] << 8);
    offset += len + 2;
  }
  if (1 + offset + 3 >= (int)rom.size()) return false;
  b.bso = rom[1 + offset];
  b.mode = rom[1 + offset + 1];
  const int packed = rom[1 + offset + 2];
  b.shift = (packed >> 4) & 7;
  b.sub = packed & 3;
  b.alt = (packed >> 2) & 3;
  b.key = rom[1 + offset + 3];
  b.inline_size = b.bso > 3 ? b.bso - 3 : 0;
  b.inline_base = 1 + offset + 4;
  const int lo = 1 + offset + b.bso + 1;
  if (lo + 1 >= (int)rom.size()) return false;
  b.length = rom[lo] | (rom[lo + 1] << 8);
  b.data_base = lo + 2;
  return true;
}

// Decode a whole table. `hdr` takes the first two bytes, `out` the rest.
// `keys` is 256 rows of 64; a row whose first entry is -1 does not exist.
inline bool decode(const std::vector<uint8_t>& rom, int tabnum,
                   const std::vector<std::vector<int>>& keys,
                   std::vector<uint8_t>& hdr, std::vector<uint8_t>& out,
                   Block& b) {
  hdr.clear();
  out.clear();
  if (!walk(rom, tabnum, b)) return false;
  if (b.length == 0) return true;
  if (!b.inline_size && keys[b.key][0] == -1) return false;

  int ii = 0;
  bool half = false;
  for (int i = 0; i < b.length; i++) {
    const uint8_t dat = rom[b.data_base + i];
    uint8_t v;
    if (b.inline_size) {
      v = inline_path(dat, b.shift, b.sub, b.alt,
                      rom[b.inline_base + ii], ii, half);
    } else {
      v = keyed_path(dat, b.shift, b.sub, b.alt,
                     (uint8_t)keys[b.key][i & 0x3f], i & 1);
    }
    if (i < 2) hdr.push_back(v);
    else       out.push_back(v);

    if (b.inline_size && ++ii >= b.inline_size) { ii = 0; half = !half; }
  }
  return true;
}

// The command sequencer, mirroring tools/calc3_ref.py's Sequencer -- which is
// the copy checked against MAME's real output by `make calc3`. Operates on a
// 64 KB RAM image so the RTL can be diffed against it directly.
struct Sequencer {
  std::vector<uint8_t> ram = std::vector<uint8_t>(0x10000, 0);
  const std::vector<uint8_t>* rom = nullptr;
  const std::vector<std::vector<int>>* keys = nullptr;
  uint16_t crc = 0;
  int cmd_off = 0;
  uint32_t write_cur = 0;
  int dsw_addr = 0, eep_base = 0, poll_addr = 0, csum_addr = 0;
  bool dsw_valid = false;
  bool key_missing = false;
  std::vector<std::pair<int,int>> placements;   // (table, address)

  uint16_t rd16(int off) const {
    return (uint16_t)((ram[off & 0xffff] << 8) | ram[(off + 1) & 0xffff]);
  }
  void wr16(int off, uint16_t v) {
    ram[off & 0xffff] = (uint8_t)(v >> 8);
    ram[(off + 1) & 0xffff] = (uint8_t)v;
  }

  // The DSW goes in inverted, at the top of every run, once init has named an
  // address for it.
  void run_dsw(uint8_t dsw) {
    if (dsw_valid) ram[dsw_addr & 0xffff] = (uint8_t)~dsw;
  }

  void command(uint16_t value, const uint16_t* eeprom) {
    if (value == 0) return;
    wr16(cmd_off, 0);                       // handshake first

    if (value == 0xff) {
      dsw_addr  = rd16(2);  dsw_valid = true;
      eep_base  = rd16(4);
      cmd_off   = rd16(6);
      poll_addr = rd16(8);
      csum_addr = rd16(10);
      write_cur = ((uint32_t)rd16(12) << 16) | rd16(14);
      wr16(csum_addr, crc);
      if (eeprom)
        for (int i = 0; i < 0x40; i++) wr16(eep_base + 2 * i, eeprom[i]);
      return;
    }

    for (int i = 0; i < (int)value; i++) {
      const uint16_t p1 = rd16(cmd_off + 2 + 4 * i);
      const uint16_t p2 = rd16(cmd_off + 4 + 4 * i);
      transfer((p1 >> 8) & 0xff, (int8_t)(p1 & 0xff), p2);
    }
  }

  void transfer(int tabnum, int disp, uint16_t writeback) {
    Block b{};
    std::vector<uint8_t> hdr, out;
    if (!decode(*rom, tabnum, *keys, hdr, out, b)) { key_missing = true; return; }

    if (b.length == 0) {
      // A control operation. Mode 6 resets the write pointer.
      if (b.mode == 0x06) write_cur = 0x00202000;
      return;
    }

    for (size_t i = 0; i < out.size(); i++)
      ram[(write_cur + i) & 0xffff] = out[i];
    placements.push_back({tabnum, (int)write_cur});

    ram[writeback & 0xffff] = hdr[0];
    ram[(writeback + 1) & 0xffff] = hdr[1];
    const int w = (writeback + disp) & 0xffff;
    wr16(w, (uint16_t)(write_cur >> 16));
    wr16((w + 2) & 0xffff, (uint16_t)write_cur);

    write_cur += (uint32_t)((out.size() + 2 + 3) & ~1u);
  }
};

}  // namespace calc3
