#!/usr/bin/env python3
"""CALC3 table decompressor — the reference model the RTL will be judged against.

WHY THIS EXISTS

`kaneko_calc3.cpp`'s `decompress_table` is ~300 lines of C with a linked-list
table walk, two encryption paths, four subtract types, four alternate-swap
modes, a bit rotate keyed off a per-block shift, and an optional inline key
table with two magic byte arrays MAME's own comments say "should be derived
from the inline table somehow". None of that is guessable from a waveform. So
it is transcribed here first, in a language where it can be checked in seconds
against tools/mame_calc3_trace.lua's capture, and only then written as RTL.

The key table is READ FROM MAME'S SOURCE, not copied into this repository.
third_party/ is gitignored and MAME is the upstream for this data; parsing it
at run time keeps one copy, keeps it attributed, and keeps rule 2's "never bake
ROM-derived data into a source file" unambiguous.

  tools/calc3_ref.py <calc3rom.bin> [--table N] [--find-hex 0055ddbb...]
"""
import argparse
import re
import sys
from pathlib import Path

MAME_SRC = Path("third_party/mame/src/mame/kaneko/kaneko_calc3.cpp")

# Both from decompress_table's inline-table branch. 31 and 30 bytes; the sizes
# are not equal and neither is a power of two, so they are indexed with an
# explicit >>1 rather than a mask.
EXTRA = [0x14,0xf0,0xf8,0xd2,0xbe,0xfc,0xac,0x86,0x64,0x08,0x0c,0x74,0xd6,0x6a,
         0x24,0x12,0x1a,0x72,0xba,0x48,0x76,0x66,0x4a,0x7c,0x5c,0x82,0x0a,0x86,
         0x82,0x02,0xe6]
EXTRA2 = [0x2f,0x04,0xd1,0x69,0xad,0xeb,0x10,0x95,0xb0,0x2f,0x0a,0x83,0x7d,0x4e,
          0x2a,0x07,0x89,0x52,0xca,0x41,0xf1,0x4f,0xaf,0x1c,0x01,0xe9,0x89,0xd2,
          0xaf,0xcd]


def load_keydata(src=MAME_SRC):
    """Parse f_calc3_keydata[0x100][0x40] out of MAME's source."""
    if not src.exists():
        sys.exit(f"{src} not found — the key table lives in MAME, and this "
                 f"model reads it there rather than keeping a second copy.")
    text = src.read_text(errors="replace")
    start = text.index("f_calc3_keydata[0x100][0x40] = {")
    body = text[start:]
    rows, depth, cur = [], 0, []
    for tok in re.finditer(r"\{|\}|0x[0-9a-fA-F]+|-1", body):
        t = tok.group(0)
        if t == "{":
            depth += 1
            if depth == 2:
                cur = []
        elif t == "}":
            if depth == 2:
                rows.append(cur)
            depth -= 1
            if depth == 0:
                break
        else:
            cur.append(int(t, 16) if t.startswith("0x") else -1)
    if len(rows) != 0x100:
        sys.exit(f"parsed {len(rows)} key rows, expected 256 — the table's "
                 f"shape in MAME changed and this parser has not followed it.")
    for i, r in enumerate(rows):
        if len(r) != 0x40:
            sys.exit(f"key row {i} has {len(r)} entries, expected 64")
    return rows


def rot(dat, bits):
    """calc3_rotate_bits: a left rotate by bits&7, byte wide."""
    b = bits & 7
    return ((dat << b) | (dat >> (8 - b))) & 0xff if b else dat & 0xff


