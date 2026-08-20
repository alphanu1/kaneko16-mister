# Findings

Durable record of measured facts. Each entry names its instrument and what it
corrected. Read this before investigating anything.

The design study is a desk study written before any source was vendored. Where
this file and the study disagree, **this file wins** — every entry here was read
out of MAME or measured on the bench.

---

## 2026-08-20 — dependency licences are not what the study said

**Instrument:** reading `LICENSE` and per-file headers in the vendored clones.

Three corrections, detailed in `THIRD-PARTY.md`:

- `jtfpga/fx68k` does not exist. Upstream is `ijor/fx68k`; `jotego/fx68k` is a fork.
- fx68k is **GPL-3.0-only**, not or-later. No version clause in `fx68k.sv`.
  This core therefore ships GPL-3.0-only.
- T80 is **BSD-3-Clause**, not LGPL-2.1. The repo has no licence file at all;
  the terms are in the `T80.vhd` header.

**What it cost:** nothing yet. Caught because the licences were read rather than
carried forward from the study.

---

## 2026-08-20 — the bring-up title's set id is `mgcrystl`

**Instrument:** `grep GAME kaneko16.cpp`.

The study calls it "Magical Crystals" in prose. The MAME romset id is
**`mgcrystl`** — no `a`, no `y`. Parent set, World 92/01/10. Siblings
`mgcrystlo` (World 91/12/10) and `mgcrystlj` (Japan, Atlus).

Everything the study claims about its config is confirmed, and MAME marks the
clocks `verified on pcb`:

| | |
|---|---|
| 68000 | `XTAL(12'000'000)`, TMP68HC000N-12 @U31, X2 is 12 MHz |
| VIEW2 | **two** `KANEKO_TMAP`, both `colbase 0x40*16`, `offset(0x5b, -0x8, 256, 240)` |
| sprites | one `KANEKO_VU002_SPRITE` |
| PSG | 2× `YM2149` at 12 MHz / 6 = 2 MHz |
| PCM | 1× `OKIM6295` at 12 MHz / 6 = 2 MHz, `PIN7_HIGH` |
| EEPROM | `EEPROM_93C46_16BIT`, read on YM2149[1] port A, CS on port B |
| screen | `set_size(256,256)`, `visarea(0, 255, 16, 239)` → **256 × 224 visible** |

---

## 2026-08-20 — ROM inventory (SUPERSEDED below — all four Tier 1 sets arrived)

**This entry described a folder holding only `wingforc.zip`. Three more sets
were added minutes later.** Kept because its Wing Force analysis still stands
and M0 planning referenced it; read the ROM inventory entry at the bottom of
this file for the current state.

## 2026-08-20 — Wing Force is a poor bring-up (still true)

**Instrument:** `ls /home/ben/roms/Kaneko16/`, `mame -verifyroms wingforc`
("romset wingforc is good"), and the `wingforc()` machine config at
`kaneko16.cpp:1883`.

`wingforc.zip` is the sole set present. It is Tier 1 in the study's sense — no
MCU — but it is the most expensive Tier 1 title to bring up, not the cheapest:

| | Wing Force | Magical Crystals |
|---|---|---|
| 68000 | **16 MHz** | 12 MHz |
| sound | **Z80 @ 4 MHz + YM2151 @ 4 MHz + OKI @ 1 MHz** | 2× YM2149 + OKI, no CPU |
| OKI clock | `XTAL(16M)/16` = **1 MHz**, PIN7_HIGH | `XTAL(12M)/6` = 2 MHz, PIN7_HIGH |
| VIEW2 | one chip → 2 layers | two chips → 4 layers |
| rotation | **ROT270 (vertical)** | ROT0 |
| refresh | **59.1854 Hz** | 60 Hz |
| visible | 320 × 224 | 256 × 224 |
| status | **prototype** | released, three revisions |

Bringing up Wing Force means T80, jt51 **and** jt6295 working on day one — the
entire M2 sound path pulled forward into M1 — plus a 16 MHz main clock. That is
precisely what choosing Magical Crystals was meant to avoid.

**It is still useful for M0.** The M0 gate is a scanline-exact VIEW2 and VU-002
match against MAME on a captured frame, and Wing Force exercises both, including
the line-scroll path. M0 needs a frame capture, not a booting core.

Wing Force also uses `init_bakubrkr`, the same gfx decode as Explosive Breaker.

**To follow the study's plan, `mgcrystl` is needed.**

---

## 2026-08-20 — Blaze On has no OKI, contradicting the study's tier table

**Instrument:** `blazeon()` machine config, `kaneko16.cpp:1830`, grepped for
`OKIM6295` — zero hits.

The study's Tier 1 table lists Blaze On's sound as "Z80 + YM2151 + OKI", and §2
and §4.4 repeat it. MAME's `blazeon()` instantiates **Z80 + YM2151 only**, into
a 2-channel stereo speaker. The OKI belongs to **Wing Force**, which is the
other user of `blazeon_map` and is where the "Z80 + YM2151 + OKI" description
actually fits — in mono, at 1 MHz.

Consequence for the plan: Blaze On is cheaper than budgeted (no jt6295), and
Wing Force is dearer (jt6295 *and* jt51 *and* T80).

---

## 2026-08-20 — the 2nd sprite chip comment appears in both Blaze On and Wing Force

**Instrument:** `blazeon()` and `wingforc()` machine configs.

Both carry, verbatim:

```
// there is actually a 2nd sprite chip! looks like our device emulation handles both at once
```

This is the study's §9 open question and it is confirmed in the source. Note it
applies to **Wing Force as well as Blaze On** — the study attributes it only to
Blaze On. Since Wing Force is the ROM on hand, the first VU-002 work done here
will run straight into it.

Both games set identical sprite parameters: `set_priorities(1, 2, 8, 8)` and
`set_offsets(0x10000 - 0x680, 0x000)`.

---

## 2026-08-20 — screen timing is better documented than the study implies

**Instrument:** the machine configs.

§9 says exact timing "is not PCB-verified in the source (`set_refresh_hz(60)`
without `set_raw()`)". That holds for `mgcrystl` and `blazeon`, but **not** for
Wing Force, which sets `59.1854` Hz — a figure precise enough that it was
derived from something, not guessed.

Neither uses `set_raw()`, so blanking parameters are still unknown. The
`vblank_time` on both is annotated `/* not accurate */` in MAME's own source.
Treat the 59.1854 as a lead worth chasing before adopting a foreign reference.

---

## 2026-08-20 — Wing Force is not another name for Blaze On

**Instrument:** the `GAME()` lines and `ROM_START` blocks in `kaneko16.cpp`.

Raised in conversation and worth settling, because it changes M1 scope.

MAME's second `GAME()` field is the parent set. That is how it expresses "same
game, different name or region":

```
GAME( 1992, blazeon,   0,        blazeon,  blazeon,  ... ROT0,   "Blaze On (World)" )
GAME( 1992, blazeonj,  blazeon,  blazeon,  blazeon,  ... ROT0,   "Blaze On (Japan)" )
GAME( 1993, wingforc,  0,        wingforc, wingforc, ... ROT270, "Wing Force (Japan, prototype)" )
```

`blazeonj` names `blazeon` as parent — that is an alternate name. `wingforc`
names `0`: it is its own parent, a separate game. They also differ by year,
rotation, machine config, init function and every ROM label
(`bz-prg1.u80` vs `e_2.24.u80`).

What is true is the hardware relationship, and it is close: same developer
(A.I, Atlus license), same `kaneko16_blazeon_state`, same `blazeon_map` memory
map, same VU-002 offsets and priorities. Wing Force runs on Blaze On's board.
That is why the study pairs them for the sound path, and it is why work on one
transfers to the other.

**Why the distinction matters here:** the study's Tier 1 table describes Blaze
On — ROT0, 12 MHz, 320×232. The ROM on hand is Wing Force — ROT270, 16 MHz,
320×224, with an OKI that Blaze On does not have. Treating the two as one title
would size M1 against the wrong game.

---

## 2026-08-20 — ROM inventory, all four Tier 1 sets present, two need attention

**Instrument:** `mame -rompath /home/ben/roms/Kaneko16 -verifyroms`, then a
headless 4-second boot of each (`-video none -sound none -seconds_to_run 4`).

Supersedes the "only Wing Force" entry above.

