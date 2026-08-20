#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
"""Assemble MAME ROM regions from a romset zip, for simulation use.

**This tool is the simulation-side twin of the MRA.** On real hardware the core
does not read a zip and has no memory map of its own: the MRA file tells the
HPS ROM loader how to concatenate and interleave the ROM parts, and the core
receives one byte stream which it writes into SDRAM. The region layouts encoded
here are exactly what an MRA must reproduce.

Consequence: these two descriptions MUST agree. If the MRA lays a region out
differently from this table, the core renders differently from the frame gate
and the gate stops meaning anything. The layouts here are transcribed from
ROM_START in kaneko16.cpp, which is the shared source of truth for both — and
when MRA generation is written it should be driven from this same table rather
than hand-written a second time.

Hard rule 2: this reads a ROM path given on the command line and writes ONLY
under build/, which is gitignored. Nothing derived from a ROM is ever
committed, and no ROM data is baked into a source file.

The region layouts are transcribed from ROM_START in kaneko16.cpp. ROM_RELOAD
matters and is not decoration: mgcrystl's sprite region reloads mc001 once and
mc002 three times, so a naive concatenation gives a region that is the right
size but wrong above 0x180000.

    tools/build_rom_regions.py mgcrystl /home/ben/roms/Kaneko16 build/roms
"""

import sys, os, zipfile, hashlib

# name -> {region: [entry, ...]}
#
# Entry forms, mirroring the ROM_START macros:
#   (file, offset, length, [reload_offsets])           ROM_LOAD  (+ ROM_RELOAD)
#   (file, offset, length, [reloads], "16le", lane)    ROM_LOAD16_BYTE, lane 0/1
#
# ROM_LOAD16_BYTE writes one byte every two, starting at offset+lane. Wing
# Force's tile region is built this way from four files; concatenating them
# would produce a region of exactly the right size holding the wrong picture.
SETS = {
    "mgcrystl": {
        "view2_0": [("mc010.u04", 0x000000, 0x100000, [])],
        "view2_1": [("mc020.u34", 0x000000, 0x100000, [])],
        "kan_spr": [
            ("mc000.u38",    0x000000, 0x100000, []),
            ("mc001.u37",    0x100000, 0x080000, [0x180000]),
            ("mc002e02.u36", 0x200000, 0x020000, [0x220000, 0x240000, 0x260000]),
        ],
        "oki1":    [("mc030.u32", 0x000000, 0x040000, [])],
    },
    # Transcribed from ROM_START( explbrkr ), kaneko16.cpp. The first version of
    # this entry was written from the zip's file listing instead, and was wrong
    # in every particular: the two 512K sprite files were swapped, ts002e sat at
    # 0x100000 rather than 0x200000, both ROM_RELOADs were missing, and the
    # region was sized 0x140000 instead of 0x240000. The result rendered 5,547
    # sprite pixels MAME does not draw at all. A zip listing gives filenames and
    # sizes; only the source gives the layout.
    # Blaze On (Japan). ONE VIEW2 chip. The duplicate sprite files load to the
    # same offsets with identical data — the board has two sprite chips fed the
    # same ROMs, which MAME handles as one.
    "blazeonj": {
        "view2_0": [("bz_bg.u2", 0x000000, 0x100000, [])],
        "kan_spr": [
            ("bz_sp1.u20", 0x000000, 0x100000, []),
            ("bz_sp2.u21", 0x100000, 0x100000, []),
        ],
    },
    # Wing Force. ONE VIEW2 chip, and its tile region is ROM_LOAD16_BYTE
    # interleaved across four files.
    "wingforc": {
        "view2_0": [
            ("bg0am.u2", 0x000000, 0x080000, [], "16le", 0),
            ("bg0bm.u2", 0x000000, 0x080000, [], "16le", 1),
            ("bg1am.u3", 0x100000, 0x080000, [], "16le", 0),
            ("bg1bm.u3", 0x100000, 0x080000, [], "16le", 1),
        ],
        "kan_spr": [
            ("sp0m.u69", 0x000000, 0x080000, []),
            ("sp1m.u1",  0x080000, 0x080000, []),
            ("sp2m.u20", 0x100000, 0x080000, []),
            ("sp3m.u20", 0x180000, 0x080000, []),
        ],
        "oki1": [("pcm.u5", 0x000000, 0x080000, [])],
    },
    "explbrkr": {
        "view2_0": [("ts010.u4",  0x000000, 0x100000, [])],
        "view2_1": [("ts020.u33", 0x000000, 0x100000, [])],
        "kan_spr": [
            ("ts001e.u37", 0x000000, 0x080000, [0x100000]),
            ("ts000e.u38", 0x080000, 0x080000, [0x180000]),
            ("ts002e.u36", 0x200000, 0x040000, []),
        ],
        "oki1":    [("ts030.u5",  0x000000, 0x100000, [])],
    },
}

