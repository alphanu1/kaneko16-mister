# Kaneko16 — releases

Copy to the SD card:

| from | to |
|---|---|
| `Kaneko16_20260823.rbf` | `/media/fat/_Arcade/cores/` — **rename to `Kaneko16.rbf` on the card** |
| `Explosive Breaker (World).mra` | `/media/fat/_Arcade/` |
| `Blaze On (Japan).mra` | `/media/fat/_Arcade/` |
| `Wing Force (Japan, prototype).mra` | `/media/fat/_Arcade/` |

ROMs are supplied by you and must be in `/media/fat/games/mame/` as the MRA
names them. Nothing here contains ROM data.

**Do not rename the core.** MiSTer resolves `<rbf>Kaneko16</rbf>` by scanning
for names starting `Kaneko16` followed by `.` or `_`, and keeps the
lexicographically greatest — so a spare copy called `Kaneko16_GOOD.rbf` beats
`Kaneko16.rbf` and is loaded instead, silently. Keep fallbacks out of
`cores/` entirely.

## What works

**Three of the four games.** One bitstream covers them all; the MRA hands the
core a game-id byte and `rtl/io/kaneko_gamecfg.sv` selects the memory map, ROM
bases, screen geometry, layer count, sprite list size and input wiring.

| Game | State |
|---|---|
| Explosive Breaker | playable, with sound |
| Blaze On (Japan) | playable, with music and effects |
| Wing Force (prototype) | playable, with in-game music; **no OKI sound effects, and no music in the attract demo** |
| Magical Crystals | **not shipped — cause found, fix in progress.** The MRA never carried a 68000 program ROM, so the CPU executed a zero-filled region |

An MRA for a game the core cannot run is deliberately not shipped: it looks
supported and then fails in a way a player cannot diagnose.

## Not finished, as of `Kaneko16_20260823.rbf`

This list describes the RBF named above. Every entry is removed in the same
change as the RBF that fixes it, so if an item is still here it is still true
of the newest build in this directory. **The heading carries the RBF's name for
exactly that reason — if they disagree, trust neither and check.**

- **Magical Crystals is not shipped.** It has never booted: its MRA never
  carried a 68000 program ROM, so the region was zero-filled and the CPU
  executed half a megabyte of zeros. The cause is understood and the fix is in
  progress; the region is awkward because its two byte lanes are different
  sizes.
- **Wing Force has no sound effects**, and no music in the attract demo. Its
  in-game music is correct. The OKI on that board hangs off the Z80's I/O ports
  rather than the 68000's bus, and that path is still being chased.
- Screen **blanking** is not PCB-verified. The refresh rate is corroborated:
  6 MHz over 384x264 totals gives 59.1856 Hz, and MAME's only precise figure in
  this driver is `set_refresh_hz(59.1854)` — on `wingforc` and `shogwarr`, four
  decimal places apart from ours. Its other entries are round placeholders
  (`60`, and `59` for Explosive Breaker), so the agreement is with the one
  number that looks measured. What is still a derivation rather than a
  measurement is how those totals SPLIT — 128 of 384 horizontal and 40 of 264
  vertical — because no `set_raw()` anywhere in the driver pins the blanking.
  Only a capture from a real PCB would settle that.

  The RATE itself is not a detail to wave away. This hardware drives its sound
  from the frame interrupt, so running 60 Hz instead of 59.1856 would play the
  music 1.4% sharp and the whole game 1.4% fast, and an off-rate core judders
  against a fixed-60 display — about one repeated frame every seventy. The
  split affects where the picture sits and how long the game has in vblank to
  write VRAM, which is a smaller thing but not a nothing.
- Tier 2 and Tier 3 of the driver are not attempted. Shogun Warriors and B.Rap
  Boys need the CALC3 MCU; Great 1000 Miles Rally, Blood Warrior and Bonk's
  Adventure need TOYBOX and, for GTMR, the KC-002 sprite chip's 8bpp path.

Removed from this list since 20260822, all confirmed on hardware:

- ~~Screen rotation is not implemented~~ — done, per game and in both
  directions, **off by default**.
- ~~The sprite renderer overruns its frame on about 1.5% of frames~~ — the
  arbitration was changed to serve by deadline rather than equal share, and
  the overrun counters have read zero since. SDRAM now runs at 96 MHz as well,
  which is headroom rather than a fix.
- ~~Music is absent~~ — Explosive Breaker's soundtrack is the OKI and it plays;
  its level was 12 dB below the Blaze On board and has been raised. Blaze On
  has music and effects.

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

**That block currently shows where the 68000 is** — per frame: the last acknowledged bus address high half, its low half, the last unmapped address, and the count of unmapped accesses. It is pointed at Magical Crystals, which runs and never enables interrupts.

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
