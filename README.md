# Kaneko 16 — MiSTer FPGA core

An FPGA implementation of Kaneko's 16-bit arcade hardware for MiSTer
(Terasic DE10-Nano, Cyclone V 5CSEBA6U23I7). Not an emulator: RTL that behaves
as the original silicon did, verified against MAME as an oracle.

**Status: early. M0 (graphics spikes) in progress, M1 (first bring-up) not
started.** See `docs/HANDOFF.md` for an honest gap analysis before assuming
anything here runs a game — nothing does yet.

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
| SDRAM controller, ROM loader | running on hardware |
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
| Z80 + YM2151 sound (Blaze On board) | **built and fits, not yet confirmed on hardware** — T80 at 4 MHz, jt51, Wing Force's OKI on the Z80's I/O ports, and a 256-byte cache over SDRAM for the program ROM. A 48 KB copy in block RAM did not fit; see `docs/findings.md` |
| Screen rotation | **not implemented** — Explosive Breaker is ROT90 and Wing Force ROT270, and both currently output unrotated |

Explosive Breaker is playable on hardware with sound. The 68000 completes its
self-test, formats a blank EEPROM, enables interrupts and runs its main loop;
tilemaps, sprites, inputs and the OKI all work.

## Games

One bitstream covers every game. The MRA hands the core a game-id byte and
`rtl/io/kaneko_gamecfg.sv` selects everything that differs — an MRA for a game
the core cannot run is not shipped, because it looks supported and then fails
in a way a player cannot diagnose.

| Game | State |
|---|---|
| Explosive Breaker | playable on hardware, with sound |
| Blaze On (Japan) | **runs on hardware** — renders and takes input. Sound path built, unconfirmed. A tilemap layer draws wrong |
| Wing Force (prototype) | **runs on hardware** — renders and takes input. Sound path built, unconfirmed. Same tilemap fault |
| Magical Crystals | held back — an unexplained 298-pixel line-scroll difference |

The debug overlay (OSD: Debug) puts seven rows of per-frame telemetry over the
picture, each a binary count with the MSB at the left:

Identify a row by its **width and colour**, not by counting down the screen —
the rows in the tall block are borrowed for whatever is under investigation and
the ordinal numbering has moved more than once.

| Position | Width | Colour | Count |
|---|---|---|---|
| 1st | 20 — widest | green | bus cycles |
| 2nd | 8 — narrowest | amber | interrupts acknowledged (3 per frame = two lit blocks) |
| 3rd | 16 | cyan | **tilemap** line fetches that overran |
| 4th | 16, tall (4 rows fused) | yellow | **borrowed — see below** |
| *(gap)* | | | |
| 5th | 16 | white | **sprite** passes that did not finish before the next frame |
| 6th | 16 | magenta | live joystick 1 word — bit 0 at the right |

`Layer1 dx` in the OSD selects the offset the VIEW2 chip applies to its second
tilemap layer: `+2` (what MAME does and the default), `0`, `-2` or `+4`. The offset is correct — MAME sets
`set_scrolldx(-(m_dx+2))` for `tmap[1]` and the game cancels it by writing that
layer's scroll two lower — so this is a diagnostic for a reported two-pixel
ghost on the Blaze On board, not a setting to leave on.

**The tall block is a scratch area.** It is currently the **Z80 sound-port
census**, for diffing against `tools/mame_z80_ports.lua` on the same title. The
OKI chain lived here for one build and answered its question — the rows lit
whenever Wing Force made any sound and were dark otherwise, so the OKI path is
correct and the fault is upstream in the Z80.

| Sub-row | Shows |
|---|---|
| 1st | Z80 writes to the YM2151 (ports `02`/`03`), per frame — the control. MAME's Wing Force: ~8 menu, ~18 demo |
| 2nd | Clocks where **jt51's own output** is non-zero — is the chip producing anything? |
| 3rd | Clocks where the **mixed** output is non-zero — did it survive the mix? |
| 4th | 4 MHz Z80 ticks LOST to a ROM-cache stall, per frame, saturating at `ffff` |

Row 1 is the control and should sit near MAME's rate. Row 2 dark with row 1
healthy means jt51 is being written and producing nothing. Row 2 lit with row 3
dark means the mix is eating it — the OKI is summed in at full weight beside the
YM before the halving. Row 4 is the ROM cache, measured at a 0.5% miss rate
against a real MAME fetch trace, so it should stay small.

It has previously carried the CPU's last bus address, the exception vector
number, the unmapped address and the VIEW2 scroll probe. **Identify rows by
width and colour, never by ordinal** — the ordinal moves, and a stale reading
of this table costs a round trip to the board and a wrong diagnosis.

Whenever that block is repurposed, this table and `releases/README.md` are
updated in the same commit.

Each row is a binary number with the MSB at the left, one block per bit; a
clear bit is dark red rather than black, so "the count is zero" is
distinguishable from "this readout is not being drawn", which are different
faults wanting opposite fixes.

The number of lit blocks is not the number counted: the interrupt row's correct
reading is 3, which draws as two adjacent lit blocks at the right-hand end.

Rows 4-7 are a chain: the first dark one is where the sound path breaks, and
each rules out everything above it. Row 1 dipping means the CPU is being
starved of memory bandwidth; row 3 non-zero means the video path is.

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

## Building and testing

`third_party/` is **not in the repository**. Populate it first:

```
./tools/bootstrap.sh
```

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
