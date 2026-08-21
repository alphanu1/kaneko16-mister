# Kaneko16 — releases

Copy to the SD card:

| from | to |
|---|---|
| `Kaneko16_YYYYMMDD.rbf` | `/media/fat/_Arcade/cores/` |
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

## Not finished

- Sprites are not drawn.
- Sound is wired but silent — the OKI M6295 path is being debugged.
- No inputs; the game runs its attract loop only.
- Screen timing is not PCB-verified (384x264 at 6 MHz, 59.1856 Hz).

## Save Backup RAM

The MRA declares `<nvram index="2" size="128"/>` for the 93C46 EEPROM. Open the
OSD to flush it to disk; with `Autosave` on, MiSTer writes it whenever the OSD
opens.