| Set | File | Verify | Boots | Note |
|---|---|---|---|---|
| `explbrkr` | `explbrkr.zip` | good | **yes**, 2519% | ready |
| `wingforc` | `wingforc.zip` | good | **yes**, 1967% | ready |
| `blazeonj` | `blazeon.zip` | good **under the right name** | **yes**, 1767% | misnamed, see below |
| `mgcrystl` | `mgcrystl.zip` | bad — 7 PLDs missing | **no** | blocked, see below |

### `blazeon.zip` is actually the Japan set, `blazeonj`

Verifying it as `blazeon` reports the two 68000 program ROMs missing. They are
not missing — they are a different revision, and MAME matches by name:

| | in the zip | `blazeon` (World) wants | `blazeonj` (Japan) wants |
|---|---|---|---|
| prg1 | `bz_prg1.u80` crc **8409e31d** | `bz-prg1.u80` crc 3d79aa70 | `bz_prg1.u80` crc **8409e31d** |
| prg2 | `bz_prg2.u81` crc **b8a0a08b** | `bz-prg2.u81` crc a16d3b1e | `bz_prg2.u81` crc **b8a0a08b** |

Hyphen vs underscore, and different data. Every other file matches both sets.
Copied to `blazeonj.zip` it verifies "good" and boots. `blazeonj` also has no
`plds` region at all, which is why it verifies clean where the World set would
not.

**Fix:** rename to `blazeonj.zip`, or fetch the World set as well. For core work
the Japan set is equivalent — same `blazeon()` machine config, same ROT0, same
12 MHz.

### `mgcrystl` is the correct set but cannot start

All eight program, sprite, tile and sample ROMs are present and correct. Missing
are the seven PLD fuse maps:

```
18cv8.u08  crc 5e35733c      18cv8.u42  crc 434c0fbb
18cv8.u20  crc 65b945b2      18cv8.u50  crc 2fd7e6dc
18cv8.u41  crc 0b05a7ea      18cv8.u51  crc 8d1fd79b
18cv8.u54  crc 5e35733c  (identical to u08 — six unique dumps, 341 bytes each)
```

They live in `ROM_REGION(0xe00, "plds", ROMREGION_ERASE00)` and **the emulation
never reads that region** — `memregion("plds")` appears nowhere in
`kaneko16.cpp`. They are preservation data. MAME nevertheless treats any missing
file in a non-`ROM_OPTIONAL` region as fatal, so it refuses to start.

**Consequence: the bring-up title cannot currently be run as an oracle.** M0's
gate is a scanline-exact match against MAME on a Magical Crystals attract frame,
and that gate is unreachable until these ~2 KB of files are obtained. Nothing
about the RTL is blocked — only the measurement.

**Workaround if they cannot be found:** M0 can be gated on Explosive Breaker
instead, which runs today and uses the same two VIEW2 chips and VU-002 as
Magical Crystals with the same YM2149 + OKI sound path. It is the closest
substitute in the library.

### The PLD dumps are worth having for their own sake

`blazeon`'s PLD region is annotated `// all brute-forced`. These 18CV8 and
22V10 fuse maps are the board's glue logic — address decode, chip selects,
bus arbitration — the layer a MiSTer core normally has to infer from MAME's
memory map. Decompiled to equations they would give the real decode rather
than an inferred one. Worth chasing beyond just unblocking MAME.

---

## 2026-08-20 — the M0 oracle path works, proved end to end on Explosive Breaker

**Instrument:** `tools/mame_view2_census.lua`, written for this. Taps the VIEW2
and VU-002 register banks through the 68000 program space at a chosen frame,
decodes them, dumps the live sprite records and writes a snapshot.

```
CENSUS_FRAME=600 mame -rompath /home/ben/roms/Kaneko16 explbrkr \
  -autoboot_script tools/mame_view2_census.lua \
  -skip_gameinfo -autoboot_delay 0 -video none -sound none \
  -nothrottle -seconds_to_run 15
```

Ran first time. Frame 600 of the attract loop, 2535% speed, title screen
snapshot correct at 224 × 256. **The M0 gate is reachable today** — it does not
need `mgcrystl`.

Address map is `bakubrkr_map`, `kaneko16.cpp:314`:

| | |
|---|---|
| VIEW2[0] | VRAM `0x500000`, regs `0x800000` |
| VIEW2[1] | VRAM `0x580000`, regs `0xb00000` |
| VU-002 | sprite RAM `0x600000`, regs `0x900000` |
| palette | `0x700000` |

### What the first capture already tells us

**Line scroll is on, all four layers, in the attract loop.** Both chips read
`layerctl = 0x0c0c` — `FGlinescr=1` and `BGlinescr=1` on each. The study lists
line scroll as used in "Blaze On 2nd demo level, Magical Crystals and Sand
Scorpion" and does not mention Explosive Breaker. It is not an edge case to
defer: **it is live in the very frames M0 gates on.** Budget it into
`kaneko_tmap.sv` from the start.

`0x0c0c` also sets bits 2 and 10, the two the study records as
`? (always 1 in gtmr/bakubrkr)`. Confirmed still set here, purpose still unknown.

**Multisprite latching is live in the same frame.** Record 0 has
`attr=0x0300`; records 1-3 all have `attr=0xe300` — bits 15, 14 and 13 set, i.e.
latched code+1, latched colour, latched X/Y as offsets, all three at once. 468 of
1024 records are non-empty. The study calls multisprite "the implementation
detail requiring care"; there is no version of M0 that avoids it.

`keeponscreen=1` in sprite reg0 (`0x4fcc`). **Corrected later the same day:
that bit is active low** — `m_keep_sprites = BIT(~new_data, 2)` — so a set bit
means the feature is OFF and the sprite bitmap is cleared every frame. See the
entry below.

### Explosive Breaker is ROT90, and it is not a Breakout clone

`GAME( 1992, explbrkr, 0, bakubrkr, bakubrkr, init_bakubrkr, ROT90, ...)`.

The study's Tier 1 table gives it as `256×224` and describes it as "Breakout".
It is **ROT90 — a vertical scrolling shooter**, displayed 224 × 256. The name
appears to have misled the desk study. `bakubrkr` (Japan) and `explbrkrk`
(Korea) are clones of it.

**This matters for M0.** The substitute oracle title is rotated relative to the
bring-up title, which is ROT0. MAME applies rotation at output; the VIEW2 and
VU-002 hardware works in native orientation. Compare native-to-native, or a
correct RTL implementation will look wrong against a rotated reference frame.

Rotation across Tier 1: `mgcrystl` ROT0, `blazeonj` ROT0, `explbrkr` **ROT90**,
`wingforc` **ROT270**.

---

## 2026-08-20 (later) — `mgcrystl` unblocked, bring-up title runs

**Instrument:** `mame -verifyroms mgcrystl`, then launched on the desktop.

A replacement `mgcrystl.zip` arrived carrying all seven PLD fuse maps at the
expected CRCs (`5e35733c 65b945b2 0b05a7ea 434c0fbb 2fd7e6dc 8d1fd79b`, plus
`u54` duplicating `u08`). **`romset mgcrystl is good`** and the game runs.

**The M0 gate is now reachable on the intended title.** Explosive Breaker
remains a valid substitute and a useful second data point — identical machine
config, different rotation — but is no longer required.

Current ROM state, all four Tier 1 titles:

| Set | File | Verify | Runs |
|---|---|---|---|
| `mgcrystl` | `mgcrystl.zip` | **good** | **yes** — bring-up title |
| `explbrkr` | `explbrkr.zip` | good | yes |
| `wingforc` | `wingforc.zip` | good | yes |
| `blazeonj` | `blazeon.zip` | good **under the name `blazeonj`** | yes, via alias |

Only the Blaze On naming issue remains, and it is cosmetic: the file is the
Japan set, so MAME needs it named `blazeonj.zip`.

## 2026-08-20 — Wing Force is Kaneko16 hardware, despite looking like an outlier

**Instrument:** `wingforc()` machine config, `kaneko16.cpp:1883`, and the
`GAME()` line's state class.

Raised in conversation. Wing Force is on this system, unambiguously:

- driver `kaneko16.cpp`, state class `kaneko16_blazeon_state`
- memory map `blazeon_map`, shared verbatim with Blaze On
- `KANEKO_TMAP` (VIEW2) and `KANEKO_VU002_SPRITE` — the two custom chips this
  core exists to implement
