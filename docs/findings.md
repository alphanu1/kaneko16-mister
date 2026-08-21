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

- ~~`jtfpga/fx68k` does not exist~~ — **WRONG, withdrawn.** It does exist; see
  the entry dated later the same day. Upstream is `ijor/fx68k`, which is what
  is vendored, and `jtfpga/fx68k` is that same code repackaged.
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

Area: 301 cells for the pipeline including the address blocks it instantiates.

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

---

## 2026-08-20 — VU-002 sprite bitmap renderer

`rtl/video/kaneko_vuspr_draw.sv` walks the resolved sprite table and draws each
16x16 into the sprite bitmap. Decision D5: a bitmap, as the hardware has, not a
per-line renderer.

```
kaneko_vuspr_draw: checks=2097152 fails=0 passes=8/8
                   bmp_writes=184340 mask_writes=771885 (rejected=587545)
```

499 cells. The reference is the C++ compositor inside the frame gate, which
produces pixel-exact frames on three games — so this asks only whether the RTL
reproduces it, ordering included.

**The ordering is the substance of this module.** MAME parses first-to-last
(the multisprite latches carry forward) but *draws* last-to-first with
first-writer-wins, so **a higher table index is frontmost**. The module walks
the table downwards and keeps the first pixel written. Sprites in the harness
are deliberately clustered, because on a scattered set the rule is invisible:
with 8 sprites the bitmap and mask write counts are equal, while with 1024 the
mask is written 246k times against 40k bitmap writes — the rejected 206k are
exactly the pixels the ordering rule discards.

The mask is marked for every non-transparent source pixel, whether or not that
pixel won. Marking only on a win would let a further-back sprite show through a
pixel an earlier one had already claimed.

### The bug worth recording: a strobe and its address must be registered together

First version drew almost nothing — 113 bitmap writes where ~1900 were due. The
cause was that `bmp_addr` was registered while `mask_waddr` was combinational,
so the mask write landed one pixel AHEAD of the bitmap write. Every subsequent
pixel then found its mask already set and drew nothing.

It was invisible in the counters (`mask_we` fired 1933 times, about the 94% of
non-transparent pixels expected from random ROM) and only became obvious when
the writes were traced: `bmp_we` at (45,76) in the same cycle as `mask_waddr`
(46,76). **A write strobe and its address must be registered together, or they
describe different cycles.**

Two harness bugs preceded it and both looked like RTL faults: memories modelled
combinationally again, and a mask port with a single shared address, which
cannot express read-then-write. The mask now has split read and write
addresses, which is what an M10K simple-dual-port provides anyway.

---

## 2026-08-20 — SDRAM controller ported, not rewritten

`rtl/mem/kaneko_sdram.sv` and `bw_monitor.sv` are ported from the Model 1 core
(same author, GPL-3.0-or-later), renamed and otherwise unchanged. Their
verification came with them.

```
sdram_model[trc=7]: checks=1944  fails=0
kaneko_sdram:       checks=74729 fails=0 violations=0 reads=95607 writes=6625
  aggregate 0.439 words/cyc = 87.8 MB/s at 100 MHz (125.5 MB/s at 143 MHz)
```

**Why port rather than write.** The controller is generic — a parameterised
array of ports with no Model-1-specific dependency — and its header records two
hazards found the hard way and invisible from a datasheet:

- requests must be latched on the request **rising edge**, not sampled as a
  level qualified by `!pend && !ack`, or a requester that issues its next
  request in direct response to an ack drops it and the port hangs forever;
- completion must clear `pend` on the **ack rising edge** and before the
  new-request latch in the same process, so a chained request landing on that
  edge wins rather than vanishing.

Rewriting would have meant rediscovering both, and the failure mode of the
first is "adding an unrelated master broke the CPU".

That file in turn follows meathax's System 32 controller; its provenance note
is retained and recorded in `THIRD-PARTY.md`.

**Bandwidth headroom.** 87.8 MB/s at 100 MHz measured under streaming traffic
across five ports. The design study's §6 estimate says the Kaneko video path has
no bandwidth concern, and this is the first number that bears on it — the tile
fetch path will want roughly 4 layers x 1 byte/pixel at ~6 MHz pixel rate,
around 24 MB/s, plus sprite ROM reads during the draw pass.

**Lint waivers.** The ported file trips WIDTHEXPAND, UNUSEDPARAM and
UNUSEDSIGNAL under our stricter `-Wall`. They are waived at the top of the file,
listed individually with the reason: the file is kept diffable against its
origin, the warnings are width-of-an-int and dead-signal notes, and the module
carries its own passing testbenches. Blanket-waiving was avoided.

