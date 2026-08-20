# Third-party code and licences

This project is **GPL-3.0-only**. That is forced by fx68k, not preferred — see
below. Everything vendored here is compatible with it, and this file records
what each dependency is and what its licence obliges.

`third_party/` is not in the repository. It is populated by `tools/bootstrap.sh`
and pinned by `deps.lock`.

**Every licence below was read from the vendored files on 2026-08-20**, not
taken from the design study or from what the projects are commonly said to be.
Two were wrong when checked. Both corrections are recorded in place.

## The licence position

`docs/kaneko16-design-study.md` section 8 stated GPL-3.0-**or-later**, forced by
fx68k. Reading the actual repository does not support the or-later half:

- `third_party/fx68k/LICENSE` is a bare, unmodified GPLv3 text.
- `third_party/fx68k/fx68k.sv` carries `Copyright (c) 2018,2021 by Jorge Cwik`
  and no version clause at all.
- The `any later version` strings inside `LICENSE` are in the licence's own
  "How to Apply These Terms" appendix. They are boilerplate the author is
  invited to use; they are not a grant the author has made.

Absent an explicit or-later grant, GPLv3 binds at version 3 only. So this core
ships **GPL-3.0-only** unless Jorge Cwik states otherwise. The practical cost is
narrow but real: GPL-3.0-only cannot be combined forward with a future GPLv4,
and it cannot be relicensed to or-later by us.

The GPL-2/GPL-3 tension is unchanged and still resolvable: MiSTer's `sys/` is
GPL-2-**or-later**, which upgrades to GPL-3. Most MiSTer cores are
GPL-2-or-later, so this one is not interchangeable with them.

## In use

### MAME — BSD-3-Clause (the specific files here)
The behavioural oracle throughout. `src/mame/kaneko/` is the whole driver family
in one directory, all headed `license:BSD-3-Clause` with copyright to Luca Elia
and David Haywood:

| File | What it is the reference for |
|---|---|
| `kaneko16.cpp` | board wiring, PCB-verified clocks, memory map |
| `kaneko_tmap.cpp/.h` | VIEW2-CHIP tilemaps — novel RTL, M0 |
| `kaneko_spr.cpp/.h` | VU-002 and KC-002 sprites — novel RTL, M0 |
| `kaneko_calc3.cpp/.h` | CALC3 MCU, tier 2 |
| `kaneko_toybox.cpp` | TBSOP01/02 MCU, tier 3 |

BSD-3-Clause is readable **and** adaptable, which is why these two custom chips
are tractable at all: there is no other public documentation of VIEW2 or VU-002.
Retain the copyright notice and the disclaimer on anything transcribed, and put
the attribution in the RTL file header, not just here.

**MAME as a whole is GPL-2.0.** The vendored subset is not. Check the header of
every file you read, not the repository licence — `src/devices/` and `src/emu/`
files pulled in alongside kaneko/ are a mix.

### ijor/fx68k — GPL-3.0-only
68000 main CPU. Cycle-accurate, fully synchronous, ~5,100 LE on Cyclone. Drop-in.

The design study called this `jtfpga/fx68k`. **That org does not exist** —
`jtfpga` is the JTFPGA brand name, the GitHub org is `jotego`, and `jotego/fx68k`
is a fork. Upstream is `ijor/fx68k` and that is what `deps.lock` pins.

### jotego/jt49 — GPL-3.0-or-later
YM2149 PSG. Two instances on the base board, at 12 MHz / 6 = 2 MHz.

### jotego/jt6295 — GPL-3.0-or-later
OKI M6295 ADPCM. One instance on the base board, two on GTMR and later.

### jotego/jt51 — GPL-3.0-or-later
YM2151 FM. Blaze On / Wing Force sound path only.

The three jotego cores carry the full or-later clause in each `hdl/` source
("either version 3 of the License, or (at your option) any later version"), so
unlike fx68k these genuinely are or-later. Re-read them on every
`bootstrap.sh --update`: jotego has relicensed cores before, and the file header
governs, not `LICENSE`.

