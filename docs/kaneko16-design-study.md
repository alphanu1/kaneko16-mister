# Kaneko 16-bit Arcade Hardware — MiSTer Design Study

**Status: feasible, one graphics subsystem to write.**
No MiSTer core exists. No public WIP found as of August 2026.
Two custom graphics devices (VIEW2 tilemap + VU-002 sprite), both extracted as clean
standalone MAME devices with full register documentation.

Target: Terasic DE10-Nano, Cyclone V 5CSEBA6U23I7 — 41,509 ALM, 553 M10K (696 KB),
112 DSP blocks, single SDRAM module.

---

## 1. Primary sources

All hardware facts derive from the following, in order of authority:

1. **`src/mame/kaneko/kaneko16.cpp`** — main driver.
   Authors: Luca Elia, David Haywood. BSD-3-Clause.
   PCB-verified clock annotations throughout.

2. **`src/mame/kaneko/kaneko_tmap.cpp`** / **`kaneko_tmap.h`** — `KANEKO_TMAP`
   device implementing the VIEW2-CHIP tilemap hardware.
   Authors: Luca Elia, David Haywood. BSD-3-Clause.
   Full register map with bit-field documentation.

3. **`src/mame/kaneko/kaneko_spr.cpp`** / **`kaneko_spr.h`** — `KANEKO_VU002_SPRITE`
   and `KANEKO_KC002_SPRITE` devices implementing VU-002 and KC-002 sprite hardware.
   Authors: Luca Elia, David Haywood. BSD-3-Clause.
   Full sprite record format documented.

4. **`src/mame/kaneko/kaneko_calc3.cpp`** / **`kaneko_calc3.h`** — `KANEKO_CALC3`
   device simulating the CALC3 MCU (NEC uPD78322, 16 KB internal ROM).
   Authors: Luca Elia, David Haywood. BSD-3-Clause.

5. **`src/mame/kaneko/kaneko_toybox.cpp`** — `KANEKO_TOYBOX` device simulating the
   TBSOP01/02 MCU (NEC uPD78324, 32 KB internal ROM — **not yet dumped**).
   Authors: David Haywood, Luca Elia, Sebastien Volpe. BSD-3-Clause.

---

## 2. Hardware overview

From `kaneko16.cpp` driver header, PCB table and clock annotations:

```
CPU    : 68000 + MCU [Optional, game-dependent]
SOUND  : OKI M6295 × (1|2) + YM2149 × (0|2)   [base variant]
    OR : Z80 + YM2151 + OKI M6295              [Blaze On / Wing Force]
    OR : 2× OKI M6295                           [GTMR / Blood Warrior]
CUSTOM : VIEW2-CHIP 23160-509 9047EAI (144pin PQFP) ← Tilemaps
         VU-002 052 151021            (160pin PQFP)  ← Sprites (older games)
         KC-002 L0002 023 9321EK702               ← Sprites (newer games)
         VU-001 046A (48pin PQFP)
         VU-003 048 XJ009 (×3, 40pin) ← Berlin Wall only, high-colour BG
MCU    : CALC3 (NEC uPD78322, 16K ROM) — Shogun Warriors, B.Rap Boys
         TBSOP01 (NEC uPD78324, 32K ROM) — Bonk's, Blood Warrior, GTMR
         TBSOP02 — Great 1000 Miles Rally 2
```

---

## 3. Game library and board variants

The library splits cleanly into tiers by MCU complexity. Implement in order.

### Tier 1 — No MCU (immediate targets)

| Title | Year | Board | Sound | Screen | Notes |
|---|---|---|---|---|---|
| Magical Crystals | 1991 | Z00FC-02 | 2× YM2149 + OKI M6295 | 256×224 | Puzzle shooter. Set id **`mgcrystl`**. |
| Explosive Breaker / Bakuretsu Breaker | 1992 | ZOOFC-02 | 2× YM2149 + OKI M6295 | 224×256 | **Vertical shmup, ROT90** — not Breakout. Set id `explbrkr`. |
| Blaze On | 1992 | Z02AT-002 | Z80 + YM2151, **no OKI** | 320×232 | Horizontal shmup, ROT0. 2× VU-002. |
| Wing Force | 1993 | Blaze On board | Z80 + YM2151 + OKI M6295 | 320×224 | **Vertical, ROT270. Prototype.** 16 MHz. Set id `wingforc`. |

