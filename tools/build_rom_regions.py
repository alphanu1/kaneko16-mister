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
        # THE TWO HALVES ARE NOT THE SAME SIZE. mc100e02 supplies the EVEN
        # bytes of the first 256 KB; mc101e02 supplies the ODD bytes of the
        # whole 512 KB. ROM_REGION is 0x040000*2 with ROMREGION_ERASE, so the
        # even bytes of the upper half are zero and that is what the hardware
        # gives. Transcribed from ROM_START( mgcrystl ) rather than from the
        # zip listing, per the note on explbrkr below.
        #
        # This region was MISSING ENTIRELY until 2026-08-23, so every Magical
        # Crystals MRA shipped with a zero-filled program ROM and the 68000
        # executed a megabyte of nothing. It presented as a black screen with
        # a healthy bus-cycle count and zero interrupts acknowledged -- a CPU
        # running perfectly well through code that does not exist.
        "maincpu": [
            ("mc100e02.u18", 0x000000, 0x020000, [], "16le", 0),
            ("mc101e02.u19", 0x000000, 0x040000, [], "16le", 1),
        ],
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
    # ---------------------------------------------------------------- Tier 2
    # CALC3 board. One VIEW2 chip, VU-002 sprites, and TWO OKIs -- the second
    # is new to this core. calc3_rom is the MCU's external DATA rom; its
    # internal program rom is not dumped, so the MCU is a simulation and this
    # region is what that simulation reads.
    "shogwarr": {
        "maincpu": [
            ("fb030e.u61", 0x000000, 0x020000, [], "16le", 0),
            ("fb031e.u62", 0x000000, 0x020000, [], "16le", 1),
        ],
        "calc3_rom": [("fb040e.u33", 0x000000, 0x020000, [])],
        # ROMREGION_ERASEFF over 0x1000000 with 0x700000 loaded: the tail is
        # 0xff on the board, not zero, and the region is sized by MAME rather
        # than by the files.
        "kan_spr": [
            ("fb-020a.u1", 0x000000, 0x100000, []),
            ("fb020b.u2",  0x100000, 0x100000, []),
            ("fb021a.u3",  0x200000, 0x100000, []),
            ("fb021b.u4",  0x300000, 0x100000, []),
            ("fb-22a.u5",  0x400000, 0x100000, []),
            ("fb-22b.u6",  0x500000, 0x100000, []),
            ("fb023.u7",   0x600000, 0x100000, []),
        ],
        "view2_0": [
            ("fb010.u65", 0x000000, 0x100000, []),
            ("fb011.u66", 0x100000, 0x080000, []),
        ],
        "oki1": [
            ("fb001e.u43", 0x000000, 0x080000, []),
            ("fb000e.u42", 0x080000, 0x080000, []),
        ],
        "oki2": [
            ("fb-002.u45", 0x000000, 0x100000, []),
            ("fb-003.u44", 0x100000, 0x100000, []),
        ],
    },
    # Same board as shogwarr. rb-024 is ROM_RELOADed once -- the dump is half
    # the size of the space it fills and MAME loads it twice, which a naive
    # concatenation would get wrong above 0x480000.
    "brapboys": {
        "maincpu": [
            ("rb-030.01.u61", 0x000000, 0x020000, [], "16le", 0),
            ("rb-031.01.u62", 0x000000, 0x020000, [], "16le", 1),
        ],
        "calc3_rom": [("rb-040.00.u33", 0x000000, 0x020000, [])],
        "kan_spr": [
            ("rb-020.u100",   0x000000, 0x100000, []),
            ("rb-021.u76",    0x100000, 0x100000, []),
            ("rb-022.u77",    0x200000, 0x100000, []),
            ("rb-023.u78",    0x300000, 0x100000, []),
            ("rb-024.u79",    0x400000, 0x080000, [0x480000]),
            ("rb-025.01.u80", 0x500000, 0x040000, []),
        ],
        "view2_0": [
            ("rb-010.u65", 0x000000, 0x100000, []),
            ("rb-011.u66", 0x100000, 0x100000, []),
            ("rb-012.u67", 0x200000, 0x100000, []),
            ("rb-013.u68", 0x300000, 0x100000, []),
        ],
        "oki1": [
            ("rb-000.u43",     0x000000, 0x080000, []),
            ("rb-003.00.u101", 0x080000, 0x080000, []),
        ],
        "oki2": [
            ("rb-001.u44", 0x000000, 0x100000, []),
            ("rb-002.u45", 0x100000, 0x100000, []),
        ],
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
# KanekoCALC3.sv; the two are checked against each other by nothing, so they are
# listed adjacently in both files with the same order.
GAME_ID = {
    "explbrkr": 0,
    "mgcrystl": 1,
    "blazeonj": 2,
    "wingforc": 3,
    "shogwarr": 4,
    "brapboys": 5,
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
    # ROM_REGION( 0x1000000, "kan_spr", ROMREGION_ERASEFF ) with 0x700000
    # loaded. Nine megabytes of this region read 0xff on the board, and a
    # sprite whose code lands up there fetches 0xff rather than 0x00 -- which
    # is a solid colour in a 4bpp tile, not transparency.
    ("shogwarr", "kan_spr"): 0xFF,
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
# A set is PRIMARY when it is the one that belongs in /_Arcade/ and shows up in
# the arcade menu. Anything else goes to _alternatives/, which MiSTer does NOT
# scan -- the player copies those by hand.
#
# blazeonj was left out on the reasoning that primary means World or USA where
# one exists, so the Japan set should wait "until a World set turns up". That
# is backwards for a release: the Japan set is the ONLY Blaze On this core
# supports, so filing it under _alternatives means the one dumped set of a
# working game never appears in the menu. releases/README.md has always told
# players to copy it to /_Arcade/, and it was already tracked there, so the
# tool disagreed with both the documentation and the shipped layout.
#
# The rule is about which of SEVERAL sets leads, not about withholding the only
# one there is.
PRIMARY = {"explbrkr", "mgcrystl", "wingforc", "blazeonj"}

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
# Magical Crystals joined on 2026-08-23, after a person played it on hardware.
# It needed two fixes, in this order, and neither was visible from the other:
#
#   1. its MRA carried no 68000 program ROM at all, because its two program
#      ROMs are DIFFERENT SIZES and the emitter assumed symmetric lanes
#   2. six DSW bits at c00000 were driven low where the board pulls them high,
#      so the game failed a boot check and sat with the 68000 masked at level 7
#
# The 298-pixel line-scroll difference in the M0 frame gate is still open and
# is NOT a reason to withhold it any more: the game runs and plays correctly on
# hardware, which is a stronger statement about the title than a static frame
# diff is. The discrepancy stays recorded in findings.md and HANDOFF.md.
#
# Wing Force has no OKI sound effects and no attract music. That is a stated
# limitation in the release README, not a bug.
SUPPORTED = {"explbrkr", "blazeonj", "wingforc", "mgcrystl"}
# Display name for a set's _alternatives/ directory, used only for sets that
# are NOT primary. Empty while every supported set is the primary of its game;
# a World Blaze On or a second Wing Force revision would put an entry back.
ALT_PARENT = {}

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
    # ---------------------------------------------------------------- Tier 2
    # The CALC3 board. Much larger than Tier 1: shogwarr alone is 20 MB, and
    # its sprite region is 16 MB of which 9 read 0xff. calc3_rom is the MCU's
    # external data and is fetched by the MCU simulation, not by a video
    # engine, but it lives in the same stream because the loader only knows
    # how to fill one.
    #
    # Ordered largest-last so the regions the video path fetches sit low, which
    # keeps their row addresses short and the arithmetic in the feeders the
    # same shape as Tier 1's.
    "shogwarr": [
        ("maincpu",   0x0000000, 0x0040000),
        ("calc3_rom", 0x0040000, 0x0020000),
        ("view2_0",   0x0060000, 0x0400000),
        ("oki1",      0x0460000, 0x0100000),
        ("oki2",      0x0560000, 0x0200000),
        ("kan_spr",   0x0760000, 0x1000000),
    ],
    "brapboys": [
        ("maincpu",   0x0000000, 0x0040000),
        ("calc3_rom", 0x0040000, 0x0020000),
        ("view2_0",   0x0060000, 0x0400000),
        ("oki1",      0x0460000, 0x0100000),
        ("oki2",      0x0560000, 0x0200000),
        ("kan_spr",   0x0760000, 0x0800000),
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


# WHERE THE CALC3 MCU'S 64 KB OF RAM LIVES IN SDRAM.
#
# Not part of the ROM stream -- nothing loads it, the MCU fills it at runtime --
# but it needs an address that cannot collide with anything the loader wrote,
# and the RTL and this tool have to agree on where that is or the reads land in
# the sprite ROM.
#
# It sits immediately above the stream, rounded up to a 64 KB boundary so the
# base is a clean value in both places:
#
#   shogwarr   stream ends 0x1760000  ->  MCU RAM at 0x1760000
#   brapboys   stream ends 0x0f60000  ->  MCU RAM at 0x0f60000
#
# 64 KB above a 23.4 MB stream is comfortable even on a 32 MB module.
#
# WHY IT IS IN SDRAM AT ALL. In block memory it costs 56 M10K and takes the
# device to 95%, where MiSTer's HDMI PLL stops meeting timing -- this core's
# own clocks are fine at +0.442 and +1.999 ns. Measured with
# tools/mame_calc3_mcuram.lua, shogwarr touches it about 2,650 times a frame,
# roughly 6.5% of a frame's clocks, so the bandwidth is affordable.
MCURAM_BYTES = 0x10000

def mcuram_base(setname):
    """Byte address of the MCU RAM window, immediately above the ROM stream."""
    end = sdram_end(setname)
    return (end + 0xffff) & ~0xffff

REGION_SIZE = {
    # Tier 2. shogwarr's sprite region is 0x1000000 with ROMREGION_ERASEFF and
    # only 0x700000 loaded, so nine megabytes of it read 0xff on the board.
    # Sized as MAME sizes it rather than as the files fill it: the sprite code
    # is 16 bits and a 256-byte record, so the address space genuinely reaches
    # there and a shorter region would alias reads that should return 0xff.
    "shogwarr": {"maincpu": 0x040000, "calc3_rom": 0x020000,
                 "kan_spr": 0x1000000, "view2_0": 0x400000,
                 "oki1": 0x100000, "oki2": 0x200000},
    "brapboys": {"maincpu": 0x040000, "calc3_rom": 0x020000,
                 "kan_spr": 0x800000, "view2_0": 0x400000,
                 "oki1": 0x100000, "oki2": 0x200000},
    # maincpu is 0x040000*2 in ROM_START, with ROMREGION_ERASE: the even bytes
    # of the upper half are genuinely zero, not absent.
    "mgcrystl": {"maincpu": 0x080000,
                 "view2_0": 0x100000, "view2_1": 0x100000,
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
    ET.SubElement(root, "rbf").text = "KanekoCALC3"
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
                # THE TWO LANES OF AN INTERLEAVE MUST ADVANCE EQUALLY.
                #
                # mra_loader's rom_data() keeps a SEPARATE write cursor per
                # lane -- romlen[idx], where idx comes from the first non-zero
                # nibble of `map` -- and NOTHING resyncs them at the closing
                # </interleave>. So an interleave whose two parts differ in
                # length leaves the cursors apart by that difference, and the
                # next part, which writes at romlen[0], lands back inside the
                # longer lane's tail and overwrites what is already there.
                #
                # mgcrystl is the only set here that is asymmetric:
                #
                #   ROM_REGION( 0x040000*2, "maincpu", ROMREGION_ERASE )
                #   ROM_LOAD16_BYTE( "mc100e02.u18", 0x000000, 0x020000 )
                #   ROM_LOAD16_BYTE( "mc101e02.u19", 0x000001, 0x040000 )
                #
                # 0x20000 of even bytes against 0x40000 of odd, with the
                # region's ERASE covering the even lane's upper half. Emitted
                # as ONE interleave it desyncs the cursors; emitted as two
                # EQUAL interleaves -- the second taking its short lane from
                # the region fill -- the cursors stay in step and the region
                # is exactly the 0x80000 MAME describes.
                #
                # Symmetric pairs, which is every other region in every other
                # set, take the first branch only and emit byte for byte what
                # they always did.
                pair = sorted(ent, key=lambda x: x[5])
                lane = lambda pe: "01" if pe[5] == 0 else "10"
                n = min(pe[2] for pe in pair)
                m = max(pe[2] for pe in pair)

                il = ET.SubElement(rom, "interleave", output="16")
                for pe in pair:
                    a = dict(name=pe[0], crc=crcs.get(pe[0], "0"), map=lane(pe))
                    if pe[2] != n:
                        a["length"] = hex(n)
                    ET.SubElement(il, "part", **a)

                if m != n:
                    il2 = ET.SubElement(rom, "interleave", output="16")
                    for pe in pair:
                        if pe[2] == n:
                            ET.SubElement(
                                il2, "part", repeat=str(m - n), map=lane(pe)
                            ).text = f"{fill_of(setname, region):02X}"
                        else:
                            ET.SubElement(il2, "part", name=pe[0],
                                          crc=crcs.get(pe[0], "0"),
                                          offset=hex(n), length=hex(m - n),
                                          map=lane(pe))
                written += m * 2
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
    # Where a region sits in the one stream the loader fills. No .get() with a
    # fallback: a region that is not in the map has no correct offset, and
    # answering 0 would put the MCU's data ROM on top of the 68000's program.
    if "--region-offset" in sys.argv:
        q = [a for a in sys.argv[1:] if not a.startswith("--")]
        if len(q) != 2:
            sys.exit("--region-offset takes a set name and a region name")
        setname, region = q
        if setname not in SDRAM_MAPS:
            sys.exit("no SDRAM map for %s" % setname)
        for name, off, _size in SDRAM_MAPS[setname]:
            if name == region:
                print("0x%x" % off)
                sys.exit(0)
        sys.exit("%s has no region %s" % (setname, region))

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
