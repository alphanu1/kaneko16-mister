# Kaneko16 — releases

Copy to the SD card:

| from | to |
|---|---|
| `Kaneko16_20260824.rbf` | `/media/fat/_Arcade/cores/` — **rename to `Kaneko16.rbf` on the card** |
| `Explosive Breaker (World).mra` | `/media/fat/_Arcade/` |
| `Blaze On (Japan).mra` | `/media/fat/_Arcade/` |
| `Wing Force (Japan, prototype).mra` | `/media/fat/_Arcade/` |
| `Magical Crystals (World, 92-01-10).mra` | `/media/fat/_Arcade/` |

ROMs are supplied by you and must be in `/media/fat/games/mame/` as the MRA
names them. Nothing here contains ROM data.

**Check what you are running.** `Kaneko16_20260824.rbf` is
`e662d4543ee88aaf10d0e004316e6347`, 3,936,852 bytes. If the core on your card
does not have that md5, you are not running this build -- and the usual reason
is a second file: MiSTer keeps the lexicographically greatest name beginning
`Kaneko16` followed by `.` or `_`, and `_` sorts after `.`, so a spare
`Kaneko16_old.rbf` in `cores/` silently wins over `Kaneko16.rbf`. Keep exactly
one.

**SDRAM:** all four games fit a 32 MB module by size, though everything here
was developed and tested on a **128 MB** one — that is the only module any of
it has actually run on. Blaze On needs 4.12 MB, Magical
Crystals 5.25 MB, Wing Force 5.56 MB and Explosive Breaker 5.75 MB — the ROM
stream is the whole requirement, because the MRA describes one contiguous
image and the loader maps it as the identity. Later titles are much larger and
some will need a 128 MB module; `README.md` in the source repository carries
the per-game table.

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
| Explosive Breaker | playable, with sound — **but missing some enemy sprites**, see below |
| Blaze On (Japan) | playable, with music and effects |
| Wing Force (prototype) | playable, with in-game music; **no OKI sound effects, and no music in the attract demo** |
| Magical Crystals | playable, with sound |

An MRA is shipped only for a game somebody has played on hardware. One that
merely builds and passes its gates is a candidate, not a release.

## Not finished, as of `Kaneko16_20260824.rbf`

This list describes the RBF named above. Every entry is removed in the same
change as the RBF that fixes it, so if an item is still here it is still true
of the newest build in this directory. **The heading carries the RBF's name for
exactly that reason — if they disagree, trust neither and check.**

- **Explosive Breaker: graphics reported missing on ONE machine, not
  reproducible on another.** Reported from hardware on 2026-08-24 against the
  previous release, `Kaneko16_20260823.rbf`: several enemies invisible while
  still firing, and the large boss at the start absent. The boss is drawn on
  the tilemap rather than as sprites -- it disappears when `Tilemaps` is turned
  off -- so at least part of what was reported is VIEW2 and not the sprite
  engine.

  **The build in this directory does not show it.** This RBF is the one running
  on the machine where the fault cannot be reproduced, which is why it is here
  and the previous one is not. What differs between the two builds has not been
  established; the tilemap and sprite logic are equivalent under the frame gate,
  so the difference is somewhere the gate does not reach.

  If it appears on your machine, two settings are worth trying before anything
  else, because both are genuinely board-dependent:

  - `SDRAM capture` — CL+4 is the default and boards disagree about it. This
    core reads SDRAM at 96 MHz and the right capture depth is not the same on
    every module.
  - Check `_Arcade/cores/` holds **no other file** named `Kaneko16_*.rbf`.
    MiSTer keeps the lexicographically greatest name beginning `Kaneko16`
    followed by `.` or `_`, and `_` sorts after `.`, so `Kaneko16_old.rbf`
    silently wins over `Kaneko16.rbf` and you run the wrong core.

  Tracked in `docs/findings.md`, with the measurements taken so far.

- **Explosive Breaker's tilemap is one pixel right of MAME**, on chip 1's
  layer 0. Measured rather than estimated: the frame gate matches MAME on
  57,344 of 57,344 pixels once a one-pixel correction is applied, and does not
  match without it. Not corrected, because Magical Crystals wants no such
  correction and the two games are configured identically -- so the rule is not
  yet known, and guessing one would trade a visible fault in one game for a
  hidden one in another.

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

**The tall yellow block is a scratch area** and changes between builds. In this
one it is **SDRAM occupancy per scanline** — total, tile feeders, sprite ROM,
and the frame's peak, one sub-row each, each a count of clocks out of the 768 a
scanline lasts. It is measuring whether the sprite bitmap can move out of block
memory, which decides whether the later Kaneko titles are reachable at all.

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

`Service switch` in the OSD is the board's service DIP, and **it is the way
into the test menu** on the games that have one — Explosive Breaker and Magical
Crystals. Neither Blaze On nor Wing Force has any test-menu code at all, so
there is nothing for it to reach on those two. Everything else these games
configure through their own test mode, which is why there is no DIP menu.

The L button is a different input: the service coin, which adds a credit
without dropping one in.

There is no `Flip screen` option. It was there and did nothing visible — the
game reads that DIP and flips its own rendering, which this core does not
implement — so it only offered a state the picture could not show. Screen
orientation is `Rotation`, which turns the finished image and is a separate
mechanism.

`Rotation` offers Off, Auto (per game), CW 90, CCW 90 and **180**. The half
turn is the one a physically portrait monitor usually wants, and it was
unreachable until now: MiSTer's `screen_rotate` asks for a half turn by NOT
rotating and raising its `flip` input, which this core had tied to zero. On a
turned monitor that left three settings each a quarter turn out and none
correct.

## Sprite offscreen skip (OSD)

A diagnostic toggle, **off by default**. It stops the sprite renderer walking
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

It now defaults to **Off** so the renderer walks every record the way the
board does, and it is turned **On** only to test whether the clip is
responsible for something missing. With the debug overlay on, the **white row**
counts sprite passes that did not finish in time and should read zero.

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