All carry `MACHINE_SUPPORTS_SAVE`, no `MACHINE_IMPERFECT_GRAPHICS`.

Corrected 2026-08-20 against the vendored driver, see `docs/findings.md`:

- The bring-up set id is **`mgcrystl`**, not "mcrystal".
- **Blaze On has no OKI.** `blazeon()` instantiates Z80 + YM2151 only. The OKI
  in the "Z80 + YM2151 + OKI" description belongs to Wing Force.
- **Wing Force was missing from this table** and is now the only ROM on hand. It
  is a separate game from Blaze On, not another name for it — `wingforc` is its
  own parent set in MAME, where `blazeonj` names `blazeon` as parent. It shares
  the board, `blazeon_map` and the VU-002 setup, and differs in year, rotation,
  main clock, sound complement and every ROM label.

**Bring-up title: Explosive Breaker (`explbrkr`)** — changed 2026-08-20, see
`docs/00-decisions.md` D4. The study originally chose Magical Crystals for its
sound path. Explosive Breaker shares that sound path (2x YM2149 + OKI, no sound
CPU) *and* renders pixel-exact against MAME across six sampled frames, whereas
Magical Crystals has an open 298-pixel line-scroll anomaly. Bringing up on a
provably exact renderer means a bring-up failure is attributable to the CPU or
memory rather than the video.

Magical Crystals remains the only title exercising line scroll and is revisited
once the rest of the system works.

### Tier 2 — CALC3 MCU (NEC uPD78322, 16K internal ROM, **NOT DUMPED**)

| Title | Year | Sound | Notes |
|---|---|---|---|
| Shogun Warriors | 1992 | 2× YM2149 + OKI M6295 | Fighter |
| B.Rap Boys | 1992 | 2× YM2149 + OKI M6295 | Beat-em-up |

CALC3 handles DIP switches, EEPROM read/write, and supplies decrypted code/data
snippets to the 68000. `KANEKO_CALC3` is a software reimplementation of that
behaviour.

**Corrected 2026-08-20. This section previously said the CALC3 ROM was "dumped and
verified", and concluded that executing the real firmware was an option. That rests
on a confusion between two different ROMs.**

What is dumped is the CALC3's **external data ROM** — `fb040e.u33` for Shogun
Warriors, which MAME's `ROM_START` labels `/* MCU Data */` and loads into the region
tagged `"calc3_rom"`. The board note in `kaneko16.cpp` reads "KANEKO CALC3 508 (74
Pin PQFP, NEC uPD78322 MCU, **Linked to FB-040.U33**)". That is the data the MCU
reads, not the code it runs.

The uPD78322's **16 KB internal program ROM is not dumped.** Decapping identified
the part; that is not a dump. And MAME instantiates no CPU core for it — no
uPD78-series device, no TLCS-90, nothing. `m_calc3_region` is passed to
`decompress_table()` as data, and every behaviour is reimplemented in C++.

**Consequence: CALC3 is in the same position as TBSOP01, not a better one.** MAME's
simulation is the only available path — there is no firmware to execute and no LLE
fallback if the HLE misses something. The plan does not change (HLE either way) but
the safety net the previous wording implied does not exist.

### Tier 3 — TBSOP01 MCU (NEC uPD78324, 32K ROM, NOT DUMPED)

| Title | Year | Sound | Notes |
|---|---|---|---|
| **Bonk's Adventure / BC Kid** | 1994 | 2× OKI M6295 | **Anchor title** |
| Blood Warrior / Gouketsuji Gaiden | 1994 | 2× OKI M6295 | Fighter |
| Great 1000 Miles Rally | 1994 | 2× OKI M6295 | Top-down racing |
| Great 1000 Miles Rally 2 | 1995 | 2× OKI M6295 | TBSOP02 variant |