Also added `` `timescale 1ns/1ps `` to our own RTL, which previously had none —
Verilator warns when some modules have one and others do not.

---

## 2026-08-20 — SDRAM re-ported from Model 2; the Model 1 version would fail on hardware

**Raised by the user**, who asked whether the Model 2 controller was better and
whether it was set up for 64 MB before trusting the port. Both halves of that
question were worth asking.

**Model 2 is configured for 64 MB**: `SDR_COL = 10` (8192 x 1024 x 4), 25-bit
word address. Model 1 hardcodes `localparam COL_BITS = 9` and a `[24:1]`
address — 32 MB, and it cannot address a 64 MB module at all.

**Model 2's controller is a later, hardware-corrected version of the same
file.** Four differences, every one found on a real board and every one
invisible in simulation:

1. **Geometry fixed at 32 MB** in Model 1, parameterised in Model 2.
2. **A10 aliasing.** Column bits map to A0..A9 then A11, A12 — skipping A10,
   the auto-precharge flag. A straight `a[COL_BITS-1:0]` slice is correct only
   up to nine column bits; at ten it puts a column bit where the precharge flag
   lives. Model 1 never reaches it because it is fixed at nine, so the bug is
   latent rather than absent. The device *model* had the same fault and it
   "made a correct 128 MB controller look broken: 3,965 data mismatches with
   ZERO protocol violations".
3. **Port 0 returned a single word.** A single-word read carries A10 on its
   FIRST command, because the first word is also the last, so the row closes
   tRCD+1 cycles after activation — inside tRAS on a real device and tolerated
   by a behavioural model. On the board the CPU port read zero while other
   ports read correctly from the same SDRAM. All ports now burst four.
4. **Capture depth range too late.** Model 1 offers CL+2..CL+5; the board needs
   CL+1 or earlier. A write-then-read of AA55/5AA5/FF00/00FF came back shifted
   by exactly one 16-bit word, and no setting in the old range could correct
   it — which is why cycling the OSD option produced garbage at every position
   and was misread as "the phase is not involved".

The Model 1 port would have passed every test here and failed on hardware.

---

## 2026-08-20 — the two SDRAM "failures" were a testbench race, not an RTL bug

The Model 2 controller reported 2 failures out of 123,927 in its concurrent
test. Building the **pristine, unmodified** Model 2 sources reproduced them
exactly — same addresses, same values — so the port was faithful and the
question was whether the controller or the test was wrong.

Bisected by removing stimulus:

```
writes with byte-enables:  2 fails
writes, full words only:   1 fail
no writes at all:          0 fails
```

So it needed a write concurrent with reads. Instrumenting the check to ask
whether the failing address had been written *while that read was already in
flight* answered it: **both were.**

**The controller is correct.** It gives no ordering guarantee between
independent ports with concurrent outstanding transactions, and never claimed
to — so a read that overlaps a write to the same address may legitimately
return either value. The harness's shadow model updates at write *issue* time
and therefore expected only the post-write value. `pick_addr` deliberately uses
just 6 rows and 4 banks ("few rows, so conflicts happen"), which makes such
collisions common rather than exotic.

Fixed in the harness, not the RTL: a raced read now accepts the pre-write value
as equally correct, and the count is **reported** rather than silently
absorbed —

```
reads accepted as raced (returned the legal pre-write value): 2
kaneko_sdram: checks=123927 fails=0 violations=0
```

Reporting it matters: a run showing zero there has not exercised the concurrent
write/read path at all, and the number quietly drifting to 0 would mean the
test stopped covering the case it exists for.

Clean at all three geometries:

| COL_BITS | module | result |
|---|---|---|
| 9 | 32 MB | checks=123927 fails=0 violations=0 |
| 10 | **64 MB** | checks=103267 fails=0 violations=0 |
| 11 | 128 MB | checks=95475 fails=0 violations=0 |

**Worth feeding back to the Model 2 project**, where the same two failures are
live in its own suite. The fix is to the testbench's expectation, not to the
controller.

---

## 2026-08-20 — ROM loader ported from Model 2

`rtl/io/kaneko_rom_loader.sv`, with the TGP microcode path removed (a second
download index feeding an on-chip 32-bit program RAM; no equivalent here).

**The design principle is the reason to port rather than write.** From its own
header: *"STREAM LAYOUT IS THE SDRAM LAYOUT"*. The MRA pads every region and
emits them in the order the SDRAM map expects, so the mapping is the identity —
stream byte N is SDRAM byte N — and there is deliberately no per-region base
arithmetic in the loader.

That matches exactly what was already recorded here about
`tools/build_rom_regions.py` being the MRA's twin. The header states the cost of
the alternative: a loader carrying region offsets computed from each other "does
not fail at load time, it fails much later as a game that boots to garbage, and
the evidence points at the CPU rather than at the loader".

Two further lessons come with the file and are kept:

- **`ioctl_wait` must survive the HOST's reaction time, not the testbench's.**
  It asks the host to stop; everything already in flight still arrives. At
  depth 8 / margin 6 the buffer tolerated 15 cycles and silently dropped words
  at 16 — and the test missed it because it swept 0..6, "the margin the
  parameter was set to: it confirmed the setting instead of testing it". Now
  512 / 256, with the sweep an order of magnitude past anything plausible.
- **`SDR_AW` must match the controller's geometry.** A loader narrower than the
  controller silently wraps the stream over its own start — "a black screen
  with no error", which is what a 43.62 MB set did against a 24-bit address.

### The inherited test is narrow, and that is not yet fixed

`kaneko_romload` passes, but it is a specific boot-readback scenario carried
over from Model 2's context: 6 checks. It does exercise the real path — ioctl
through the loader through the SDRAM controller and back — which is worth
having as a smoke test.

It does **not** verify stream integrity: that a full ROM image fed in arrives
byte-for-byte at the right SDRAM addresses. Given that the whole design rests on
the identity mapping, that is the property most worth testing, and the next
piece of work here is a test that streams the assembled `explbrkr` regions
through and compares. Recorded rather than left implied.

---

## 2026-08-20 — stream integrity verified: 5.75 MB in, byte for byte

The loader's whole design rests on the identity mapping (D6), and nothing
tested it — the inherited testbench is a 6-check boot-readback scenario.
`sim/io/tb_kaneko_romstream.cpp` now feeds the real assembled `explbrkr` image
and watches every SDRAM write the loader issues.

```
kaneko_romstream: image=3014656 words (5.75 MB) writes=3014656
                  checks=7 fails=0 stalled=21237879
```

Every input word written exactly once, at `byte offset >> 1`, with the right
data. No stray writes, no duplicates, no missing words, `overflow` never
asserted, `rom_loaded` did.

`stalled=21237879` matters: the host is made to honour `ioctl_wait` the way the
HPS does — continuing to send for 4-16 more words after it asserts, because the
signal *asks* the host to stop and everything in flight still arrives. That is
the exact case the ported file records as having silently dropped words when
the margin was too small. A run with a low stall count would mean the
backpressure path was not exercised.

### A free correctness check fell out of assembling the program ROM

`explbrkr`'s `maincpu` is `ROM_LOAD16_BYTE` — u18 on even bytes, u19 on odd.
Assembled, the 68000 reset vectors read:

```
initial SSP = 0x0010f7fc     initial PC = 0x00000914
```

`bakubrkr_map` puts work RAM at `0x100000-0x10ffff` and ROM at
`0x000000-0x07ffff`, so the stack pointer lands exactly inside work RAM and the
entry point inside ROM. A wrong interleave gives garbage in both. This is the
first evidence that the program ROM is assembled correctly, and it came for
free from looking at the first eight bytes.

---

## 2026-08-20 — first synthesised core: builds, fits and TIMES

`quartus_sh --flow compile` under Quartus 17.0, full flow:

```
Analysis & Synthesis  successful, 0 errors
Fitter                successful   ALMs 7,578 / 41,910 (18%)
                                   block RAM 405,249 / 5,662,720 bits (7%)
                                   PLLs 3 / 6
