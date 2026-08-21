# Kaneko16 — releases

Copy to the SD card:

| from | to |
|---|---|
| `Kaneko16_20260821.rbf` | `/media/fat/_Arcade/cores/` |
| `Explosive Breaker (World).mra` | `/media/fat/_Arcade/` |

ROMs are supplied by you and must be in `/media/fat/games/mame/` as the MRA
names them. Nothing here contains ROM data.

## What works

**Explosive Breaker only.** The 68000, memory system, interrupts, EEPROM and
the VIEW2 tilemap path run; sound and sprites are in progress.

Everything game-specific is still compiled in for this one title — the memory
map is `bakubrkr_map`, and the screen offsets, colour base, sprite priorities
and layer count are constants. The other three Tier 1 games (Magical Crystals,
Blaze On, Wing Force) are **not** shipped as MRAs, because loading one would
produce a broken picture rather than a game. They arrive when the per-game
configuration table does.

## Not finished, as of `Kaneko16_20260821.rbf`

This list describes the RBF named above. Every entry is removed in the same
change as the RBF that fixes it, so if an item is still here it is still true
of the newest build in this directory.

- Sprites are not drawn.
- Sound is wired but silent — the OKI M6295 path is being debugged. The chip
  and everything around it are verified in simulation against the bytes the
  game really writes, so the fault is in the SDRAM port, the sample data's
  placement, or the audio output stage. Turn on `Debug` in the OSD: rows 4-7
  are yellow and count the four links in the chain, and the first dark row is
  where it breaks.
- No inputs; the game runs its attract loop only.
- Screen timing is not PCB-verified (384x264 at 6 MHz, 59.1856 Hz).

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