TBSOP01 is simulated in MAME via `KANEKO_TOYBOX`. Because the ROM is not dumped, MAME
uses software simulation based on reverse-engineered behaviour. The simulation handles
the command protocol correctly for all supported games. **For a MiSTer core, MAME's
simulation is the implementation path** — there is no firmware to execute.

Bonk's Adventure is the prestige title. Note from `kaneko_toybox.cpp`:
```
bonk:
    Where does the hardcoded EEPROM default data come from?
    Where does the data for the additional tables come from?
```
These are open MAME questions. If they affect normal gameplay rather than just edge
cases, Bonk's may require additional reverse engineering beyond what MAME has.

---

## 4. Device analysis — from machine config

### 4.1 M68000 — Main CPU

68000 at 12 MHz (Magical Crystals, verified on PCB) or 16 MHz (GTMR, verified on PCB).

**RTL:** `ijor/fx68k` — **GPL-3.0-only**. Drop in.

Corrected twice, 2026-08-20. The licence correction stands: fx68k grants no
or-later, so this core ships GPL-3.0-only. See `THIRD-PARTY.md`.

**The claim that `jtfpga/fx68k` does not exist was WRONG and is withdrawn.** It
does exist, and its `hdl/fx68k.sv` is byte-identical to ijor's apart from line
endings — a repackaging into jtframe's layout, not a functional fork. Three
repositories carry this core:

| | |
|---|---|
| `ijor/fx68k` | upstream, and what is vendored here |
| `jtfpga/fx68k` | ijor's, repackaged for jtframe. Functionally identical. |
| `jotego/fx68k` | ijor's plus an optional `FX68K_ALTERA_REGS` define that moves the register file into 2 BRAM blocks, freeing ~2000 logic cells on Cyclone. Off by default. |

**MAME modelling:** `M68000` device, accurate.

### 4.2 YM2149 × 2 — PSG Sound (base variant)

Two YM2149 at 12 MHz / 6 = 2 MHz (verified on PCB). YM2149 is a GI AY-3-8910
clone — three square-wave channels plus noise per chip, six channels total.

Port B of the second YM2149 is used for EEPROM chip-select and OKI bank switching.
This is register I/O, not a separate chip.

**RTL:** `jotego/jt49` — GPL-3.0-or-later. Drop in × 2.

**MAME modelling:** `YM2149` device, accurate.

### 4.3 OKI M6295 × 1 or × 2 — PCM

One OKI at 12 MHz / 6 = 2 MHz in the base variant (Magical Crystals, verified on PCB).
Two OKIs at 16 MHz / 8 = 2 MHz in GTMR and later titles (verified on PCB).

**RTL:** `jotego/jt6295` — GPL-3.0-or-later. Drop in.

**MAME modelling:** `OKIM6295` device, accurate.

### 4.4 Z80 + YM2151 — Sound (Blaze On / Wing Force variant)

Z80 at 4 MHz driving a YM2151 at 4 MHz. Communicates with the 68000 via a sound
latch. Blaze On and Wing Force use this path instead of the YM2149+OKI combination.

**RTL:** T80 (Z80) + `jotego/jt51` (YM2151) — both drop in.

**MAME modelling:** `Z80` + `YM2151` devices, accurate.

### 4.5 93C46 EEPROM — Settings storage

Standard 93C46 16-bit serial EEPROM. Present on all boards. In games with an MCU,
the MCU mediates EEPROM access. In Magical Crystals, the 68000 accesses it directly
via YM2149 port B bits.

**RTL:** Standard 93C46 device, trivial.

### 4.6 VIEW2-CHIP — Tilemaps — ONE novel device

`KANEKO_TMAP` device in `kaneko_tmap.cpp`. BSD-3-Clause. Full register documentation
embedded in source.

**Architecture:**
- One VIEW2 chip generates **2 tilemap layers** (FG and BG)
- Magical Crystals uses **2 VIEW2 chips** → 4 layers total
- Layer size: 512 × 512 pixels
- Tile size: 16 × 16 pixels, 4bpp
- Line scroll: 512 horizontal scroll offsets per layer (one per tilemap line)