- M68000 main CPU

What makes it read as an outlier is board population and clocking, not silicon:
16 MHz rather than 12, ROT270 rather than ROT0, and an OKI M6295 that Blaze On
does not have. It is a prototype on a Blaze On board.

**In scope, but still a poor first target** — see the Wing Force entry above.
It needs T80, jt51 and jt6295 all working on day one.

---

## 2026-08-20 — VIEW2 register decode: two bits in the design study are wrong

**Instrument:** `kaneko_tmap.cpp` device code, read against the study's §4.6
tables. The code is authoritative over its own comment block, and both were
checked.

Found while writing `rtl/video/kaneko_tmap.sv`. Both errors are off-by-N in a
bit position, which is exactly the class of mistake that produces plausible
garbage rather than an obvious failure.

### Tile priority is bits **10:8**, not 12:11

The study's tile format gives `[15:13] unused` and `[12:11] High Priority`.
MAME reads it as:

```c
tileinfo.category = (attr >> 8) & 7;
```

which is **bits 10, 9 and 8**, and its comment block agrees:

```
0000.w   fedc b--- ---- ----   unused?
         ---- -a9- ---- ----   High Priority (vs Sprites)
         ---- ---8 ---- ----   High Priority (vs Tiles)
```

Correct decode: unused `[15:11]`, high-priority-vs-sprites `[10:9]`,
high-priority-vs-tiles `[8]`, colour `[7:2]`, flip X `[1]`, flip Y `[0]`.
The study is shifted two bits up and drops the vs-sprites / vs-tiles split.

### BG Disable is bit **12**, not 15

The study's layer control table opens with `[15] BG Disable`. MAME:

```c
m_tmap[0]->enable(BIT(~layers_flip_0, 12));
m_tmap[1]->enable(BIT(~layers_flip_0,  4));
```

Bit 12, matching its comment (`---c ---- ---- ----`, where `c` is nibble digit
12). Every other bit in the study's layer-control table is right.

### Also worth recording, not errors but traps

- **`TILE_FLIPXY` swaps its bits.** `tilemap.h` defines it as
  `((xy & 2) >> 1) | ((xy & 1) << 1)`, so `TILE_FLIPXY(attr & 3)` maps attr bit
  1 to TILE_FLIPX and attr bit 0 to TILE_FLIPY. The study's `[1] Flip X,
  [0] Flip Y` is **correct** — but only because the macro swaps. Reading the
  call without reading the macro gives the opposite answer.
- **MAME never uses layerctl bits 1:0.** It applies bits 9:8 to *both*
  tilemaps. The study lists FG Flip X/Y at `[1:0]` as if independent; in MAME
  they are documented and unimplemented. Unknown whether real hardware flips
  the layers separately.
- **tmap[0] is the register map's "BG", tmap[1] its "FG"**, and layer 1's VRAM
  is at the LOW half of the window (`vram_1` at 0x0000, `vram_0` at 0x1000).
  Layer 1's scroll registers are at 0x00/0x02, layer 0's at 0x04/0x06.

---

## 2026-08-20 — line scroll is indexed by MAP row, not screen line

**Instrument:** `tilemap_t::draw_common` and `effective_rowscroll` in
`src/emu/tilemap.cpp`, read because the RTL needed to know which line indexes
the scroll RAM.

The study says the 512 line-scroll words are "added to the global scroll value
per scanline", which reads as one word per *screen* line. MAME does not do
that. In `draw_common`:

```c
int rowheight = m_height / scrollrows;             // 512/512 = 1
blit.cliprect.sety(currow * rowheight + ypos, ...);
int scrollx = rowscroll[currow];
```

`draw_instance` places tilemap row `r` at screen line `r + ypos`, and the
scroll applied to it is `rowscroll[r]`. So the index is the **tilemap row**,
i.e. `map_y` after vertical scroll — not the raw scanline.

The two are only equivalent while `scroll_y` is zero. In the Explosive Breaker
attract frame already captured, `scroll_y = 0x0200 >> 6 = 8`, so an
implementation indexing by screen line would be **eight lines out** on every
line-scrolled layer. That is a subtle, plausible-looking wrong picture rather
than a visible break.

The resulting arithmetic, now in `rtl/video/kaneko_tmap.sv`:

```
map_y = (screen_y + dy + (scroll_y >> 6))                       mod 512
map_x = (screen_x + dx + ((scroll_x + linescroll[map_y]) >> 6)) mod 512
```

Note also the sum happens **before** the `>> 6`: both terms are 10.6 fixed
point and are summed at full precision, then truncated once. And `dx` differs
by 2 between the layers — MAME sets `scrolldx` to `-dx` for tmap[0] and
`-(dx+2)` for tmap[1].

---

## 2026-08-20 — M0 first RTL: VIEW2 address engine builds, lints and passes

**Instrument:** `make lint && make test`, and yosys `stat`.

```
lint: 1 file(s) clean
kaneko_tmap: checks=3001024 fails=0 exhaustive_pixaddr=1024 (global flip not covered)
```

`rtl/video/kaneko_tmap.sv` implements the VIEW2 coordinate pipeline: vertical
scroll, horizontal scroll with line scroll, tile lookup, attribute decode and
tile-ROM pixel addressing for `gfx_8x8x4_row_2x2_group_packed_lsb` (16x16 as
four 8x8 sub-tiles at bytes 0/32/64/96, 4-byte rows, low nibble is the left
pixel).

Area, yosys generic cells, one layer: **236 cells** (hscroll 152, vscroll 76,
pixaddr 8). Negligible — the tilemap's real ALM cost will be the pixel
pipeline, line buffers and VRAM, not this address math. No revision to the
§6 budget is warranted yet.

**What this does and does not prove.** The harness compares the RTL against a
reference model transcribed from MAME by hand. It proves the RTL matches that
transcription — it does not prove the transcription is right. The M0 gate, a
scanline-exact frame diff against a running MAME, is still owed and is the
thing that would catch a misread of the source.

**Not covered:** global layer flip (layerctl bits 9:8). MAME routes it through
`tilemap_t::set_flip`, whose interaction with `scrolldx`/`dx_flipped` is a
separate transform not yet implemented. The frames M0 gates on have it clear
(`layerctl = 0x0c0c`). Named here, in the RTL header and in the harness
header rather than left silent.

---

## 2026-08-20 — M0 second RTL: VU-002 sprite parser, and two bugs the fuzz caught

**Instrument:** `make lint && make test`, and yosys `stat`.

```
lint: 2 file(s) clean
kaneko_tmap:  checks=3001024 fails=0 exhaustive_pixaddr=1024 (global flip not covered)
kaneko_vuspr: checks=40960 fails=0 passes=40
              latched_code=21685 latched_color=21913 latched_xy=21850