### MiSTer-devel/T80 — BSD-3-Clause
Z80. Blaze On / Wing Force sound path only.

**Not LGPL-2.1**, which is what it is widely described as and what this file
said before the files were read. The repository ships **no licence file at all**.
The terms are in the `T80.vhd` header: Daniel Wallner's opencores grant
(2001-2002) with retain-notice, synthesized-form and no-endorsement clauses —
3-clause BSD. Sorgelig's 2018 "Version 350" additions add a copyright line and
no separate terms.

This makes T80 the least constrained dependency here, but two clauses still
bind: keep the header intact on any file lifted, and do not use the authors'
names to endorse anything.

### MiSTer-devel/Template_MiSTer — GPL-2.0-or-later
Core skeleton and the `sys/` framework. The repo `LICENSE` is a GPLv2 copy, but
the per-file headers in `sys/` read "either version 2 of the License, or (at
your option) any later version". That or-later clause is the only reason a GPL-3
core can use it — do not drop it, and do not assume it from the `LICENSE` file.

## Vendored local references

### `third_party/model1-ref` — copy of `sega-model1-mister`
A pinned shallow copy of the sibling Model 1 core, taken 2026-08-20 at
`a5dc6b3`, so that repository is never read or written in place (hard rule 5).
It is in active development elsewhere on this machine.

Reference only, for repository structure, bootstrap and verification patterns.
It is the same author's work, so reuse is unencumbered — but take it as a
**copy into this tree with its own header**, never as a cross-repo include.

## Ported from the Model 1 core

### `rtl/mem/kaneko_sdram.sv`, `rtl/mem/bw_monitor.sv`
Ported 2026-08-20 from **`sega-model2-mister`** (`rtl/mem/m2_sdram.sv`,
`bw_monitor.sv`), renamed and otherwise unchanged. Same author,
GPL-3.0-or-later, so no licence friction — an or-later grant may be used as
GPL-3.0-only.

Ported from Model 2 and **not** Model 1. The Model 1 file is an earlier version
of the same controller; it passes its own suite and would fail on hardware.
See `docs/findings.md` for the four differences.

Ported rather than rewritten because the controller is generic (a parameterised
array of ports, no Model-1-specific dependency) and because its header records
two hazards found the hard way and invisible from a datasheet: requests must be
latched on the request *rising edge* rather than sampled as a level, and
completion must clear `pend` on the ack rising edge before the new-request latch
in the same process. Rewriting would have meant rediscovering both.

**That file in turn follows meathax's System 32 controller** (`s32`,
GPL-3.0). Its provenance note is retained in place and must not be dropped.

Its verification came with it: `sim/mem/sdram_model.sv` (a device model),
`kaneko_sdram_harness.sv`, and the two testbenches.

## Originally written here

Everything under `rtl/`, `sim/`, `tools/`, `quartus/`, `mra/` and `docs/` except
where a file header says otherwise. GPL-3.0-only.

Files that transcribe from MAME must carry the BSD-3-Clause attribution to Luca
Elia and David Haywood in their own headers. For this core that will be most of
the video path: the VIEW2 tile and scroll register decode, the VU-002 sprite
record decode and its multisprite latching, and the sprite/tile priority mixer.

## ROM images

Never committed, nor anything derived from them — extracted tables, decrypted
dumps, `.hex` arrays baked into source (hard rule 2). ROM data is loaded at
runtime through the MRA path. Any tool that reads a ROM takes its path on the
command line and writes only under `build/`, which is gitignored.

## Release checklist

Before publishing a build:

- [ ] `LICENSE` present and unmodified, and it is the **GPLv3** text
- [ ] SPDX header on every source file (`GPL-3.0-only`, not `-or-later`)
- [ ] This file lists every vendored component actually used
- [ ] `deps.lock` pins the exact upstream revisions built against
- [ ] Elia/Haywood BSD-3-Clause notice retained wherever MAME-derived
- [ ] Wallner/Sorgelig BSD notice retained if any T80 file was lifted
- [ ] Licences re-read since the last `bootstrap.sh --update`
- [ ] ROM images are not distributed. Ever.