**Tile format** (2 words per tile, from `kaneko_tmap.cpp`):
```
Word 0:
  [15:11] unused
  [10:9]  High Priority (vs Sprites)
  [8]     High Priority (vs Tiles)
  [7:2]   Colour / palette
  [1]     Flip X
  [0]     Flip Y
Word 1: Tile code
```

Corrected 2026-08-20. This table read `[15:13] unused` and `[12:11] High
Priority` — two bits too high, and it merged the vs-sprites and vs-tiles
fields. MAME reads the priority as `(attr >> 8) & 7`. See `docs/findings.md`.

**Layer control register** (at offset `0x008` in the register bank):
```
[12]    BG Disable      <- corrected 2026-08-20, was documented as [15]
[11]    BG Line Scroll enable
[10]    ? (always 1 in gtmr/bakubrkr)
[9]     BG Flip X
[8]     BG Flip Y
[7:5]   unused
[4]     FG Disable
[3]     FG Line Scroll enable
[2]     ? (always 1 in gtmr/bakubrkr)
[1]     FG Flip X
[0]     FG Flip Y
```

**Scroll registers:**
```
0x000: FG Scroll X
0x002: FG Scroll Y
0x004: BG Scroll X
0x006: BG Scroll Y
```

Line scroll RAM: 512 words per layer, added to the global scroll X value.

**Indexed by tilemap row, not by screen scanline** — corrected 2026-08-20. MAME's
`rowscroll` index is the tilemap row that lands on a given screen line, i.e. `map_y`
after vertical scroll. The two coincide only while scroll Y is zero; Explosive
Breaker's attract frame has scroll Y = 8, so indexing by scanline is eight lines out.
The sum is also taken **before** the `>> 6`, at full 10.6 precision.

Used in Blaze On 2nd demo level, Magical Crystals, Sand Scorpion — and, measured
2026-08-20, in Explosive Breaker's attract loop on all four layers.

**MAME modelling:** `KANEKO_TMAP`, a standalone device. Accurate, no imperfect flags
on base titles.

### 4.7 VU-002 Sprites — bundled novel device

`KANEKO_VU002_SPRITE` device in `kaneko_spr.cpp`. BSD-3-Clause. Full sprite format
documented.

**Architecture:**
- 1024 sprites
- Sprite size: 16 × 16 × 4bpp
- Double-buffered bitmap output (256×256 or 512×512)
- Priority system: sprites interleave with tile layers at 4 priority levels

**Sprite record format** (8 bytes / 4 words, from `kaneko_spr.cpp`):
```
Word 0 — Attribute:
  [15]  Multisprite: Use Latched Code + 1
  [14]  Multisprite: Use Latched Color (and Flip?)
  [13]  Multisprite: Use Latched X,Y as Offsets
  [12:11] Index of XY Offset table
  [9]   High Priority (vs FG tiles of high priority)
  [8]   High Priority (vs BG tiles of high priority)
  [7:2] Colour
  [1]   X Flip
  [0]   Y Flip
Word 1: Tile Code
Word 2: X Position << 6
Word 3: Y Position << 6
```

**Multisprite mode** is the implementation detail requiring care: when latching flags
are set, the sprite inherits position/colour/code from the previous sprite rather than
reading new values from RAM. This is how multi-tile objects are constructed without
storing all coordinates explicitly.

**Priority system** (from device constructor):
```
sprite[0]: above tile[0], below the others
sprite[1]: above tile[0-1], below the others
sprite[2]: above tile[0-2], below the others
sprite[3]: above all
```

**Keep-sprites-on-screen** flag (register bit 2): clips sprites to the visible area.
Only used in VU-002 (type 0), not KC-002 (type 1).

**Sprite registers** (at offset `0x000` in register bank):
```
[15]  Sprites Disable
[2]   Keep sprites on screen
[1]   Flip X (global)
[0]   Flip Y (global)
```

**MAME modelling:** `KANEKO_VU002_SPRITE`, standalone device. Accurate for base
titles. Blaze On TODO: 2× VU-002 should produce separate bitmaps and mix them;
current MAME handles it as one chip. Implement correctly.

