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
        # The mode byte of the LAST table walked. A zero-length table is a
        # control operation and the mode says which, so the sequencer needs it
        # after decompress() has returned nothing.
        self.last_mode = None

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

        self.last_mode = mode

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


class Sequencer:
    """mcu_run: the command loop that drives the decompressor.

    Operates on a 64 KB MCU RAM image so the RTL can be diffed against it
    directly. Everything MAME reaches through `m_mcuram[]` is a plain array
    access here for the same reason it is there: those accesses bypass the
    68000's address space, which is why no MAME write tap can see the command
    handshake or the ROM checksum, and why they had to be read out of the
    algorithm rather than measured.
    """

    def __init__(self, c3, ram=None, crc=0):
        self.c3 = c3
        self.ram = ram if ram is not None else bytearray(0x10000)
        self.crc = crc
        self.cmd_off = 0
        self.write_cur = 0
        self.dsw_addr = self.eeprom_addr = self.poll_addr = 0
        self.checksum_addr = 0
        self.placements = []          # (table, address, length) in order

    # MCU RAM is 68000 memory: big-endian words, byte addressed from 0.
    def rd16(self, off):
        return (self.ram[off] << 8) | self.ram[off + 1]

    def wr16(self, off, val):
        self.ram[off] = (val >> 8) & 0xff
        self.ram[off + 1] = val & 0xff

    def command(self, value, eeprom=None):
        """Run one command, as if the 68000 had just written `value`."""
        if value == 0:
            return
        self.wr16(self.cmd_off, 0)        # handshake, before anything else

        if value == 0xff:
            self.dsw_addr      = self.rd16(2)
            self.eeprom_addr   = self.rd16(4)
            self.cmd_off       = self.rd16(6)
            self.poll_addr     = self.rd16(8)
            self.checksum_addr = self.rd16(10)
            self.write_cur     = (self.rd16(12) << 16) | self.rd16(14)
            self.wr16(self.checksum_addr, self.crc)
            if eeprom is not None:
                for i in range(0x40):
                    self.wr16(self.eeprom_addr + 2 * i, eeprom[i])
            return

        # Any other value is a COUNT of transfers, each two parameter words.
        for i in range(value):
            p1 = self.rd16(self.cmd_off + 2 + 4 * i)
            p2 = self.rd16(self.cmd_off + 4 + 4 * i)
            self.transfer(tabnum=(p1 >> 8) & 0xff,
                          unk=p1 & 0xff,
                          writeback=p2)

    def transfer(self, tabnum, unk, writeback):
        hdr, data = self.c3.decompress(tabnum)
        if data is None:
            # A zero-length table is a control operation, not a transfer. Mode
            # 06 resets the write pointer; MAME hardcodes 0x202000 and says so,
            # and brapboys pulling table 1a to 202000 twice is that showing up.
            if self.c3.last_mode == 0x06:
                self.write_cur = 0x202000
            return 0

        addr = self.write_cur
        for i, b in enumerate(data):
            off = (addr + i) & 0xffff
            self.ram[off] = b
        self.placements.append((tabnum, addr, len(data)))

        # The header goes back to the address the command named, and the
        # 32-bit data pointer to that address displaced by a SIGNED unk.
        self.ram[writeback & 0xffff] = hdr[0]
        self.ram[(writeback + 1) & 0xffff] = hdr[1]
        disp = unk - 256 if unk > 127 else unk
        w = (writeback + disp) & 0xffff
        self.wr16(w, (addr >> 16) & 0xffff)
        self.wr16((w + 2) & 0xffff, addr & 0xffff)

        # length here is the TABLE length, header included -- two more than the
        # bytes written. Getting that wrong shifts every later table.
        self.write_cur += (len(data) + 2 + 3) & ~1
        return len(data)


