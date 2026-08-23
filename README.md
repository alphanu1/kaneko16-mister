# Kaneko 16 — MiSTer FPGA core

An FPGA implementation of Kaneko's 16-bit arcade hardware for MiSTer
(Terasic DE10-Nano, Cyclone V 5CSEBA6U23I7). Not an emulator: RTL that behaves
as the original silicon did, verified against MAME as an oracle.

**Status: all four Tier 1 games are playable on hardware.** Explosive Breaker,
Magical Crystals, Blaze On and Wing Force run with graphics, input and sound,
and all four are shipped. Wing Force is missing its OKI sound effects and its
attract music; everything else plays. Later titles needing the CALC3 or TOYBOX
MCUs are not attempted. See `docs/HANDOFF.md` for the gap analysis.

## The hardware

| | |
|---|---|
| CPU | 68000 at 12 MHz (16 MHz on later boards) |
| Graphics | **VIEW2-CHIP** tilemaps and **VU-002** / **KC-002** sprites — the two custom devices this core exists to implement |
| Sound | 2x YM2149 + OKI M6295, or Z80 + YM2151 + OKI depending on board |
| Protection | CALC3 or TBSOP01/02 MCU on later titles, neither with a dumped program ROM |

Target library spans Magical Crystals, Explosive Breaker, Blaze On, Wing Force,
Shogun Warriors, B.Rap Boys, Bonk's Adventure, Blood Warrior and Great 1000
Miles Rally 1/2.

## Per-block status

| Block | State |
|---|---|
| VIEW2 tilemap address engine | fuzzed clean (3.0M checks), oracle-verified |
| VU-002 sprite list parser | fuzzed clean (41k checks), oracle-verified |
| Tilemap pixel fetch and line buffers | fuzzed clean; rendering on hardware, no visible artefacts |
| VU-002 sprite subsystem | `kaneko_spr_sys`: parser, resolved table, double-buffered bitmap and mask, mixer read. 65k checks clean, instantiated in the core |
| Video timing | 384x264 at 6 MHz, 59.1856 Hz; running on hardware |
| SDRAM controller, ROM loader | running on hardware at **96 MHz**, twice the core clock, through `kaneko_sdram_x2`. The read capture depth is an OSD option because the board has never agreed with the simulation model about it — it wants CL+4 where the model wants CL+5. Changing it at runtime leaves artefacts until the affected data is overwritten; it is a diagnostic, not a setting |
| 68000 (fx68k) + bus decode | running on hardware; matches MAME exactly over 100k bus accesses |
| ROM line cache | 16 lines x 4 words, 0.1% miss; CPU back to MAME's bus rate |
| SDRAM masters | nine: four tile layers, the 68000, the OKI, two sprite ports and the Z80's program fetch. Served in two tiers by deadline, not equal share |
| Scanline interrupts | IRQ5/4/3 autovectored; the game takes all three, once per frame |
| VIEW2 / sprite register files | `kaneko_regs16`, byte-enabled, read back correctly |
| YM2149 x2 (jt49) | wired and mixed to the audio output; the game keeps their volumes at zero |
| OKI M6295 (jt6295) | **working on hardware** — sound effects play. Bank limit and control port are both per-game: the 68000 drives it on most boards, the Z80 on Wing Force |
| EEPROM (93C46) | working; 20,910 reads replayed against MAME, zero mismatches |
| Inputs | two players, 2 buttons each, start/coin/service, and the board's DIPs — assembled per board, because the two boards wire the words differently, not just relocate them |
| Game configuration table | `rtl/io/kaneko_gamecfg.sv` — one bitstream, four games; memory-map pages, ROM bases, video geometry, layer count, sprite list size and input wiring all selected by the MRA's game-id byte |
| Z80 + YM2151 sound (Blaze On board) | **working on Blaze On** — music and effects. T80 at 4 MHz, jt51, and a 256-byte cache over SDRAM for the program ROM; a 48 KB copy in block RAM did not fit. Wing Force has in-game music but no OKI effects and no attract music; its OKI hangs off the Z80's I/O ports rather than the 68000's bus, and that path is still open |
| Screen rotation | **working on hardware** — per game, because it is per game in both senses: Explosive Breaker is ROT90 and Wing Force ROT270, turned in OPPOSITE directions, while Blaze On and Magical Crystals are ROT0. Uses MiSTer's `screen_rotate` and the DDR3 framebuffer, so it costs no M10K and no SDRAM bandwidth. **Off by default** — on a landscape monitor a turned game is a tall strip, and the framebuffer path costs a frame of latency. OSD: Off / Auto (per game) / CW / CCW |

