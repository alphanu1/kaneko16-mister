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


def region(a):
    """Name the address as bakubrkr_map does (kaneko16.cpp).

    Transcribed from the driver, not guessed. The first version of this guessed
    the VIEW2 and palette windows from the mgcrystl map and put them at 400000
    and 300000; nothing was reported there so the census looked clean while
    naming the wrong board.
    """
    if a < ROM_END:                return "rom       000000-07ffff"
    if 0x100000 <= a < 0x110000:   return "work ram  100000-10ffff"
    if 0x400000 <= a < 0x400020:   return "ym2149-0  400000-40001f"
    if 0x400200 <= a < 0x400220:   return "ym2149-1  400200-40021f"
    if a == 0x400400:              return "oki       400401"
    if 0x500000 <= a < 0x504000:   return "view2-0 v 500000-503fff"
    if 0x580000 <= a < 0x584000:   return "view2-1 v 580000-583fff"
    if 0x600000 <= a < 0x602000:   return "spriteram 600000-601fff"
    if 0x700000 <= a < 0x701000:   return "palette   700000-700fff"
    if 0x800000 <= a < 0x800020:   return "view2-0 r 800000-80001f"
    if 0x900000 <= a < 0x900020:   return "sprite  r 900000-90001f"
    if 0xa80000 <= a < 0xa80002:   return "watchdog  a80000"
    if 0xb00000 <= a < 0xb00020:   return "view2-1 r b00000-b0001f"
    if 0xd00000 <= a < 0xd00002:   return "lockout/eeprom d00000-1"
    if 0xe00000 <= a < 0xe00008:   return "inputs    e00000-e00007"
    # Nothing in bakubrkr_map covers these and nothing in MAME's map does
    # either — see findings. Named rather than lumped in with "other" so a
    # genuinely new one stands out.
    if a in (0xc00000, 0xe40000, 0xe80000, 0xec0000):
        return f"unmapped  {a:06x}"
    return f"OTHER     {a & 0xfc0000:06x}"


def main():
    if len(sys.argv) < 3:
        print("usage: diff_bus_trace.py <ours.txt> <mame.txt>", file=sys.stderr)
        return 2
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