# The command streams MAME logged, with the write base its first table landed
# on. Both are observations, not guesses: the commands come from the driver's
# own "MCU executed command" log and the base from the first captured run.
SELFTEST = {
    "shogwarr": dict(
        params=dict(dsw=0x0000, eeprom=0x0100, cmdbase=0x030a, poll=0x0000,
                    checksum=0x0200, write=0x00207fe0),
        commands=[(1, [0x19]), (3, [0x80, 0x41, 0x10]), (2, [0x11, 0x11])],
        expect=[(0x19, 0x207fe0, 216), (0x80, 0x2080bc, 686),
                (0x41, 0x20836e, 4102), (0x10, 0x209378, 1328),
                (0x11, 0x2098ac, 1010)],
    ),
}


def selftest(c3, rundir, romname):
    setname = romname.split("-")[0]
    spec = SELFTEST.get(setname)
    if not spec:
        # No plausible default: a set with no recorded stream cannot be
        # checked, and saying so beats inventing one that passes.
        print(f"no recorded command stream for {setname}")
        return 1

    p = spec["params"]
    seq = Sequencer(c3)
    seq.wr16(2, p["dsw"]);      seq.wr16(4, p["eeprom"])
    seq.wr16(6, p["cmdbase"]);  seq.wr16(8, p["poll"])
    seq.wr16(10, p["checksum"])
    seq.wr16(12, (p["write"] >> 16) & 0xffff)
    seq.wr16(14, p["write"] & 0xffff)
    seq.command(0xff)

    for count, tables in spec["commands"]:
        for i, t in enumerate(tables):
            seq.wr16(seq.cmd_off + 2 + 4 * i, t << 8)
            seq.wr16(seq.cmd_off + 4 + 4 * i, 0x0400 + 2 * i)
        seq.command(count)

    fails = 0
    for i, (t, a, l) in enumerate(spec["expect"]):
        if i >= len(seq.placements):
            print(f"  table {t:02x}: never placed"); fails += 1; continue
        gt, ga, gl = seq.placements[i]
        if (gt, ga, gl) != (t, a, l):
            print(f"  table {gt:02x} at {ga:06x} len {gl} — "
                  f"expected {t:02x} at {a:06x} len {l}")
            fails += 1
        else:
            print(f"  table {gt:02x}  {ga:06x}  {gl:5d} bytes  ok")

    # The addresses agreeing is not the same as the BYTES agreeing.
    #
    # Compare ONLY the runs this stream actually replayed. A longer capture
    # holds runs from commands the recorded stream does not cover, and scoring
    # those as failures makes the length of the MAME run decide whether the
    # model passes -- a test that fails for a reason unrelated to the thing
    # under test. They are reported as uncovered instead, which is a gap in
    # the recorded stream and worth seeing.
    placed = {a for _, a, _ in seq.placements}
    uncovered = []
    for f in sorted(rundir.glob(f"{setname}-run*.bin")):
        base = int(f.name.split("-")[-1].split(".")[0], 16)
        want = f.read_bytes()
        if base not in placed:
            uncovered.append((base, len(want)))
            continue
        got = bytes(seq.ram[base - 0x200000:base - 0x200000 + len(want)])
        if got != want:
            print(f"  RAM at {base:06x} differs from {f.name}")
            fails += 1

    if uncovered:
        print(f"  {len(uncovered)} captured run(s) outside the recorded "
              f"command stream, not checked:")
        for base, n in uncovered:
            print(f"    {base:06x}  {n} bytes")

    print(f"calc3 selftest: {'PASS' if not fails else str(fails) + ' FAILS'}")
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rom")
    ap.add_argument("--table", type=int, default=None)
    ap.add_argument("--find-hex", default=None,
                    help="byte pattern to locate across every table")
    ap.add_argument("--selftest", metavar="RUNDIR", default=None,
                    help="replay the captured command stream and check every "
                         "table lands where MAME put it, byte for byte")
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

    if args.selftest:
        sys.exit(selftest(c3, Path(args.selftest), Path(args.rom).name))

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
