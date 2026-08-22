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
        # 68000 program, ROM_LOAD16_BYTE: u80 even bytes, u81 odd. The region
        # is ROMREGION_ERASEFF, so the tail of the 1 MB slot is 0xff — a game
        # reading up there gets what the hardware gives it, not zeroes.
        "maincpu": [
            ("bz_prg1.u80", 0x000000, 0x040000, [], "16le", 0),
            ("bz_prg2.u81", 0x000000, 0x040000, [], "16le", 1),
        ],
        "audiocpu": [("3.u45", 0x000000, 0x020000, [])],
        "view2_0": [("bz_bg.u2", 0x000000, 0x100000, [])],
        "kan_spr": [
            ("bz_sp1.u20", 0x000000, 0x100000, []),
            ("bz_sp2.u21", 0x100000, 0x100000, []),
        ],
    },
    # Wing Force. ONE VIEW2 chip, and its tile region is ROM_LOAD16_BYTE
    # interleaved across four files.
    "wingforc": {
        "maincpu": [
            ("e_2.24.u80", 0x000000, 0x080000, [], "16le", 0),
            ("o_2.24.u81", 0x000000, 0x080000, [], "16le", 1),
        ],
        "audiocpu": [("s-drv_2.22.u45", 0x000000, 0x010000, [])],
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
    "blazeonj": 2,
    "wingforc": 3,
}

# ROM_REGION fill byte, where it is not zero.
#
# MAME fills an unfilled part of a ROM region with 0x00 unless the region says
# otherwise. blazeonj's says otherwise:
#
#   ROM_REGION( 0x100000, "maincpu", ROMREGION_ERASEFF )
#   ROM_LOAD16_BYTE( "bz_prg1.u80", 0x000000, 0x040000, ... )
#   ROM_LOAD16_BYTE( "bz_prg2.u81", 0x000001, 0x040000, ... )
#
# 512 KB of program in a 1 MB window, and the upper half reads 0xFF on the real
# board, not 0x00. That is not decoration: blazeon_map maps the whole megabyte
# as ROM, so the game can read up there, and a checksum over the region gets a
# different answer from 0x00 than from 0xFF.
#
# Every other Tier 1 region is either exactly filled or explicitly ERASE (zero),
# so this table has one entry and must stay that way by inspection, not by
# assumption — check ROM_START before adding a game.
FILL = {
    ("blazeonj", "maincpu"): 0xFF,
}


def fill_of(setname, region):
    return FILL.get((setname, region), 0x00)


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

# Which games the CORE actually supports today.
#
# Shipping an MRA for a game the core cannot run is worse than shipping none:
# it looks like a supported title and fails in a way the player cannot
# diagnose.
#
# The Blaze On board joins on the per-game configuration table: its memory map
# pages, ROM bases, video geometry, layer count, sprite list size, sprite
# offset and INPUT WIRING all come from kaneko_gamecfg.sv, selected by the id
# below. Both titles close the frame gate at 100%.
#
# Magical Crystals is deliberately NOT here. Its game-table entry and its
# memory map are done, but it is the one title the frame gate does not close:
# 298 pixels of line-scroll difference that nobody has explained. Shipping a
# title with a known unexplained video discrepancy makes every later bug report
# ambiguous, so it waits until that is understood.
#
# Neither Blaze On nor Wing Force has its Z80 + YM2151 sound CPU yet, so both
# run silent. That is a stated limitation in the release README, not a bug.
SUPPORTED = {"explbrkr", "blazeonj", "wingforc"}
ALT_PARENT = {"blazeonj": "Blaze On"}

# SDRAM layout: region -> (base, size). This IS the MRA's emission order, and
# the loader maps it as the identity — stream byte N is SDRAM byte N.
#
# Sized for the Tier 1 games. Later tiers have larger sprite ROMs and the map
# will grow; because the MRA owns the layout, growing it means editing the MRA
# and this table together, not changing address arithmetic in RTL.
# A LAYOUT PER GAME, AND EXPLOSIVE BREAKER'S IS FROZEN.
#
# One shared layout was the mistake. Making room for a game that is not even
# implemented moved every region, which changed the MRA of a game that WORKED,
# which broke it. A working artefact does not get churned for a speculative one.
#
# Each game has its own MRA and its own row in the core's game table, so there
# is no reason for them to share offsets. The core reads its region bases from
# that table, so a new game cannot disturb an existing one — the property that
# actually matters, as opposed to merely leaving gaps and being careful.
#
# EXPLBRKR'S ENTRY IS A FIXED CONTRACT. It is the layout its shipped MRA
# already uses. Changing it invalidates every copy of that MRA in the wild, so
# it does not change — not to tidy it, not to align it, not to make room.
SDRAM_MAPS = {
    "explbrkr": [
        ("maincpu", 0x000000, 0x080000),
        ("view2_0", 0x080000, 0x100000),
        ("view2_1", 0x180000, 0x100000),
        ("kan_spr", 0x280000, 0x240000),
        ("oki1",    0x4c0000, 0x100000),
    ],
    "mgcrystl": [
        ("maincpu", 0x000000, 0x080000),
        ("view2_0", 0x080000, 0x100000),
        ("view2_1", 0x180000, 0x100000),
        ("kan_spr", 0x280000, 0x280000),   # larger than explbrkr's
        ("oki1",    0x500000, 0x040000),
    ],
    # The Blaze On board: one VIEW2 chip, a Z80, and a megabyte of 68000 code.
    "blazeonj": [
        ("maincpu",  0x000000, 0x100000),
        ("view2_0",  0x100000, 0x100000),
        ("kan_spr",  0x200000, 0x200000),
        ("audiocpu", 0x400000, 0x020000),
    ],
    "wingforc": [
        ("maincpu",  0x000000, 0x100000),
        ("view2_0",  0x100000, 0x200000),
        ("kan_spr",  0x300000, 0x200000),
        ("oki1",     0x500000, 0x080000),
        ("audiocpu", 0x580000, 0x010000),
    ],
}