Assembler             successful   Kaneko16.rbf, 2.34 MB
TimeQuest             successful   ZERO negative slack, 18 setup / 15 hold clocks
```

**The timing result is only meaningful because the core PLL was constrained.**
`emu|pll|pll_inst|altera_pll_i|...` appears in both the setup and hold
summaries, so `sys_top.sdc`'s clock groups matched and the SDC guard did not
fire. That is the check the guard exists for: a core whose PLL hierarchy does
not match gets timed against the HDMI and audio PLLs, reports SUCCESS, and
emits an .rbf that fails on hardware. Model 2 paid -36.5 ns for it once.

Worst setup slack on a core clock is **+0.251 ns** — positive but not
comfortable, and worth watching as the CPU and the rest of the video path land.

### What this build is

No 68000. It loads the MRA stream into SDRAM and renders a wall of tiles
straight from the tile ROM, so what appears is real Explosive Breaker artwork
fetched through the pipeline the finished core will use. The modes are chosen so
a wrong picture localises itself: mode 3 is a pattern touching no memory at all,
so a blank screen there means the video path while a picture there and nothing
elsewhere means the memory path.

Deliberate simplifications, each recorded rather than assumed:

- **One 48 MHz clock for SDRAM and core**, so there is no clock-domain crossing.
  A CDC has its own failure modes and adding one before memory has ever worked
  on hardware means debugging two unproven things at once.
- **NP=5 rather than 1.** The controller sizes arbiter state from NP and does
  not elaborate at 1 (`index 2 cannot fall outside the declared range [0:0]`),
  and five is the configuration its testbench covers — so the build runs the
  arrangement that is actually verified.
- **No rotation.** explbrkr is ROT90, but D3's rotation stage is deliberately
  left out so the picture is judged in native orientation, the same orientation
  the frame gate compares.

### The MRA is generated and CHECKED, not written

`make mra` emits the MRA and the stream image from one table and then expands
the MRA the way the HPS does, comparing:

```
MRA expands to  0x05c0000 bytes  sha1=76f3027bc3de64ab
stream image is 0x05c0000 bytes  sha1=76f3027bc3de64ab
MATCH
```

This closes D6's loop. It also caught a real bug in the generator: parts were
emitted in *entry* order, but `ROM_RELOAD` places copies at specific offsets
that interleave with other files — explbrkr's sprite region is u37, u38, u37,
u38, u36 *by address*, not u37, u37, u38, u38, u36. That would have loaded a
region of exactly the right size with its halves transposed, and nothing at
load time would have complained.

---

## 2026-08-20 — FIRST PICTURE ON HARDWARE, and the two bugs it found

The bring-up core ran on the board and put tile artwork on screen. Both faults
it exposed were in the bring-up renderer itself, not in the verified blocks —
which is what it was built to do.

### 1. Address scaled by four

`run_word` counts **8-byte bursts**, but it was added directly to a **word**-
address base:

```systemverilog
sdr_addr <= SDR_AW'(base + {4'd0, run_word});      // wrong: quarter address
sdr_addr <= SDR_AW'(base + {run_word, 2'b00});     // fixed
```

Every fetch landed at a quarter of its intended address, so adjacent pixels drew
from overlapping wrong data. On screen: dense fine-grained hash with no clean
tile boundaries.

**Worth noting what that photo already proved**, before the fix: the core
loaded, the PLL and video timing produced a signal the monitor locked to, the
loader moved 5.75 MB into SDRAM, and the controller returned *real ROM data* —
because wrong-address ROM data looks like that, whereas a dead memory path gives
uniform noise or black. Three of the four things the build exists to prove had
already passed.

### 2. The fetcher had no lookahead, dropped requests, and churned in blanking

After the address fix the picture became recognisable tiles with **horizontal
smearing that drifted diagonally**. Three flaws, all in the fetch:

- **No lookahead.** The request was issued as the group's first pixel was
  already being displayed, so the opening pixels of every 8-pixel group showed
  the previous group's data. Constant per line, hence the diagonal drift.
- **Dropped requests.** `run_word_q` only advanced when a request was *issued*,
  so a run that changed while one was in flight was never fetched at all.
- **Blanking churn.** `screen_x` runs to H_TOTAL, so during hblank the tile
  index kept cycling and fired spurious fetches.

Now it prefetches exactly one 8-pixel group ahead, wrapping to the next line
correctly, double-buffers, compares against what it **has** rather than what it
last asked for, and only fetches positions that will be displayed. A group is 64
core clocks against an SDRAM read of ~20-30.

### What this establishes on hardware

The loader, the SDRAM controller, the PLL, the video timing and the tile decode
all work on the real board at the real clock — none of which simulation could
settle. The derived 6 MHz / 384 x 264 timing produces a signal the display
locks to, which is the first evidence for that reconstruction beyond its
agreement with MAME's 59.1854 Hz.

### The MRA filename is what the menu shows

`<name>` inside the XML is not what MiSTer lists. The arcade menu is built from
the **.mra filenames** in `_Arcade`, so a file called `explbrkr.mra` lists as
"explbrkr" however the XML is titled. The generator now names the file after the
game, and takes the title, year and manufacturer from MAME's `GAME()` line
rather than a hand-kept table — the same reasoning as the ROM layouts: a second
description drifts.

```
mra/Explosive Breaker (World).mra
  <name>Explosive Breaker (World)</name>  <year>1992</year>
  <manufacturer>Kaneko</manufacturer>
```

---

## 2026-08-20 — CORRECTION: `jtfpga/fx68k` does exist. I was wrong.

**Raised by the user, who was looking at the page.** An earlier entry here, and
matching edits to the design study and `THIRD-PARTY.md`, asserted that
`jtfpga/fx68k` did not exist and that the org was `jotego`. That was wrong on
both counts and is withdrawn.

The original probe was a `git ls-remote` batch in which that one URL reported
not-found. Re-running it returns `refs/heads/master 1217ab8d`, and the GitHub
API returns 200 for both the repo and the `jtfpga` org. The most likely cause is
a transient failure or rate-limit during a batch of ten probes — **and the
lesson is that a single negative result from a network probe is not evidence of
absence.** Every other repo in that batch resolved, which made the one failure
look like a real answer rather than a flaky one.

It also propagated: the false claim was written into three documents as a
"correction" to the design study, complete with reasoning about brand names
versus org names. The reasoning was plausible and entirely invented.

### What the three repositories actually are

| repo | `fx68k.sv` | notes |
|---|---|---|
| `ijor/fx68k` | upstream | vendored here, pinned in `deps.lock` |
| `jtfpga/fx68k` | **byte-identical to ijor's** apart from CRLF line endings | repackaged into jtframe's `hdl/` + `cfg/files.yaml` layout |
| `jotego/fx68k` | ijor's **+130 lines** | adds an optional `FX68K_ALTERA_REGS` define putting the register file in 2 BRAM blocks — "Frees up ~2000 Logic Cells on Cyclone III". Off by default. |

All three ship `microrom.mem` and `nanorom.mem`, which `fx68k.sv` loads with
`$readmemb` and cannot run without.

### What to actually use

Staying on `ijor/fx68k`. jtfpga's is the same code, so switching buys nothing
but a different directory layout. **jotego's is the only one with a
MiSTer-relevant difference**, and it is worth revisiting when ALM pressure
appears: `FX68K_ALTERA_REGS` trades two M10K blocks for roughly 2000 logic
cells. At 18% utilisation today there is no pressure, and the define is off by
default in jotego's too — so adopting it would be a deliberate choice, not a
consequence of switching repos.

---

## 2026-08-20 — the 68000 executes Explosive Breaker's boot code

`make test` now includes a CPU harness: fx68k plus `rtl/cpu/kaneko_bus.sv`,
booting out of the real `explbrkr` program ROM. The trace is the result; the
assertions are only the ones that need no oracle.

```
  #   addr      r/w  data   uds lds
  0   000000    R   0010    1   1     SSP high
  1   000002    R   f7fc    1   1     SSP low   -> 0010f7fc, inside work RAM
  2   000004    R   0000    1   1     PC high
  3   000006    R   0914    1   1     PC low    -> 00000914, inside ROM
  4   000914    R   007c    1   1  \
  5   000916    R   0700    1   1  /  ori #$0700,SR   — mask interrupts
  6   000918    R   4ef9    1   1  \
  8   00091a    R   0000    1   1   > jmp $0000c8a8
  9   00091c    R   c8a8    1   1  /
 10   00c8a8    R   13fc    1   1  \
 11   00c8aa    R   0000    1   1   |  move.b #$00, $900009
 12   00c8ac    R   0090    1   1   |
 13   00c8ae    R   0009    1   1  /
 15   900008    W   0000    0   1     byte write, LDS only -> 900009
