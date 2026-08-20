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
| VIEW2 tilemap address engine | written, fuzzed clean (3.0M checks), partially oracle-verified |
| VU-002 sprite list parser | written, fuzzed clean (41k checks), partially oracle-verified |
| Tilemap/sprite pixel path, mixer, timing | **not written** — mixer exists only as C++ in the frame harness |
| 68000, SDRAM, ROM loader, sound, I/O, `sys/` | **not started** |

M0 frame gate, RTL rendered against a frame MAME actually produced:

```
mgcrystl  99.48%   (298 / 57344 pixels differ)
explbrkr 100.00%   (exact)
blazeonj 100.00%   (exact)
wingforc 100.00%   (exact, 71680 pixels)
```

The gate is scanline-exact. Neither passes yet.

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

Synthesis is pinned to **Quartus 17.0** and `make quartus` refuses any other
version. 24.x accepts Cyclone V and will build a subtly different core; that is
why the check exists. See `CLAUDE.md`.

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

## Licence

**GPL-3.0-only.** Forced by fx68k, which grants no "or later" — see
`THIRD-PARTY.md`. This is narrower than most MiSTer cores, which are
GPL-2.0-or-later, and it is a deliberate consequence rather than a preference.

ROM images are not distributed, and nothing derived from them is committed.
