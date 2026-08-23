#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
"""Diff the core's 68000 bus trace against MAME's.

WHY THIS DOES NOT DIFF THE TRACES LINE BY LINE

fx68k reproduces the 68000's prefetch; MAME's core models it differently and
re-reads the same word in places fx68k does not. A raw diff drowns in that
within a dozen lines and says nothing about whether the core is correct.

What is architecturally determined, and so must agree exactly, is:

  * every WRITE, in order — a write is never speculative
  * every READ outside ROM, in order — RAM and I/O reads the program actually
    asked for, as opposed to instruction fetches

Those two streams are what this compares. Instruction fetches are counted and
reported but not diffed.
"""
import sys
from collections import Counter

ROM_END = 0x080000       # kaneko_bus.sv: sel_rom = a[23:19] == 0


def load(path):
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) != 4:
                continue
            out.append((int(p[0], 16), p[1], int(p[2], 16), int(p[3], 16)))
    return out


def fmt(rec):
    a, rw, d, m = rec
    lane = {0xffff: "w", 0xff00: "hi", 0x00ff: "lo"}.get(m, f"{m:04x}")
    return f"{a:06x} {rw} {d:04x} .{lane}"


# The memory maps, transcribed from kaneko16.cpp -- NOT shared, NOT guessed.
#
# A previous version guessed the VIEW2 and palette windows from the mgcrystl
# map while tracing bakubrkr; nothing was reported there, so the census looked
# clean while naming the wrong board. It was then pinned to bakubrkr_map, which
# made the same mistake in the other direction the moment mgcrystl was traced:
# its palette is at 500000 and its sprite RAM at 700000, exactly the two
# windows bakubrkr swaps, so every count landed under a confidently wrong name.
#
# Hard rule 9. The map is a per-game fact and belongs in a per-game table.
MAPS = {
    "bakubrkr": [
        (0x100000, 0x110000, "work ram  100000-10ffff"),
        (0x500000, 0x504000, "view2-0 v 500000-503fff"),
        (0x580000, 0x584000, "view2-1 v 580000-583fff"),
        (0x600000, 0x602000, "spriteram 600000-601fff"),
        (0x700000, 0x701000, "palette   700000-700fff"),
        (0xa80000, 0xa80002, "watchdog  a80000"),
        (0xe00000, 0xe00008, "inputs    e00000-e00007"),
    ],
    # blazeon_map, shared by blazeonj and wingforc. ROM is a full megabyte
    # here, the third and fourth input words are UNK then SYSTEM (bakubrkr has
    # them the other way round), and e00000 is the sound latch on write and an
    # IRQ acknowledge on read.
    "blazeon": [
        (0x300000, 0x310000, "work ram  300000-30ffff"),
        (0x500000, 0x501000, "palette   500000-500fff"),
        (0x600000, 0x604000, "view2-0 v 600000-603fff"),
        (0x700000, 0x701000, "spriteram 700000-700fff"),
        (0x980000, 0x980020, "sprite r2 980000-98001f"),
        (0xc00000, 0xc00008, "inputs    c00000-c00007"),
        (0xe00000, 0xe00002, "sndlatch  e00000"),
        (0xe40000, 0xe40002, "irq ack   e40000"),
        (0xec0000, 0xec0002, "irq ack   ec0000"),
    ],
    "mgcrystl": [
        (0x300000, 0x310000, "work ram  300000-30ffff"),
        (0x500000, 0x501000, "palette   500000-500fff"),
        (0x600000, 0x604000, "view2-0 v 600000-603fff"),
        (0x680000, 0x684000, "view2-1 v 680000-683fff"),
        (0x700000, 0x702000, "spriteram 700000-701fff"),
        (0xa00000, 0xa00002, "watchdog  a00000"),
        (0xc00000, 0xc00006, "inputs    c00000-c00005"),
    ],
}

# Windows both maps agree on.
COMMON = [
    (0x400000, 0x400020, "ym2149-0  400000-40001f"),
    (0x400200, 0x400220, "ym2149-1  400200-40021f"),
    (0x400400, 0x400402, "oki       400401"),
    (0x800000, 0x800020, "view2-0 r 800000-80001f"),
    (0x900000, 0x900020, "sprite  r 900000-90001f"),
    (0xb00000, 0xb00020, "view2-1 r b00000-b0001f"),
    (0xd00000, 0xd00002, "lockout/eeprom d00000-1"),
]