```

That is a textbook 68000 boot — vectors, mask interrupts, long jump — and the
first thing the game does is write the **sprite registers** at `0x900009`, which
`bakubrkr_map` decodes exactly there. Later in the trace it is clearing sprite
RAM at `0x600014` upward.

### Two bugs fixed getting here

**The burst lane selection was wrong.** `kaneko_bus` selected a word from the
64-bit read by `a[2:1]`, as if the controller aligned a burst down to four
words. It does not — `kaneko_sdram.sv` starts a burst at the **exact** address
given and increments (`xfer_addr[COL_BITS:1] + 1`). So word 0 of the burst *is*
the requested word, and lane selection returned the right data only when
`a[2:1]` was 0. Every odd word read as zero, and the reset vectors came back
`0010 0000 0000 0000` instead of `0010 f7fc 0000 0914` — recognisably half
right, which is what made it findable.

**fx68k cannot be simulated from upstream.** `ijor/fx68k` trips
`%Error-BLKANDNBLK: Unsupported: Blocking and non-blocking assignments to same
non-packed variable: 'Nanod'`. `jtfpga/fx68k` — the repo the user pointed at —
ships `hdl/verilator/`, a variant that flattens the `s_nanod` struct into
individual wires and elaborates cleanly. Its `hdl/` is byte-identical to ijor's,
so synthesis is unaffected. **This is the concrete reason to prefer that fork,
and without it the 68000 would be the one block here with no harness.**

### Open: four addresses the map does not decode

`e40000`, `e80000`, `ec0000` and `c00000`. The first three look like mirrors of
the input ports at `e00000-e00007` from partial decoding on the PCB; `c00000` is
*mgcrystl*'s DSW port, which `bakubrkr_map` does not have at all. MAME decodes
none of them either.

The bus **acknowledges** them and returns `0xffff`, because a 68000 waiting on a
DTACK that never comes simply stops, with no error and nothing to see. They are
counted and printed rather than failed: failing would encode a guess as a
requirement, and ignoring would lose the question. Settling it is part of the
trace comparison against MAME, which is the next step and the real gate.

---

## 2026-08-21 — the core with a 68000 in it fits and times

```
Logic utilization (ALMs)  9,714 / 41,910   (23%)   — was 7,578 without the CPU
Total registers           14,246
Total block memory bits   1,360,289 / 5,662,720 (24%)
Setup / Hold              ZERO negative slack, core PLL constrained
Worst core-clock slack    +0.180 ns
```

fx68k costs about 2,100 ALMs here. Slack tightened from +0.247 to +0.180 ns,
which is the number to watch as the rest of the video path lands.

### The 5x overflow was one inference failing, not a design that is too big

The first attempt died at the fitter:

```
Error (170011): Design contains 438004 blocks of type combinational node.
                However, the device contains only 83820 blocks.
```

Five times the device. That reads like a design far too large, and it was not.
Both new memories were written as one 16-bit array with **bit-slice writes** —
`wram[addr][15:8] <= ...` — which Quartus does not recognise as a byte-enabled
memory. It does not infer a smaller memory or warn; it infers **none**, and
builds 512 Kbit of work RAM plus the video memories out of flip-flops and
address muxes.

Rewritten as **two byte-wide arrays per memory**, each written whole, they infer
every time: block memory went from 405,249 bits to 1,360,289 and the
combinational explosion vanished.

Byte enables are not optional here — the 68000 writes single bytes, and the very
first store the boot code makes is `move.b #$00, $900009`.

### `quartus_sh --flow compile` rewrites the .qsf

Rule 10 was set (`PROJECT_OUTPUT_DIRECTORY build/quartus`) and then silently
undone: the full-flow driver writes settings files by default, which reset the
assignment to `output_files` and put every report back in the project root. A
build that obeys the rule once and then stops is worse than one that never did,
because the second time nobody looks.

`make quartus` now runs `quartus_map`, `quartus_fit` and `quartus_asm`
individually with `--write_settings_files=off`, and `quartus_sta` separately
because it accepts neither flag. `db/` and `incremental_db/` have no assignment
that moves them, so they are symlinked into `build/`.

### Not yet tested on hardware

The MiSTer stopped responding before this build could be deployed — no route to
host, so powered off or off the network. The bitstream is built, timed and
staged in `releases/`.

## The 68000 read the ROM with its bytes the wrong way round

*Instrument: `sim/top/tb_kaneko_cpumem.cpp` (`make boot`), against
`sim/mem/sdram_model.sv`. Corrected: the CPU bring-up build, which ran on
hardware and did nothing.*

The first build with a CPU in it went to the board and behaved like a core with
no CPU at all: the tile-map debug views were correct, and the palette view was
black with no liveness bar. The bar is `bus_cycles_lat >> 8`, so it needs more
than 256 bus cycles in a frame to light a single pixel — and the 68000 was
managing four in total, ever.

`sim/cpu` had passed. It executes real boot code, reaches
`move.b #$00, $900009`, and reads the reset vectors as `0010 f7fc / 0000 0914`.
It passed because it was not testing this. That harness acks every ROM fetch
combinationally —

```systemverilog
wire rom_ack_now = 1'b1;
```

— and its testbench fed words straight out of the file, big-endian:

```cpp
dut->rom_q = (uint16_t)((rom[byte_addr] << 8) | rom[byte_addr + 1]);  // big-endian
```

Neither the loader, the arbiter, nor the SDRAM was in the path. Everything that
only fails in the presence of a real memory system was untested, and the byte
order the board actually delivers had never once been presented to the CPU.

`sim/top/kaneko_cpumem_harness.sv` instantiates what the core instantiates —
same clock divider, same reset, same `ROM_BASE`, the real `kaneko_rom_loader`,
the real `kaneko_sdram`, the device model, and the video port driven as hard as
it will go so a starved CPU port cannot hide behind a dead one. Fed both byte
orders, it separates them completely:

| stream packing | reset SSP / PC | bus cycles in 42 ms |
| --- | --- | --- |
| byte *n* → `dout[7:0]` (what hps_io does) | `1000FCF7` / `00001409` | **4, then dead at tick 172** |
| byte *n* → `dout[15:8]` | `0010F7FC` / `00000914` | 62,189, still running |

`hps_io` is built `WIDE=1`; `ioctl_dout <= io_din[DW:0]` and the HPS packs file
byte *n* into the low half. So SDRAM word *n* is `{file[2n+1], file[2n]}` — the
order the graphics path is built around and is pixel-exact against MAME with.
The 68000 wants the other one.

Swapped, the reset SSP becomes `1000FCF7` and the PC `00001409`, which is even,
so there is no address error to notice — the CPU simply starts executing
byte-swapped code. `0x724E` is `moveq #$4E,d1`, one of the most common opcodes
in any 68000 program; swapped it is `0x4E72`, `STOP`. With `IPL[2:0]` tied
inactive, the first one reached ends the program permanently. Four bus cycles,
no interrupt to wake it, black screen.

The fix is one line in `kaneko_bus.sv`, at the endian boundary (D7):

```systemverilog
rom_word <= {rom_dout[7:0], rom_dout[15:8]};
```

`sim/cpu`'s testbench now packs its words the way SDRAM holds them, so the two
harnesses agree about what the board produces rather than one of them quietly
assuming the answer.

### What this cost, and the general shape of it

The bug was reachable by reading: `hps_io.sv` says `WIDE`, the region file says
`0010 f7fc`, and those two facts are three lines apart. It survived because the
harness that would have caught it had been written to make the CPU run, and it
succeeded at that — an immediate-ack ROM and a hand-fed word are exactly what
you reach for when the question is "does the decoder work". They are also
exactly what removes the memory system from the test.

Two things follow, and both are now in the tree rather than in this paragraph:

- **A harness that stubs the thing under suspicion proves nothing about it.**
  `make boot` exists so the CPU is tested against the memory system it will
  actually have.
- **The liveness bar could not report what happened.** `>> 8` cannot show four
  bus cycles; it renders zero and looks identical to a CPU held in reset. An
  instrument that cannot distinguish "stopped" from "never started" is not
  evidence either way — rule 6.

### Two open items this run also surfaced

- The device model reports two refresh gaps, at tick 3376 and 6752 and never
  again, in every run. Both fall before any ROM data is written, so nothing is
  at risk of being lost, but the controller is not refreshing regularly from
  the moment it leaves initialisation and that should be settled rather than
  assumed harmless.
- The read capture depth disagrees between the two machines. `rd_lat_sel = 0`
  (CL+1) is what the board needs, on the evidence of a write-then-read
  self-test; the device model needs `3` (CL+3), the controller's reset default.
  `make boot` sweeps the selector and reports which one the model wants rather
  than hard-wiring either, but the two ought to agree and do not.

### `make boot` covers explbrkr only