class Calc3:
    def __init__(self, rom: bytes, keydata):
        self.rom = rom
        self.key = keydata

    def decompress(self, tabnum):
        """Return (header, data) for a table, or (None, None) for a blank one.

        Mirrors decompress_table. The first TWO decoded bytes are the data
        header and are not written to MCU RAM -- that is what local_counter
        guards, and missing it shifts every table by two bytes.
        """
        rom = self.rom
        numregions = rom[0]
        if tabnum > numregions:
            return None, None

        # datarom++ in the C, so every index below is against rom[1:].
        d = rom[1:]
        offset = 0
        for _ in range(tabnum):
            offset += d[offset] + 1
            length = d[offset] | (d[offset + 1] << 8)
            offset += length + 2

        blocksize_offset = d[offset + 0]
        mode             = d[offset + 1]
        alternateswaps   = d[offset + 2]
        shift            = (alternateswaps & 0xf0) >> 4
        subtracttype     = alternateswaps & 0x03
        alternateswaps   = (alternateswaps & 0x0c) >> 2
        key_byte         = d[offset + 3]

        inline_base = inline_size = 0
        if blocksize_offset > 3:
            inline_base = offset + 4
            inline_size = blocksize_offset - 3

        offset += blocksize_offset + 1
        length = d[offset + 0] | (d[offset + 1] << 8)
        offset += 2

        if length == 0:
            return None, None

        out = bytearray()
        header = bytearray()

        for i in range(length):
            if inline_size:
                dat = self._inline(d, offset, i, inline_base, inline_size,
                                   shift, subtracttype, alternateswaps)
            else:
                dat = self._keyed(d, offset, i, key_byte, shift,
                                  subtracttype, alternateswaps)
            if i > 1:
                out.append(dat)
            else:
                header.append(dat)

        return bytes(header), bytes(out)

    def _inline(self, d, offset, i, base, size, shift, sub, alt):
        idx = i % size
        inlinet = d[base + idx]
        dat = d[offset + i]

        # Shogun Warriors table 0x40 takes its own path in MAME.
        if sub == 3 and alt == 0:
            dat = (dat - inlinet) & 0xff
            if not (idx & 1):
                dat = (dat - EXTRA[idx >> 1]) & 0xff
            return dat

        if not ((i // size) & 1):
            if idx & 1:
                dat = rot((dat - inlinet) & 0xff, shift)
            else:
                if sub != 0x02:
                    dat = (dat - inlinet - EXTRA[idx >> 1]) & 0xff
                else:
                    dat = (dat + inlinet + EXTRA[idx >> 1]) & 0xff
                dat = rot(dat, 8 - shift)
        else:
            if not (idx & 1):
                dat = rot((dat - inlinet) & 0xff, shift)
            else:
                if sub != 0x02:
                    dat = (dat - EXTRA2[idx >> 1]) & 0xff
                else:
                    dat = (dat + EXTRA2[idx >> 1]) & 0xff
                dat = rot(dat, 8 - shift)
        return dat

    def _keyed(self, d, offset, i, key_byte, shift, sub, alt):
        key = self.key[key_byte]
        if key[0] == -1:
            sys.exit(f"table asks for key {key_byte:02x}, which MAME marks "
                     f"invalid — a real fatalerror there, not a soft case.")
        dat = d[offset + i]
        keydat = key[i & 0x3f] & 0xff

        if sub == 1:
            dat = (dat + keydat) & 0xff if (i & 1) else (dat - keydat) & 0xff
        elif sub == 2:
            dat = (dat + keydat) & 0xff if not (i & 1) else (dat - keydat) & 0xff
        elif sub == 3:
            dat = (dat - keydat) & 0xff

        if alt in (0, 3):
            dat = rot(dat, 8 - shift) if not (i & 1) else rot(dat, shift)
        elif alt == 1:
            dat = rot(dat, 8 - shift)
        elif alt == 2:
            dat = rot(dat, shift)
        return dat


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("--table", type=int, default=None)
    ap.add_argument("--find-hex", default=None,
                    help="byte pattern to locate across every table")
    args = ap.parse_args()

    rom = Path(args.rom).read_bytes()
    c3 = Calc3(rom, load_keydata())
    ntab = rom[0]
    print(f"calc3rom {len(rom)} bytes, {ntab} tables")

    if args.table is not None:
        hdr, data = c3.decompress(args.table)
        if data is None:
            print(f"table {args.table:02x}: blank")
            return
        print(f"table {args.table:02x}: header {hdr.hex()} length {len(data)}")
        print(data[:64].hex())
        return

    if args.find_hex:
        want = bytes.fromhex(args.find_hex)
        hits = 0
        for t in range(ntab + 1):
            try:
                hdr, data = c3.decompress(t)
            except IndexError:
                continue
            if data and want in data:
                print(f"  table {t:02x} contains it at offset "
                      f"{data.index(want)}, header {hdr.hex()}, "
                      f"length {len(data)}")
                hits += 1
        print(f"{hits} table(s) contain the pattern")
        return

    ok = blank = bad = 0
    for t in range(ntab + 1):
        try:
            hdr, data = c3.decompress(t)
        except IndexError:
            bad += 1
            continue
        if data is None:
            blank += 1
        else:
            ok += 1
    print(f"{ok} decompressed, {blank} blank, {bad} ran off the end")


if __name__ == "__main__":
    main()
