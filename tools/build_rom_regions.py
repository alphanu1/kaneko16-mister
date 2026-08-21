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

import sys, os, re, zipfile, hashlib

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
        # 68000 program, ROM_LOAD16_BYTE: u18 on even bytes, u19 on odd.
        "maincpu": [
            ("ts100e.u18", 0x000000, 0x040000, [], "16le", 0),
            ("ts101e.u19", 0x000000, 0x040000, [], "16le", 1),
        ],
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

# Game id, handed to the core as MRA <rom index="1">. The core has one
# bitstream for every game and selects its memory-map pages and video
# constants from this. Adding a game means adding it here AND to the table in
# Kaneko16.sv; the two are checked against each other by nothing, so they are
# listed adjacently in both files with the same order.
GAME_ID = {
    "explbrkr": 0,
    "mgcrystl": 1,
}

# set name -> zip basename, where they differ
ZIPNAME = {"blazeonj": "blazeon"}

# arcade-organizer categories. Not derivable from MAME's GAME() line — that
# carries year, manufacturer and title but no genre — so this is a hand table,
# and it is the one place in this file that is not taken from the oracle.
# Missing categories do not break anything; they just leave the game out of
# arcade-organizer's sorted view.
CATEGORY = {
    "explbrkr": "Shooter / Flying Vertical",
    "mgcrystl": "Platform",
    "blazeonj": "Shooter / Flying Horizontal",
    "wingforc": "Shooter / Flying Vertical",
}

# Which MRA is the primary one for a game, and which are variants. The primary
# sits in releases/ and appears in the /_Arcade/ menu on a stock install;
# variants go under releases/_alternatives/_<Game>/ and are opt-in. Convention
# is World or USA if one exists, otherwise Japan.
PRIMARY = {"explbrkr", "mgcrystl", "wingforc"}

# Which games the CORE actually supports today. Everything game-specific is
# still compiled in for explbrkr — the memory map is bakubrkr_map, and the
# offsets, colour base, sprite priorities and layer count are constants — so
# loading any other set would produce a broken picture rather than a game.
#
# Shipping an MRA for a game the core cannot run is worse than shipping none:
# it looks like a supported title and fails in a way the player cannot
# diagnose. This set grows when the per-game configuration table lands, and
# not before.
# Magical Crystals is deliberately NOT here yet. Its game-table entry and its
# memory map are done, but it is the one title the frame gate does not close:
# 298 pixels of line-scroll difference that nobody has explained. Shipping a
# title with a known unexplained video discrepancy makes every later bug report
# ambiguous, so it waits until that is understood. The Blaze On board is at
# 100% and goes first.
SUPPORTED = {"explbrkr"}
ALT_PARENT = {"blazeonj": "Blaze On"}