# Addresses the traced set's own map does not cover. Named rather than lumped
# into OTHER so a genuinely new one stands out.
UNMAPPED = {
    "bakubrkr": (0xc00000, 0xe40000, 0xe80000, 0xec0000),
    "mgcrystl": (0xe00000, 0xe40000, 0xe80000, 0xec0000),
}


# Sets that share another set's map.
ALIAS = {"blazeonj": "blazeon", "wingforc": "blazeon"}


def region_for(setname):
    setname = ALIAS.get(setname, setname)
    """Return a namer for this set. Raises rather than defaulting.

    A set with no map has no correct answer, and substituting another game's
    produced the exact failure above: plausible names over the wrong board.
    """
    if setname not in MAPS:
        raise SystemExit(
            f"diff_bus_trace: no memory map for {setname!r}. "
            f"Known: {', '.join(sorted(MAPS))}. Transcribe it from "
            "kaneko16.cpp rather than reusing another game's -- the palette "
            "and VIEW2 windows move between maps."
        )
    windows = MAPS[setname] + COMMON
    unmapped = UNMAPPED.get(setname, ())

    def region(a):
        rom_end = 0x100000 if setname == "blazeon" else ROM_END
        if a < rom_end:
            return f"rom       000000-{rom_end - 1:06x}"
        for lo, hi, name in windows:
            if lo <= a < hi:
                return name
        if a in unmapped:
            return f"unmapped  {a:06x}"
        return f"OTHER     {a & 0xfc0000:06x}"

    return region


def main():
    if len(sys.argv) < 4:
        print("usage: diff_bus_trace.py <ours.txt> <mame.txt> <setname>",
              file=sys.stderr)
        return 2
    region = region_for(sys.argv[3])
    ours, mame = load(sys.argv[1]), load(sys.argv[2])
    if not ours or not mame:
        print(f"empty trace: ours={len(ours)} mame={len(mame)}", file=sys.stderr)
        return 2

    def keep(r):
        return r[1] == "W" or r[0] >= ROM_END

    a_all, m_all = ours, mame
    a, m = [r for r in a_all if keep(r)], [r for r in m_all if keep(r)]

    print(f"  ours {len(a_all):6d} accesses, {len(a):5d} after dropping "
          f"instruction fetches")
    print(f"  mame {len(m_all):6d} accesses, {len(m):5d} after dropping "
          f"instruction fetches")

    n = min(len(a), len(m))
    first = None
    for i in range(n):
        # Compare only the lanes both sides actually drove. A byte write has
        # an undefined value on the idle half of the bus and the two cores do
        # not agree about what they leave there, which is not a difference.
        aa, mm = a[i], m[i]
        if aa[0] != mm[0] or aa[1] != mm[1] or aa[3] != mm[3]:
            first = i; break
        mask = aa[3]
        if (aa[2] & mask) != (mm[2] & mask):
            first = i; break

    if first is None:
        print(f"  MATCH over all {n} compared accesses")
    else:
        print(f"\n  FIRST DIVERGENCE at compared access {first}")
        lo = max(0, first - 6)
        print(f"  {'ours':<22} {'mame':<22}")
        for i in range(lo, min(n, first + 7)):
            mark = "<<" if i == first else "  "
            print(f"  {fmt(a[i]):<22} {fmt(m[i]):<22} {mark}")

    # Census. This is what settles the unmapped addresses: if a region appears
    # on one side only, that is the core and the driver disagreeing about the
    # map, not about behaviour.
    ca = Counter(region(r[0]) for r in a_all)
    cm = Counter(region(r[0]) for r in m_all)
    print("\n  region                        ours     mame")
    for k in sorted(set(ca) | set(cm)):
        flag = "  <- one side only" if (k not in ca) != (k not in cm) else ""
        print(f"  {k:<28} {ca.get(k,0):6d}  {cm.get(k,0):6d}{flag}")

    return 0 if first is None else 1


if __name__ == "__main__":
    sys.exit(main())