All four games are playable on hardware. The 68000 completes its
self-test, formats a blank EEPROM, enables interrupts and runs its main loop;
tilemaps, sprites, inputs and sound all work on Explosive Breaker and Blaze On,
and Wing Force is complete apart from its OKI effects.

Magical Crystals joined them on 2026-08-23 and plays correctly.

## Games

One bitstream covers every game. The MRA hands the core a game-id byte and
`rtl/io/kaneko_gamecfg.sv` selects everything that differs — an MRA for a game
the core cannot run is not shipped, because it looks supported and then fails
in a way a player cannot diagnose.

| Game | State |
|---|---|
| Explosive Breaker | **playable**, with sound |
| Blaze On (Japan) | **playable**, with music and effects |
| Wing Force (prototype) | **playable**, graphics, input and in-game music all correct. **No OKI sound effects, and no music in the attract demo** |
| Magical Crystals | **playable**, with sound. Took two independent fixes: its MRA carried no 68000 program ROM, because its two program ROMs are different sizes and the emitter assumed symmetric interleave lanes; and six DSW bits at `c00000` were driven low where the board pulls them high, which failed a boot check and left the 68000 masked at level 7 refusing interrupts |

Two OSD options are development instruments rather than settings. The **debug
overlay** draws per-frame counters over the picture — bus cycles, interrupts,
fetch overruns, sprite overruns and the live pad word — and is documented row
by row in `docs/debug-overlay.md`. Its tall yellow block is a scratch area that
changes between builds; in this one it is **SDRAM occupancy per scanline**,
measuring whether the sprite bitmap can move out of block memory. **`Layer1 dx`** selects the offset the VIEW2
chip applies to its second tilemap layer; `+2` is MAME's value and the default,
and the alternatives are wrong for every game that behaves.

M0 frame gate, RTL rendered against a frame MAME actually produced:

```
mgcrystl  99.48%   (298 / 57344 pixels differ)
explbrkr 100.00%   (exact)
blazeonj 100.00%   (exact)
wingforc 100.00%   (exact, 71680 pixels)
```

The gate is scanline-exact. Three of the four are pixel-exact; mgcrystl's
298-pixel difference is an unresolved line-scroll anomaly on odd rows, recorded
in `docs/findings.md`.

CPU gate, the core's 68000 bus trace against MAME's on explbrkr:

```
ours 100000 accesses, 22897 after dropping instruction fetches
mame 100000 accesses, 22898 after dropping instruction fetches
MATCH over all 22897 compared accesses
```

## SDRAM

The MRA describes one contiguous stream and the loader maps it as the identity,
so a game's SDRAM requirement is just the sum of its ROM regions. Measured for
the shipped games, estimated from `ROM_REGION` sizes for the rest:

**Tier 1 — shipped.** No MCU, VU-002 sprites. Measured.

| Game | SDRAM |
|---|---|
| Blaze On | 4.12 MB |
| Magical Crystals | 5.25 MB |
| Wing Force | 5.56 MB |
| Explosive Breaker | 5.75 MB |

**Tier 2 — CALC3 MCU, VU-002 sprites.** Estimated from `ROM_REGION` sizes.

| Game | SDRAM |
|---|---|
| B.Rap Boys | ~15.4 MB |
| Shogun Warriors | ~23.4 MB |

**Tier 3 — TOYBOX MCU, KC-002 sprites.** Estimated. Adds ~1 MB for the sprite
bitmap, which cannot live in block memory.

| Game | SDRAM |
|---|---|
| Bonk's Adventure | ~14.1 MB |
| Great 1000 Miles Rally | ~15.4 MB |
| Great 1000 Miles Rally 2 | ~19.1 MB |
| **Blood Warrior** | **~35.1 MB — exceeds 32 MB** |

**All four shipped games fit comfortably in a 32 MB module** by size — the
largest is under 6 MB, and nothing in Tier 1 comes close to the limit.

**Development and testing here is on a 128 MB module**, so that is the only
configuration anything has actually run on. A 32 MB board should be fine for
the shipped games on these numbers, but "fits by arithmetic" is not the same
statement as "has been played", and nobody has played it. If you run one,
saying so is useful.

Later tiers do not all fit. **Blood Warrior is Tier 3** — TOYBOX MCU and the
KC-002 sprite chip — and at 35 MB, 30 MB of it `kan_spr`, it is the one title
here that **requires** a 128 MB module rather than merely preferring one.
Shogun Warriors, the largest Tier 2 game at 23 MB, fits 32 MB but leaves little
margin once the sprite bitmap moves into SDRAM.