# SDRAM layout: region -> (base, size). This IS the MRA's emission order, and
# the loader maps it as the identity — stream byte N is SDRAM byte N.
#
# Sized for the Tier 1 games. Later tiers have larger sprite ROMs and the map
# will grow; because the MRA owns the layout, growing it means editing the MRA
# and this table together, not changing address arithmetic in RTL.
# ONE LAYOUT FOR EVERY GAME, SIZED TO THE LARGEST OF EACH REGION.
#
# The core carries one set of base addresses, so the layout cannot move between
# games — only the contents. Every slot below is the largest that region is
# across all four Tier 1 titles, so this map is final and the RBF and the MRAs
# stop being a matched pair that changes:
#
#            explbrkr  mgcrystl  blazeonj  wingforc     slot
#   maincpu   0x80000   0x80000  0x100000  0x100000   0x100000
#   view2_0  0x100000  0x100000  0x100000  0x200000   0x200000
#   view2_1  0x100000  0x100000         -         -   0x100000
#   kan_spr  0x240000  0x280000  0x200000  0x200000   0x280000
#   oki1     0x100000   0x40000         -   0x80000   0x100000
#   audiocpu        -         -   0x20000   0x10000    0x20000
#
# A game leaves the tail of each slot zero-filled. Sizing a slot to whichever
# game was implemented first is how the next game renders garbage from the end
# of somebody else's ROM — which is why this was done once, for all of them,
# rather than grown a title at a time.
SDRAM_MAP = [
    ("maincpu",  0x000000, 0x100000),
    ("view2_0",  0x100000, 0x200000),
    ("view2_1",  0x300000, 0x100000),
    ("kan_spr",  0x400000, 0x280000),
    ("oki1",     0x680000, 0x100000),
    ("audiocpu", 0x780000, 0x020000),
]
SDRAM_END = 0x7a0000        # 7.625 MB

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
    "explbrkr": {"maincpu": 0x080000, "view2_0": 0x100000, "view2_1": 0x100000,
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


def build_stream(setname, outdir):
    """Concatenate the assembled regions into one image in SDRAM_MAP order.

    This is what the MRA emits and what the HPS streams to the core. Writing it
    here keeps the simulation and the MRA driven from one description — see the
    note at the top about the two having to agree.
    """
    buf = bytearray(SDRAM_END)
    placed = []
    for region, base, size in SDRAM_MAP:
        path = os.path.join(outdir, f"{setname}_{region}.bin")
        if not os.path.exists(path):
            placed.append((region, base, size, "absent, zero-filled"))
            continue
        data = open(path, "rb").read()
        if len(data) > size:
            sys.exit(f"{region}: {len(data):#x} bytes does not fit {size:#x}")
        buf[base:base + len(data)] = data
        placed.append((region, base, size, f"{len(data):#x} bytes"))

    out = os.path.join(outdir, f"{setname}_stream.bin")
    with open(out, "wb") as f:
        f.write(buf)
    print(f"  {os.path.basename(out):28s} {SDRAM_END:#09x}  "
          f"sha1={hashlib.sha1(buf).hexdigest()[:16]}")
    for region, base, size, note in placed:
        print(f"      {base:#09x} {region:9s} {size:#09x}  {note}")


def game_info(setname, mame_root="third_party/mame"):
    """Pull the real title, year and manufacturer out of MAME's GAME() line.

    Taken from the source rather than a table here, for the same reason the ROM
    layouts are: a hand-kept list of titles is a second description that drifts,
    and MAME is the oracle the rest of this project already uses. Falls back to
    the set name if the source is not vendored.
    """
    import glob
    pat = re.compile(
        r'^GAME[L]?\(\s*(\d{4})\s*,\s*' + re.escape(setname) +
        r'\s*,.*?ROT\d+\s*,\s*"([^"]*)"\s*,\s*"([^"]*)"',
        re.M)
    for path in glob.glob(os.path.join(mame_root, "src/mame/kaneko/*.cpp")):
        try:
            m = pat.search(open(path, encoding="utf-8", errors="ignore").read())
        except OSError:
            continue
        if m:
            return {"year": m.group(1), "manufacturer": m.group(2),
                    "name": m.group(3)}
    return {"year": "", "manufacturer": "", "name": setname}


def build_mra(setname, rompath, outdir):
    """Emit the MRA, driven from the same SETS/SDRAM_MAP tables.

    D6: the MRA owns the layout and the loader maps it as the identity, so the
    MRA and SDRAM_MAP must agree. Generating one from the other is the only way
    to keep that true — a hand-written MRA is a second description that drifts.
    """
    import xml.etree.ElementTree as ET

    zname = ZIPNAME.get(setname, setname)
    crcs = {}
    with zipfile.ZipFile(os.path.join(rompath, zname + ".zip")) as z:
        for info in z.infolist():
            crcs[info.filename] = f"{info.CRC:08x}"

    info = game_info(setname)
    root = ET.Element("misterromdescription")
    # The TITLE, not the set id — this is what the MiSTer arcade menu shows.
    ET.SubElement(root, "name").text = info["name"]
    ET.SubElement(root, "setname").text = setname
    ET.SubElement(root, "rbf").text = "Kaneko16"
    if info["year"]:
        ET.SubElement(root, "year").text = info["year"]
    if info["manufacturer"]:
        ET.SubElement(root, "manufacturer").text = info["manufacturer"]
    if setname in CATEGORY:
        ET.SubElement(root, "category").text = CATEGORY[setname]

    # Save Backup RAM: the 93C46 EEPROM, 64 words of 16 bits.
    #
    # The board's only non-volatile storage — settings, high scores and
    # whatever the game calibrates on first boot. Index 2 is the arcade
    # convention, and without this element the HPS keeps no file, the core
    # finds a blank part every time, and the game spends about four seconds
    # reformatting it before it will start.
    ET.SubElement(root, "nvram", index="2", size="128")

    # Index 1: one byte of configuration, read before the ROM stream.
    cfg = ET.SubElement(root, "rom", index="1")
    ET.SubElement(cfg, "part").text = f"{GAME_ID.get(setname, 0):02X}"

    rom = ET.SubElement(root, "rom", index="0", zip=f"{zname}.zip", md5="none")
    cursor = 0
    for region, base, size in SDRAM_MAP:
        entries = SETS[setname].get(region)
        if base != cursor:
            ET.SubElement(rom, "part", repeat=str(base - cursor)).text = "00"
            cursor = base
        if not entries:
            ET.SubElement(rom, "part", repeat=str(size)).text = "00"
            cursor += size
            continue

        # Emit parts in ADDRESS order, not entry order. ROM_RELOAD places a
        # copy at a specific offset, and those offsets interleave with other
        # files: explbrkr's sprite region is u37, u38, u37, u38, u36 by address,
        # not u37, u37, u38, u38, u36. Emitting per entry produced exactly that
        # wrong order, which would have loaded a region of the right size with
        # the halves transposed.
        placements = []          # (offset, entry, is_interleave_pair)
        i = 0
        while i < len(entries):
            e = entries[i]
            mode = e[4] if len(e) > 4 else "flat"
            if mode == "16le":
                placements.append((e[1], entries[i:i + 2], True))
                i += 2
            else:
                for dst in [e[1]] + e[3]:
                    placements.append((dst, e, False))
                i += 1
        placements.sort(key=lambda p: p[0])

        written = 0
        for off, ent, is_pair in placements:
            if off > written:
                ET.SubElement(rom, "part", repeat=str(off - written)).text = "00"
                written = off
            if is_pair:
                il = ET.SubElement(rom, "interleave", output="16")
                for pe in sorted(ent, key=lambda x: x[5]):
                    ET.SubElement(il, "part", name=pe[0],
                                  crc=crcs.get(pe[0], "0"),
                                  map="01" if pe[5] == 0 else "10")
                written += ent[0][2] * 2
            else:
                ET.SubElement(rom, "part", name=ent[0], crc=crcs.get(ent[0], "0"))
                written += ent[2]

        if written < size:
            ET.SubElement(rom, "part", repeat=str(size - written)).text = "00"
        cursor = base + size

    ET.indent(root, space="    ")
    # THE FILENAME IS WHAT THE MENU SHOWS. MiSTer's arcade list is built from
    # the .mra filenames in _Arcade, not from the <name> element inside them —
    # so a file called explbrkr.mra lists as "explbrkr" however the XML is
    # titled. Name the file after the game.
    safe = re.sub(r'[/\\:*?"<>|]', "-", info["name"]).strip()
    out = os.path.join(outdir, f"{safe}.mra")
    ET.ElementTree(root).write(out, encoding="unicode", xml_declaration=False)
    with open(out, "a") as f:
        f.write("\n")
    print(f"  {os.path.basename(out):34s} {cursor:#09x} bytes described")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 3:
        sys.exit(__doc__)
    build(args[0], args[1], args[2])
    if "--stream" in sys.argv:
        build_stream(args[0], args[2])
    if "--mra" in sys.argv:
        # MRAs are a build product: they are generated from the ROM layout
        # and staged into releases/ by make release. Under build/ with
        # everything else generated (rule 10) — releases/ is the published
        # copy, this is the intermediate.
        build_mra(args[0], args[1], "build/mra")