# set name -> zip basename, where they differ
ZIPNAME = {"blazeonj": "blazeon"}

REGION_SIZE = {
    "mgcrystl": {"view2_0": 0x100000, "view2_1": 0x100000,
                 "kan_spr": 0x280000, "oki1": 0x040000},
    # Blaze On (Japan). ONE VIEW2 chip. The duplicate sprite files load to the
    # same offsets with identical data — the board has two sprite chips fed the
    # same ROMs, which MAME handles as one.
    "blazeonj": {
        "view2_0": [("bz_bg.u2", 0x000000, 0x100000, [])],
        "kan_spr": [
            ("bz_sp1.u20", 0x000000, 0x100000, []),
            ("bz_sp2.u21", 0x100000, 0x100000, []),
        ],
    },
    # Wing Force. ONE VIEW2 chip, and its tile region is ROM_LOAD16_BYTE
    # interleaved across four files.
    "wingforc": {
        "view2_0": [
            ("bg0am.u2", 0x000000, 0x080000, [], "16le", 0),
            ("bg0bm.u2", 0x000000, 0x080000, [], "16le", 1),
            ("bg1am.u3", 0x100000, 0x080000, [], "16le", 0),
            ("bg1bm.u3", 0x100000, 0x080000, [], "16le", 1),
        ],
        "kan_spr": [
            ("sp0m.u69", 0x000000, 0x080000, []),
            ("sp1m.u1",  0x080000, 0x080000, []),
            ("sp2m.u20", 0x100000, 0x080000, []),
            ("sp3m.u20", 0x180000, 0x080000, []),
        ],
        "oki1": [("pcm.u5", 0x000000, 0x080000, [])],
    },
    "explbrkr": {"view2_0": 0x100000, "view2_1": 0x100000,
                 "kan_spr": 0x240000, "oki1": 0x100000},
    "blazeonj": {"view2_0": 0x100000, "kan_spr": 0x200000},
    "wingforc": {"view2_0": 0x200000, "kan_spr": 0x200000, "oki1": 0x080000},
}


def build(setname, rompath, outdir):
    if setname not in SETS:
        sys.exit(f"unknown set '{setname}'; known: {', '.join(sorted(SETS))}")

    # The zip is not always named after the set: blazeon.zip on this machine
    # holds the blazeonj (Japan) set, whose program ROMs differ from the World
    # set's.
    zpath = os.path.join(rompath, ZIPNAME.get(setname, setname) + ".zip")
    if not os.path.exists(zpath):
        sys.exit(f"not found: {zpath}")

    os.makedirs(outdir, exist_ok=True)
    # Refuse to write anywhere git would track. Hard rule 2 is checked, not
    # assumed — the check is cheap and the failure is expensive.
    real = os.path.realpath(outdir)
    if os.path.commonpath([real, os.path.realpath("build")]) != os.path.realpath("build"):
        sys.exit(f"refusing to write ROM-derived data outside build/: {real}")

    with zipfile.ZipFile(zpath) as z:
        names = set(z.namelist())
        for region, entries in SETS[setname].items():
            size = REGION_SIZE[setname][region]
            buf = bytearray(size)
            for entry in entries:
                fname, off, length, reloads = entry[0], entry[1], entry[2], entry[3]
                mode = entry[4] if len(entry) > 4 else "flat"
                lane = entry[5] if len(entry) > 5 else 0
                if fname not in names:
                    sys.exit(f"{zpath}: missing {fname}")
                data = z.read(fname)
                if len(data) != length:
                    sys.exit(f"{fname}: expected {length} bytes, got {len(data)}")
                for dst in [off] + reloads:
                    if mode == "16le":
                        buf[dst + lane : dst + lane + length * 2 : 2] = data
                    else:
                        buf[dst:dst + length] = data
            out = os.path.join(outdir, f"{setname}_{region}.bin")
            with open(out, "wb") as f:
                f.write(buf)
            print(f"  {os.path.basename(out):28s} {size:#09x}  "
                  f"sha1={hashlib.sha1(buf).hexdigest()[:16]}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    build(sys.argv[1], sys.argv[2], sys.argv[3])