### 4.8 KC-002 Sprites — tier 3 upgrade

`KANEKO_KC002_SPRITE` device in the same `kaneko_spr.cpp`. Used in GTMR and
Blood Warrior. 16 × 16 × **8bpp** (wider palette) vs VU-002's 4bpp. Attribute
format differs slightly:

```
Word 0 — Attribute (KC-002 / type 1):
  [15:13] Multisprite flags (same as VU-002)
  [12:11] XY Offset index
  [9]     X Flip
  [8]     Y Flip
  [7]     High Priority (vs FG)
  [6]     High Priority (vs BG)
  [5:0]   Colour
```

Add KC-002 support when targeting GTMR (Tier 3). The device is already extracted in
MAME — it's a parameter change and a different attribute decoder.

---

## 5. Protection MCU summary

| MCU | Device | ROM status | MAME approach | MiSTer approach |
|---|---|---|---|---|
| CALC3 (uPD78322) | `KANEKO_CALC3` | **Not dumped** (internal ROM; the dumped `calc3_rom` is external *data*) | Software sim | MAME's simulation |
| TBSOP01 (uPD78324) | `KANEKO_TOYBOX` | **Not dumped** | Software sim | MAME's simulation |
| TBSOP02 | `KANEKO_TOYBOX` | Not dumped | Software sim | MAME's simulation |

CALC3: corrected 2026-08-20. The internal program ROM is **not** dumped, so LLE is
not available — the region MAME calls `calc3_rom` is the external data ROM
(`fb040e.u33`, labelled `/* MCU Data */`), and no CPU core is instantiated anywhere
for this MCU. Port MAME's simulation, as with TOYBOX.

TBSOP01/02: no ROM exists. MAME's simulation is the only available approach. Port
`kaneko_toybox.cpp` as-is. The open questions in the MAME source (Bonk's EEPROM
defaults, additional table transfers) apply to the MiSTer core equally — they are
unsolved reverse engineering problems, not implementation gaps.

---

## 6. ALM budget

| Block | ALM | Status |
|---|---|---|
| M68000 @ 12–16 MHz | 3,000–4,000 | fx68k — drop in |
| 2× YM2149 @ 2 MHz | 800–1,200 | jt49 × 2 — drop in |
| OKI M6295 × 1 or 2 | 500–1,000 | jt6295 — drop in |
| Z80 + YM2151 (Blaze On path) | 3,000–4,000 | T80 + jt51 — drop in |
| 93C46 EEPROM, NVRAM, glue | 200–400 | trivial |
| **VIEW2 tilemap (2 chips = 4 layers)** | **3,000–5,000** | novel — see 4.6 |
| **VU-002 sprite engine** | **2,000–4,000** | novel — see 4.7 |
| CALC3 HLE | 200–500 | port of MAME's simulation; no firmware exists to run |
| TOYBOX simulation | 500–1,000 | port of MAME simulation |
| Priority mixer, palette, sync | 800–1,500 | standard pattern |
| `sys/` framework | 5,000 | fixed |
| **Total** | **19,000–28,600** | |
| **vs 41,509** | **fits, 13–22K spare** | |

Comfortable at both ends. No bandwidth concerns — VIEW2 tilemaps are tile-fetched
sequentially and the OKI sample data fits in SDRAM with substantial headroom.

---

## 7. Milestone plan

**M0 — VIEW2 tilemap and VU-002 sprite standalone spikes**
Build `kaneko_tmap.sv` and `kaneko_vuspr.sv` in isolation.
Capture frame data from MAME (Magical Crystals attract loop) and drive the DUT.
Synthesise each standalone for ALM and Fmax.
Gate: scanline-exact match against MAME on a fixed attract frame.

**M1 — Magical Crystals (Tier 1, base path)**
fx68k, jt49 × 2, jt6295, SDRAM controller, MRA ROM loader, EEPROM.
Gate: ROM self-test passes, game boots, attract renders correctly.

**M2 — Explosive Breaker, then Blaze On**
Explosive Breaker: same config as Magical Crystals, verify ZOOFC-02 board variant.
Blaze On: add T80 + jt51 sound path, handle 2× VU-002 correctly.