`tools/build_rom_regions.py` describes a `maincpu` region for explbrkr alone —
the other Tier 1 sets carry graphics and sound only, because the frame gate
never needed their code — and `kaneko_bus` decodes `bakubrkr_map` alone. Booting
another title needs its memory map as well as its ROM. The target now says so
instead of failing on a missing file.

Rule 9 still holds for this change: the byte order is a property of the
`hps_io` interface and the 68000, not of any one game, and `make gate` is
unchanged at 3 of 4 pixel-exact with mgcrystl at its known 298-pixel anomaly.

## The 68000 matches MAME for 100,000 bus accesses of boot

*Instrument: `make bustrace` — `tools/mame_bus_trace.lua` against
`sim/top/tb_kaneko_cpumem.cpp`, diffed by `tools/diff_bus_trace.py`.
Corrected: three open questions and two wrong assumptions about the oracle.*

Rule 6 says settle the CPU against MAME rather than against a waveform. Both
sides now emit the same four-column format — address, R/W, data, lane mask —
and the result on explbrkr is:

```
ours 100000 accesses, 22897 after dropping instruction fetches
mame 100000 accesses, 22898 after dropping instruction fetches
MATCH over all 22897 compared accesses
```

That covers boot through the clears of the palette, sprite RAM and both VIEW2
tilemaps, every VIEW2 and sprite register write, and the EEPROM/lockout write.

### Instruction fetches are counted, not compared

fx68k reproduces the 68000's prefetch and MAME's core models it differently,
re-reading words fx68k does not. A raw line diff drowns in that within a dozen
lines and says nothing about correctness. What is architecturally determined —
and so must agree exactly — is every **write**, and every **read outside ROM**.
Those are what the differ compares; fetches are counted and reported.

In practice the two agreed far beyond that. Over the first 10,434 accesses the
traces are identical line for line, prefetch included.

### The four "unmapped" addresses are unmapped on the board too

`c00000`, `e40000`, `e80000` and `ec0000` are written once each during boot —
values `0000`, `0002`, `00aa`, `0065` — and **`bakubrkr_map` does not decode any
of them either**. MAME ignores the writes; so does the core; the traces are
identical at identical positions. `e4/e8/ec` sit at `e00000 + 0x40000/0x80000/
0xc0000`, and `e00000-e00007` is the read-only input port block, so partial
decoding on A18/A19 would land them on a port that ignores writes.

These were carried as an open question since the CPU first ran. They are
settled: nothing to implement. `unmapped_hit` stays wired so a *new* one is
still noticed.

`d00000` was never unmapped — it is coin lockout and EEPROM, and the core
already decodes it. It only looked unexplained because the differ's first
region table was transcribed from the mgcrystl map, which puts the palette and
VIEW2 windows elsewhere. Nothing was reported at the wrong addresses, so the
census looked clean while naming the wrong board.

### Three ways the oracle lied first

None of these produced an error. Each produced a plausible trace.

**MAME segfaults if the taps are installed before `machine:soft_reset()`.**
Deterministically, a frame and a half later, part-way through the VIEW2 VRAM
clear — the reset rebuilds the address map and leaves the tap objects dangling,
and nothing complains until one is next used. Without the reset the same taps
carry 100,000 accesses. This is why the first capture stopped at ~20,900 and
looked like a natural limit.

**MAME re-runs an autoboot script on machine reset.** Any "open the output file
on reset" logic therefore runs again from a fresh chunk, truncating the file
while the previous chunk's handle keeps its offset. The result was a
1,900,000-byte file — exactly 100,000 records — that was sparse NULs followed by
a few hundred lines of early boot. Right size, almost entirely empty.

**A 68000 RESET does not clear D0-D7 or A0-A6.** It loads SSP and PC and touches
nothing else. MAME has already run a frame by the time an autoboot script can
install anything, so its registers carried values from that frame while the core
leaves power-on reset with zeros. The boot code pushes registers it has not
initialised yet — `MOVEM.L D0/D7/A0-A3,-(SP)` at `016dde` — and the traces
diverged there on A1 and D7, MAME holding `00700000` and `7fffffff` against the
core's zeros. Ten thousand accesses of exact agreement, then a difference that
was entirely the instrument's doing.

The fix for all three is to reset the **CPU** rather than the machine: zero the
registers, load SSP and PC from the vectors, set SR to supervisor with
interrupts masked. The memory map is never rebuilt, the script never re-runs,
and the architectural state matches a core leaving power-on reset. The trace is
also streamed to disk and flushed rather than accumulated in a Lua table, so a
run that dies still leaves every access up to the fatal one — which is what
turned "bisect over whole runs" into "read the tail".

### What this does not cover

The core has no interrupts yet, and 100,000 accesses is roughly two frames, so
the comparison ends before the game's first VBlank handler would run. The
divergence that matters next is the one interrupts will introduce, and it cannot
be measured until IRQ5 and IRQ4 exist.

## Scanline interrupts: three levels, not two

*Instrument: `kaneko16_state::interrupt` in kaneko16.cpp, plus a frame-by-frame
SR poll in MAME. Corrected: a working note that had only two of the three.*

```
scanline 224 -> IRQ5    main vblank; also buffers sprite RAM
scanline 144 -> IRQ3    translates part of the sprite buffer
scanline  64 -> IRQ4    translates part of the sprite buffer
```

A note carried since the CPU first ran said "IRQ5 at scanline 224, IRQ4 at
scanline 64" and omitted IRQ3 entirely. The driver's own comment on the two
lower levels is "each of these 2 int are responsible of translating a part of
sprite buffer from work ram to sprite ram. How these are scheduled is unknown."

### The scanline numbers need no conversion

`set_size(256, 256)` with `set_visarea(0, 255, 16, 239)` — MAME's vpos counts
from the top of the blanked frame with the visible area starting at line 16,
which is exactly what `kaneko_video_timing` does with `V_START = 16`. The two
numberings coincide, so 224/144/64 are used as they appear in the driver.

Note that 224 is sixteen lines *before* the end of the visible area, not the
start of vblank. That is what the driver does, and its comment — "2 frame
delayed normaly; differs per PCB?" — says it is not certain either. Reproduced
rather than corrected.

### HOLD_LINE, and what answers the acknowledge

MAME asserts each level with `HOLD_LINE`: the line stays asserted until the CPU
acknowledges it. A pulse would be dropped whenever the 68000 happened to be
masking interrupts, and the game would lose frames in a way that looks like a
timing fault anywhere but here. `kaneko_irq` holds each level in a flip-flop and
clears it on the acknowledge for that level.

The board has no vector generator, so every acknowledge is answered with VPA and
the 68000 autovectors through 0x64..0x7c. Two things this forces:

- **VPAn is asserted only during the acknowledge.** VPAn low in a normal cycle
  turns that cycle into a synchronous 6800-style one.
- **`kaneko_bus` must stay out of the acknowledge entirely**, which is why it
  now takes a `cpu_space` input. Left to itself it would decode FC=7 as an
  ordinary access, find nothing mapped at `fffffx`, and assert DTACK anyway —
  the deliberate "answer everything so the CPU cannot hang" behaviour. The CPU
  would then take a *vectored* interrupt through whatever the read mux was
  driving: a jump to a garbage address, one frame after the game finally
  enables interrupts, with nothing in the trace to point at the cause.

### The game does not enable interrupts for about four seconds

Polling SR once per frame in MAME:

```
frame  60 SR=2700 mask=7 PC=00cc9e
frame 180 SR=2709 mask=7 PC=00ccca
frame 240 SR=2700 mask=7 PC=009d9e
frame 300 SR=2504 mask=5 PC=009f08
```