def print_game_id(setname):
    """The config byte for a set, for callers that need it outside an MRA.

    Raises rather than defaulting: a set with no id has no correct answer, and
    substituting 0 silently configures the core as Explosive Breaker.
    """
    if setname not in GAME_ID:
        sys.exit(f"{setname}: no entry in GAME_ID")
    print(GAME_ID[setname])


def sdram_map(setname):
    if setname not in SDRAM_MAPS:
        sys.exit(f"no SDRAM layout for '{setname}'")
    return SDRAM_MAPS[setname]

def sdram_end(setname):
    return max(b + n for _, b, n in sdram_map(setname))

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
    "blazeonj": {"maincpu": 0x100000, "audiocpu": 0x020000,
                 "view2_0": 0x100000, "kan_spr": 0x200000},
    "wingforc": {"maincpu": 0x100000, "audiocpu": 0x010000,
                 "view2_0": 0x200000, "kan_spr": 0x200000, "oki1": 0x080000},
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
            buf = bytearray([fill_of(setname, region)]) * size
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
    buf = bytearray(sdram_end(setname))
    placed = []
    for region, base, size in sdram_map(setname):
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
    print(f"  {os.path.basename(out):28s} {sdram_end(setname):#09x}  "
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


    rom = ET.SubElement(root, "rom", index="0", zip=f"{zname}.zip", md5="none")
    cursor = 0
    for region, base, size in sdram_map(setname):
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
                ET.SubElement(rom, "part", repeat=str(off - written)).text = \
                    f"{fill_of(setname, region):02X}"
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
            # The region's OWN fill, not zero — see FILL. This is the tail of
            # blazeonj's maincpu: 512 KB of 0xFF that the game can read.
            ET.SubElement(rom, "part", repeat=str(size - written)).text = \
                f"{fill_of(setname, region):02X}"
        cursor = base + size

    # Index 1: the game-id word.
    #
    # md5="none" IS REQUIRED, and its absence is why this never arrived.
    # MiSTer's mra_loader decides whether to send a rom with
    #
    #     no_checksum = !strcasecmp(arc_info->md5, "none") || !strlen(...)
    #     checksumsame |= no_checksum;
    #     rom_finish(checksumsame, ...)
    #
    # and `arc_info->md5` is a PERSISTENT field carried between <rom> elements
    # rather than cleared per element. A <rom> with no md5 attribute inherits
    # whatever the previous one left there, so whether it is sent depends on
    # document order and on what came before it. Working cores always carry the
    # attribute; ours did not, and the byte was silently never transferred.
    #
    # Emitted AFTER index 0 for the same reason — that is where every working
    # MRA puts it, and the loader's state is order-dependent.
    cfg = ET.SubElement(root, "rom", index="1", md5="none")
    # NOT .get(setname, 0). A game missing from the table has no correct id,
    # and defaulting to 0 emits "Explosive Breaker" — the core then loads this
    # game's ROMs and configures itself as a different PCB, which fails much
    # later and nowhere near the cause. This shipped once; see findings.md.
    if setname not in GAME_ID:
        raise SystemExit(
            f"{setname}: no entry in GAME_ID. Add it there and to the table in "
            f"rtl/io/kaneko_gamecfg.sv — the two are checked against each other "
            f"by nothing.")
    # TWO BYTES, NOT ONE, AND THE ID IN BOTH.
    #
    # The core runs hps_io with WIDE=1 — 16-bit file I/O. A one-byte file is
    # zero 16-bit words, so the transfer never produces an ioctl write and the
    # core keeps game_id at its reset value. Explosive Breaker is id 0, so it
    # worked; every other title silently ran on Explosive Breaker's memory map,
    # geometry and inputs, which cost most of a night. Every working MiSTer core
    # that passes config this way sends an even number of bytes — 1942's is
    # "05 98".
    #
    # The id is written into BOTH bytes rather than padded with a zero, so it
    # does not matter which half of the 16-bit word the core reads. A pad byte
    # in the wrong half reads as game 0, which is Explosive Breaker, which is
    # exactly the failure this comment exists to prevent — indistinguishable
    # from working, for one game out of four.
    ET.SubElement(cfg, "part").text = \
        f"{GAME_ID[setname]:02X} {GAME_ID[setname]:02X}"

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
    # A query that answers one question and exits, so a Makefile can ask for a
    # game's config byte without assembling anything.
    if "--game-id" in sys.argv:
        q = [a for a in sys.argv[1:] if not a.startswith("--")]
        if len(q) != 1:
            sys.exit("--game-id takes exactly one set name")
        print_game_id(q[0])
        sys.exit(0)

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
