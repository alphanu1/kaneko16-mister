# Kaneko16 — releases

Copy to the SD card:

| from | to |
|---|---|
| `Kaneko16_20260822.rbf` | `/media/fat/_Arcade/cores/` |
| `Explosive Breaker (World).mra` | `/media/fat/_Arcade/` |

ROMs are supplied by you and must be in `/media/fat/games/mame/` as the MRA
names them. Nothing here contains ROM data.

## What works

**Explosive Breaker only.** The 68000, memory system, interrupts, EEPROM, the
VIEW2 tilemap path, VU-002 sprites, OKI M6295 sound and the controls all run.

Everything game-specific is still compiled in for this one title — the memory
map is `bakubrkr_map`, and the screen offsets, colour base, sprite priorities
and layer count are constants. The other three Tier 1 games (Magical Crystals,
Blaze On, Wing Force) are **not** shipped as MRAs, because loading one would
produce a broken picture rather than a game. They arrive when the per-game
configuration table does.

## Not finished, as of `Kaneko16_20260822.rbf`

This list describes the RBF named above. Every entry is removed in the same
change as the RBF that fixes it, so if an item is still here it is still true
of the newest build in this directory.

- Screen rotation is not implemented. Explosive Breaker is a ROT90 game, so it
  plays sideways on a horizontal monitor until the rotation output stage lands.
- The sprite renderer still overruns its frame on about 1.5% of frames with
  heavy content, so sprites occasionally update a frame late. Down from every
  frame. Debug row 8 counts it.
- Music is absent: the YM2149s are wired and mixed, but this board's music is
  OKI samples and the game keeps the PSG volumes at zero. Verify against MAME
  before treating that as a fault.
- Screen timing is not PCB-verified (384x264 at 6 MHz, 59.1856 Hz).

## Layer1 dx +2