Tier 3 also needs about **1 MB** of SDRAM for the KC-002 sprite bitmap,
which cannot live in block memory: 512x512x16 double-buffered is 8.39 Mbit
against the device's 5.66 Mbit, so it does not fit even if the core held
nothing else. `docs/00-decisions.md` D5 records that measurement and what it
rules out.

## Building and testing

`third_party/` is **not in the repository**, and neither is `sys/`. Both are
gitignored, so a fresh clone has neither. Populate them first:

```
./tools/bootstrap.sh
```

That fetches the five cores the bitstream is built from — `fx68k`, `jt49`,
`jt51`, `jt6295` and `t80` — at the revisions pinned in `deps.lock`, and copies
the MiSTer framework into `sys/`. Quartus reads `sys/sys.tcl` from the project
file, so opening the QSF before bootstrapping fails on a missing file rather
than on anything to do with this core. MAME is needed as well for the oracle
gates below, but not to compile.

**Playing the core needs none of this** — an `.rbf`, an `.mra` and your own
ROMs, all described in `releases/README.md`.

Then the simulation gate, which must be clean before any synthesis:

```
make lint && make test
```

The oracle frame diff needs MAME and a ROM set:

```
make frame SET=mgcrystl ROMPATH=/path/to/roms
```

The 68000 is gated against the real memory system — loader, arbiter and an
SDRAM device model rather than a stubbed ROM — which needs an assembled
program region, so it sits outside `make test`:

```
make boot SET=explbrkr ROMPATH=/path/to/roms
```

Synthesis is pinned to **Quartus 17.0** and `make quartus` refuses any other
version. 24.x accepts Cyclone V and will build a subtly different core; that is
why the check exists. See `CLAUDE.md`.

To put a build on a MiSTer and verify what landed:

```
make deploy                 # core + MRAs, checksum-checked
make deploy MISTER=1.2.3.4
```

## Documentation

| | |
|---|---|
| `docs/HANDOFF.md` | state of play and what is left — read first |
| `docs/findings.md` | measured facts, each with its instrument and what it corrected |
| `docs/00-decisions.md` | decisions and what would reverse them |
| `docs/kaneko16-design-study.md` | the original feasibility study, with corrections marked in place |
| `THIRD-PARTY.md` | every vendored dependency and what its licence obliges |

`docs/findings.md` is the important one. The design study was written before
any source was vendored, and reading MAME has since corrected it on several
checkable points — tile priority bits, the BG disable bit, the line-scroll
index, the CALC3 ROM status, two dependency licences. Where the two disagree,
`findings.md` wins.

## Credits

This core is built on other people's work, and most of the hard parts of it are
theirs. Licences and the obligations they carry are in `THIRD-PARTY.md`; this
section is the acknowledgement.

| | |
|---|---|
| **Jorge Cwik** (*ijor*) | [fx68k](https://github.com/ijor/fx68k) — the 68000. A cycle-accurate implementation from the die, and the reason this core is GPL-3.0-only. Vendored via [jtfpga/fx68k](https://github.com/jtfpga/fx68k), whose `hdl/verilator/` variant is what makes it simulate here. |
| **Jose Tejada** (*jotego*) | [jt49](https://github.com/jotego/jt49) — YM2149, [jt6295](https://github.com/jotego/jt6295) — OKI M6295, [jt51](https://github.com/jotego/jt51) — YM2151. The entire sound path. |
| **MiSTer-devel** | [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) and `sys/` — the framework: scaler, HDMI, OSD, HPS interface, save handling. [T80](https://github.com/MiSTer-devel/T80) for the Z80, originally by Daniel Wallner. |
| **MAME team** | The behavioural oracle for every part of this project. `src/mame/kaneko/` is by **Luca Elia** and **David Haywood**; the tilemap, sprite and MCU devices, the memory maps and the per-game quirks were all read from it. Where this project's documentation and MAME disagreed, MAME was right. |
| **Kaneko** | The original hardware, 1991-1994. |

The RTL under `rtl/` is original to this project. Everything under
`third_party/` is not, is never committed here, and is fetched by
`tools/bootstrap.sh` at the revisions pinned in `deps.lock`.

## Licence

**GPL-3.0-only.** Forced by fx68k, which grants no "or later" — see
`THIRD-PARTY.md`. This is narrower than most MiSTer cores, which are
GPL-2.0-or-later, and it is a deliberate consequence rather than a preference.

ROM images are not distributed, and nothing derived from them is committed.