```

`rtl/video/kaneko_vuspr.sv` walks the 1024-record sprite list in RAM order and
resolves each record through the multisprite latches. Area, yosys generic
cells: **1231** (216 flip-flops). Still small; as with the tilemap, the ALM
will go on the pixel pipeline and line buffers, not the parser.

The harness compares a **whole list** per pass, not individual records,
because the latches carry state forward — a per-record check would pass on a
model that latched at the wrong point in the sequence. Multisprite bits are
biased heavily rather than left uniform: roughly half of all records use at
least one latch, which is what the real data does (records 1-3 of the captured
Explosive Breaker frame are all `attr=0xe300`). Pass 0 uses the real `mgcrystl`
sprite register set from MAME's own comment block, `4FCC 0000 0040 00C0 ...`,
whose first word matches the `0x4fcc` the live census read.

### Two bugs, both found by the harness rather than by reading

**1. The RAM read pipeline was a word out.** The first state issued an address
instead of capturing the word its predecessor had addressed, so `attr` was
loaded with the *code* word and every field decoded from the wrong place. With
a synchronous RAM, the state following an address issue must capture.

**2. The XY offset table index dropped its base.** The table lives at register
words 8, 10, 12, 14 (byte offsets 0x10..0x1e). The index was written as
`{2'b10, off_index, 1'b0}[3:0]`, and the `[3:0]` slice discards the leading
bit, yielding `2*idx` — words 0/2/4/6, which is the *low* half of the register
file. Correct is `{1'b1, off_index, 1'b0}`.

Both are the kind that produce plausible garbage rather than a visible failure,
and neither was apparent on rereading the RTL. This is hard rule 4 earning its
place: the harness shipped in the same change as the module, and it failed
first time.

### VU-002 pixel format differs from the tilemap in exactly one respect

Sprites decode with `gfx_8x8x4_row_2x2_group_packed_**MSB**`; the tilemap uses
the **LSB** variant. The sub-tile structure is identical — 16x16 as four 8x8
blocks at bytes 0/32/64/96, rows of 4 bytes, 128 bytes per tile. The only
difference is nibble order within a byte: sprites take the **high** nibble for
an even X, tiles take the low one. Getting it backwards swaps every pixel pair
in every sprite, which reads as corruption rather than as an offset.

### Sprite ordering, for whoever builds the mixer

MAME is explicit that parsing must run first-to-last for the latches, while
drawing must run last-to-first for priority. In `draw_sprites_custom` the mask
is `if (pri[x] == 0) dest[x] = ...; pri[x] = 0xff;` — first writer wins — so
combined with the reverse draw order, **a higher RAM index is frontmost**. The
parser emits in RAM order; reversing for the draw is the consumer's job.

Final pixel value in MAME is `((pen_base + c) & 0x3fff) + ((priority & 3) << 14)`
with `pen_base = 16 * colour` for 4bpp, i.e. palette index in bits 13:0 and the
2-bit sprite priority carried in bits 15:14.

### Not covered

Global sprite flip (reg0 bits 1:0) is implemented and fuzzed, but against the
transcription only — no captured frame exercises it yet. The `fliptype == 1`
path (B.Rap Boys, which MAME flags as not properly understood) is exercised in
one pass in eight, again against the transcription.

---

## 2026-08-20 — CALC3's internal ROM is NOT dumped; the study said otherwise

**Instrument:** `grep` over `src/mame/kaneko/`, the `shogwarr` `ROM_START`, and
the `KANEKO_CALC3` device constructor. Raised in conversation, then verified.

The design study said the CALC3 ROM was "dumped and verified in MAME" and
concluded that executing the real firmware was an available fallback if HLE
missed something. That is wrong, and it rests on conflating two ROMs.

**What is dumped** is the CALC3's *external data ROM*. For Shogun Warriors it is
`fb040e.u33`, 0x20000 bytes, and MAME's own `ROM_START` labels the region:

```
ROM_REGION( 0x020000, "calc3_rom", 0 )   /* MCU Data */
ROM_LOAD( "fb040e.u33", 0x000000, 0x020000, CRC(299d0746) ... )
```

The board note in `kaneko16.cpp` says it plainly: "KANEKO CALC3 508 (74 Pin
PQFP, NEC uPD78322 MCU, **Linked to FB-040.U33**)". U33 is what the MCU reads.

**What is not dumped** is the uPD78322's 16 KB internal program ROM. Decapping
identified the part — `kaneko_calc3.cpp` says "CALC3 is a NEC uPD78322 series
MCU with 16K internal rom & 640 bytes of ram" — but identifying a die is not
dumping its ROM.

**Corroborating: MAME instantiates no CPU core for it.** No uPD78-series device,
no TLCS-90, nothing. The only mentions of the part number anywhere in the
directory are comments. `KANEKO_CALC3` takes the region tag `"calc3_rom"`,
passes it to `decompress_table()` as data, and reimplements every behaviour in
C++. The device appears only in `kaneko16.cpp` and `kaneko16.h`.

**Consequence.** CALC3 sits in exactly the same position as TBSOP01/TOYBOX:
MAME's software simulation is the only path, and there is no LLE fallback. The
implementation plan is unchanged — HLE was already the choice — but the safety
net the study implied does not exist. If the HLE misses a behaviour on Shogun
Warriors or B.Rap Boys, the answer is more reverse engineering, not "run the
real firmware instead".

One practical carry-forward for M3: the `calc3_rom` data ROM still has to be
loaded through the MRA path and fed to the table-decompression logic. It is
data the implementation needs, just not code.

---

## 2026-08-20 — two Quartus installs; 24.1std will not refuse Cyclone V

**Instrument:** `quartus_map --version` on both installs, and a listing of
`quartus/common/devinfo/`.

```
/home/ben/intelFPGA_lite/17.0      Quartus Prime 17.0.0    Build 595  04/25/2017 Lite
/home/ben/intelFPGA_lite/24.1std   Quartus Prime 24.1std.0 Build 1077 03/04/2025 Lite
```

Hard rule 7 is 17.0 only: MiSTer's `sys/`, its IP and its QSF conventions
target 17.0.x, and that is what the rest of the ecosystem is built and timed
against.

**The load-bearing detail is that 24.1std does not fail.** Its `devinfo`
directory carries `cyclonev` alongside `cycloneive` and `cycloneivgx`, so it
accepts the DE10-Nano part and produces a bitstream — against different IP, a
different fitter and a different STA. The failure mode is a core that behaves
subtly differently on hardware, not a build error, and nothing downstream
catches it.

So the rule is enforced rather than documented:

- `make quartus` depends on `quartus-check`, which reads
  `quartus_map --version` from `QUARTUS_ROOT` and **refuses any version but
  17.0**. Verified in both directions: it passes on 17.0 and exits non-zero on
  24.1std with an explanation.
- The path is absolute, not taken from `PATH`. Neither Quartus is on `PATH`
  here, which is the correct state — `bootstrap.sh` now warns if one appears,
  because a stray `PATH` entry is exactly how the wrong toolchain gets used
  without anyone noticing.
- `make quartus` also depends on `lint test`, so hard rule 4's simulation gate
  runs before any synthesis can start.

Do not raise `QUARTUS_WANT` to make a build pass. A construct 17.0 rejects is a
construct to rewrite.

### Addendum — QSYS_ROOTDIR disagrees with itself on this machine

**Instrument:** `command -v` in login and non-login shells, a sweep of every
`PATH` directory and the desktop `.desktop` files, then
`systemctl --user show-environment`.

Raised in conversation as "quartus is in PATH". It is not — `quartus_sh`,
`quartus_map` and `quartus` resolve nowhere, in any shell, and there is no
wrapper script or launcher. But `QSYS_ROOTDIR` is exported, from two sources,
with two different values:

```
.bashrc / .bash_profile   ->  /home/ben/intelFPGA_lite/17.0/quartus/sopc_builder/bin
systemd user session      ->  /home/ben/intelFPGA_lite/24.1std/quartus/sopc_builder/bin
```

Neither `/etc/environment`, `~/.config/environment.d/` nor the Plasma env
directory sets it, so the session value is stale state — most likely left by
the 24.1std installer or an `import-environment` at session start.

**Why it matters:** a build started from a terminal sees 17.0, and one started
from a desktop launcher — or from `systemd-run --user`, which is how MAME was
launched earlier in this session — sees 24.1std. Same machine, different
toolchain, decided by how the process happened to be started. Combined with
24.1std silently accepting Cyclone V, this is the exact failure hard rule 7
targets, and it is live.

`make quartus` is unaffected: it resolves by absolute path and ignores the
environment. The hazard is anything invoked outside it.

---

## 2026-08-20 — "keep sprites on screen" is ACTIVE LOW, and I read it backwards

**Instrument:** `kaneko16_sprite_device::regs_w`, `kaneko_spr.cpp`.

```c
if (get_sprite_type() == 0)
    m_keep_sprites = BIT(~new_data, 2);
```

Note the `~`. Sprite register 0 bit 2 **set** means keep_sprites is **false**.

`mgcrystl` and `explbrkr` both run reg0 = `0x4fcc`, whose bit 2 is 1 — so
keep_sprites is **off** and the sprite bitmap is cleared every frame:

```c
m_sprites_maskmap[m_buffer].fill(0, clip);
if (!m_keep_sprites)
    m_sprites_bitmap[m_buffer].fill(0, clip);