The first instruction at the reset PC is `ORI #$0700,SR`, so interrupts are
masked from the start, and the mask stays at 7 for roughly 240 frames while the
boot code runs a long self-test — a loop at `00ca14..00ca24` that walks about
two thousand bytes of sprite RAM comparing each one. Our core runs the same loop
over the same addresses; the 300,000-access trace matches MAME exactly, and
**neither machine takes a single interrupt in that window**.

`mask=5` at frame 300 is not the game running with level 5 blocked — it is the
CPU sitting *inside* the IRQ5 handler, which is where a frame-boundary sample
lands most of the time once the handler is running every frame.

### Why the bus trace stops being the right instrument here

Once interrupts are live the two machines diverge legitimately: MAME runs this
board at 59 Hz over 256 lines, `kaneko_video_timing` runs 264 lines at
59.1856 Hz. Different line rate, different frame length, so scanline 224 arrives
a different number of instructions into boot on each side no matter where the
CPU is released from reset. Aligning the harness to a frame boundary was tried
and reverted: it would have made the mismatch look deliberate without removing
it.

Screen timing is not PCB-verified (design study §9). Until it is, the bus trace
covers boot up to the first interrupt — which it does exactly — and the
interrupt logic is verified by `sim/cpu/tb_kaneko_irq.cpp` (91 checks) plus an
end-to-end acknowledge count in `make boot`.

### The acknowledge path is tested with level 7

explbrkr masks at level 7 for its first ~240 frames, and the harness cannot
reach that in a run of any reasonable length (see below), so nothing would have
exercised the acknowledge wiring at all. Level 7 is non-maskable, so `make boot`
forces it once the machine has booted:

```
== C: interrupt acknowledge path (forced level 7)
    acknowledges    1
    vector 0x7c/7e  15 reads
```

One acknowledge, not many, is correct: the 68000 recognises level 7 on the
*transition* to 7 rather than on the level, so a held 7 is taken once. fx68k
models that. The vector reads at 0x7c are the autovector for level 7 — proof
that VPAn is being answered rather than the cycle being DTACKed by the bus.

## The 68000 is running at about 45% speed: every ROM fetch is a full SDRAM burst

*Instrument: `make boot BOOT_ARGS="--ticks 300000000"`.*

```
DTACKs          8397878
last DTACK at   299999804 of 300000000 ticks
interrupts      none taken
```

8,397,878 bus cycles in 300 M ticks at 48 MHz is **35.7 ticks per bus cycle**,
or 0.744 us. A 68000 at 12 MHz completes a bus cycle in four clocks — 0.333 us,
16 ticks here. The core is 2.23x slower than the part it is replacing, so the
CPU is effectively running at about 5.4 MHz.

That is why the 300 M tick run — roughly 370 frames — takes no interrupts at
all. MAME's SR poll puts the game's unmask at around frame 240-300, and at 45%
speed the core has only made about 165 frames' worth of progress by then. The
interrupt logic is not implicated: nothing had asked for one yet.

`kaneko_bus` fetches four words from SDRAM and keeps one:

```systemverilog
rom_word <= {rom_dout[7:0], rom_dout[15:8]};
```

The other three are discarded, and the next instruction fetch — almost always
the very next word — starts a fresh burst, arbitration and all. The comment
there already called caching them "the obvious optimisation once the CPU runs".
It is no longer an optimisation: a core that runs the game at half speed is
wrong, not slow, and it will be wrong on hardware in a way that looks like bad
timing everywhere else.

Three of four sequential fetches should hit a four-word line. That is the next
change, and this measurement is its gate.

### Fixed: a 16-line ROM cache brings the CPU back to MAME's bus rate

*Instrument: `make boot BOOT_ARGS="--ticks 3000000"`, which now reports miss
rate and ticks per bus cycle; MAME's own rate measured with a tap counter over
60 frames.*

MAME does **41,517 bus cycles per frame** on explbrkr. That, not the 68000's
four-clock minimum, is the number to match — a real 68000 spends plenty of
clocks on internal cycles with no bus activity, so 16 ticks per cycle is a lower
bound neither machine reaches.

| ROM cache | bus cycles / frame | vs MAME | ticks / cycle |
|---|---|---|---|
| none | 24,412 | 59% | 33.2 |
| 1 line | 32,236 | 78% | 25.2 |
| 16 lines | 42,240 | ~102% | 19.2 |

The remaining difference is under 2% and is instruction mix between the two
measurement windows, not a speed difference: the memory system has stopped being
the limit.

Two changes got there.

**Direct-mapped, four-word lines, aligned.** The controller starts a burst at
the exact word address given and increments — it does not align — so an
unaligned request returns a window straddling two lines that cannot be tagged at
all. Aligning to `{wa[SDR_AW:3], 2'b00}` makes each burst a natural block, and
incidentally removes a hazard that was already there: the controller wraps a
burst inside the column bits, and an unaligned four-word burst can cross a row
boundary, which an aligned one never can.

**One line is not enough, and the reason is measurable.** A single line only
helps straight-line code. explbrkr's boot self-test sits in a loop at
`00ca14..00ca24` spanning three four-word blocks, so a one-line cache misses on
every fetch of it — ROM requests halved rather than quartered. Direct-mapped
over several lines holds it entirely: **0.1% miss rate**, and 4 lines measured
the same as 32.

16 is kept rather than 4 because the 3 M-tick window is dominated by that one
self-test loop, and the core cannot yet reach the game's actual main loop to
measure its working set. 16 lines costs **+120 ALMs and +1,296 memory bits** —
0.3% of the device — which is cheap insurance against a working set this
measurement cannot see. Revisit it with a real number once the game runs.

**DTACK one clock earlier.** With the cache doing its work the bus was still
spending an edge getting to `S_DONE` before asserting DTACK. Asserting it in
`S_IDLE` for the paths that answer immediately — a cache hit, work RAM, video
memory, the registers — took 19.8 ticks per cycle to 19.2.

The cache is transparent: `make bustrace` still reports MATCH over all 22,897
compared accesses, which is the check that matters — a cache that returned the
wrong word would diverge from MAME on the first hit.

### A missing .qsf entry cost a build

`kaneko_irq.sv` was written, linted, unit-tested and wired in, and the Quartus
build died nine seconds in with "instantiates undefined entity" — after lint and
the full simulation gate had already run. The `.qsf` lists sources one at a time,
so a new module is invisible to synthesis until someone remembers it.

`make quartus` now runs `qsf-check` first, which fails if any file under `rtl/`
is missing from the project. It runs before lint and test, so the answer arrives
in a second rather than after the gate.

## Why the game never reaches its main loop: two decoded-but-unread registers

*Instrument: `make boot --data-only --tail`, diffed against a MAME trace tapped
only outside ROM so the oracle can reach frame 229.*

The core boots, runs at MAME's bus rate, and still takes **no interrupts in 370
frames** — 6.25 s of emulated time against the 3.9 s MAME needs to finish its
self-test and unmask. Not slowness. A divergence during the self-test.

### Finding it needed two changes to the instrument

**Data-only tracing.** Instruction fetches are 77% of accesses and the differ
drops them anyway; reaching the point where the game unmasks needs ~9.5 M
accesses, which is not reachable with a tap on the whole address space. Tapping
only `0x080000` upwards removes 77% of the Lua callbacks. Nothing writes to the
ROM window, so nothing is lost.

**A ring buffer of the last N accesses.** A prefix trace answers "do we start
the same way". When two machines agree for millions of accesses and one is then
stuck, the question is "where does it end up", and only the tail can say.

### MAME was booting a formatted machine

