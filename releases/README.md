# Kaneko16 — releases

Copy to the SD card:

| from | to |
|---|---|
| `Kaneko16_20260823.rbf` | `/media/fat/_Arcade/cores/` — **rename to `Kaneko16.rbf` on the card** |
| `Explosive Breaker (World).mra` | `/media/fat/_Arcade/` |
| `Blaze On (Japan).mra` | `/media/fat/_Arcade/` |
| `Wing Force (Japan, prototype).mra` | `/media/fat/_Arcade/` |
| `Magical Crystals (World, 92-01-10).mra` | `/media/fat/_Arcade/` |

ROMs are supplied by you and must be in `/media/fat/games/mame/` as the MRA
names them. Nothing here contains ROM data.

**Do not rename the core.** MiSTer resolves `<rbf>Kaneko16</rbf>` by scanning
for names starting `Kaneko16` followed by `.` or `_`, and keeps the
lexicographically greatest — so a spare copy called `Kaneko16_GOOD.rbf` beats
`Kaneko16.rbf` and is loaded instead, silently. Keep fallbacks out of
`cores/` entirely.

## What works

**All four games.** One bitstream covers them all; the MRA hands the
core a game-id byte and `rtl/io/kaneko_gamecfg.sv` selects the memory map, ROM
bases, screen geometry, layer count, sprite list size and input wiring.

| Game | State |
|---|---|
| Explosive Breaker | playable, with sound |
| Blaze On (Japan) | playable, with music and effects |
| Wing Force (prototype) | playable, with in-game music; **no OKI sound effects, and no music in the attract demo** |
| Magical Crystals | playable, with sound |

An MRA is shipped only for a game somebody has played on hardware. One that
merely builds and passes its gates is a candidate, not a release.

## Not finished, as of `Kaneko16_20260823.rbf`

This list describes the RBF named above. Every entry is removed in the same
change as the RBF that fixes it, so if an item is still here it is still true
of the newest build in this directory. **The heading carries the RBF's name for
exactly that reason — if they disagree, trust neither and check.**

- **Wing Force has no sound effects**, and no music in the attract demo. Its
  in-game music is correct. The OKI on that board hangs off the Z80's I/O ports
  rather than the 68000's bus, and that path is still being chased.
- Tier 2 and Tier 3 of the driver are not attempted. Shogun Warriors and B.Rap
  Boys need the CALC3 MCU; Great 1000 Miles Rally, Blood Warrior and Bonk's
  Adventure need TOYBOX and, for GTMR, the KC-002 sprite chip's 8bpp path.

Removed from this list since 20260822, all confirmed on hardware:

- ~~Magical Crystals is not shipped~~ — it plays. Two independent faults: its
  MRA carried no 68000 program ROM, because its two program ROMs are different
  sizes and the emitter assumed symmetric interleave lanes; and six DSW bits at
  `c00000` were driven low where the board pulls them high, which failed a boot
  check and left the 68000 masked at level 7, refusing interrupts it could see
  being raised.

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

`Debug overlay` in the OSD, **off by default**. It draws development counters
over the top-left of the picture — 68000 bus cycles, interrupts acknowledged,
video fetch overruns, sprite overruns, the live pad word and the last unmapped
address.

It is a diagnostic instrument, not something you need to play the games. If you
are reporting a fault it is worth photographing, because it says a great deal
in one frame. The rows are documented one by one — width, colour and meaning —
in `docs/debug-overlay.md` in the source repository.

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

A diagnostic toggle, **on by default**. It stops the sprite renderer walking
records whose 16x16 box lies entirely outside the visible area.

It exists because the sprite pass is the one part of the video path with no
fixed upper bound: it clears the coverage mask, parses up to 1024 records and
draws at a pixel per clock, and every pixel can miss a 2.25 MB ROM. The frame
budget it has to fit inside is **811,008 core clocks** — 48 MHz divided by
59.1856 Hz — and that number does not change with SDRAM speed, because it is
the core clock over the frame rate.

`tb_kaneko_spr_sys` times a pass both ways. With its on-screen sprite set a
pass costs about **91,700 clocks**, roughly 11% of a frame, and enabling the
skip changes nothing — which is the correct result, because there is nothing
offscreen to skip. The saving only appears when a game parks sprites off the
edge of the screen, and how large it is depends entirely on how many.

Turn it **Off** if sprites are missing; leave it **On** otherwise. With the
debug overlay on, the **white row** counts sprite passes that did not finish in
time and should read zero.

It is switchable because it reached hardware alongside another sprite change
and one of the two stopped Explosive Breaker's laser from drawing.

## Save Backup RAM

The MRA declares `<nvram index="2" size="128"/>` for the 93C46 EEPROM. Open the
OSD to flush it to disk; with `Autosave` on, MiSTer writes it whenever the OSD
opens.

## Credits

The 68000 is [fx68k](https://github.com/ijor/fx68k) by **Jorge Cwik**. The sound
chips are [jt49](https://github.com/jotego/jt49),
[jt6295](https://github.com/jotego/jt6295) and
[jt51](https://github.com/jotego/jt51) by **Jose Tejada**. The Z80 is
[T80](https://github.com/MiSTer-devel/T80), originally by **Daniel Wallner**.
The framework is **MiSTer-devel**'s. The hardware behaviour was verified throughout against
**MAME**, whose Kaneko driver is by **Luca Elia** and **David Haywood**.

GPL-3.0-only — forced by fx68k, which grants no "or later". Full detail in
`THIRD-PARTY.md` in the source repository.