The VIEW2 chip draws its second tilemap layer two pixels further along than the
first — real hardware behaviour, which the game cancels by writing that layer's
scroll two lower. `Layer1 dx` in the OSD selects that offset — `+2` (MAME's value, the default),
`0`, `-2` or `+4` — as a diagnostic for a two-pixel misalignment reported on
the Blaze On board. Leave it at **+2**; the others are wrong for every game
that behaves.

## The debug overlay

`Debug overlay` in the OSD (off by default) draws seven rows of per-frame
counters over the top-left of the picture. Each row is a **binary number, most
significant bit on the left**, one block per bit: lit means 1, dark red means 0.
The dark-red field matters — it is how you tell "the count is zero" from "this
readout is not being drawn at all", which are different faults that want
opposite fixes.

**Count blocks, not the value.** A row is a number written in binary, so the
number of lit blocks is not the number being counted. Reading right to left,
the rightmost block is worth 1, the next 2, then 4, 8 and so on:

| lit blocks (rightmost first) | value |
|---|---|
| none | 0 |
| `1` | 1 |
| `1 0` | 2 |
| `1 1` | **3** |
| `1 0 0` | 4 |
| `1 1 1 1 1 1 1 1` | 255 |

So the interrupt row showing **two adjacent lit blocks at the right-hand end is
a count of 3**, which is correct and what you want to see. One lit block on its
own would be a count of 1, and would mean two of the three interrupts are
missing.

Identify a row by its **width and colour**, not by counting down the screen.
The tall yellow block is a scratch area that gets borrowed for whatever is
under investigation, so the ordinal numbering moves.

| Position | Width | Colour | Counts, per frame |
|---|---|---|---|
| 1st | 20, widest | green | 68000 bus cycles. This is the CPU's pulse — if it is dark the CPU is not running, and if it dips the CPU is being starved of memory bandwidth. 20 bits. |
| 2nd | 8, narrowest | amber | Interrupts acknowledged. Should be a steady **3** per frame — IRQ5, IRQ4 and IRQ3 — which draws as two adjacent lit blocks at the right-hand end. 8 bits. |
| 3rd | 16 | cyan | Tile line fetches that overran — the fetch for a scanline was still running when the next one started. Zero is correct. Non-zero means the video path is short of SDRAM bandwidth, and the count says by how much. 16 bits. |
| 4th | 16, tall | yellow | Writes reaching the OKI M6295, from whichever CPU drives it — the 68000 at `400401` on most boards, the Z80's port `0a` on Wing Force. Counted on the write edge so the two are comparable. It watched only the 68000's strobe until 2026-08-22 and therefore read zero on Wing Force whatever the Z80 did. 16 bits. |
| ↳ | | yellow | OKI sample-ROM fetches answered. |
| ↳ | | yellow | Clocks with an OKI channel flagged busy — the chip accepted a play command. |
| ↳ | | yellow | Clocks where the OKI produced a non-zero sample. |
| 5th | 16 | white | *(set apart below the yellow block)* Sprite passes that did not finish before the next frame started. Zero is correct. A pass clears the coverage mask, parses 1024 records and draws them at a pixel per clock, and every pixel can miss a 2.25 MB ROM — about 92,000 clocks of a frame's 811,000, so there is room, but this is the one part of the video path with no fixed upper bound. 16 bits. |
| 6th | 16 | magenta | **Live** pad-1 button word, not a per-frame count. Bit 0 is at the RIGHT: `0` right, `1` left, `2` down, `3` up, `4` A, `5` B, `6` X, `7` Y, `8` L, `9` R, `10` select, `11` start. Press a button and see which block lights — this is what the core actually receives, as opposed to what the pad is labelled. |

The four yellow rows are a **chain**, in order. Each one rules out everything
above it, so the first dark row is where the sound path breaks. All four lit
and no audio means the fault is past the chip, in the mixing or output stage.

**That block currently traces the sound path past the YM's write port** — per
frame: YM2151 writes (the control), clocks where jt51's output is non-zero,
clocks where the MIXED output is non-zero, and 4 MHz ticks lost to a ROM-cache
stall (saturating at `ffff`). It counted the Z80's ports before this, which
established that the CPU drives the YM at MAME's rate even when silent. Compare against `tools/mame_z80_ports.lua` run on
the same title. It carried the OKI chain for one build before this, which
showed that path to be correct. It had been carrying the VIEW2 scroll probe;
that probe answered its question — the raw scroll registers read back
7340/72c0 on hardware, exactly MAME — and the tile fault it was chasing is
parked, so the rows went back to their default. Whenever it is repurposed, this
table and the one in the top-level `README.md` are updated in the same commit.

These rows were added *during* the silent-sound investigation and the bug was
actually found by reading the RTL, not by reading them — so treat the chain as
the instrument for next time rather than a war story. What it would have shown:
row 4 lit, row 5 lit, row 6 dark, putting the fault between the sample ROM
arriving and the chip accepting a command.

## Controls

| | |
|---|---|
| D-pad | 8-way joystick |
| A | Shot |
| B | Bomb |
| Start / Start button | Start |
| Select / Coin button | Insert coin |
| R | Pause (the board's TILT input) |
| L | Service coin — adds a credit without a coin |

`Flip screen` and `Service switch` in the OSD are the board's two physical DIP
switches — everything else this game configures through its own test mode,
which is why there is no DIP menu. **`Service switch` is the way into the test
menu**; the L button is a different input, the service coin, which adds a
credit without dropping one in.

## Sprite offscreen skip (OSD)

A diagnostic toggle, on by default. It stops the sprite renderer walking
records whose 16x16 box is entirely outside the visible area, which takes a
full 1024-record pass from about 1,039,000 clocks to about 155,000 against a
frame budget of 811,000 — the difference between overrunning every frame and
not.

It is switchable because it went to hardware in the same build as another
sprite change and one of the two stopped Explosive Breaker's laser from
drawing. Turn it **Off** if sprites are missing; leave it **On** otherwise and
watch debug row 8.

## Save Backup RAM

The MRA declares `<nvram index="2" size="128"/>` for the 93C46 EEPROM. Open the
OSD to flush it to disk; with `Autosave` on, MiSTer writes it whenever the OSD
opens.

## Credits

The 68000 is [fx68k](https://github.com/ijor/fx68k) by **Jorge Cwik**. The sound
chips are [jt49](https://github.com/jotego/jt49) and
[jt6295](https://github.com/jotego/jt6295) by **Jose Tejada**. The framework is
**MiSTer-devel**'s. The hardware behaviour was verified throughout against
**MAME**, whose Kaneko driver is by **Luca Elia** and **David Haywood**.

GPL-3.0-only — forced by fx68k, which grants no "or later". Full detail in
`THIRD-PARTY.md` in the source repository.