`build/bustrace/nvram/explbrkr/eeprom` — 128 bytes, written by an earlier run.
CLAUDE.md already says to run MAME from a scratch directory because it drops
`nvram/` and `cfg/` wherever it starts; this is what that rule is for. A saved
EEPROM makes the oracle boot a formatted machine while the core boots a blank
one, and they take different paths through the setup code.

It happened not to matter here — the blank and saved runs are byte-identical for
823,998 accesses and first differ at 823,999, which is the first EEPROM read —
but that was luck, not design. `make bustrace` now clears `nvram/` and `cfg/`
every run, so the comparison is always first-boot.

### The bug, twice

`kaneko_bus`'s read mux had no case for two decoded regions, so both fell
through to the `0xffff` default:

| address | ours | MAME | first divergence at |
| --- | --- | --- | --- |
| `a80000` watchdog | `ffff` | `0000` | data access 55,400 |
| `400000` YM2149 | `ffff` | `0000` | data access 823,898 |

Decoding an address without giving it a read value is worse than not decoding
it: `unmapped_hit` never fires, so the telemetry that exists precisely to catch
this says nothing. Both looked like correct decodes.

Fixing the watchdog moved the first divergence from 55,400 to **823,898** — a
15x improvement, and far enough that the core now matches MAME through the whole
self-test and into the frame-229 sound initialisation.

The watchdog reads back as zero (`watchdog_timer_device::reset16_r`). The reset
itself is deliberately not implemented: a watchdog that never fires is the safe
direction during bring-up, where a core that silently restarted would be much
harder to attribute than one that hangs.

### What is left, and it is a real device

The remaining divergence is the YM2149s, and they cannot be stubbed with a
register file alone, because the EEPROM hangs off them:

| line | reached via |
| --- | --- |
| CLK, DI | `eeprom_w` at `d00001` — bit 0 clk, bit 1 di |
| CS | YM2149 **#1 port B**, written at `40021e` |
| DO | YM2149 **#1 port A**, read at `40021c` |

Measured over a blank-EEPROM boot, MAME reads `40021c` **1,024 times** (1,002
zeros, 22 ones), writes CS 129 times, and clocks `d00001` about 4,000 times with
the low byte cycling 0/1/2/3 — clk and di exactly as a 93C46 expects. With a
blank EEPROM it clocks ~50,000 times, formatting it.

So the game genuinely reads data back out of the EEPROM during boot, and the
bits matter. jt49 is already vendored and exposes `addr`/`cs_n`/`wr_n`/`din`/
`dout` with `IOA_in`/`IOB_out`, so it supplies the register read-back and the
port wiring, and the sound path later. The 93C46 has to be written.

## The game boots: EEPROM and YM2149s, and the interrupts start

*Instrument: `make eetest` — MAME's own CLK/DI/CS sequence replayed against
`kaneko_eeprom93c46`, checking every value the game reads back.*

```
DTACKs      14905512
ticks/cycle 20.1
interrupts  376 taken (IRQ5 126, IRQ4 125, IRQ3 125), first at tick 199045456
```

One of each interrupt per frame, first at frame 245 — MAME's SR poll puts its
own unmask at around frame 240. explbrkr now completes its self-test, formats a
blank EEPROM, enables interrupts and runs its main loop.

### The EEPROM is not where the memory map suggests

`bakubrkr_map` decodes `d00001` and nothing else, but that is only half the
chip:

| line | reached via |
| --- | --- |
| CLK, DI | `eeprom_w` at `d00001` — bit 0 clk, bit 1 di |
| CS | YM2149 **#1 port B**, written at `40021e` |
| DO | YM2149 **#1 port A**, read at `40021c` |

So the sound chips had to go in before the EEPROM could work at all. jt49
rather than a hand-rolled register file: it already models the port direction
bits and the per-register read masks, and it is the chip this core will use for
sound anyway.

### Four things the datasheet does not tell you

Each of these was found by replaying MAME's own sequence, and each produced a
model that looked right:

- **DO idles high.** The pin is open drain with a pull-up, so outside a read it
  reads 1 (`eepromser.cpp:288`). A model that idles low agrees with **99.7%** of
  the trace, because most reads happen while data is shifting out and formatted
  contents are mostly zero. That is the shape of a near-miss that reads as
  success.
- **While waiting for a start bit, DO is the ready/busy status** — a 93Cxx
  override (`eepromser.cpp:658`), not the idle level. This is what the game
  polls after a write, and without it the core spun forever in a loop at
  `00c30a..00c31c`.
- **Every command except READ ends in a completion wait**, left only by CS
  falling, and DO reads high throughout it — *not* the ready status. Sending the
  status there reported busy where MAME reported 1, on every programming cycle.
- **Reads stream.** 93Cxx enables auto-increment, so clocking past sixteen bits
  walks into the next word (`eepromser.cpp:415`).

Timings are MAME's (`eeprom.cpp:42-45`): write 1750 us, erase 1000 us,
erase-all and write-all 8000 us. An earlier attempt measured "111.8 us" from
MAME directly and that was wrong — it timed from a later CS fall rather than
from the write.

### Two of the bugs were in the instrument, not the model

Worth recording because both produced confident, wrong numbers:

- **The replay advanced time by per-event gaps.** Each event also costs
  `settle()` ticks, so the DUT crept ahead of the machine it was copying — about
  600 us of drift over nine thousand events, expiring every 1750 us timer early
  and reporting ready while MAME was still busy. 414 mismatches that looked like
  a modelling error.
- **Then the fix double-counted.** `tick()` counted, and the advance loop added
  the same count again, so the DUT clock ran at exactly half machine time and
  every programming timer took twice as long to expire. The residual was a clean
  2x, which is what gave it away.

Reading `eepromser.cpp` settled in minutes what several rounds of hypothesis
had not. The oracle's source is as available as its behaviour, and cheaper.

Final: **20,910 checked reads, zero mismatches.**

## Save Backup RAM, and two framework assumptions that were wrong

*Instrument: MiSTer's own source — `support/arcade/mra_loader.cpp` and
`menu.cpp`, sparse-checked-out under `third_party/main_mister`.*

The 93C46 is the only non-volatile thing on this board: settings, high scores
and whatever the game calibrates on first boot. Without persistence it starts
blank every time and the game spends about four seconds reformatting it.

MRA gets `<nvram index="2" size="128"/>` — 64 words of 16 bits, index 2 being
the arcade convention. The framework then does both halves itself:

```c
arcade_nvm_load()  user_io_set_index(nvram_idx); user_io_set_download(1); ...
arcade_nvm_save()  user_io_set_index(nvram_idx); user_io_set_upload(1);   ...
```

so the core's side is `ioctl_download && ioctl_index == 2` to load and
`ioctl_upload` -> `ioctl_din` to save.

### The core has to ASK to be saved

`menu.cpp:2264`:

```c
if (is_arcade() && spi_uio_cmd(UIO_CHK_UPLOAD)) { arcade_nvm_save(); }
```

`UIO_CHK_UPLOAD` is command 0x3C, which `hps_io` answers from
`ioctl_upload_req`. So "Autosave flushes when you open the OSD" is the
framework asking the core whether it has anything to save — **a core that never
says yes never autosaves, however correctly it implements the upload.**

The first attempt here added `"R[13],Save Backup RAM;"` to the CONF_STR and
expected the player to select it. Wrong mechanism. The EEPROM now raises a
`dirty` flag on any write, erase or erase-all, and that drives
`ioctl_upload_req`. It is held rather than pulsed and cleared when the upload
completes, so a write landing during a save still produces a fresh edge.

### Reset is the other way round