**M3 — CALC3 MCU: Shogun Warriors and B.Rap Boys (Tier 2)**
Implement `kaneko_calc3_hle.sv` based on `kaneko_calc3.cpp` command protocol.
Note the external data ROM (`calc3_rom`) must be loaded via MRA and fed to the
table-decompression path; it is data, not code.
CALC3 handles: DIP reading, EEPROM access, decryption of 68000 code/data snippets.
Gate: Shogun Warriors boots, character select and one round playable.

**M4 — TOYBOX MCU: Bonk's Adventure and Blood Warrior (Tier 3)**
Port `kaneko_toybox.cpp` simulation to SystemVerilog.
Add KC-002 sprite variant for Blood Warrior.
Gate: Bonk's Adventure boots and first level playable.

**M5 — Great 1000 Miles Rally (Tier 3 continued)**
16 MHz main CPU variant, 2× OKI, KC-002 sprites, TOYBOX simulation.
Two sequels (GTMR2) follow from the same base.

---

## 8. Licence position

**GPL-3.0-only** — forced by fx68k. `THIRD-PARTY.md` in this repository carries the
full position and the evidence; the short version follows.

Corrected 2026-08-20 by reading the vendored clones. This section previously said
or-later, and named two licences that turned out to be wrong:

- **fx68k is GPL-3.0-ONLY, not or-later.** `LICENSE` is a bare GPLv3 text and
  `fx68k.sv` carries only a copyright line — no version clause. The "any later
  version" text inside `LICENSE` is the licence's own how-to-apply appendix, not a
  grant the author made. So the core ships GPL-3.0-only.
- **T80 is BSD-3-Clause, not LGPL-2.1.** `MiSTer-devel/T80` ships no licence file;
  the terms are in the `T80.vhd` header — Daniel Wallner's opencores BSD grant with
  retain-notice, synthesized-form and no-endorsement clauses. Permissive, and
  compatible, but the notice must be retained on anything lifted.

Unchanged and verified: all MAME device sources used as reference are BSD-3-Clause
(Luca Elia, David Haywood, others) — readable **and** adaptable, which is what makes
VIEW2 and VU-002 tractable. jt49, jt51 and jt6295 are genuinely GPL-3.0-or-later,
with the full clause in each `hdl/` source. MiSTer's `sys/` is GPL-2.0-or-later,
and that or-later clause is the only reason a GPL-3 core may use it.

---

## 8b. Screen orientation

Two titles are vertical and they rotate in **opposite** directions: Explosive Breaker
is ROT90, Wing Force is ROT270. Everything else in the library is ROT0.

The core provides an OSD rotation toggle for these, **defaulted to vertical**. See
`docs/00-decisions.md` D3 for the reasoning and its consequences for the video path —
in particular that rotation is an output-stage concern and the tilemap/sprite hardware
works in native orientation.

---

## 9. Open questions

**Blaze On 2× VU-002.** From `kaneko_spr.cpp` TODO: the hardware produces two
separate sprite bitmaps and mixes them; MAME currently ignores the second register
set. Implement correctly; likely affects priority handling at the mix boundary.

**Bonk's Adventure TOYBOX unknowns.** Two open items in `kaneko_toybox.cpp`:
hardcoded EEPROM defaults and additional data table transfer mode. If these affect
normal gameplay they require additional reverse engineering beyond what MAME has.
Test Bonk's in MAME first and note any MAME limitations before targeting it.

**Line scroll accuracy.** The VIEW2 line scroll path is used in Blaze On, Magical
Crystals and Sand Scorpion. MAME implements it correctly for these titles. Replicate
from `kaneko_tmap.cpp` and verify against MAME's per-scanline output.

**Screen timing.** Most games run at 59–60 Hz. Exact pixel clock and blanking
parameters are not PCB-verified in the source (`set_refresh_hz(60)` without
`set_raw()`). This is a known gap in the driver. Use the closest available reference
(Double Dragon, same era Technos/Kaneko hardware, has verified timing) and adjust if
a hardware recording contradicts it.
