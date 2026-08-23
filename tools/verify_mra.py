#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
"""Expand an MRA the way the HPS does, and check it equals the stream image.

Decision D6 says the MRA owns the SDRAM layout and the loader maps it as the
identity, which makes the MRA and tools/build_rom_regions.py two descriptions of
one thing. This is the check that they agree.

It matters because the failure is silent: a region placed wrongly by the MRA
loads without error and shows up much later as a game that boots to garbage,
with the evidence pointing at the CPU. The frame gate renders from the region
images; the hardware renders from the MRA. If those diverge, the gate stops
predicting the hardware.

    tools/verify_mra.py mra/explbrkr.mra /home/ben/roms/Kaneko16 \\
                        build/roms/explbrkr_stream.bin
"""
import sys, os, zipfile, hashlib
import xml.etree.ElementTree as ET


def expand(mra_path, rompath):
    root = ET.parse(mra_path).getroot()
    rom = root.find("./rom[@index='0']")
    zname = rom.get("zip")
    out = bytearray()
    with zipfile.ZipFile(os.path.join(rompath, zname)) as z:
        for el in rom:
            if el.tag == "part" and el.get("repeat"):
                fill = bytes.fromhex((el.text or "00").strip())
                out += fill * int(el.get("repeat"))
            elif el.tag == "part":
                out += z.read(el.get("name"))
            elif el.tag == "interleave":
                # THE LANES MUST ADVANCE EQUALLY, and this used to zero-fill
                # the short one instead of saying so.
                #
                # mra_loader keeps a cursor PER LANE -- romlen[idx] in
                # rom_data() -- and never resyncs them at </interleave>. A
                # lopsided interleave therefore leaves the cursors apart, and
                # the next part writes at romlen[0], back inside the longer
                # lane's tail. Modelling it as one buffer sized from the longer
                # lane hid that completely: it produced exactly the bytes the
                # region wanted and would have blessed an MRA the loader
                # corrupts. Refuse it instead.
                lanes = {}
                for pt in el:
                    ln = 0 if pt.get("map") == "01" else 1
                    if pt.get("name"):
                        data = z.read(pt.get("name"))
                        off = int(pt.get("offset"), 0) if pt.get("offset") else 0
                        cut = int(pt.get("length"), 0) if pt.get("length") else 0
                        data = data[off:]
                        if cut:
                            data = data[:cut]
                    else:
                        unit = bytes.fromhex((pt.text or "00").strip())
                        data = unit * int(pt.get("repeat", "1"), 0)
                    lanes[ln] = data

                widths = {ln: len(d) for ln, d in lanes.items()}
                if len(set(widths.values())) != 1:
                    sys.exit(
                        f"  interleave lanes advance unequally: {widths} — "
                        "mra_loader keeps one cursor per lane and never "
                        "resyncs them, so every part after this one would "
                        "land in the wrong place. Split it into equal "
                        "interleaves."
                    )

                buf = bytearray(next(iter(widths.values())) * 2)
                for ln, data in lanes.items():
                    # map="01" supplies byte 0 of each 16-bit word, "10" byte 1.
                    buf[ln:len(data) * 2:2] = data
                out += buf
            else:
                sys.exit(f"unhandled MRA element <{el.tag}>")
    return bytes(out)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    mra, rompath, stream_path = sys.argv[1:4]
    got = expand(mra, rompath)
    want = open(stream_path, "rb").read()

    print(f"  MRA expands to  {len(got):#09x} bytes  sha1={hashlib.sha1(got).hexdigest()[:16]}")
    print(f"  stream image is {len(want):#09x} bytes  sha1={hashlib.sha1(want).hexdigest()[:16]}")

    if got == want:
        print("  MATCH — the MRA and the SDRAM map agree")
        sys.exit(0)

    if len(got) != len(want):
        print(f"  LENGTH DIFFERS by {len(got) - len(want):+d} bytes")
    n = min(len(got), len(want))
    first = next((i for i in range(n) if got[i] != want[i]), None)
    if first is not None:
        print(f"  first difference at {first:#09x} "
              f"(mra={got[first]:02x} stream={want[first]:02x})")
        bad = sum(1 for i in range(n) if got[i] != want[i])
        print(f"  {bad} of {n} bytes differ ({100.0*bad/n:.2f}%)")
    sys.exit(1)
