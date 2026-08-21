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
| Tilemap pixel fetch, sprite bitmap renderer, mixer | fuzzed clean; **not yet instantiated in the core** |
| Video timing | 384x264 at 6 MHz, 59.1856 Hz; running on hardware |
| SDRAM controller, ROM loader | running on hardware |
| 68000 (fx68k) + bus decode | running on hardware; matches MAME exactly over 100k bus accesses |
| Scanline interrupts | IRQ5/4/3 with autovectoring; unit-tested, not yet exercised past boot |
| VIEW2 / sprite register files | **stubbed** — the CPU's writes go nowhere and read back as 0 |
| Sound (YM2149 x2, OKI M6295) | **not started** |
| Inputs, EEPROM, coin lockout | **not started** — inputs read as 0xffff |

The core currently boots the 68000 and shows debug views (tile contact sheet,
palette, CPU liveness). It does not yet render the game: the pixel path exists
and is verified, but nothing in the core drives it.

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

## Licence

**GPL-3.0-only.** Forced by fx68k, which grants no "or later" — see
`THIRD-PARTY.md`. This is narrower than most MiSTer cores, which are
GPL-2.0-or-later, and it is a deliberate consequence rather than a preference.

ROM images are not distributed, and nothing derived from them is committed.