There is no framework-provided reset for the core menu. `R` is a CONF_STR
option type — `menu.cpp:2126`, "check for 'T'oggle and 'R'eset (toggle and then
close menu)" — and the framework appends only `STD_EXIT`. Reset appears at the
bottom of most cores' OSD by convention, because they declare `"R0,Reset;"`
last.

So: **saves need no menu entry and reset needs one.** Both assumptions were
made the wrong way round before reading the source.

### Contents come from power-up or the loader, never from reset

Two hazards, neither of which bites today and both of which are the wrong shape
for a non-volatile part:

- The array was cleared in the reset branch. With `rst` tied to power-on that is
  harmless, but it is one wiring change from erasing the player's saves — and
  splitting `rst_por` from `rst_sys` was done precisely so a core reset could
  not. A reset loop over all 64 words also prevents RAM inference outright.
- The backup write port sat inside the reset gate. The HPS sends the save file
  the moment it parses `<nvram>`, which is *before* the ROM stream and can be
  before the core leaves reset; a load dropped there would look exactly like a
  save that never persisted.

The array now initialises to all ones at power-up — what an unprogrammed part
reads — and the backup port is outside the reset gate. Load order is safe
either way: `<nvram>` is parsed before `<rom>`, and the CPU is held in reset
until `rom_loaded`, so the EEPROM is populated before the game ever reads it.

## Block RAM inference, the second time

*Instrument: `quartus_map` alone — two minutes against the full flow's eighteen.*

Splitting the VIEW2 windows so the video side can read a tile entry and a scroll
word in the same cycle produced:

```
Error (170011): Design contains 137160 blocks of type combinational node.
                However, the device contains only 83820 blocks.
```

The same failure as the bit-slice writes earlier in the project, with the same
misleading shape — a design that looks far too big when it is one inference that
did not happen. Two causes:

- **Arrays of arrays.** `logic [7:0] ta_hi [0:1][0:1][0:1023]`, indexed three
  deep. Quartus wants one plain one-dimensional array per memory; declaring
  them inside the generate gives that naturally.
- **A read inside a mux.** The CPU read-back did
  `qch <= is_v1 ? tc_hi[...] : is_v0 ? ... ;`, which makes the address and
  enable conditional and leaves no simple-dual-port to infer. Reading each array
  unconditionally into its own register and muxing the *registered outputs*
  costs a 4:1 mux of 16 bits and gets the memory back.

Three things now known to block inference, all of which look like tidy RTL:
bit-slice writes, conditional reads, and a reset that clears every location.

Checking with `quartus_map` alone is the cheap move: it reports
`Info (276029): Inferred altsyncram megafunction ...` per array, so the question
is answered in two minutes rather than after an eighteen-minute fit fails.

### A marginal timing path is placement, not capacity

One build missed setup on the framework's HDMI output clock by 84 ps:

```
; pll_hdmi|...|divclk ; -0.084 ; -0.084 ;
```

`pll_hdmi` runs the HDMI output at 148.54 MHz through `ascal`; no core logic is
on that path. The build immediately before it had **more** logic — 12,401 ALMs
against 12,018 — and closed at zero, which is what identifies placement rather
than capacity as the cause. Changing RTL that is not on the failing path would
have been the wrong lever.

`SEED 1` to `SEED 3` closed it: -0.084 to +0.344, with the same logic and the
same memory. The seed is pinned in the .qsf so the result is reproducible
rather than re-rolled on every compile.

Two process notes from the same episode, both of which cost a build:

- **Read the whole Setup Summary.** The check that reported "zero negative
  slack" grepped for two clock names and did not cover the row that failed. A
  timing check that can only see part of the table is not a timing check.
- **`pkill -f` matches the shell that issued it.** `pkill -f "make quartus"`
  killed the command running it, twice, because the pattern appears in its own
  command line. Use `pkill -x` against exact process names.

### The VIEW2 layer control bits, corrected

Transcribing the register bank turned up a decode this project had had wrong in
two places. `kaneko_tmap.cpp` `prepare_common()`:

```cpp
m_tmap[0]->enable(BIT(~layers_flip_0, 12));
m_tmap[1]->enable(BIT(~layers_flip_0,  4));
```

| bit | meaning |
| --- | --- |
| 12 | layer 0 disable |
| 4 | layer 1 disable |
| 11 | layer 0 line scroll — selects the 0x3000 scroll window |
| 3 | layer 1 line scroll — selects the 0x2000 scroll window |
| 9 / 8 | flip X / flip Y, **both layers** |

Two errors were carried: the layer 0 disable was recorded as bit **15** (which
is unused), and flip was recorded as a per-layer pair at bits 1/0 as well as
8/9. `tools/mame_view2_census.lua` printed both, so any census taken with it
reported layer 0's enable state from a bit that never changes.

Neither had bitten, because nothing consumed the registers until now — the same
reason the register banks could store nothing and the bus traces still matched.
Both are fixed.

**The numbering runs opposite to the byte order throughout**, and this is the
part worth remembering:

| | registers | VRAM | scroll | control bits |
| --- | --- | --- | --- | --- |
| layer 0 | 2 / 3 (bytes 0x04/0x06) | byte 0x1000 | byte 0x3000 | 12, 11 |
| layer 1 | 0 / 1 (bytes 0x00/0x02) | byte 0x0000 | byte 0x2000 | 4, 3 |

So the FIRST register pair, the FIRST VRAM block and the FIRST scroll block all
belong to layer **1**, while the higher control bits belong to layer 0. Every
one of those is an opportunity to wire a layer to the wrong memory and get a
picture that looks plausible.

Scroll Y is `>> 6`; scroll X is not, because line scroll is added before the
shift: `set_scrollx(i, (layer0_scrollx + scroll) >> 6)`.

dx differs by two between the layers — `set_scrolldx(-m_dx)` for layer 0 and
`-(m_dx+2)` for layer 1 — and explbrkr's offsets are `set_offset(0x5b, -0x8,
256, 240)`. The frame gate, which is pixel-exact, passes dx positive: 0x5b for
layer 0 and 0x5d for layer 1, dy -8 for both.

### OPEN: an OSD reset still looks like it loses the EEPROM

*Reported from hardware, 2026-08-21. Not yet diagnosed.*

After an OSD reset the amber interrupt bars take four to five seconds to
appear, which is the signature of the game reformatting a blank EEPROM. A core
reset should not be able to do that: the array is initialised only by the
`initial` block at power-up, `rst_por` is the EEPROM's only reset, and the
contents are not cleared anywhere.

Candidates, most likely first:

1. **The save file is never written, so every start is a first start.** The
   framework only writes when the core answers UIO_CHK_UPLOAD, and only when the
   OSD is opened. If no save has been taken yet, a cold boot and a reset look
   identical — both find a blank part. Check whether
   `/media/fat/config/nvram/` has a file at all before concluding anything
   about reset.
2. **`bk_q` is a registered read.** `ioctl_din` follows `bk_addr` by one clock,
   and if the HPS samples as it advances the address, every word is off by one
   and the file is shifted. The game would then reject the contents on load and
   reformat — which looks exactly like a reset wiping them.
3. **A core reset does not reload.** `arcade_nvm_load()` runs when the MRA is
   parsed, not on reset, so after a reset the EEPROM keeps whatever is in RAM.
   That is correct behaviour and means a reset can only *appear* to lose data
   if the data was never right.

The distinguishing test is cheap: cold boot twice with an OSD open in between,
and see whether the SECOND cold boot is fast. If it is, reset is the problem;
if it is not, the save was never written and reset is innocent.