```

**This corrects an earlier entry in this file and a statement made in
conversation**, both of which read the census output `keeponscreen=1` as "the
clip path is active". It is the opposite. The consequence is good news for M0:
with the bitmap cleared each frame, a captured frame is self-contained and a
single-frame render is reproducible. Had it been latching, an exact diff would
have required replaying sprite history.

`tools/mame_view2_census.lua` decodes the raw bit and labels it
`keeponscreen`, which is now a misleading name for what it prints. The value is
right; the label inverts the meaning.

### Also: the sprite disable bit is documented but not implemented

Register 0 bit 15 is `Sprites Disable?? (see blazeon)` in MAME's comment, with
the question marks in the original. Grepping the device shows bit 15 is read
**only** as `USE_LATCHED_CODE` in the sprite attribute — never from register 0.
MAME does not honour it. So it cannot be used to suppress sprites for an
isolated tilemap diff, which was the plan until this was checked.

---

## 2026-08-20 — sprite RAM is buffered and read a frame late

**Instrument:** `kaneko16_state::interrupt` at `kaneko16.cpp:1662`, and the
`ym2149`-adjacent accessors at `kaneko16.cpp:255`.

`mgcrystl` instantiates `BUFFERED_SPRITERAM16`. At scanline 224:

```c
m_kaneko_spr->render_sprites(..., m_spriteram->buffer(), ...);
m_spriteram->copy();
```

Sprites are rendered from the **buffer**, and only then is live copied into it.
Reading `0x700000` through the CPU returns `m_spriteram->live()`
(`return m_spriteram->live()[offset];`), which is therefore **already the next
frame's data**. A dump of live RAM at frame N does not describe what frame N
displays.

`tools/mame_dump_frame.lua` now captures `spriteram_prev.bin` at frame N-1 as
well, and the renderer should use that one.

**Caveat, stated rather than buried:** MAME's own comment at that call reads
`// 2 frame delayed normaly; differs per PCB?`, and `kaneko_spr.cpp` carries
`TODO: verify sprite lag frames`. So the exact lag is unsettled in MAME
itself. One frame is the best available guess, not a fact. On the captured
frame the two snapshots are byte-identical — the sprites are static there — so
this frame cannot distinguish one lag from two. A frame with moving sprites
will be needed to pin it down, and that measurement is owed before any sprite
diff result is trusted.

---

## 2026-08-20 — M0 GATE FIRST RESULT: 98.88% pixel match against MAME

**Instrument:** `make frame` — `tools/mame_dump_frame.lua` captures a real
`mgcrystl` frame and MAME's rendered output; `tools/build_rom_regions.py`
assembles the tile and sprite ROMs; `sim/video/tb_kaneko_frame.cpp` renders
57,344 pixels driving every address through the RTL and diffs the result.

```
kaneko_frame: pixels=57344 diff=642 match=98.8804%
  attribution: sprite-covered=344 tile=298 background=0
```

This is the first check that is not circular. The fuzz harnesses compare the
RTL to a transcription of MAME, so a misreading passes both sides; here the
reference is a frame MAME actually rendered. The RTL supplies every address —
tile lookup, line scroll, ROM byte and nibble, sprite resolution and sprite
pixel address. The harness only fetches memory, mixes and compares.

**98.88% on the first run means the address arithmetic and the mixing model are
substantially right.** It is not a pass. The gate is scanline-exact; 642 wrong
pixels is 642 wrong pixels.

### The remaining 642 are NOT a constant offset

First hypothesis from the miss pattern was a one-pixel horizontal shift — six
consecutive misses all satisfied `want(col) == our(col-1)`. Sweeping a constant
sampling offset over ±2 in both axes refutes it outright:

```
        xadj -2      -1       0       1       2
 yadj -2   13855   13241   12439   13294   13957
      -1   10081    9187    8029    9233   10243
       0    4456    2704     642    3206    4865
       1   10143    9222    8127    9329   10349
       2   13866   13348   12604   13472   14150
```

(0,0) is the minimum in both axes. The error is localised, not a global origin
mistake. Misses cluster in rows 55-67 and split roughly evenly between
sprite-covered and tile pixels.

### This frame cannot test two of the claims made about it

Switching the line-scroll index between `map_y` and `screen_y` produces
**byte-identical results**, as does switching the sprite RAM between the
previous frame's and the live copy. Neither is evidence of correctness — the
frame is degenerate for both questions:

- `mgcrystl` holds `scroll_y = 0x0200 >> 6 = 8` and `dy = -8`, so
  `map_y == screen_y` exactly. A scan of frames 30..1200 shows scroll Y is 8
  for the **entire attract loop** (0 for the first ~60 frames). This game
  cannot discriminate the line-scroll index at all.
- The two sprite RAM snapshots are byte-identical on this frame; sprites are
  static across most of the loop.

**Method note worth keeping:** a gate frame has to be chosen to exercise the
property under test. A frame that agrees with both branches of a hypothesis
tests neither, and reporting its match rate as support for either would be
wrong.

### Next measurements, in order

1. **Re-run the gate on Explosive Breaker.** It is a vertical scroller
   (ROT90), so `scroll_y` genuinely varies and `map_y != screen_y`. That is the
   test the line-scroll finding actually needs. Its machine config matches
   `mgcrystl` closely — same `set_offset(0x5b, -0x8)`, same visible area — so
   the harness needs only the sprite priorities and colour bases checked.
2. **Find consecutive frames where sprite RAM changes** to settle the buffering
   lag, which MAME itself flags as unverified.
3. Only then chase the residual 642.

### The dump was not reproducible until fixed

Two identical `make frame` runs disagreed — 642 vs 256 pixels. MAME writes
`nvram/` and `cfg/` into its working directory, `mgcrystl` has a 93C46 EEPROM,
and the second run booted from the first run's saved state, landing at a
different point in the attract loop. `make dump` now deletes the dump directory
first. Any measurement taken before that fix is suspect.

---

## 2026-08-20 — full ROM library present; all nine sets verify and boot

**Instrument:** `mame -verifyroms` on all sets, then a headless 5-second boot
of each from a cleaned directory.

```
mgcrystl explbrkr blazeonj wingforc shogwarr brapboys bonkadv bloodwar gtmr
9 romsets found, 9 were OK — and all nine boot.
```

Every tier is now covered: Tier 1 (no MCU), Tier 2 (CALC3 — `shogwarr`,
`brapboys`), Tier 3 (TOYBOX — `bonkadv`, `bloodwar`, `gtmr`). Note `bonkadv`,
the study's anchor title, runs. `mgcrystl_no.zip` is the superseded incomplete
set; MAME ignores it since no set has that name.

---

## 2026-08-20 — M0 gate on Explosive Breaker: 87.97%, and its config is NOT mgcrystl's

**Instrument:** `make frame SET=explbrkr`.

```
set: explbrkr  view2_2_pri=1 spr_pri={8,8,8,8}
kaneko_frame: pixels=57344 diff=6896 match=87.9743%
  attribution: sprite-covered=6352 tile=544 background=0
```

Two per-game differences had to be found before this ran at all, and both would
have produced a plausible wrong picture rather than an obvious failure:

- **`explbrkr` takes `MACHINE_RESET_OVERRIDE(kaneko16_state, gtmr)`**, which
  sets `m_view2_2_pri = 1`. So its second VIEW2 writes its *category* into the
  priority bitmap, where `mgcrystl`'s writes 0.
- **Sprite priorities are `{8,8,8,8}`** — above everything — against
  `mgcrystl`'s `{2,3,5,7}`.

The memory maps also differ and are not interchangeable: `mgcrystl_map` has the
palette at `0x500000` and VIEW2 windows at `0x600000`/`0x680000`;
`bakubrkr_map` has VIEW2 at `0x500000`/`0x580000` and the palette at
`0x700000`. Both the dump script and the harness are now parameterised by set.

**The tilemap path is doing well here — 544 tile misses out of 57,344, under
1%.** The 6,352 sprite misses are where the error is concentrated.

---

## 2026-08-20 — the sprite lag assumption is WRONG, or at least not established

**Instrument:** `make frame SET=explbrkr` with the sprite RAM switched between
the previous frame's live copy and this frame's.

```
previous frame's RAM (the documented assumption)  diff=6896   87.97%
this frame's live RAM (no lag)                    diff=6600   88.49%
```

On a frame where the two snapshots genuinely differ, **live scores better**.
That contradicts the one-frame-lag model recorded earlier in this file.

It does not establish "no lag" either, and the reason is a flaw in the
instrument: `render_sprites`/`copy()` run at **scanline 224**, but the frame
notifier that captures `spriteram_prev.bin` fires at **end of frame** — after
scanline 224. So the captured "previous frame" content includes writes made
after the copy point, and is not what the buffer actually held. Neither
snapshot is the buffer.

MAME's own comment at that call is `// 2 frame delayed normaly; differs per
PCB?` and `kaneko_spr.cpp` carries `TODO: verify sprite lag frames`. Combined
with a misaligned capture, **the lag is genuinely unsettled and this
measurement cannot settle it.** The fix is to capture at scanline 224 via a
scanline tap rather than a frame notifier, and to compare against the buffer
rather than any live snapshot. Until then no sprite diff figure should be
quoted as evidence about the parser.

---

## 2026-08-20 — the line-scroll index claim is STILL untested

Recorded because a claim believed-but-untested is worse than a known gap.

The earlier finding — that MAME indexes line scroll by tilemap row (`map_y`),
not screen line — is derived from reading `tilemap.cpp` and remains
well-supported by the source. **It has not been confirmed against a rendered
frame**, and both candidate frames are degenerate for opposite reasons:

| | varying line scroll? | `map_y != screen_y`? | can test? |
|---|---|---|---|
| `mgcrystl` f600 | **yes** — chip1 L0 alternates `0x15c0`/`0x1600` per line | no — `scroll_y=8`, `dy=-8` | no |
| `mgcrystl` f60  | no — all zero | yes — `scroll_y=0` | no |
| `explbrkr` f900 | no — **all four layers all-zero** | yes — `scroll_y` varies | no |

Switching the index between `map_y` and `screen_y` produces byte-identical
output on both, exactly as those degeneracies predict. That is not evidence of
correctness.

A discriminating frame needs **both** conditions at once. `mgcrystl` only ever
runs `scroll_y ∈ {0, 8}` across its whole attract loop, so it cannot supply
them together. The natural candidate is **Blaze On's 2nd demo level**, which
MAME's own header names as a line-scroll user, and whose `dy = +8` makes
degeneracy unlikely at any scroll value.

That needs harness work first: Blaze On has **one** VIEW2 chip (two layers, not
four), a 512-entry sprite list rather than 1024, and a second sprite chip at
`0x980000` that MAME ignores entirely — the open question already recorded in
this file. Sand Scorpion is the other candidate but lives in a different
driver.

---

## 2026-08-20 — sprite capture fixed; an earlier "93.82%" is WITHDRAWN

**Instrument:** `tools/mame_dump_frame.lua`, rewritten to capture sprite RAM at
**scanline 223** — immediately before the driver's `copy()` at scanline 224 —
instead of at end of frame.

### The first attempt was a broken instrument that read like a result

The scanline capture was first added as a second coroutine resumed from the
existing frame notifier. That coroutine was then advanced twice per frame: once
by the notifier and once by `emu.wait`'s own scheduling. It captured the wrong
frames **and corrupted the main dump**.

It did not look broken. Explosive Breaker appeared to improve from 87.97% to
**93.82%**, which is exactly the direction a real fix would move it. What gave
it away was Magical Crystals in the same run: **71.54%, with 13,204 TILE
misses.** Sprite RAM cannot affect tile pixels. The dumped state and the dumped
reference frame no longer described the same moment.

**The 93.82% figure reported for Explosive Breaker is withdrawn.** It was
measured against a corrupted dump.

Rewritten as a single linear coroutine — autoboot scripts already run in one,
so `emu.wait` works directly and no second coroutine is needed.

### What the corrected instrument measures

| snapshot | mgcrystl f600 | explbrkr f900 |
|---|---|---|
| `buf1` — scanline 223 of N-1, i.e. the buffer, one-frame lag | 642 / **98.88%** | 6600 / **88.49%** |
| `buf2` — scanline 223 of N-2, two-frame lag | 642 / 98.88% | 6896 / 87.97% |
| `live` — frame N, no lag | 642 / 98.88% | 6600 / 88.49% |

**One-frame lag beats two-frame lag** on the only frame able to tell them apart
(6600 vs 6896). That is evidence against MAME's own `// 2 frame delayed
normaly` comment for this board, though that comment does say "differs per
PCB?".

**One-frame lag is still indistinguishable from no lag**, because `buf1 ==
live` byte-for-byte on both dumps — the sprite RAM does not change between
scanline 223 of frame N-1 and the end of frame N. Settling that needs a frame
where it does. `buf1` is the correct model on the source reading and is now the
default; it is not yet independently confirmed.

### Corrections to earlier entries in this file

- The claim that "live scored better, contradicting the one-frame lag" was
  based on the misaligned end-of-frame capture. With a scanline-accurate
  capture, `buf1` ties `live` and beats `buf2`. The earlier entry stands as
  written only in its conclusion that the instrument was flawed.
- The end-of-frame `spriteram_prev.bin` capture has been removed rather than
  kept as an option. It was never the buffer.

**Standing lesson, and the reason this is written up at length:** an instrument
that perturbs what it measures produces a plausible number in the expected
direction. The only thing that caught it was a second measurement in the same
run moving in a way the hypothesis could not explain. Change one thing, and
check the things that should not have moved.

---

## 2026-08-20 — explbrkr sprite ROM layout was wrong; 88.49% -> 98.28%

**Instrument:** `ROM_START( explbrkr )` in `kaneko16.cpp`, after a sprite census
in the frame harness localised the error.

The census was what pointed at it. On `explbrkr` the harness drew **5,971**
sprite pixels where MAME's frame has only **1,118**, overlapping on 424 —
i.e. 5,547 sprite pixels MAME does not draw at all. `mgcrystl` overlapped
13,503 of 13,526 in the same run, so the sprite *path* was fine and the
*data* was not.

**The `explbrkr` entry in `tools/build_rom_regions.py` had been written from
the zip's file listing rather than from `ROM_START`, and was wrong in every
particular:**

| | what I had | what the source says |
|---|---|---|
| first file | `ts000e.u38` @ 0x000000 | `ts001e.u37` @ 0x000000 |
| second file | `ts001e.u37` @ 0x080000 | `ts000e.u38` @ 0x080000 |
| third file | `ts002e.u36` @ 0x100000 | `ts002e.u36` @ **0x200000** |
| ROM_RELOAD | none | **two** — 0x100000 and 0x180000 |
| region size | 0x140000 | **0x240000** |

The two 512K files were swapped, the third was at the wrong offset, both
reloads were missing and the region was under-sized by 1 MB.

```
explbrkr  88.49%  ->  97.21%   (6600 -> 1598 pixels)
mgcrystl  98.88%  ->  98.88%   (unchanged, as expected)
```

`mgcrystl` is unaffected because its layout *was* read from `ROM_START`. The
single-file regions now hash to MAME's own `ROM_LOAD` SHA-1s, which is a free
check the multi-file sprite region does not get.

**Lesson: a zip listing gives filenames and sizes. Only the source gives the
layout.** Both look equally plausible in a table, and the wrong one produces a
picture rather than an error.

---

## 2026-08-20 — sprite lag is TWO frames; the earlier one-frame result is REVERSED

**Instrument:** the frame gate, re-run against all three snapshots once the
sprite ROM was correct.

```
explbrkr f900     diff    match     ours   mame   overlap
  buf1  (1 frame) 1598    97.21%     674   1118      146
  buf2  (2 frame)  986    98.28%    1122   1118      717
  live  (0 frame) 1598    97.21%     674   1118      146
```

**Two-frame lag wins**, and it is not close. It also produces almost exactly
the right *number* of sprite pixels — 1,122 against MAME's 1,118 — where the
one-frame model produces 674.

This **reverses** the conclusion recorded earlier today, that one-frame beat
two-frame (6600 vs 6896). That measurement was taken with the broken sprite ROM
above, so both figures described a render whose sprite tiles were garbage. The
ranking it produced carried no information.

The corrected result agrees with MAME's own comment at the call site:
`// 2 frame delayed normaly; differs per PCB?`. Two independent things now
point the same way, where before the measurement contradicted the source and I
took the measurement's side.

`buf2` is now the harness default. `mgcrystl` remains unable to distinguish any
of the three — its sprites are static across the whole window.

**Standing lesson:** a comparison between two hypotheses is only worth the
inputs it is run on. Both branches were fed corrupt data, so the ranking was
noise that looked like a result — and it was reported as one.

### Where the gate stands

```
mgcrystl f600   diff=642   98.88%   (census: ours 13526, mame 13801, overlap 13503)
explbrkr f900   diff=986   98.28%   (census: ours 1122,  mame 1118,  overlap 717)
```

`explbrkr`'s remaining error is now symmetric — 405 pixels where only we place
a sprite, 401 where only MAME does — which reads like a small positional
offset on a few sprites rather than wrong data. That is the next thread.

---

## 2026-08-20 — OPEN: odd rows take the even row's line scroll, and I cannot explain why

**Instrument:** a per-row X-offset sweep in the frame harness (`ROWSWEEP=1`),
which finds, for each row independently, the sampling offset that minimises
that row's mismatches. Measuring what MAME did beats arguing about it.

```
row  39 (map_y  55, odd ): best xadj=-1 [0 misses], at 0 [8]
row  41 (map_y  57, odd ): best xadj=-1 [1],        at 0 [16]
row  42 (map_y  58, even): best xadj=+0 [1],        at 0 [1]
row  43 (map_y  59, odd ): best xadj=-1 [1],        at 0 [19]
row  44 (map_y  60, even): best xadj=+0 [2],        at 0 [2]
row  47 (map_y  63, odd ): best xadj=-1 [3],        at 0 [30]
```

**Even rows are already right. Odd rows are consistently one pixel too far
right, and correcting them takes their error to nearly zero.**

`mgcrystl`'s chip1 layer0 line-scroll RAM holds two values alternating by
index: even indices `0x15c0`, odd `0x1600`. The difference is `0x40`, which is
exactly one pixel in 10.6 fixed point. So the observed error is precisely "we
used the odd index's value where MAME used the even one".

### What has been ruled out

| hypothesis | test | result |
|---|---|---|
| global constant offset | ±2 sweep, both axes | (0,0) is the minimum — refuted |
| line scroll not applied at all | `LSOFF=1` | 642 -> 2433, much worse — it IS applied |
| index phase off by one | `LSADJ=-1` | 656, slightly worse — fixes odd rows, breaks even |
| index off by two | `LSADJ=±2` | 642, identical — alternation has period 2 |
| priority suppressing sprites | `SPRTOP=1` | byte-identical — not priority |

The empirical rule that fits is **`index = map_y & ~1`** — odd rows reuse the
preceding even row's value — which takes the frame from 642 to **358**
(98.88% -> 99.38%).

### Why it has NOT been adopted

I cannot derive that rule from `tilemap.cpp`, and a rule that fits without a
mechanism is how a wrong model gets baked in. What the source says:

- `set_scroll_rows(0x200)` = 512, `m_height` = 512, so `rowheight = 1` — one
  scroll entry per tilemap row, no pairing.
- `draw_common` groups only *consecutive equal* rowscroll values; these
  alternate, so every group is one row.
- `effective_rowscroll` = `m_dx - m_rowscroll[i]`, clamped mod width. Hand
  computed: even rows give xpos 425, odd 424, i.e. map_x 122/123 — exactly what
  the RTL produces.
- `xextent` in that call is `visarea.right() + left() + 1` and is only used in
  the FLIPX branch, which is not taken here.

Every reading of the source says per-row. The measurement says per-row-pair.

It also does not explain everything: `index & ~1` leaves 358 pixels wrong, and
rows 49-52 have misses that no X offset fixes at all.

**The RTL is unchanged and still follows the source.** Changing it to match an
unexplained empirical fit would trade a defensible model for a better number.

### Next steps for this question

1. Check whether the rule survives on a different frame or game with a
   *different* line-scroll pattern. A rule that only fits this alternation is
   probably a coincidence of it.
2. Consider that the game may be writing the scroll RAM in a way that makes
   the alternation an artefact — e.g. longword writes covering two entries.
   MAME would still read per-row, so this would not explain MAME's output, but
   it would explain the data's shape.
3. If it survives, instrument MAME directly rather than inferring from pixels.

**This is now the largest single known error in the tilemap path** and the top
open question for closing M0 on `mgcrystl`.

---

## 2026-08-20 — multi-game gate: Wing Force and Blaze On are PIXEL-EXACT

**Instrument:** `make gate` — a new target that dumps and renders every
configured game and prints one table. Built because a fix tuned until one game
matches is how the other games silently break (hard rule 9).

```
GAME          FRAME     DIFF     MATCH
mgcrystl        600      642  98.8804%
explbrkr        900      986  98.2806%
blazeonj        600        0 100.0000%
wingforc        600        0 100.0000%
```

**Wing Force renders 71,680 of 71,680 pixels exactly**, and Blaze On 74,240 of
74,240. Both were verified not to be degenerate: an offset sweep shows any
one-pixel shift costs 7,042 pixels on Wing Force and 2,035 on Blaze On, so the
zero is a real match and not a blank frame trivially agreeing.

That is a first full M0 pass, on a configuration that exercises a good deal:
**one** VIEW2 chip rather than two, a **512**-entry sprite list rather than
1024, ROT270, a `0xf980` sprite X offset from `set_offsets(0x10000-0x680, 0)`,
and a **byte-interleaved** `ROM_LOAD16_BYTE` tile region.

### What it does NOT prove

Blaze On's frame is 91% black with 10 distinct colours, so its number is much
weaker than Wing Force's (59 colours, 38% non-black).

More importantly, **only `mgcrystl` exercises line scroll at all**:

| game | line-scroll RAM |
|---|---|
| `mgcrystl` | chip1 L0 — 3 distinct values, alternating by index |
| `explbrkr` | all four layers all-zero |
| `blazeonj` | both layers all-zero |
| `wingforc` | both layers all-zero |

So the two exact results say nothing about the line-scroll path, and the one
open anomaly — odd rows taking the even row's scroll value — is confined to the
only frame that tests it. A passing gate on three games would still leave that
question exactly where it is.

### Per-game facts now in the configuration table

Every one of these differs between games and would render a plausible wrong
picture if assumed: memory map, `m_view2_2_pri`, sprite priorities, VIEW2 chip
count, sprite list size, sprite X/Y offsets, ROM layout including interleave,
rotation, and screen geometry. They live in `GAMES[]` in the harness and
`MAPS`/`SETS` in the tools, never in the shared path.

Two mechanical notes from building this: `blazeon.zip` holds the `blazeonj`
set, so the gate aliases it through a symlink rather than renaming anything in
the ROM folder; and `tools/build_rom_regions.py` gained `ROM_LOAD16_BYTE`
support, without which Wing Force's tile region is the right size and the wrong
picture.

### The ROM layout table is the MRA's twin

Noted in conversation and worth recording: on hardware the core has no memory
map of its own for ROM data. The **MRA** tells the HPS loader how to
concatenate and interleave the parts, and the core receives one stream into
SDRAM. `tools/build_rom_regions.py` encodes exactly what an MRA must
reproduce, so the two descriptions must agree or the core will render
differently from the gate. When MRA generation is written it should be driven
from that same table rather than hand-written a second time.

---

## 2026-08-20 — OPEN: the capture-to-picture frame alignment differs per game

**Instrument:** a wide X-offset scan on `explbrkr` frame 400, then reading the
scroll register on consecutive frames.

`explbrkr` frame 400 rendered 69.97% with 17,218 mismatches. A wide scan found
that a uniform **+4 pixel** X offset takes it to **exactly zero**. Four pixels
is `0x100` in 10.6 fixed point, and the chip1 `scroll_x` register decrements by
exactly `0x100` per frame while the game scrolls:

```
frame 398: cd40    frame 399: cc40    frame 400: cb40    frame 401: ca40
```

So the picture `scr:pixels()` returned at frame 400 was rendered from **frame
399's** register state. The state capture is one frame ahead of the reference
image.

Adding `STATE_LAG=1` — capturing tile state one frame before the picture —
takes `explbrkr` frame 400 from 17,218 to **0**, and leaves frames 600 and 800
exact. That looks conclusive.

**It is not.** The same change takes `mgcrystl` frame 600 from 642 to **9,725**
(98.88% -> 83.04%). And `mgcrystl`'s tile registers are *identical* across
frames 598, 599 and 600:

```
f598: 68c0 0200 6940 0200 0c0c
f599: 68c0 0200 6940 0200 0c0c
f600: 68c0 0200 6940 0200 0c0c
```

so the regression cannot be register alignment — it comes from its VRAM or
palette, which do change per frame. Sprite captures were verified to be
picture-relative and unaffected by `STATE_LAG`, so they are not the cause
either.

**Two games therefore disagree about the correct alignment, and no single
value is right for both.** `STATE_LAG` defaults to **0**, which preserves the
better overall result across the gate; `STATE_LAG=1` reproduces the
explbrkr-exact behaviour.

### Why this matters more than the pixel counts

Every frame-gate number in this file is measured against a reference whose
alignment to the captured state is now known to be uncertain. That does not
invalidate the exact results — `wingforc` and `blazeonj` at 0 diff, and
`explbrkr` at frames 600/800 — because an exact match under an ambiguous
alignment is still an exact match. It does mean **a non-zero diff cannot
currently be attributed to the RTL rather than to the harness.**

Ruled out: a late capture (`DUMP_AT` at scanlines 200, 223, 224 and end of
frame all give identical results, so the state is stable across that window).

Next: determine when MAME actually calls `screen_update` relative to
`emu.wait_next_frame()`. If the coroutine resumes at the start of frame N+1
rather than the end of frame N, every capture is systematically one frame late,
and the per-game disagreement is then about when each game writes its state
within the frame. That is worth settling before chasing any remaining residual,
because it sets the meaning of every number here.

---

## 2026-08-20 — RESOLVED: MAME renders at vblank begin, not at end of frame

**Instrument:** MAME's own source — `src/emu/screen.cpp`, `src/emu/video.cpp`
and `src/frontend/mame/luaengine.cpp`, vendored for the purpose.

The previous entry left the capture/picture alignment open, with two games
disagreeing. Reading the source settles the mechanism.

### What MAME does

`screen_device::vblank_begin`:

```c
// if this is the primary screen and we need to update now
if (!(m_video_attributes & VIDEO_UPDATE_AFTER_VBLANK))
    update_if_primary();
```

**The screen is rendered at VBLANK BEGIN.** `kaneko16` does not set
`VIDEO_UPDATE_AFTER_VBLANK`, so that is the path taken.

The Lua frame notifier fires much later. `video_manager::frame_update` runs
`finish_screen_updates()` first and only then
`machine().call_notifiers(MACHINE_NOTIFY_FRAME)`, which is what
`lua_engine::on_machine_frame` — and therefore both
`add_machine_frame_notifier` and `wait_next_frame` — is attached to.

So an end-of-frame capture is a whole vblank period newer than the picture. A
game that writes its video registers during vblank drifts by a full frame; one
that writes earlier does not. That is exactly why `explbrkr` needed a one-frame
correction and `mgcrystl` did not — and why no single frame offset could fit
both.

### The frame counter is not reliable either

`emu.wait()` resumes on a timer, not on a frame notifier, so any wait inside
the loop stops the counter tracking rendered frames. Two runs differing only by
an `emu.wait` captured **demonstrably different pictures for "frame 600"**
while every byte of captured state was identical. Frameskip was ruled out:
`-noautoframeskip -frameskip 0` changes nothing.

### The fix

Capture the state at vblank start and the picture one line later, **in the same
block**. Frame identity then stops mattering — whatever frame it is, the state
and the picture describe the same instant. `DUMP_AT=vblank` is now the default.

```
             before          after
mgcrystl       642            298      99.48%
explbrkr       986              0     100.00%   EXACT
blazeonj         0              0     100.00%
wingforc         0              0     100.00%
```

**Explosive Breaker is now pixel-exact**, and three of the four gate frames
pass. `mgcrystl`'s remaining 298 are the odd-row line-scroll anomaly, which is
unchanged by this and remains the one open question in the tilemap path.

### What this corrects

The previous entry's `STATE_LAG` experiment — one frame of tile-state lag —
fitted `explbrkr` and broke `mgcrystl`, and I recorded it as an unexplained
per-game disagreement. It was neither per-game nor a frame lag: it was a
sub-frame capture-point error that happened to round to a frame for one game.
`STATE_LAG` is retained only as a diagnostic and defaults to 0.

**Standing lesson:** when two games disagree about a constant, suspect the
instrument before concluding the hardware differs. The question "what does MAME
actually do" had a definite answer in fifty lines of its own source, and no
amount of fitting offsets to pixel counts would have found it.

---

## 2026-08-20 — priority mixer moved from the harness into RTL

**Instrument:** `make gate` before and after the swap.

The mixing had been C++ inside the frame harness, so the gate validated the
address engines but not the mixing. `rtl/video/kaneko_mixer.sv` now implements
it and the harness drives the RTL at every mixing site, including the
diagnostic sweeps. **The gate is byte-identical after the swap** — `mgcrystl`
298, the other three exact — which is the result wanted: the RTL reproduces
what the C++ did, and is now itself checked against MAME.

One simplification worth recording. MAME draws eight category passes, each
touching four layers in a fixed order, with later draws overwriting earlier
ones. For a *single pixel* that collapses to: **the winner is the solid layer
with the highest category, ties broken by the highest layer index.** So the
mixer is combinational, not a state machine — 8 passes x 4 layers becomes one
comparison.

The priority-bitmap value left behind is the **winner's**, not the highest
category present, because the last write is what stands. Both the chip-1 rule
(`m_view2_2_pri`) and the sprite comparison table are per-game inputs, not
constants — hard rule 9.

Area: 325 yosys cells, combinational.

**Reuse position, checked rather than assumed.** Grepping every vendored
repository for VIEW2 or VU-002 RTL returns nothing: there is no existing
implementation of either custom chip, and the mixer is not a chip at all but
the documented interaction between them, which exists only in
`kaneko16_v.cpp`. Everything else in the system is already available — fx68k,
jt49, jt6295, jt51, T80, and the template's `arcade_video.v`, `hps_io.sv` (which
is also the ROM loader), OSD and PLLs. The SDRAM controller is the one
remaining non-novel gap, and `model1-ref/rtl/mem/m1_sdram.sv` is the same
author's and can be ported rather than rewritten.

---

## 2026-08-20 — VIEW2 pixel fetch pipeline: 1 pixel/clock against real memories

`rtl/video/kaneko_tmap_fetch.sv` wraps the verified combinational address
engine with the memory accesses it implies. Four registered stages, 1
pixel/clock, 4 clocks latency:

```
S0  screen_x/y      -> map_y            -> scroll RAM address
S1  scroll word     -> map_x, tile idx  -> VRAM address
S2  VRAM word       -> attr/code decode -> tile ROM address
S3  ROM byte        -> nibble select    -> pixel out
```

`kaneko_tmap_fetch: checks=972776 fails=0 latency=4 bubbles=89038 stalls=27209`

The reference is **not** another transcription of MAME — it is the
combinational path the frame gate already validates against real MAME frames.
This harness asks one question: does the pipelined version, driven against
memories, produce exactly what the verified combinational version produces?
Pipelining bugs are their own species — a stage off by one, a signal that
fails to travel with its pixel, a control input sampled at the wrong stage —
and the frame gate would not catch any of them.

Bubbles (`req_valid` low) and stalls (`ce` low) are interleaved so the
pipeline is not only ever exercised back to back.

### Implementation choices, which are ours and not the hardware's

- **VRAM is 1024 x 32**, holding `{code, attr}` in one word, so a tile entry is
  a single read. The chip's own VRAM is 16-bit with attr and code in adjacent
  words; packing them halves the fetch cost and changes nothing visible.
- The scroll RAM read is unconditional even when line scroll is disabled — the
  result is masked instead. Gating it would save nothing and would put the
  control bit in the address path.

Area: 355 cells for the pipeline including the address blocks it instantiates.

### Two harness bugs worth recording, because both looked like RTL bugs

1. **Queue alignment off by one.** Popping when `size > LATENCY` compares each
   request against its *successor's* output. The signature was unmistakable in
   hindsight: `dut` values matched `ref` values from the adjacent check.
2. **Memories modelled combinationally.** The pipeline assumes registered
   M10K-style reads — address captured at an edge, data on the next cycle —
   but the model returned data in the same cycle, so every stage saw its own
   cycle's address instead of the previous one's. The three reads are chained
   (`vram_addr` depends on `scr_data`, `rom_addr` on `vram_data`), so each has
   to be presented and evaluated in order.

Neither was a fault in the RTL. When a brand-new harness reports ~99% failure
against already-verified logic, suspect the harness.
