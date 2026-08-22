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
kaneko_vuspr_draw: checks=524288 fails=0 passes=8/8
                   bmp_writes=368680 mask_writes=1543770 (rejected=1175090)
  stall-equivalence: 524288 pixels compared, 0 differ, 408268 stalled cycles
```

499 cells. The reference is the C++ compositor inside the frame gate, which
produces pixel-exact frames on three games — so this asks only whether the RTL
reproduces it, ordering included.

(`checks` was 2,097,152 until 2026-08-21, when the bitmap stopped being square:
one `BMP_W_LOG2` for both axes meant 512x512, and the check count is one per
pixel per pass. The write counts then doubled, because every pass now runs
twice — see below.)

### The sprite ROM is in SDRAM, so the renderer had to learn to freeze

The module was written against a ROM that answers every cycle. The sprite ROM
is 2.25 MB and lives in SDRAM behind an arbiter, so it does not. `ce` freezes
the whole pipeline — state, counters and both write strobes — and is driven
from the feeder's hit signal, the same shape as `kaneko_tmap_fetch`.

The test for it is stronger than "still matches the reference": every pass runs
twice on the same sprites, once with a ROM that always answers and once with
one that stalls 33% of the time, and **the two bitmaps must be identical**.
524,288 pixels compared across 408,268 stalled cycles, zero differ. A stall that
lost or duplicated a pixel shows up here even if both runs happened to satisfy
the reference in aggregate.

The harness change that matters as much as the RTL one: the held ROM, table and
mask addresses only advance on a cycle the module is allowed to advance.
Latching them while frozen hands stage B the byte for an address the pipeline
has not reached yet, which is a harness bug that reads exactly like an RTL
bug — the same trap recorded for the tmap fetch harness.

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

### The white flash is the game, not the core

*Instrument: a per-frame palette census in MAME.*

Reported from hardware as a bug: the whole screen flashes bright white now and
then. It is correct. MAME does the same thing, in four-frame bursts:

```
frame 305: 515/544 live entries near-white (94%)
frame 306: 515/544 ...
frame 313-316, 321-324 ...
```

The game floods the palette with near-white for four frames at a time — a
screen-flash effect. 515 of the 544 live entries go white together, which is
what makes it look like an output fault rather than a picture.

Worth keeping as a shape: a full-screen artefact that appears intermittently
looks like a video-path failure and can just as easily be the game. The census
cost two minutes and settled it; guessing at the video path would have cost a
build per guess.

### Scroll registers are read once per frame, not per line

*Reported from hardware: horizontal tearing.*

`kaneko_tmap.cpp` reads the scroll registers in `prepare_common()`, which runs
once before a frame is rendered. The core read them live out of the register
bank, so a register the IRQ handler changed mid-frame applied to part of the
screen and not the rest.

Worse than per-frame tearing, in fact: the line fetch spans about 1800 clocks,
so a single scanline was not guaranteed to be built from one set of values
either.

Latched at the start of the visible area — so the frame being drawn uses the
values the game set for it — rather than at vblank, which would use the values
from the end of the previous one.

Not yet snapshotted: the line-scroll RAM. MAME copies all 512 rows of it in the
same `prepare_common()`, and the core still reads it live per line. A game that
rewrites scroll RAM mid-frame would tear the same way. Nothing has shown that
yet, and snapshotting it costs 2048 words, so it is recorded rather than done.

### Block RAM inference, narrower than the rule already recorded

The per-layer line buffers went through three shapes before Quartus would infer
them, and only the first one produced a warning:

| declaration | result |
| --- | --- |
| `lbuf [0:1][0:H_VIS-1]` | "EDA Netlist Writer cannot regroup multidimensional array into its bus" — flip-flops |
| `lbuf [0:2*H_VIS-1]`, indexed `lbuf[{bank, x_wr}]` | **no message at all**, still flip-flops |
| `lb0`/`lb1`, plain arrays, plain address signal | inferred |

The middle case is the one worth remembering. It obeys the rule already written
down for `kaneko_vmem` — one plain one-dimensional array per memory — and still
did not infer, because the *index* was a concatenation. Quartus said nothing.

The only symptoms were the resource numbers: **26,949 ALMs against 12,412**, and
a block-memory total that fell by exactly 28,672 bits, the size of the memory
that had vanished. `kaneko_tmap_line` alone showed 14,014 ALMs in the fitter's
hierarchy report, which is how it was localised.

So the rule is narrower than previously recorded: a memory needs a plain array
AND a plain address signal. Four things are now known to prevent inference,
none of which look wrong when read:

- bit-slice writes (`mem[a][15:8] <= ...`)
- conditional reads (a read inside a mux)
- a reset that clears every location
- an array of arrays, **or a concatenated index**

And the cheap check for all of them is `quartus_map` alone — two minutes against
the full flow's eighteen — grepping for `Inferred altsyncram` per array. That
found this one before a build was spent on it.

### The SDRAM map is sized for explbrkr, and mgcrystl does not fit

`make mra SET=mgcrystl` fails:

```
kan_spr: 0x280000 bytes does not fit 0x240000
```

`SDRAM_MAP` allocates 0x240000 for the sprite region, which is explbrkr's size.
mgcrystl needs 0x280000. The map has to be sized for the LARGEST region across
every supported game, not the one that was brought up first — a per-game map
would mean the core's region base addresses change per game, and those are
compiled in.

Growing kan_spr to 0x280000 pushes oki1 from 0x4c0000 to 0x500000 and the total
to 0x600000, six megabytes of a 64 MB module. Nothing is short of space; the
work is that the bases are hardcoded in Kaneko16.sv (TROM0_BASE, TROM1_BASE,
OKI_BASE) and have to move with the map.

Deferred rather than done: the sound path is mid-debug and changing every ROM
base underneath it would confuse the two. It belongs with the per-game
configuration table, where the map should be fixed once for all four games.

### Release layout

The MiSTer convention, recorded because it is not obvious from the tooling:

```
releases/Kaneko16_YYYYMMDD.rbf        the bitstream, dated
releases/<Game> (Region).mra          one primary MRA per game
releases/_alternatives/_<Game>/...    regional variants, opt-in
```

The primary MRA appears in `/_Arcade/` on a stock install; the alternatives are
copied by hand. "Primary" is World or USA where one exists, otherwise Japan —
so Blaze On's only dumped set here is the Japan one and it sits under
`_alternatives` until a World set turns up.

`make release` builds that layout. `releases/` stays gitignored while the core
changes every twenty minutes; un-ignore it when there is a version worth
tagging. The MRAs go to MiSTer-devel/MRA-Alternatives_MiSTer only once the core
is stable enough for the official update system.

MRAs now carry `<category>`, which `arcade-organizer` uses to sort games. It is
the one field not taken from MAME — the `GAME()` line has year, manufacturer
and title but no genre — so it is a hand table in build_rom_regions.py and
should be checked by someone who knows the games.

## The OKI path is correct in simulation, so the fault is downstream

Three reports of "still no sound" with the OKI wired, and no instrument had
been read. Rule 6 says diff against the oracle, and the first question is what
the CPU actually asks for, so a 300M-tick run captured the last 40,000 bus
accesses of a real Explosive Breaker boot.

### The CPU is issuing a correct play command 99 times

Every access in the 0x400000 IO region in that window is at 0x400400:

    400400 W 0808 00ff     stop channel 0
    400400 W 8888 00ff     select phrase 0x08
    400400 W 1313 00ff     play it on channel 0, attenuation 3
    400400 R 0000 00ff     status: reads back zero

297 writes and 99 reads, the same three-byte sequence 99 times over. That is a
valid M6295 command sequence, so the CPU side is not the problem. The read is
the tell: the game polls the status byte, sees no channel busy, and re-issues.
It is stuck in a retry loop, which is why nothing plays and why nothing
*progresses* either.

Everything checked against MAME rather than assumed:

| | MAME | ours |
|---|---|---|
| chip address | `map(0x400401, 0x400401)` | `a[23:1] == 23'h200200`, LDS |
| chip clock | `XTAL(12'000'000)/6` = 2 MHz | 48 MHz / 24 |
| pin 7 | `PIN7_HIGH` | `ss = 1` |
| bank register | `oki_bank0_w<7>`, YM2149 0 port B | `ym0_iob_out[2:0]` |
| bank map | `common_oki_bank_install(0, 0x20000, 0x20000)` | `kaneko_oki_bank` |

All five agree. The odd byte at 0x400401 is the 68000's LOWER byte, so LDS and
`oEdb[7:0]` are the right lane, and the captured mask of `00ff` confirms it.

### And jt6295 starts a channel when given exactly those bytes

`sim/sound/tb_kaneko_oki.cpp` is the OKI as `Kaneko16.sv` wires it — jt6295 fed
through `kaneko_tilerom` from a modelled SDRAM — driven with the three bytes
above. It starts a channel 39 clocks later, reports status `0xf1`, and produces
samples peaking at 704 of a 14-bit range.

So every link is good against an *ideal* sample ROM, and the break is in what
the model does not capture: the real SDRAM controller's sixth port, the ROM
data actually being at 0x4c0000, or the audio output stage. Four yellow
telemetry rows now separate those on hardware — writes, ROM fetches answered,
channel busy, non-zero samples — and the first dark row is the answer.

This is the fourth time on this core that a device was "wired" without a
harness and did not work. Rule 4 already says every new RTL module ships with a
testbench; the gap here was that jt6295 is third-party, so the *integration*
around it looked like it belonged to nobody. It does not — the strobe, the byte
lane, the bank arithmetic and the ROM feeder are all ours.

### MAX_BANK is a per-game fact and was a constant

The bank clamp was written as `bank > 6 ? 6 : bank`, which is right only for a
1 MB sample region. MAME derives it:

    int max_bank = (length - fixedsize) / bankedsize;
    int i = max_bank;
    while (i < length / bankedsize)
        configure_entry(i++, &sample[length - bankedsize]);

Read from each `ROM_REGION` in MAME rather than assumed, because the first
guess here was wrong in two of four:

| set | oki1 region | max_bank | |
|---|---|---|---|
| `explbrkr` | `0x100000` | 7 | bank 7 aliases 6 |
| `wingforc` | `0x080000` | 3 | banks 4-7 alias 3 |
| `mgcrystl` | `0x040000` | 1 | banks 2-7 alias 1 |
| `blazeonj` | none | - | that board is Z80 + YM2151 |

Only Explosive Breaker carries 1 MB, so the hardcoded 6 happened to be right
for the title being debugged and wrong for the bring-up title, which has a
quarter of the samples and six aliased banks. It would have read past the
region and played the wrong sample rather than failing, which is exactly the
failure mode hard rule 9 exists for.
It is now `kaneko_oki_bank`'s `MAX_BANK` parameter, checked at ten points
against MAME's rule, and it joins the game table with everything else.

### The bug: the OKI's SDRAM port burst one word instead of four

`kaneko_sdram` chose a burst length per port from a hand-written list:

```systemverilog
function automatic logic [3:0] blen(input int unsigned p);
  case (p)
    0, 1, 2, 3, 4: blen = 4'd4;
    default: blen = 4'd1;
  endcase
endfunction
```

Port 5 was added for the OKI's sample fetch. This was not. So the OKI, alone
among six masters, got a single-word burst.

That does not fail cleanly, which is why every link in the chain reported
success. `p_dout` is 64 bits and the capture registers hold their previous
contents, so a one-word burst returns **two correct bytes and six stale ones**
— whatever the last port to use that capture slot happened to read.
`kaneko_tilerom` takes the whole 64 bits as its cache line and reports a hit,
so `rom_ok` asserted normally. jt6295 then read a six-byte phrase header out of
it to get a sample's start and stop addresses, got two good bytes and four
bytes of somebody else's tile data, and decoded a sample from nowhere.

Silence, with the CPU writing correctly, the ROM feeder answering, and the
cache hitting. Nothing in the isolated `sim/sound` harness could see it: its
SDRAM model returns all eight bytes, because that is what the protocol says.

#### Two `default:` clauses agreeing about a port neither served

The reason this survived is worth more than the fix. `sim/mem/tb_kaneko_sdram.cpp`
tested `NP = 5` while `Kaneko16.sv` ran `NPORTS = 6`, and every port accessor in
the testbench ended in

```c++
default: return d->p4_dout;
```

so a request for port 5 was quietly answered with port 4. The testbench drove
port 4 twice and never touched port 5. One silent default in the RTL and one in
the testbench, each hiding the same port, each looking correct in isolation.

Bumping the harness to `NP = 6` produced 3,954 immediate failures on p5 and
`req=0 grant=0` from the bandwidth monitor. With the port properly plumbed and
the burst fixed, all six ports serve and p5 takes a fair share of grants
(49,247 against p4's 49,280).

Both defaults are gone. The RTL has one `RD_BLEN = 4` for every read port —
there is no port that wants one word, and a write asks for a single word
explicitly at its call site. The testbench aborts on an out-of-range port
instead of aliasing it.

This is the second time this exact mirror has been wrong: a comment in the
testbench already recorded that it once claimed ports 1 and 2 burst four where
the RTL said 1, 2 and 3. A hand-maintained list in two places, checked by
neither, fails the same way every time.

#### The rule this earns

**A port count, or any other size the core picks, is a number the harness must
be forced to agree with — not one it restates.** `NPORTS` in `Kaneko16.sv` and
`NP` in the SDRAM harness were independent constants that happened to match
until they did not. Where two files must agree on a width, the test has to fail
loudly when they diverge, and `default:` is exactly the construct that stops it
failing.

`make nports-check` now enforces it, in the same shape as `qsf-check` and for
the same reason — nothing else catches two numbers drifting apart. It found two
more harnesses still on five ports the moment it was written
(`kaneko_romload_harness`, `kaneko_romstream_harness`), neither of which
exercises the read ports but both of which would have drifted the same way. It
runs as part of `make all` and gates `make quartus`.

### Confirmed on hardware

Sound plays on the board with the burst fix. The chain the four yellow rows
count is intact end to end, and the diagnosis holds: the OKI, its bank map and
its ROM feeder were all correct, and the SDRAM port beneath them was handing
out two valid bytes in eight.

Worth keeping because it was the hard part: **nothing in the sound path was
wrong.** Three rounds of "still no sound" were spent inside jt6295, the M6295
command protocol, the bank arithmetic and the byte lane, all of which checked
out against MAME. The fault was one level below the lowest layer anyone was
looking at, in a module that had passed its own tests for weeks — because its
test had been written for five ports and the core had grown to six.

The general shape, which will recur: **when every layer of a stack verifies and
the stack does not work, the fault is in the layer nobody counted as part of
the stack.** The SDRAM controller was "already working"; it was not part of the
sound investigation until it was the whole of it.

### What is NOT fixed, and is a separate problem

Frame pacing is uneven when a large detailed object is on screen. Reported on
the same build that fixed the sound, so it is not a regression from the burst
change — it was visible before and is unrelated to the OKI.

The mechanism is credible but not yet measured: `kaneko_tilerom` holds **one
eight-byte entry per layer**, so a scanline crossing many distinct tiles costs
one full SDRAM round trip per sixteen pixels per layer, and nothing hides the
latency. A flat background of one repeated tile hits the single entry across
tile boundaries and costs almost nothing; a detailed object misses every time.
That is exactly the "gets worse when the big ship arrives" the owner describes.

The 600M-tick boot run measures the 68000 at **18.4 ticks per bus cycle against
the 16 a 12 MHz part needs** — about 87% speed — with 1.8% of ROM accesses
missing the CPU's own cache. That harness deliberately hammers the video port
as the arbiter's worst case, so it is a pessimistic bound rather than a
representative figure, and it is not yet evidence. The green debug row (bus
cycles per frame) dropping as the object appears would be.

Do not fix this by guessing. Two tearing diagnoses have already been shipped on
this core that were each plausible, each fixed something real, and neither was
the symptom.

### The A/B refuted the frame-pacing explanation

When the sound fix also appeared to fix the uneven frame pacing, the obvious
story was that a device reading garbage becomes a bandwidth parasite: jt6295
working from a corrupted sample header would stream from arbitrary addresses,
miss the eight-byte cache constantly, and hammer the SDRAM every tile layer and
the 68000 share.

That story is wrong. Two 600M-tick boots of the real ROM, identical but for the
burst length on port 5 — the bug reintroduced in a scratch copy of
`kaneko_sdram` outside the repository, so nothing in the tree was modified:

| | broken (port 5 bursts 1) | fixed (all ports burst 4) |
|---|---|---|
| OKI ROM fetches | 886,728 | 886,729 |
| CPU ticks per bus cycle | 18.5 | 18.4 |
| interrupts taken | 1,477 | 1,486 |
| OKI busy clocks | 1,185,941 | 210,893,948 |
| OKI non-zero sample clocks | 633,600 | 210,079,584 |
| CPU writes to the chip | 904 | 13 |

The bottom three rows confirm the sound fix outright: the chip goes from
essentially never playing to playing continuously, and the CPU stops re-issuing
— 904 writes becomes 13, which is the retry loop ending.

**The top three refute the bandwidth story.** SDRAM fetches differ by one in
886,728. The CPU's bus rate is unchanged. The OKI was never generating extra
traffic, because an ADPCM stream's fetch rate is set by the sample clock and not
by which addresses it reads — garbage addresses stream at exactly the same rate
as good ones.

So there is no measured mechanism by which the burst fix improved frame pacing,
and the entry stays in `releases/README.md` as unresolved. The likeliest
explanation is that perceived smoothness changed when audio appeared, which is
a real effect and not evidence about the video path. It may also simply not
have recurred yet; it is content-dependent by report.

Note the limit of this instrument, per rule 6: the boot harness has **no video
path**. Its port 0 is a synthetic hammer, not four tile layers. So it can say
the OKI's traffic did not change and the CPU's rate did not change, and it
cannot say anything about tile-fetch contention. Answering the frame-pacing
question needs the whole-core frame gate that still does not exist.

### The frame pacing resolved, and no measurement explains why

Reported gone on the build that fixed the sound, and still gone on further
play. The entry is out of the release notes.

It is recorded here rather than forgotten because **nothing measured explains
it**. The A/B above shows the OKI's SDRAM traffic was identical before and
after the burst fix (886,728 against 886,729 fetches) and the CPU's bus rate
unchanged (18.5 against 18.4 ticks per cycle), so the bandwidth story was
wrong. Two candidates remain, neither tested:

- perceived smoothness genuinely changed when audio appeared, which is a real
  perceptual effect and not a fact about the video path;
- it was content-dependent and the content has not recurred.

If it comes back, start from the cyan overrun row (row 3) and the green bus
cycle row (row 1) together — overruns without a bus-cycle dip is the video
path alone; both moving is contention. And note what still does not exist: a
whole-core frame gate. Neither the boot harness nor any module harness renders
a frame through the real controller, so no simulation here can currently
reproduce a pacing fault.

### OPEN: the interrupt row occasionally reads 4 instead of 3

Reported 2026-08-21. Row 2 normally shows two adjacent lit blocks — a count of
3, one each for IRQ5, IRQ4 and IRQ3. Occasionally, for a fraction of a second,
those two go dark and the next block up lights: `100` instead of `011`, a count
of **4**. The game is unaffected.

3 to 4 is a clean increment of one, which is worth more than it looks: it is
one extra interrupt counted in that frame, not a corrupted readout. A latch
race produces exactly this and so does a genuinely doubled interrupt, so the
reading does not distinguish them — but it does rule out the counter being
scrambled.

Simulation says a steady 3: the 600M-tick boot takes 1,486 interrupts over
about 500 frames of interrupt activity, split 496/495/495 across the three
levels. So this does not reproduce in the harness.

**Do not assume the CPU is at fault.** The counter latches on `vbl_rise` and
resets in the same cycle, and IRQ5 is generated at scanline 224 — close to
where the frame boundary is drawn. A race between the latch and the last
interrupt of a frame would show exactly this: one frame counting an extra
interrupt that the next frame then does not count, with no interrupt actually
being taken twice. That is the instrument being wrong, not the thing.

Two measurements would separate them, neither done: count interrupts over 64
frames rather than one and check the total is 192 rather than looking at one
frame's value, and compare per-level counts, since a latch race would show up
in whichever level fires nearest the boundary.

## 2026-08-21 — the sprite subsystem, and three bugs the module tests could not see

`rtl/video/kaneko_spr_sys.sv` wraps the parser and the renderer and owns the
memory between and after them: the resolved table, the double-buffered bitmap
and its coverage mask, and the mixer's read port.

```
tb_kaneko_spr_sys: 65543 checks, 0 fails
  render and read back   5403 reference pixels, 0 differ, write counts exact
  double buffering       4097 of the previous frame readable mid-pass
  parity mask            0 pixels left over from the previous frame
```

Every one of the three bugs it found was in a module that already passed its
own tests. That is the point of the integration test and it is worth saying
plainly: **module tests verify a module against its harness's idea of the
world, and the bugs live in the difference between that idea and the core.**

### 1. The parser read every word of every sprite one cycle early

`tb_kaneko_vuspr.cpp` carried the line

```c++
// Synchronous read: data presented one clock after the address.
dut->ram_data = g_ram[dut->ram_addr % g_ram.size()];
```

The comment says synchronous; the code is combinational. It hands the module
the word for the address it is presenting *this* cycle. `kaneko_vmem`'s sprite
port is a registered block RAM and answers one cycle later, so against the real
memory the parser latched the attribute word as the code, the code as X, and so
on for all 1024 records.

It never showed up because the module was only ever run from reset in its own
harness, where the address happens to start at 0 and the first word is right by
luck. The subsystem test caught it on the *second* pass, where the address left
over from the first pass is not 0.

Fixed on both sides: the parser gained an `S_PRIME` state that lets the first
address settle, and the testbench now holds the address at the edge and
presents its data on the following cycle. The parser still matches MAME
exactly — 40,960 checks, identical latch counts — so the fix is
behaviour-preserving against the oracle and correct against real memory.

**This is the third occurrence of this exact trap**, and
`tb_kaneko_vuspr_draw.cpp` already carried a comment about the previous two.
Writing the warning down did not stop it happening again in a file that did not
have the warning in it.

### 2. One sprite pixel per sprite, dropped, only when the ROM stalls

The renderer's mask address is combinational from its pixel counters, and those
counters advance on the **last** cycle of a sprite. So when the sprite ROM
misses immediately afterwards — which it does, because the next sprite is
somewhere else in a 2.25 MB region — the address has already moved to the next
sprite's first pixel while stage B still owes a decision on the last one.

Reading the mask every cycle then replaces the correct answer with one for the
wrong address. When `ce` returns, the final pixel of the sprite is judged
already-marked and dropped: about one pixel per sprite, eleven per frame at
twenty-four sprites, and the pixels *downstream* of it change too, because a
mask that was never set lets a further-back sprite win. 43 wrong pixels from 11
missing writes.

The fix is one line — freeze the back surface's mask read with `ce` — and the
front surface is deliberately not frozen, because the mixer reads it every
pixel and has nothing to do with the renderer's stalls.

Worth noting what did **not** find this: the renderer's own stall-equivalence
test, which compares a stalled run against an unstalled one over 524,288 pixels
and passes. It passes because its harness advances the held mask address only
on `ce` — modelling the correct behaviour, and therefore unable to detect that
the RTL around it does not implement it. A harness that models the fix cannot
test the fix.

A wrong first guess is recorded too: the same symptom looks exactly like a
read-during-write collision, so an explicit write-first bypass was added to the
mask first. It changed nothing, which is how it was ruled out.

### 3. A sprite count of zero drew 2048 sprites

`index <= sprite_count - 1` underflows to 2047. Not hypothetical: the subsystem
uses an empty list to mean "draw nothing this frame", and the surface filled
with stale table entries instead. Guarded in `S_IDLE`.

### The mask is never cleared

Clearing 65,536 mask bits every frame is a pass the frame does not have to
spare. Each surface carries a parity bit that flips when it becomes the back
buffer, and a pixel counts as marked when its stored bit **equals** that
parity — so two frames of staleness read as clear for nothing. The bitmap needs
no clearing either, because the mixer gates on the mask. Verified: 0 pixels
left over across a swap.

## 2026-08-21 — sprites and controls in the core

`kaneko_spr_sys` instantiated, a seventh SDRAM port added for the sprite ROM,
and the mixer fed real sprite pixels instead of a hardwired zero. Controls
wired at the same time, so Explosive Breaker is playable rather than an attract
loop.

### Two guards earned their keep in one evening

`make nports-check` — written this afternoon after the OKI's port turned out to
be the one port nothing tested — fired the moment `NPORTS` went from 6 to 7 and
named all four harnesses still on 6. `make qsf-check` caught `kaneko_spr_sys`
missing from the Quartus project. Neither failure would have been visible in
simulation, and both are the class of bug that costs a build or a hardware
round trip.

### Quartus 17.0 rejects `localparam` in a parameter port list

```systemverilog
module kaneko_vuspr_draw #(
    parameter  int unsigned BMP_W_LOG2 = 8,
    localparam int unsigned AW = BMP_W_LOG2 + BMP_H_LOG2   // 17.0: syntax error
)(
```

Verilator accepts it; 17.0's parser predates SystemVerilog-2012 and does not.
Hard rule 7 says a construct 17.0 rejects is a construct to rewrite, so the
address width is written out in the ports and the localparam moved into the
body. Worth recording because the module linted clean for hours before anything
told us: **`make lint` does not check the toolchain that builds the core.**
`quartus_map` alone answers in two minutes and is the cheap check to run after
adding a module.

### The sprite surfaces infer block RAM

All five memories inferred on the first attempt — `bmp0`, `bmp1`, `msk0`,
`msk1` and the resolved table — which is not something to assume given this
core has now lost two builds to inference failures. The declaration shape is
the one the earlier failures taught: separate 1-D arrays rather than an array
indexed by buffer, plain addresses, unconditional reads into their own
registers, no reset that clears every location.

### Inputs, read from MAME and not guessed

Everything is active low, ports at `0xe00000`-`0xe00007`, and the two DIPs this
board has live in P1's **low byte** — flip screen and service. Every other
setting is in the game's own test mode, which is why the OSD has no DIP menu.

MiSTer's joystick bit order came from the firmware's own table rather than from
memory: `menu.cpp`'s `joy_button_map[]` is RIGHT, LEFT, DOWN, UP, A, B, X, Y,
L, R, SELECT, START. Start and coin accept both the named `J1` buttons and the
dedicated START/SELECT ones, because players expect both.

A `"jn,..."` line was written and then removed: this framework's firmware
matches an **uppercase** `'J'` (`user_io.cpp`), so a lowercase one is silently
ignored. Silently-ignored configuration is worse than none — it looks like it
works.

### Coin lockout: nothing to do for this game

`bakubrkr_map` has no write handler at `0xe40000`, so the four writes the CPU
makes there are unmapped in MAME as well as here. The earlier boot trace's
`unmapped 4, first at E40000` was therefore correct behaviour, not a missing
decode. Other titles in the driver do use `coin_lockout_w`, and it arrives with
their memory maps.

### The build: sprites and controls fit comfortably

```
Logic utilization (ALMs)  13,896 / 41,910  (33%)
Total block memory bits    3,177,885 / 5,662,720  (56%)
M10K blocks                  414 / 553  (75%)
```

All five timing summaries positive: setup 0.483, hold 0.174, recovery 3.557,
removal 0.486, minimum pulse width 1.041. Checked by reading each section and
counting its rows (7/7/4/4/11) — an earlier check on this core reported "all
timing met" from a parser that had matched zero rows, which is the same as not
checking.

**The sprite memory came in cheaper than budgeted and it is worth knowing why.**
The estimate was 2.28 Mbit for two 256x256 surfaces plus masks and the table;
the actual delta is 1.55 Mbit. `bmp_data <= {b_prio, 4'd0, b_colour, b_pix}`
carries four constant zero bits, and Quartus stored 12 bits per pixel instead
of 16. Splitting priority into its own narrow memory by hand had been
considered to save exactly this; measuring first rather than hand-optimising
was the right call, and the fitter did it for free.

75% of M10K is the number to watch. Sprites doubled the block-RAM demand, and
the remaining 139 blocks are what rotation, a second VIEW2 configuration and
the Blaze On board's larger surfaces have to come out of.

### Two bugs from the first hardware run of sprites

Sprites drew, which is the important part. Two faults, and both are worth
recording for what they say about the tests that missed them.

#### The sprite surface was read 16 lines too low

`kaneko_video_timing.sv` says it plainly:

```systemverilog
output logic [8:0] screen_y,     // V_START .. V_START+V_VIS-1, i.e. the
                                 // RAW scanline
```

`screen_y` already runs 16..239, in MAME's coordinate space, because
`V_START` is the visible area's `min_y`. The sprite surface is indexed the
same way — the parser folds `visarea().min_y` into every record. Reading it at
`screen_y + 16` therefore applied the offset twice and put every sprite a
sixteenth of the screen out of place.

The mistake was reasoning from the frame gate's `sy = VIS_MIN_Y + row` without
checking whether our `screen_y` was its `row` or its `sy`. It is `sy`. The
answer was in a comment on the port being read.

#### The parity mask does not clear locations nothing ever wrote

The clever version gave each surface a parity bit that flipped when it became
the back buffer, so a pixel counted as marked when its stored bit **equalled**
that parity, and two frames of staleness read as clear for nothing.

It is wrong for locations no pass has **ever** written. Those hold their
power-up 0 for ever, so they read as marked exactly when the parity is 0 — and
since the parities alternate, the untouched parts of the screen show stale
bitmap for two frames out of every four. On hardware that is a flickering field
of garbage where no sprite has ever been.

Replaced with an explicit clear: 65,536 mask writes at one per clock at the
start of every pass. A pass goes from about 27,000 clocks to 92,000, against a
frame of roughly 811,000, so it costs about 11% of a frame and buys certainty.

**The test that missed it is the interesting part.** It checked the surface
after a single buffer swap and passed, because the broken scheme has a
four-frame cycle — two good frames, then two bad — and one sample landed on a
good one. A test of "does this clear" cannot sample once: the cycle length of
whatever scheme is underneath is not visible from outside, so it has to check
**every frame, for many frames.** It now does, and would have failed the parity
version on the third frame.

#### And a third, found while fixing the second

Adding the clear introduced a new state, and the overrun counter was written
per-state — so a frame arriving during the clear went uncounted. Since the
clear is now most of a pass, that hid every overrun: the periodic-frame test
reported 0 where the truth was 6. Counting moved to "any frame arriving while
not idle", which is what the readout is supposed to mean and does not need
revisiting each time a phase is added.

### The sprite pass did not fit in a frame, and the measurement nearly lied

The hardware overlay showed one sprite overrun per frame. Measured in
simulation with an idealised SDRAM, a pass at the core's real sprite count:

```
   24 sprites      88,364 clocks
  256 sprites     308,996
 1024 sprites   1,039,364      <- a frame is 811,008
```

So it overran every frame, not occasionally. Roughly 1,015 clocks per sprite,
of which about 750 are sample-ROM round trips: a 16x16 4bpp sprite is sixteen
eight-byte rows, and each row is one miss on a one-entry cache. Sixteen round
trips per sprite is already minimal for that cache; the cost is 1024 sprites,
not the cache.

`in_clip` gated the bitmap *write* and not the *fetch*, so a sprite entirely
outside the visible area still cost 256 clocks and sixteen SDRAM round trips
for a result known in advance. `kaneko_vuspr_draw` now tests the 16x16 box
against the clip rectangle in `S_LATCH` and skips the record in two cycles.

```
 1024 records,  0% off screen   1,039,364
               50%                536,394
               90%                154,896
               95%                113,140
```

Games use a fraction of the 1024 records the hardware parses, so the normal
case is the bottom of that table. The worst case — a thousand visible sprites
— still does not fit, and that needs either a shorter round trip or several in
flight at once.

**And a near miss worth recording.** The first attempt at this measurement
reported *identical* pass times at 0%, 50%, 90% and 95% off screen, and that
was reported as "the skip does not help". It was not a result at all: the
edit that was supposed to place sprites off screen had not applied, because
the string it searched for had already been changed, so the same all-on-screen
list was measured four times.

Four identical numbers to the digit should have been the tell. **A measurement
that does not move when the input moves is not evidence that the input does not
matter — it is evidence the input did not move.** Check the knob turns before
believing the reading.

### The laser cut off early: "keep sprites on screen" was not implemented

Reported from hardware against MAME side by side — Explosive Breaker's laser
holds on screen in MAME and cleared after a frame here. It is a real device
feature, and the mistake was architectural rather than a wrong constant.

MAME clears the two sprite surfaces on different conditions:

```cpp
m_sprites_maskmap[m_buffer].fill(0, clip);        // always
/* keep sprites on screen - used by mgcrystl when you get the first gem */
if (!m_keep_sprites)
    m_sprites_bitmap[m_buffer].fill(0, clip);     // only when not keeping
```

and decides transparency from the bitmap word itself, not from the mask:

```cpp
const u16 pri = (srcbitmap[x] & 0xc000) >> 14;
const u16 pix = srcbitmap[x] & 0x3fff;
if (pix & 0x3fff) { ... }
```

`kaneko_spr_sys` gated the mixer on the **mask**, which makes anything not
drawn this frame invisible — a clear every frame whatever the game asks for.
The mask is a within-a-pass structure for first-writer-wins; the visible plane
is the bitmap, and it persists when the game asks.

Fixed: the mixer reads the bitmap and treats a zero pen as transparent, the
mask is cleared every pass, and the bitmap is cleared only when `keep_sprites`
is off. `keep_sprites` is `BIT(~data, 2)` of sprite register 0 and is held in
its own register rather than derived from the register file, because MAME only
updates it on a write to that register's low byte and starts it false —
deriving it from the stored value would make it *true* at power-up, when the
file reads zero and the inversion turns that into "keep".

The lesson is about where the design was checked. `kaneko_vuspr_draw` was
verified pixel-exact against the frame gate's compositor, and the compositor is
right — but the gate only ever renders **one** frame, so no test anywhere could
see a behaviour that is about what survives **between** frames. The whole class
of cross-frame device behaviour was outside every harness this core had.

### keep-sprites is never used by Explosive Breaker, measured

The laser was assumed to need `m_keep_sprites`. It does not. A write tap on
sprite register 0 across 2,400 frames, driven through a coin, a start and held
fire by script:

```
writes to 0x900000: 2 over 2400 frames
  4fcc  x2   bit2=1  keep_sprites=0
```

Two writes in the whole run, both with bit 2 set, so MAME's `keep_sprites` is
false for the entire game. Whatever holds the laser on screen in MAME, it is
not this. The implementation stays because it is correct against the device
and Magical Crystals does use it — MAME's comment names that game — but it is
inert here and cannot be the regression.

**The regression is therefore the off-screen skip, and the reason it is not
already known is that both went into the same build.** That is the mistake
recorded twice already on this core: two changes in one bitstream, and the
symptom cannot be attributed to either. It was recorded after the tearing
diagnoses, stated again as the reason rotation was held back from the sprite
build, and then made anyway an hour later.

The skip is not obviously wrong. It tests exact against the reference in bulk
at every off-screen ratio, and exact at nine clip boundary cases including
straddling every edge, one pixel inside on each side, and negative
coordinates. So rather than guess, it is now switchable from the OSD —
`Sprite offscreen skip` — which settles it in one build rather than two, and
lets the same build show what the skip is worth against the overrun counter.

### The 2x SDRAM clock: adapter written, NOT working yet

`rtl/mem/kaneko_sdram_x2.sv` runs the controller at 96 MHz with the core's
requesters left at 48. The core cannot follow — its critical path measures
15.74 ns, a ceiling near 63 MHz — so two clocks are required, and because both
come from one PLL at an exact 2:1 ratio this is not a clock-domain crossing:
edges are aligned and no synchroniser is needed or present.

**It does not pass yet and is not instantiated in the core.** What the harness
has found so far, all of it in the testbench or in assumptions rather than in
the controller:

1. **The acknowledge is already two fast cycles wide.** The adapter extended it
   to three "so the slow domain would not miss it", which let the slow side
   acknowledge one transaction twice and read the second time into the next
   one's data. Measured — the controller carries its own `ack_d` edge detector,
   which is the tell — and the extension removed.

2. **The first transaction counter counted levels, not edges**, so it reported
   1400 requests becoming 2800 transactions: a clean 2x that read very
   convincingly as "every request goes through twice". It was the instrument.

3. **A packed `[NP-1:0][63:0]` is exposed to C++ as an array of 32-bit words**,
   so `p_dout[1]` is port 0's upper half and not port 1. The testbench reported
   the RTL delivering one port's data to another. `kaneko_sdram_harness` had
   already solved this by flattening its ports, with a comment saying exactly
   why, and this harness did not follow it.

4. **A comment line must not begin with the simulator's name** — parsed as a
   pragma. Recorded against `kaneko_mixer.sv`; walked into again.

Three of those four were faults in the measurement, each of which produced a
plausible story about the RTL. With them fixed, capture depth 3 gives 2,573
failures of 5,602 against 5,601 before, so the remaining fault is real and
still unfound. The capture depth mattering at all is expected: the device is
clocked from the controller clock, so the read round trip moves with frequency,
which is why the core exposes four settings.

Committed unfinished and unused deliberately: it cannot affect the core, and
`make lint && make test` are green because the harness is not registered. It is
not going near hardware until it passes.

### The sprite overrun fixed by a second cache entry, not a faster clock

A pass at 1024 sprites cost about 1,015 clocks per sprite, of which roughly 750
were sample-ROM round trips — sixteen per sprite, strictly serial. The obvious
answer was to halve the round trip by doubling the SDRAM clock, and that was
proposed and started before anyone looked at *why* there were sixteen.

The sprite ROM address is `{py[3], px[3], py[2:0], px[2:1]}`, so the eight-byte
block index is `{py3, px3, py2, py1}` and the byte within it is
`{py[0], px[2:1]}`. **One block therefore holds two rows.** The renderer walks x
inside y, so row 0 reads block A then block B, and row 1 wants A again — after B
has evicted it from a one-entry cache. Sixteen misses where eight would do.

A second entry per port, filled alternately:

```
 1024 records, 0% off screen   1,039,364 -> 673,204   (frame budget 811,008)
               50%               536,394 -> 359,444
               90%               154,896 -> 122,010
```

The worst case the hardware can present — a thousand fully visible sprites —
now fits in a frame with room, where before it overran by 28%. That is the same
factor the 2x SDRAM clock was going to buy, for a parameter instead of a PLL
change, a second clock domain, an adapter and a retimed design.

Tiles stay at one entry deliberately, and the same measurement says why: a
scanline there walks seventeen *different* tiles and never revisits one, so
extra entries buy nothing. The counts confirm it — `kaneko_tilerom` reports
39,221 bursts and 315,881 stall cycles, identical to before.

**The lesson is the order of operations.** The round-trip *latency* was measured
and the fix aimed at it. The round-trip *count* was never questioned, and it was
the term with a factor of two sitting in it for free. Measuring which term
dominates is not the same as measuring whether that term is necessary.

### Confirmed: the missing laser WAS the sprite overrun

The owner proposed it and was right, against three of my own hypotheses that
were not. Worth recording how the wrong ones were eliminated, because each was
eliminated by measurement rather than by argument:

| suspect | how it was ruled out |
|---|---|
| keep-sprites inverted | a MAME write tap: sprite register 0 written twice in 2,400 frames, both `0x4fcc`, bit 2 set — `keep_sprites` is never enabled in this game |
| the off-screen skip | made it an OSD toggle; flipping it changed nothing |
| the mixer reading the bitmap | never needed testing — the cache fix resolved it first |

The mechanism fits exactly. A pass that overruns its frame means the sequencer
ignores the next `frame_start`, so **sprite RAM is sampled every other frame**.
A laser that exists in RAM for a frame or two is then simply not seen — not
drawn wrongly, absent. That is why it looked intermittent, why it appeared to
"clear early", and why it tracked changes in pass duration rather than anything
in the drawing.

The lesson for the next one: the symptom was *a sprite is missing*, and every
hypothesis I formed was about the sprite pipeline — the parser, the clip, the
mask, the mixer. None was about **whether the pipeline ran often enough**. The
owner's was, and the owner's was right.

### The remaining 1.5%

Reported at about 1.5% of frames over a ten-minute run — roughly 530 of 35,500.
Simulation says the pathological case, 1024 fully visible sprites, now takes
673,204 clocks of an 811,008 budget: 83% used, 17% spare. Real content is
lighter than that but the simulation models a fixed 18-clock SDRAM latency with
no contention, and the board has seven ports competing, so the spare is thinner
in practice than on paper.

Sixteen fetches per sprite is now the floor, not an inefficiency: a 16x16 4bpp
sprite is 128 bytes and a block is 8, so all sixteen must be read. The
one-entry cache was doing **thirty-two** because the A,B,A,B walk evicted each
block before the next row wanted it; two entries brought it to the minimum.

Reducing it further means not waiting for each fetch rather than making fewer:

- **Pipelining.** A sprite's sixteen block addresses are a deterministic
  function of `(code, xx, yy)`, so the next can be requested before the current
  arrives. Two outstanding requests would hide most of the round trip. Contained
  in `kaneko_tilerom`, no clocks touched.
- **The 2x SDRAM clock.** Halves every round trip everywhere, not just here, but
  needs the PLL work, the adapter that does not yet pass, and a retimed design.

Pipelining first, on the same reasoning as last time: it is the cheaper of the
two and it addresses the term that actually dominates.

### Sprite ROM: two ports, and the pattern that says why

Enumerating all 256 pixels of a sprite in the order the renderer draws them
gives the block sequence outright, rather than by argument:

```
0 4 0 4  1 5 1 5  2 6 2 6  3 7 3 7  8 12 8 12  9 13 9 13  ...
   16 distinct blocks, 32 visits
```

Two facts fall out, and both are structural rather than statistical:

1. **Bit 2 of the block index — address bit 5, "is x past 8" — splits the
   sixteen blocks into two halves that never mix.** So an entry per half needs
   no replacement policy at all: an address selects its entry. The two-entry
   cache added earlier was really this, discovered from its effect rather than
   its cause.

2. **Each row pair uses one block from each half, alternating.** Held in two
   entries the alternation is free, and the cost is the two fetches at the
   start of each pair — which a single port makes serial.

A port per half makes them concurrent, and it also prefetches without
predicting anything: while the renderer draws from the first half, the second
half's entry is already fetching the block it will want, because that block's
address is a function of the address already presented.

```
 1024 records, 0% off screen   1,039,364 -> 673,204 -> 501,340
               50%               536,394 -> 359,444 -> 276,620
               90%               154,896 -> 122,010 -> 106,575
                                                   (budget 811,008)
```

The worst case the hardware can present now uses 62% of a frame where it
started at 128%. Half the remaining time is the mask clear, which is a fixed
65,536 clocks and the next thing worth attacking if this is ever short again.

`kaneko_tilerom`'s `LINES` parameter is left at its default of 1 and the tile
path is untouched — 39,221 bursts and 315,881 stall cycles, unchanged. Tiles
walk seventeen different tiles per scanline and revisit none, so neither the
second entry nor a second port would buy anything there.

## 2026-08-21 — the game table, and a gate that had been red without anyone looking

Magical Crystals is the cheap second title: no Z80, no MCU, and its map is the
same set of windows as Explosive Breaker's at different addresses. Every window
that moves does so on a 64 KB boundary and keeps its size, so the movable part
is exactly `a[23:16]`:

```
             explbrkr   mgcrystl        size
  work RAM     0x10       0x30          64 KB
  VIEW2 0      0x50       0x60          16 KB
  VIEW2 1      0x58       0x68          16 KB
  sprite RAM   0x60       0x70           8 KB
  palette      0x70       0x50           4 KB
  watchdog     0xa8       0xa0
  inputs       0xe0       0xc0
```

ROM, both YM2149s, the OKI, all three register blocks, the coin lockout and
the EEPROM are at the same address in both. The input bit layouts are
identical too — `DSW_P1` is `P1` under another name — so only the page moves.

The game id arrives as MRA `<rom index="1">`, one byte, before the ROM stream.
`SDRAM_MAP` grew so a single layout serves both: `kan_spr` is 0x240000 on
Explosive Breaker and 0x280000 on Magical Crystals, so the slot is the larger
and the smaller game leaves its tail zero-filled. `oki1` moved to 0x500000 with
it, which makes the RBF and the MRA a matched pair from here on.

### The gate had been red for hours

```
before          after
mgcrystl 74.6%  99.48%
explbrkr 96.9%  100.00%
blazeonj 100%   100.00%
wingforc 74.4%  100.00%
```

`make gate` was run for the first time since the parser gained its `S_PRIME`
state and three of four games had regressed. The cause was the same trap as
ever — `tb_kaneko_frame.cpp` feeding the parser sprite RAM combinationally
while `kaneko_vmem`'s port is synchronous — and it is the **fourth** occurrence
in this repository.

What makes this one different is that it was already known. `tb_kaneko_vuspr.cpp`
had been corrected for exactly this, in the same change that added `S_PRIME`,
and the second harness was simply not thought of. Hard rule 9 says to run
`make gate` before committing any change to shared video code, and it was not
run — for several commits and four hardware builds.

The rule did not need discovering. It needed following. The lesson is narrower
and more useful than "model memories correctly": **when a fix is applied to one
harness, the same fault is in every other harness that models the same thing**,
and the multi-game gate is what finds them.

### The sprite surface is 320 wide, and 320 is not a power of two

Blaze On and Wing Force are 320 pixels wide; Explosive Breaker and Magical
Crystals are 256. One bitstream serves all four, so the surface is the wider of
them and Explosive Breaker uses 256 columns of it.

That breaks the address. `{y, x}` concatenation only works for a power-of-two
width, and the two ways out are not equal:

- **Round up to 512.** 512 x 256 x 12 bits, twice over for the double buffer,
  does not fit in 553 M10K beside the tile path, the palette, the work RAM and
  the Z80's ROM still to come.
- **`y * BMP_W + x`.** With a constant width this synthesises to shifts and an
  add — 320 is 256 + 64 — so the honest address is also the cheap one.

Both testbenches were changed with it, and the reason is worth stating: a test
that concatenates agrees with a DUT that concatenates, and both are wrong on a
320-wide screen. The width is now a named constant in the testbenches with a
note that it must match, rather than a shift amount that silently works out.

The clear grew with the surface, 65,536 to 81,920 clocks, and the worst case
still fits comfortably:

```
 1024 fully visible sprites, 320-wide surface   517,724 of 811,008
```

Gate unchanged on all four games, and `kaneko_vuspr_draw`'s stall-equivalence
still exact at 655,360 pixels compared.

## The Blaze On board: what it actually needs, read from MAME

Gathered while a build ran, so that resuming does not mean deriving it again.
The Z80 subsystem is done; everything below is not.

### It is a different PCB, not a different ROM

The driver file carries **12 machine configs, 9 memory maps and 5 state
classes**. A Neo Geo core runs any cartridge because every cartridge meets the
same board; this chipset is a family, closer to System 16 or CPS1. The 68000 is
the one part that does not change.

|  | explbrkr | blazeon |
|---|---|---|
| VIEW2 tilemap chips | two | **one** |
| sound | 2x YM2149 + OKI | **Z80 + YM2151** |
| EEPROM | yes | **none** |
| screen | 256x224 | **320x232** |
| sprite records | 1024 | **512** |
| sprite offsets | 0, 0 | **0xf980, 0** |
| sprite priorities | {8,8,8,8} | **{1,2,8,8}** |
| VIEW2 offset | 0x5b, -0x8 | **0x33, 0x8** |
| work RAM | 0x100000 | 0x300000 |
| palette | 0x700000 | 0x500000 |

### The memory map falls out of the page scheme

```
  work RAM   page 0x30      palette    page 0x50
  VIEW2 0    page 0x60      sprite RAM page 0x70, 4 KB (512 records)
  inputs     page 0xc0      sound latch 0xe00000, even byte
  second VU-002 regs at 0x980000 are plain RAM in MAME — the known gap
  no EEPROM, no watchdog, no YM2149, no OKI
```

Only the sound latch needs a new decode. The rest is table entries.

### The inputs do NOT just move

This is the part that is more than a page. On Explosive Breaker start and coin
are in SYSTEM; on Blaze On they are in the **P1 and P2 words**:

```
  DSW2_P1  c00000   low byte  difficulty, lives, demo sounds, service DIPs
                    b8-13     P1 up/down/left/right/B1/B2
                    b14 START1   b15 COIN1
  DSW1_P2  c00002   low byte  Coin_A, Coin_B DIPs
                    b8-13     P2 controls
                    b14 START2   b15 COIN2
  UNK      c00004   unused
  SYSTEM   c00006   b13 service   b14 tilt   b15 service coin
```

And Blaze On has **real DIP switches** — difficulty, lives, demo sounds,
coinage — where Explosive Breaker configures everything in its test mode. So
the OSD needs a DIP menu for this board, and the input word assembly is
per-game rather than one layout at a movable address.

### Still to do

1. Video timing for 320x232, and the tile line buffer from 256 to 320
2. Game-table entries: pages, one VIEW2, 512 records, offsets, priorities, dx/dy
3. Sound latch decode at 0xe00000
4. Z80 ROM source — 48 KB of the 128 KB region is mapped; in M10K that is about
   40 blocks against 139 free, and the 320-wide surface has already taken some
5. Per-game input assembly and a DIP menu
6. Audio mixing: YM2151 stereo alongside the existing mono path

Done already: the Z80 subsystem, the CPU ROM regions, the SDRAM map sized for
all four games, and the 320-wide sprite surface.

## 2026-08-22 — a working game broken for an unimplemented one

Explosive Breaker went to a black screen with no CPU activity. The cause was
not a bug in the sense of a wrong line; it was a decision.

The SDRAM layout was one shared map with regions packed nose to tail. Making
room for Blaze On's larger regions — **for a game that does not run yet** —
moved every region after `maincpu`, which changed the MRA of a game that
worked. The RBF and the MRA became a matched pair, the pair was split, and the
board went dark.

Two things were wrong and only one of them was the layout.

### A working artefact does not get churned for a speculative one

There was no need to touch it at all. SDRAM is 32 MB and 5.75 were in use;
`audiocpu` could have gone above the last region and the others grown upward
into space nothing occupied. Repacking was tidier and bought nothing.

### And the layout should never have been shared

Each game already has its own MRA and its own row in the core's game table, so
there is no reason for them to share offsets. The bases are per game now and
**the `explbrkr` column is a fixed contract**: it is what its shipped MRA
already uses, and it does not change to tidy it, align it, or make room. A new
game can no longer disturb an existing one, which is a property rather than a
promise to be careful.

### The verification that was quoted as reassurance was worthless

"It boots in simulation" was said, with a real boot to point at. The boot
harness runs `NPORTS = 6`; the core runs 8. So the boot was verified against a
memory system with two fewer requesters — and the missing two are the sprite
ROM's, the heaviest in the design, sixteen round trips per sprite across a
thousand sprites a frame. The CPU is the port that starves when contention
rises, and contention was exactly what was not modelled.

`make nports-check` — written this afternoon *specifically* to catch a port
count drifting between core and harness — matched `NP = n` and not
`NPORTS = n`, so it reported "NPORTS=8 everywhere" the entire time. **A guard
that names the thing it checks has to match the spelling actually used.**

Both fixed: the guard matches either spelling, and the boot harness now
instantiates the real sprite subsystem on its real ports, so a boot verified
there is verified under the contention the board actually has.

## 2026-08-22 — the black screen is INTERMITTENT, which invalidates the hunt

`cb481bcc` black-screened, was replaced with a known-good build, was put back
unchanged an hour later, and booted. Same RBF, same MRA, opposite results.

That single fact undoes most of a night's reasoning. Every theory below was
formed on the assumption of a deterministic fault, and each was tested by
changing something and seeing the screen stay black:

| theory | how it was "tested" | what the test was actually worth |
|---|---|---|
| MRA config byte | removed it, still black | nothing |
| SDRAM map resize | reverted it, still black | nothing |
| reader contention during load | gated readers, still black | nothing |
| sprite path | kill switch, still black | nothing |
| address decode | reverted it, still black... then it booted | nothing |

**A single failing observation cannot exonerate a change when the fault is
intermittent.** Five changes were cleared on exactly that evidence, and none of
them were actually cleared. The bisect that was about to start would have
inherited the same flaw: a build that boots once proves nothing, and three
builds of that is three wasted hours.

The tell was there and was missed. Every theory was endorsed by simulation and
refuted by hardware, five times running. That pattern does not mean five wrong
guesses about logic — it means the fault is not in logic at all. Something that
passes every simulation and varies between identical bitstreams is timing,
placement, or the analogue behaviour of an interface.

### The candidate, already documented in this repository

`rtl/pll/pll.v` says it outright, written when the SDRAM clock was HALVED to
buy margin rather than fix the cause:

> at 80 MHz the device is clocked on the inverse of the controller clock, which
> gives it only a half period of skew and no true phase shift ... if the data
> comes back correct the cause is timing and the fix is a properly
> phase-shifted SDRAM_CLK

`SDRAM_CLK` is still `~clk_sdram`. The interface has no proper constraint, so
static timing analysis cannot see it and never fails. Adding an eighth port
grew the arbiter; every build since has had a different placement; and a
marginal interface boots or does not depending on where the fitter happened to
put things.

That also explains why the OSD carries a `SDRAM capture` option with four
settings at all. It exists because this was suspected once before.

### What would settle it, in order of cost

1. **Power-cycle the same bitstream several times.** If it boots some times and
   not others, it is confirmed without building anything.
2. **Sweep `SDRAM capture`.** If a different capture phase boots a bitstream
   that otherwise does not, confirmed.
3. **Checksum the ROM in SDRAM after loading** and show it on the debug
   overlay. Turns "black screen" into "the ROM arrived corrupt", which is a
   fact rather than an inference.
4. **Drive `SDRAM_CLK` from the spare PLL output with a real phase shift.**
   `outclk_2` is sitting unused at 48 MHz. This is the fix the note names, and
   it is also the prerequisite for the 2x SDRAM clock that would give the
   sprite renderer room.

## 2026-08-22 — the Blaze On board, finished in RTL; and an MRA that lied about which game it was

### The three items, and which one was real

Two of the three remaining Blaze On items were constants that had been left
compiled-in, and closing them was mechanical:

- **One VIEW2 chip.** The Blaze On board has one, not two. Layers 2 and 3 are
  now masked off when `two_chips` is low, so an absent chip cannot paint —
  previously the second chip's registers read as zero and its layers were
  *enabled*, because enable is active low.
- **Tile line buffer 256 -> 320.** The buffer is now sized 320 (the widest
  board) with the fetch width supplied at runtime as `h_active`, so Explosive
  Breaker still fetches exactly 256. Buffer size and fetch count are two
  different numbers and conflating them is what made this look like a
  parameter change.

The third was not a constant at all.

### The inputs do NOT just move, they are assembled differently

This is worth stating plainly because "per-game" had until now always meant "a
different number in the table". Here it means a different wiring:

```
  explbrkr / mgcrystl          blazeon / wingforc
  P1     b0    flip DIP        DSW2_P1  b0-7  difficulty, lives, demo, service
         b1    service DIP              b8-13 P1 up/down/left/right/B1/B2
         b8-13 P1 controls              b14   START1      b15  COIN1
  P2     b8-13 P2 controls     DSW1_P2  b0-7  Coin_A, Coin_B
  SYSTEM b8  START1                     b8-13 P2 controls
         b9  START2                     b14   START2      b15  COIN2
         b10 COIN1             UNK      unused
         b11 COIN2             SYSTEM   b13 service  b14 tilt  b15 service coin
         b12 service
         b13 tilt
         b14 service coin
```

Start and coin are in SYSTEM on one board and in the player words on the other.
So the core builds both words and selects with `inputs_blazeon`; there is no
arrangement of offsets that turns one into the other. Everything is active low
on both boards. Blaze On also has REAL DIP switches where Explosive Breaker
configures itself through its test mode, so those bits come from the OSD.

### The MRA said the game was Explosive Breaker

The Blaze On and Wing Force MRAs already on the device emitted a game-id byte
of `00`. That is Explosive Breaker.

`GAME_ID` in `tools/build_rom_regions.py` had two entries — `explbrkr: 0` and
`mgcrystl: 1` — and the emitter reads it as `GAME_ID.get(setname, 0)`. A game
missing from the table does not fail; it silently becomes game zero. So the
core would have loaded Blaze On's ROMs into SDRAM correctly and then
configured itself as a different PCB: wrong memory-map pages, wrong ROM bases,
wrong geometry, wrong layer count, wrong input wiring.

**A hardware test of Blaze On would have failed for a reason that had nothing
to do with any of the RTL above**, and the obvious place to look would have
been the new code. The comment in the file even says the two tables "are
checked against each other by nothing".

The `.get(setname, 0)` default is the same shape of fault as the SDRAM burst
`default:` that hid the OKI silence and the harness `default:` that hid the
port count: **a default that produces a plausible value instead of an error.**
Three times now. The rule is in `CLAUDE.md`; this is its third incident.

### State

`make gate`, main tree, after all of the above:

```
GAME          FRAME     DIFF     MATCH
mgcrystl        600      298  99.4803%
explbrkr        900        0 100.0000%
blazeonj        600        0 100.0000%
wingforc        600        0 100.0000%
```

`SUPPORTED` now carries `explbrkr`, `blazeonj` and `wingforc`. Both new titles
run **silent** — the Blaze On board is Z80 + YM2151 and neither is wired. That
is a stated limitation, not a bug, and it is the next piece of work.

### The Z80 program ROM goes in block RAM, not on an SDRAM port

`kaneko_z80snd`'s ROM contract is "data one clock after the address". That is
what a Z80 fetch wants and it is not something SDRAM can offer. Every other ROM
consumer in this core either bursts ahead with a scanline of slack (the tile
and sprite fetchers) or stalls its CPU through DTACK (the 68000). The Z80 has
no wait state wired, so serving it from SDRAM would mean inventing one, adding
a ninth port and a cache — to deliver 48 KB that fits in 39 M10K blocks.

So `kaneko_z80rom.sv` holds it in block RAM and fills it by **snooping the
loader's SDRAM write port** during download. The tap is already the final
address and the final data, so nothing in there has to know what the MRA
emitted or in what order. Cost is 393,216 bits, about 7% of the device.

Byte order was derived rather than guessed, because all three ways of getting
it wrong produce a ROM of exactly the right size:

    the loader stores stream byte N at SDRAM byte N and does not swap
    the 68000 path reads {W[7:0], W[15:8]} to get a big-endian word
    a big-endian word at even address A is {byte[A], byte[A+1]}
    => byte[A] = W[7:0]   and   byte[A+1] = W[15:8]

The harness fills all 49152 bytes with a pattern whose period is not 256 — a
plain ramp cannot distinguish an offset of 256 bytes from no offset at all —
surrounds the region with words that must not land, and reads every byte back.

### The sound latch is the EVEN byte, and reads of it are an IRQ acknowledge

    map(0xe00000, 0xe00001).nopr();                     // "Read = IRQ Ack ?"
    map(0xe00000, 0xe00000).w(m_soundlatch, ...);       // EVEN byte only

An even byte on a big-endian 68000 is the UPPER half of the word, so the write
is qualified by UDS and never by LDS. Taking a word write as two bytes would
send the low half as a second, spurious command. The read side is decoded and
given a value of zero, because a decoded address that returns nothing has cost
this core three separate sessions.

### An unconnected harness input is the same bug as a default

Adding `pg_snd` to `kaneko_bus` surfaced that the CPU harnesses connect NONE of
the `pg_*` window pages — they tie to 0 and every window decodes at page 0x00,
which is where the ROM lives. Those harnesses only exercise ROM reads and
unmapped accesses, so it has never mattered, but a new page defaulting to 0
would have put the sound latch on top of the reset vector.

`pg_snd` is now driven explicitly in both harnesses. **The remaining pages are
still unconnected and should be wired to a real game's map**; that is left as
its own change because it will move the CPU gate's `unmapped` count and that
number wants moving deliberately, not as a side effect.

## 2026-08-22 — the Blaze On black screen: a game table connected to nothing

Explosive Breaker good on hardware, Blaze On black, same bitstream. Two
faults, and the first one is the more alarming.

### The per-game memory map drove nothing for eleven commits

`kaneko_gamecfg` computes seven window pages — work RAM, both VIEW2 windows,
sprite RAM, palette, watchdog, inputs — and `kaneko_bus` declares an input for
each. Commit b1d343f, "Wire the per-game configuration module into the top
level", added the module and its output wires and **left the bus's inputs off
the instance**. The wires went nowhere. Quartus tied every page to GND, so
every window decoded at page 0x00, which is where the ROM lives.

Quartus reported it on every build since:

```
; pg_wram ; Input ; Warning ; Declared by entity but not connected by instance.
;                             If a default value exists, it will be used.
;                             Otherwise, the port will be connected to GND.
```

Seven of those, in `build/quartus/Kaneko16.map.rpt`, in a 2 MB report nobody
reads. Verilator's `PINMISSING` catches exactly this and says so in one line —
but the top level is never verilated, because it instantiates VHDL (T80) and
vendor IP (pll, hps_io), so the only instrument that could see it was the build
report.

`make quartus` now greps for that warning and fails the build. It is the only
place this class of fault can be caught in this design.

**Unresolved, and recorded rather than glossed:** by this reading Explosive
Breaker should not work either, and it demonstrably does — loaded repeatedly on
hardware. The boot harness with the pages forced to zero shows EB running a
tight loop rather than the game, which agrees with the theory and disagrees
with the board. That contradiction is not explained. The hardware test of the
fix is the experiment that settles it: if EB survives, the sim's model of the
broken case was simply wrong; if EB breaks, it was depending on the page-0
decode and that needs understanding before anything else ships.

### The program ROM window is a per-game SIZE

```
  bakubrkr_map  map(0x000000, 0x07ffff).rom()    512 KB
  mgcrystl_map  map(0x000000, 0x07ffff).rom()    512 KB
  blazeon_map   map(0x000000, 0x0fffff).rom()      1 MB   (Wing Force too)
```

It was 512 KB for every game. Blaze On carries a full megabyte of 68000 code,
so every fetch above 0x07ffff fell through to the unmapped path, was
acknowledged, and returned nothing.

Widening it for all games was tried once and blacked out Explosive Breaker,
because that game's SDRAM layout puts view2_0 at byte 0x080000 — a read there
returns tile graphics, not the zero-fill the reasoning assumed. The comment
left behind at the time said it "becomes a per-game page when the Blaze On
board actually lands, not before". It has landed.

### The boot harness could not have caught either one

`sim/top/kaneko_cpumem_harness.sv` connected NONE of the pg_* pages, so it ran
every game with the same broken decode the bitstream had — a harness that
agrees with whatever it is handed reports success either way. It now
instantiates `kaneko_gamecfg` and feeds it the MRA's config byte through the
same ioctl stream the real core uses, and `make boot SET=<game>` passes the
game id from the set name.

With that in place all three supported titles reach their main loop:

```
  explbrkr   105277 DTACKs   4 unmapped
  blazeonj   114555 DTACKs  13 unmapped
  wingforc   114546 DTACKs  26 unmapped
```

The unmapped accesses are all at 0xe40000 and above, which MAME has as
`nopr()` IRQ acknowledges on this board. They are acknowledged and harmless;
decoding them explicitly is a separate change.

### Blaze On, second pass: the CPU runs and takes no interrupts

The overlay, decoded against the source rather than eyeballed:

```
  row 0  green  20 bits  bus cycles per frame     -- BITS SET, CPU executing
  row 1  amber   8 bits  interrupts acknowledged  -- ZERO
  row 2  cyan   16 bits  line-fetch overruns      -- zero
  rows 4-7 yellow        the OKI chain            -- zero, no sound wired
  row 8  white  16 bits  sprite overruns          -- zero
  row 9  magenta         live joystick word       -- zero, nothing pressed
```

A running 68000 with zero acknowledged interrupts is one with them masked: it
is stuck in early init, before the game enables them. The IRQ path itself is
not implicated — `kaneko_irq` compares raw `vcnt` against 224/144/64 and
`V_TOTAL` is a fixed 264, so the levels fire whatever the per-game geometry is,
and simulation confirms 47 of each per second.

### ROMREGION_ERASEFF, and a fill byte that is a per-game fact

```
  ROM_REGION( 0x100000, "maincpu", ROMREGION_ERASEFF )
  ROM_LOAD16_BYTE( "bz_prg1.u80", 0x000000, 0x040000, ... )
  ROM_LOAD16_BYTE( "bz_prg2.u81", 0x000001, 0x040000, ... )
```

512 KB of program in a 1 MB window, and MAME fills the rest with **0xFF**.
`tools/build_rom_regions.py` padded every region with `00`. `blazeon_map` maps
the whole megabyte as ROM, so the game can read up there, and a checksum over
the region gets a different answer from 0x00 than from 0xFF.

It is the only Tier 1 region with the flag — explbrkr's is exactly filled,
mgcrystl's says `ROMREGION_ERASE` (zero), wingforc's 1 MB is fully populated by
two 512 KB ROMs. So the table has one entry, and the stream hashes confirm the
scope: blazeonj's changed, the other two are byte-identical.

**This is a real fix and it is NOT known to be the black screen.** The boot
harness produces byte-identical behaviour with either fill, because the CPU
does not read above 0x080000 in the window simulated. Corrected because MAME
says so, not because it was measured to matter.

### The instrument, because static reading had already been wrong twice

`kaneko_bus` reports the address of any unmapped access and the top level threw
it away. Two rows added:

```
  row 10  orange  unmapped accesses this frame, 16 bits
  row 11  blue    address of the last one, a[23:8], HELD until the next
```

Held rather than sampled per frame: a stuck CPU asks for the same thing every
time, and a value that survives to the next frame is one a photograph can read.

An unmapped access is acknowledged, so it never hangs the bus — it returns a
value the game did not expect, which is invisible unless the address is
reported. The standing suspect is `map(0x980000, 0x98001f).ram()`, the second
VU-002's register block, which MAME backs with plain RAM because the game
touches it and this core does not decode it at all. If that is it, row 11 reads
`9800`.

### The boot harness disagreed with hardware, and that was its own bug

`kaneko_cpumem_harness` left `kaneko_video_timing`'s geometry inputs
unconnected — the same class as the memory-map pages, tied to 0, giving a
visible area of zero height and a `vblank_rise` that never fires. Wired from
the game table. It did not reproduce the fault, but a harness that disagrees
with hardware about the thing being debugged cannot be used to reason about it.

Verilator's PINMISSING would have caught this too; the harness build passes
`-Wno-fatal`, so it was a warning in a wall of warnings. Unlike the Quartus
case there is no guard for it yet.

### The overlay's blue channel was hardcoded off

```
  wire [7:0] out_b = in_dbg ? 8'h00 : src_b;
```

Every blue component of every debug row was discarded. The cyan overrun row
rendered green, the white sprite row yellow, the magenta joystick row red —
three rows documented by colour and none of them that colour. It never showed
because all three read zero and a CLEAR bit is dark red whatever the row's
colour is, so the fault only becomes visible the moment a bit is set. Found
while checking why two new rows did not draw, which is the only reason it was
found at all.

### Two rows that should have drawn, did not

Rows added at scanlines 92 and 100 do not appear on hardware, while the row at
82 does. The RBF on the board was checksum-verified as the one built, the rows
are in the source at that commit, and they survive synthesis — they are in the
netlist and not reported stuck or synthesized away. The visible area is 232
lines for this board and the frame gate renders all 232 pixel-exact, so
scanlines 92 and 100 are inside it.

**Unexplained.** Recorded rather than guessed at, because three separate
theories about this core's video path have already been wrong this session and
each one cost a build.

Rather than spend another twenty-five minute build finding out, the diagnostics
moved into rows that demonstrably render and that carry nothing on this board:

```
  row 4  first of the four OKI rows   CPU's last bus address, a[23:8]
  row 8  was sprite overruns          unmapped accesses this frame
  row 9  was the joystick word        address of the last unmapped access
```

The row-4 commandeering is what makes the build informative when NOTHING is
unmapped: a stuck 68000 loops over a handful of addresses, so one photograph
lands inside the loop and names the routine. Without it, "no unmapped
accesses" would have cost a whole build to learn nothing. The rows at 92 and
100 are left in place, because whether they come back is itself a datum.

### The MAME oracle clears the CPU and kills the best theory

`make bustrace SET=blazeonj` — 100,000 bus accesses, ours against MAME's, same
four-column format, diffed. `blazeonj` verifies good against MAME (it is a
clone of `blazeon`, so the ROMs are found in the parent zip even though the
parent itself is missing its PLD dumps), so the oracle genuinely runs for the
title being debugged — the check hard rule 6 exists to force.

```
  region                    ours     mame
  work RAM  300000         32643    32643
  palette   500000          4096     4096
  VIEW2 v   600000          1954     1956
  spriteram 700000          4096     4096
  sprite r  900000            32       32
  view2 r   800000             7        7
  rom                      57157    57155
```

The VIEW2 register writes match value for value. The palette is written 2048
times with 0x0000 in BOTH — the game is clearing it, so a black screen at this
point in boot is what MAME shows too.

**The 68000, the memory map and the register decode are correct.** Whatever
breaks Blaze On is not in the part this session spent its time rewriting.

Two results worth having:

- **0x980000 is written and never read.** All ten accesses are writes, in both.
  The second VU-002 register block not being decoded is harmless, and the
  standing theory that a read-back there was hanging the game is dead. It would
  have cost a build to learn that on hardware.
- **Neither `rom_1mb` nor the ERASEFF fill was the black screen.** Neither our
  CPU nor MAME's reads above 0x080000 at all in 100k accesses. Both changes are
  correct against MAME and both are irrelevant to this fault. They stay because
  they are right, not because they did anything.

One genuine defect found: reads of 0xe40000 return 0xFFFF from us and 0x0000
from MAME, whose `nopr()` returns zero. It is the first and only value
divergence in 100k accesses and it caused no change of path, but it is wrong,
and it is an IRQ-acknowledge address on a machine whose symptom is zero
interrupts. Fixed separately from the instrument build — one kind of change at
a time.

Beyond ~100k accesses the two drift (sprite RAM 9568 against 11996 at 500k),
which is expected and not evidence: this core runs 264 lines at 59.19 Hz and
MAME's screen is a different height at 60 Hz, so the two reach scanline 224 a
different number of instructions apart. The Makefile already documents 100k as
the meaningful window.

### The missing overlay rows are probably the same fault, seen from the video side

Rows at scanlines 16 through 87 render. Rows at 92 and 100 do not. That is the
signature of an ACTIVE AREA about 90 lines tall instead of 232 — not a
coincidence and not an overlay bug. It is independent evidence pointing at the
video geometry, which is exactly where the CPU trace cannot see.

The frame gate renders blazeonj at 320x232 pixel-exact, but it drives
`kaneko_frame_top`, which sets geometry directly rather than through
`kaneko_gamecfg` and `kaneko_video_timing` the way the core does. So the gate
does NOT cover the path the hardware uses, and the one number both symptoms
point at is the one number nothing tests end to end.

Wing Force is the free control: same board, same one-VIEW2 configuration,
`v_vis` 224 rather than 232. If it truncates the same way the fault is
board-wide; if it does not, it is specific to 232.

## 2026-08-22 — Blaze On has CRASHED, not stalled: it parks in its exception handler

The overlay diagnostics landed and every row except bus cycles read zero. That
is not a dead instrument, and the proof is that `bus_cycles_lat` is latched on
`vbl_rise` exactly like every other row — so a non-zero bus-cycle count means
the latch fires and the zeros are real.

Decoding row 0 from the photograph: 20 bits, MSB left, blocks 4, 6 and 7 lit =
bits 15, 13, 12 = **45,056 bus cycles per frame**. A 12 MHz 68000 gets ~202,700
clocks per frame at 59.19 Hz, so at ~4.5 clocks per bus cycle that is a CPU
running absolutely flat out.

So the measurement was:

```
  bus cycles          45056 per frame, full speed
  interrupts              0
  unmapped accesses       0
  last bus address        a[23:9] == 0, i.e. below 0x200
```

### The ROM says exactly where it is

```
  vec  0 @ 0x0000 -> 0x0030fd80      (SSP)
  vec  1 @ 0x0004 -> 0x0000024a      (reset PC)
  vec  2 @ 0x0008 -> 0x00000100
  vec  3 @ 0x000c -> 0x00000100
  ...                                 58 vectors, all 0x00000100

  0x000100:  4e71 NOP    4e71 NOP    60fa BRA.S -6
```

A three-instruction park-forever loop, and fifty-eight exception vectors point
at it. Every reading fits: a six-byte loop runs entirely out of the ROM cache,
which is why the CPU is at full speed; the loop lives at 0x100-0x105, which is
why a[23:9] is zero; it touches only ROM, which is why nothing is unmapped.

**Blaze On is not stuck in initialisation. It has taken an exception and
crashed.** Every hypothesis before this — the memory map, the ROM window, the
region fill, the second VU-002 registers, the video geometry — was aimed at the
wrong failure.

### The oracle now matches over the whole window

With the 0xe40000/0xec0000 acknowledge windows decoded and the register banks
added to the boot harness:

```
  ours 100000 accesses, 42843 after dropping instruction fetches
  mame 100000 accesses, 42845 after dropping instruction fetches
```

No divergence at all, where before there were two. So the fault happens LATER
than 100k accesses, or comes from something only the hardware has. The CPU and
the memory map are cleared for the third time and by a stronger instrument.

### What names the culprit

The loop address cannot say which exception fired, because all 58 vectors land
there. The vector FETCH can: the 68000 reads its vector from 0x000008-0x0000ff
immediately before jumping, and once parked it never reads below 0x100 again,
so the last such read stays latched. Vector number is the byte address over
four, and `eab` is bits 23:1 of the byte address, so it is `eab[7:2]`.

Bus error, vector 2, is impossible in this core — BERR is never asserted — so
anything else distinguishes "jumped into garbage" (4 illegal, 10/11 line-A/F)
from "genuine arithmetic trap" (5 divide by zero, 6 CHK) from "odd word
address" (3).

### The SDRAM capture point changes whether Blaze On crashes

Two experiments on the bitstream already on the board, no rebuild:

```
  Sprites = Off              no change, still black
  SDRAM capture CL+1 (def)   black
                CL+2         black
                CL+3         black
                CL+0         RUNS LONGER, then draws garbage tiles
```

**Sprites off changing nothing rules out sprite bandwidth** as the cause, which
was the leading theory an hour ago.

**A capture point that changes a game from crashed to running is the signature
of a marginal capture race**, not a logic fault. If CL+1 were uniformly one
cycle late, every burst would be shifted by a word and Explosive Breaker could
not work either — it does. So the window is marginal and whether a given read
lands correctly depends on traffic and data pattern. Blaze On drives more
video bandwidth than Explosive Breaker (320 wide against 256, 232 lines against
224) and tips it over.

This is the fault `rtl/pll/pll.v` has been describing all along:

```
  All three PLL outputs:  phase_shift = "0 ps"
  Kaneko16.sv:            assign SDRAM_CLK = ~clk_sdram;
```

The clock the memory sees is the internal clock INVERTED THROUGH FABRIC — half
a period of skew at 48 MHz plus uncontrolled routing and IO delay, rather than
a dedicated phase-shifted PLL output. The file's own note says "the cause is
timing and the fix is a properly phase-shifted SDRAM_CLK". This is the first
hard evidence for that rather than a suspicion.

The garbage tiles at CL+0 are probably a SECOND bug that CL+1 was hiding by
crashing the game before it ever drew a frame. Not yet investigated; the colour
base is 0x400 for every Tier 1 game including Blaze On, so it is not that.

Open question that decides the fix: does Explosive Breaker still work at CL+0?
If it does, the immediate move is to change the default and both games run
while the real phase-shift work is done properly. If it does not, no single
capture point suits both and the fault is in the burst or arbiter logic rather
than the pad timing — a different fix entirely.

### CORRECTION: CL+0 is not a fix, and the SDRAM is not the fault

Explosive Breaker at CL+0 renders garbage and plays dodgy audio — it breaks.
That settles the direction the other way:

```
              CL+1 (default)        CL+0
  explbrkr    perfect               garbage, still running
  blazeonj    black, parked 0x100   runs, garbage
```

**Explosive Breaker working at CL+1 and breaking at CL+0 means CL+1 is the
correct capture point.** So Blaze On surviving longer at CL+0 is it running on
corrupt data, not it being fixed — a coincidence of which wrong bytes happen
not to trap. The previous entry read the first half of this experiment as
evidence of a marginal capture race; the second half disproves it.

**Blaze On's crash at CL+1 is therefore a real logic bug**, on hardware that is
demonstrably returning correct data to another game at the same setting. The
SDRAM phase-shift work in `rtl/pll/pll.v` remains worth doing on its own
merits, and is NOT this fault.

Recorded because the correction matters more than the original guess: one
experiment's half is not a result, and the leading theory has now been wrong
four times on this bug — sprite bandwidth, the second VU-002 registers, the ROM
window and fill, and now SDRAM capture timing. Every one of them died to a
measurement, and none of them died to an argument.

## 2026-08-22 — the Blaze On black screen: TWO bugs on one input read

The oracle found it in one line, after two earlier divergences were cleared out
of the way so the comparison could reach this far:

```
  ours   c00006 R ffff        mame   c00006 R ff00
```

0xc00006 is SYSTEM on this board. Two independent faults land on that read, and
either alone is fatal.

### 1. The third and fourth input words are SWAPPED between the boards

```
  bakubrkr_map   e00000 P1   e00002 P2   e00004 SYSTEM  e00006 UNK
  blazeon_map    c00000 P1   c00002 P2   c00004 UNK     c00006 SYSTEM
```

Blaze On has an extra unused word at offset 4 which pushes SYSTEM to offset 6.
The read mux in `kaneko_bus` was written for bakubrkr_map:

```
  (a[2:1] == 2'd2) ? in_system : in_unk
```

so on the Blaze On board a read of SYSTEM returned the UNUSED word. A per-game
fact sitting in shared code, which is hard rule 9, and it is now gated on
`blazeon_io`.

### 2. An idle input word is not "all ones"

MAME's `INPUT_PORTS_START(blazeon)` SYSTEM port defines ONLY the high byte:

```
  0x8000 IPT_SERVICE1   0x4000 IPT_TILT   0x2000 PORT_SERVICE_NO_TOGGLE
  0x1000..0x0100 IPT_UNKNOWN (active low, 1 when idle)
  0x00ff  NOT DEFINED AT ALL
```

Undefined bits in a MAME port read **zero**, so the word reads 0xFF00 idle.
This core built it as 0xFFFF on the assumption that an unpressed input is all
ones. It is not: it is whatever the board actually drives, and the unwired half
of this one drives nothing. The bit assignment was wrong too — service coin,
tilt and the service DIP were in the wrong order — and is now taken straight
from the port definition.

The game reads SYSTEM, tests the low byte, gets 0xff where it wants 0x00, and
jumps to the park loop at 0x000100. That accounts for EVERY observation: the
CPU at full speed (45,056 bus cycles a frame, a six-byte loop out of the ROM
cache), no exception vector ever fetched, nothing unmapped, and the address
pinned below 0x200.

### What actually found it

**Not reading the memory map.** That map was read several times this session
and looked correct every time, because the check being made was "is the window
in the right place" and not "is each word inside it the right word". Six
theories died before this one — sprite bandwidth, the second VU-002 registers,
the ROM window, the region fill, the video geometry and SDRAM capture timing —
and every one of them died to a measurement rather than an argument.

**It only surfaced after clearing two earlier divergences.** The 0xe40000
value and the register banks the boot harness did not have were each stopping
the comparison short of this point. Both looked like minor correctness fixes;
their real worth was letting the oracle see further.

**The harness was feeding an idealised value.** `in_system` was tied to 0xffff
unconditionally, which is exactly how the core shipped the same assumption — a
harness that hands the CPU a perfect input cannot catch a wrong one. It now
presents the per-board word.

### And the instrument was measuring itself

The exception-vector latch used `eab[23:8] == 0` to mean "byte address below
0x100". `eab` is bits 23:1 of the byte address, so that admits addresses up to
0x1ff — including the park loop at 0x100-0x105, whose own fetches overwrote the
latch every pass. It reported near-zero and was read as "no exception taken",
which happened to be the right conclusion for the wrong reason. Now
`eab[23:7]`. CLAUDE.md already carries the rule: check the instrument could
have seen it.

Verification, after both fixes:

```
  blazeonj  c00006 R ff00 == mame, first divergence moved from access 2
            to access 63152, which is interrupt-timing drift (this core runs
            264 lines at 59.19 Hz, MAME's screen is a different height at 60)
  explbrkr  100000 accesses, NO divergence at all
```

### CORRECTION: the SYSTEM bug was real but was NOT the crash

Deployed, and Blaze On is unchanged — still black, still parked. Explosive
Breaker is unaffected, so the shared-mux change is safe.

The evidence against the SYSTEM word being the cause was already in hand and
was not weighed properly: the 400M-tick simulation ran 491 frames without ever
touching 0x000100, and that run had `in_system` tied to 0xffff — the WRONG
value. A wrong value that does not crash the game in simulation is not the
thing crashing it on hardware. "The oracle found a divergence" was allowed to
become "the oracle found the cause".

Both fixes stand on their own merits: the word order and the 0xFF00 idle value
are what MAME says the board does. Neither is the black screen.

What this build DOES bring is a working vector instrument. The previous one
used `eab[23:8]` to mean "byte address below 0x100", which admits 0x1ff and let
the park loop overwrite the latch with its own fetches every pass — it always
read near-zero regardless. With `eab[23:7]` it can only latch a genuine vector
fetch, so for the first time it distinguishes "took an exception" from "jumped
here deliberately". Those are opposite investigations.

Still unexplained and now the central question: the core runs Blaze On for 491
frames in simulation and parks it immediately on hardware, with the CPU, the
memory map, the register decode and every input word verified against MAME.
The remaining difference is the video path's SDRAM traffic, which the boot
harness does not model at all.

### Wing Force fails identically — the fault is BOARD-WIDE

Wing Force parks its CPU exactly as Blaze On does. The two share the
`blazeon_map` configuration and differ in geometry (v_vis 224 against 232),
in where the OKI lives (Z80 I/O ports rather than the 68000 bus) and in MAME's
68000 clock. None of those differences matters to the fault.

That eliminates every per-title cause at once: not Blaze On's ROM, not its
region fill, not its 232-line geometry. Whatever it is, both titles on this
board share it.

Also worth recording because it validates an earlier result: `spr_off` holds
`kaneko_spr_sys` in RESET rather than merely blanking its output, so the
"sprites off, no change" test genuinely removed the sprite fetching and sprite
bandwidth is properly ruled out. A switch that only blanked the output would
have made that result meaningless.

### A tilemap kill switch, to close the contention question

`O[17] Tilemaps On/Off` stops `line_start`, so the tile ROM feeder issues no
SDRAM requests at all. With it and the sprite switch both off, the 68000 is the
ONLY consumer of SDRAM on a board whose OKI is idle.

This exists to settle the one hypothesis nothing else can reach. Both Blaze On
board titles run 491 frames in simulation and park immediately on hardware, and
the single thing the boot harness does not model is the video path competing
for memory. Adding the video path to the harness is hours of work; this is one
switch and one build, and it is decisive in both directions:

  still parks with zero video traffic  ->  contention is NOT the cause, and
                                           that whole line of enquiry closes
  boots                                ->  contention confirmed, and the fix is
                                           in the arbiter or burst scheduling

## 2026-08-22 — the game-id byte never arrived. One bug, three dead games.

Blaze On reports **256x224** in the MiSTer OSD. That is Explosive Breaker's
geometry. And `ZZ-TEST-EB-as-game01.mra` — Explosive Breaker's own ROMs with
the config byte changed to 01 — boots Explosive Breaker normally, when it
should have handed it Magical Crystals' memory map and broken it.

Two independent proofs of one thing: **the MRA's `<rom index="1">` config byte
never reaches the core, and `game_id` is stuck at its reset value of 0.**

```
  explbrkr   id 0   WORKS      <- and 0 is the reset default
  mgcrystl   id 1   black, CPU running
  blazeonj   id 2   black, CPU parked
  wingforc   id 3   black, CPU parked
```

### Why: one byte is zero words

The core runs `hps_io` with **WIDE=1**, 16-bit file I/O. Our config ROM was a
single byte:

```
  ours          <rom index="1"><part>02</part></rom>        ONE byte
  1942, works   <rom index="1"><part>05 98</part></rom>     TWO bytes
```

A one-byte file is zero 16-bit words, so the transfer never produces an ioctl
write and the latch never fires. Every working MiSTer core that passes config
this way sends an even number of bytes. Fixed in
`tools/build_rom_regions.py`; no bitstream change, the MRA alone.

The id now goes in BOTH bytes rather than being padded with a zero, on purpose:
a pad in the wrong half reads as game 0, which is Explosive Breaker, which is
indistinguishable from working for one game in four. That is precisely the
failure being fixed.

### The signal that was in hand for hours

Correcting Blaze On's MRA from id 00 to id 02 changed NOTHING on hardware. That
was observed, noted, and moved past. **A configuration change that provably
alters the artefact and provably changes nothing on the device is evidence
about the DELIVERY PATH, not the content.** Every hour after that was spent
below the fault: the per-game pages, the ROM window, the region fill, the input
word order, the 0xFF00 SYSTEM value, the acknowledge windows. All real, all
verified against MAME, none of them able to take effect.

### The default that hid it, for the fourth time

`game_id` falls back to 0 when nothing sets it, and 0 is a REAL GAME that then
works perfectly. Had the fallback been an invalid id — one that renders
obviously broken or refuses to run — the fault would have been visible on
Explosive Breaker the first time it was loaded, instead of hiding behind the
one title anybody was testing.

**The fallback for a missing selector must not be a valid selection.** Fourth
incident of a default that returns a plausible value: the SDRAM burst length,
the harness port count, `GAME_ID.get(setname, 0)`, and now the reset value of
`game_id` itself.

### The two-byte fix did not work, and the md5 theory was wrong

Blaze On still reports 256x224 with a two-byte `<part>02 02</part>`. So the
WIDE=1 word-count theory was not it, or not all of it.

The follow-up theory — that a missing `md5` attribute stopped the transfer —
is disproved by MiSTer's own source. `mra_loader.cpp` clears `arc_info->md5`
at the start of every `<rom>` element (line 477), and

```
  int checksumsame = !strlen(arc_info->zipname) || !strcasecmp(md5, hex);
  int no_checksum  = !strcasecmp(md5, "none") || !strlen(md5);
  checksumsame |= no_checksum;
  rom_finish(checksumsame, ...)
```

forces `checksumsame` true when there is no zipname, which a config rom does
not have. It would have been sent either way. `md5="none"` and emitting index 1
after index 0 are kept as tidying, not as fixes.

Everything on the core side checks out and has been verified line by line:
`hps_io` and `kaneko_gamecfg` share `clk_sys` so no pulse can be lost across
domains; `rst_por` is only `~pll_locked` and released long before download;
`ioctl_index[7:0]` is compared against 1; `ioctl_dout[7:0]` is the low byte
that WIDE=1 fills first. The byte still does not land, and no more theorising
is going to settle it.

### So: a probe, and a way round it

`cfg_writes` counts ioctl writes seen at index 1. That separates two faults
nothing so far distinguishes — the transfer never happening, versus happening
with the wrong value.

And an OSD **Game override** selects the id directly. This matters more than
the probe: **nothing in the per-game table has ever been exercised on
hardware.** The pages, ROM bases, geometry, layer count, sprite list size and
input assembly are all verified against MAME and all of them have only ever run
as Explosive Breaker's values on the board, because the selector never
arrived. The override makes the whole table testable while the delivery
problem is still open.

It is applied INSIDE the table rather than muxed onto its output, so every
derived signal moves together. The testbench caught the first attempt doing
this wrong: `game_id` still reported the latched MRA value while the table
acted on the forced one — a core running one board's pages with another's
geometry, and a readout lying about which. There is now one effective id, and
the test asserts the override moves every output, not just the one being
looked at.

## 2026-08-22 — twelve hours of hardware tests were run against the wrong bitstream

`Kaneko16_GOOD.rbf`, the fallback parked in `_Arcade/cores/` at 00:35, shadowed
`Kaneko16.rbf` on every single load. MiSTer's `mra_loader.cpp` resolves
`<rbf>Kaneko16</rbf>` like this:

```
  snprintf(newstring, ..., "%s", filename);            // "Kaneko16"
  if (!strncasecmp(newstring, entry->d_name, len) &&
      (entry->d_name[len] == '.' || entry->d_name[len] == '_'))
      if (!lastfound[0] || strcmp(lastfound, entry->d_name) < 0)
          strcpy(lastfound, entry->d_name);            // keeps the GREATEST
```

It accepts `Kaneko16` followed by `.` or `_`, and keeps the lexicographically
greatest. `'_'` is 0x5F, `'.'` is 0x2E, so `Kaneko16_GOOD.rbf` wins.

**Everything measured on hardware after 00:35 was measuring `ba391b84`.** The
deploys were correct and checksum-verified on the card; the FPGA never loaded
them. Explosive Breaker kept working, so nothing looked wrong.

Invalidated, all of it: Blaze On black with the CPU parked, the 256x224
geometry reading, sprites-off making no difference, the SDRAM capture CL+0
results, the exception-vector readings, the "game-id byte never arrives"
conclusion, and the `ZZ-TEST-EB-as-game01` result. Also the two anomalies that
were written up as unexplained — overlay rows at scanlines 92 and 100 "not
rendering", and an OSD option that "was not there". Both were simply absent
from the loaded bitstream. One of them had a whole findings entry theorising
about video geometry.

With the fallback moved out of `cores/`:

```
  explbrkr   works
  blazeonj   RUNS — warning screen and attract, tiles/sprites misplaced
  wingforc   RUNS from its own MRA, same misplacement
  mgcrystl   boots, debug overlay good, screen black
```

**The game-id byte does arrive.** Wing Force loading its own geometry from its
own MRA proves it. The per-game table works, and every fix made during the
blackout — the pages, the ROM window, the region fill, the input word order,
the 0xFF00 SYSTEM value, the acknowledge windows — is real and now actually
running.

### The lesson is about verification, not about MiSTer

A checksum on the SD card proves the copy landed. It proves nothing about what
the FPGA loaded, and that distinction went unexamined for twelve hours while
being cited as evidence. The fix is a visible marker that changes every build —
a new OSD entry, a version nibble on the overlay — checked before any reading
is trusted. `releases/` already has a rule that working is defined by the
device and not by the build directory; this is the same rule one level deeper.

### First real hardware readings for the Blaze On board

With the correct bitstream finally loading:

```
  explbrkr   works
  blazeonj   RUNS. Warning screen and attract render. Tilemap SCROLLING is
             correct. Text is doubled with a ~2 pixel horizontal offset.
             Sprites present but displaced about an eighth of the screen
             (~40px of 320) and drawn half-complete. Inputs work.
  wingforc   RUNS from its own MRA, same symptoms.
  mgcrystl   boots, overlay healthy, screen black.
```

MAME's own frames for blazeonj at the same point are 320x232 with clean
single-width text and whole sprites, so none of this is the game.

### Where the gate cannot see, and why that matters

`sim/video/tb_kaneko_frame.cpp` does NOT instantiate `kaneko_vmem`. It feeds
VRAM from a C++ array straight into the renderer through `t_vram_attr_addr` and
`t_vram_code_addr`. So the 100% frame match proves the RENDERER correct given
correct VRAM, and proves nothing at all about:

- `kaneko_vmem`'s bank decode (vram_0 / vram_1 / scroll_0 / scroll_1)
- the CPU write path from `kaneko_bus` into that memory
- sprite RAM contents as the CPU actually writes them

Every symptom above lives in exactly that blind spot. The layer/register
mapping was checked by hand and is consistent between the gate, the top level
and `kaneko_vmem` — tmap0 takes regs 2/3 and VRAM 0x1000, tmap1 takes regs 0/1
and VRAM 0x0000, enables are bits 12 and 4 active low — so the swap theory is
not supported and the fault is elsewhere in the same region.

The structural fix is to drive the gate's VRAM through the CPU write path
rather than loading it directly. That closes the blind spot permanently instead
of chasing each symptom onto hardware one build at a time. It is the same
lesson as the boot harness, which agreed with whatever it was handed until it
was given the real register banks and the real input words.

Sprite displacement of roughly 40px on a 320-wide screen, with half-drawn
sprites, suggests 256-wide assumptions surviving in the sprite clip or wrap —
`spr_xoffs` is 0xF980 from MAME's `set_offsets(0x10000 - 0x680, 0)` and is
applied, so it is not that constant.

### Wing Force's sprite base pointed into its own tile ROM

Two reports, one fault: no sprites when loaded from its MRA, and "completely
wrong ones" under the OSD override. Both are what reading the wrong SDRAM
region looks like.

```
             kan_spr     base_spr said
  explbrkr   0x280000    0x280000  ok
  mgcrystl   0x280000    0x280000  ok
  blazeonj   0x200000    0x200000  ok
  wingforc   0x300000    0x200000  <- inside view2_0
```

`base_spr` was selected on `blazeon_board`. Blaze On and Wing Force share a
PCB and NOT an SDRAM layout — Wing Force's view2_0 is twice the size, which
pushes kan_spr from 0x200000 to 0x300000. So Wing Force's sprite fetcher read
the middle of its own tile ROM and drew tile graphics as sprites, while Blaze
On drew its sprites correctly and the pair looked like two different bugs.

Hard rule 9, again, and in its sharpest form yet: **the board is not the game.**
Every other Blaze On board fact — one VIEW2 chip, 512 sprites, the input word
order, the memory-map pages — genuinely is per board. This one is not, and
being right about the others is what made it invisible.

### tools/check_bases.py

The RTL repeats the ROM tool's SDRAM layout as WORD addresses in
`kaneko_gamecfg.sv`, and nothing compared the two descriptions. Now `make lint`
cross-checks `base_trom0`, `base_trom1`, `base_spr` and `base_oki` against
`SDRAM_MAPS` for every game.

Verified against the bug it was written for — run on the old RTL it prints
`wingforc: base_spr must include word 0x180000 (byte 0x300000) for kan_spr`.
A check that has never been shown to fail is not a check.

`make mra` already does this for the MRA against the same tables, for the same
reason: a region misplaced there loads without error and surfaces much later as
garbage. This is that guard one layer further in.

### The sprite clip was Explosive Breaker's screen, hardcoded

```
  .clip_x0(10'd0), .clip_x1(10'd255),
  .clip_y0(10'd16), .clip_y1(10'd239),
```

MAME clips sprite drawing to the visible area, and the visible area is per
game. This was Explosive Breaker's, applied to everything. On the Blaze On
board — 320 wide, starting at line 0 — sprites lost their last 64 columns and
their top 16 rows.

On hardware that read as sprites about a sixteenth of the screen too low and an
eighth too early, drawn half-complete at the boundary. 16 of 232 IS a
sixteenth, which is what identified it: the number was not approximately
something, it was exactly the difference between the two boards' `v_start`.

Now derived from `CFG_H_VIS`, `CFG_V_START` and `CFG_V_VIS`, so the clip cannot
drift from the screen it clips to.

### A toggle that fixes something is a reset that came too early

Blaze On showed no sprites at all until the OSD sprite switch was turned off
and back on. `spr_off` holds `kaneko_spr_sys` in reset, so toggling it re-reset
the module — after the ROM had finished loading.

The instance used `rst_sys`, which does NOT include `~rom_loaded`; `cpu_rst`
does. Released on `rst_sys` alone the sprite system began parsing sprite RAM
and fetching sprite ROM before anything was in SDRAM, latched state from what
it read, and never recovered. Now `cpu_rst | spr_off`.

Worth keeping as a diagnostic shape: **a switch that makes a broken thing work
is almost always re-running an initialisation that happened at the wrong
time.** It was reported as "I have to turn the sprites off and then back on for
them to appear" and that sentence contains the whole diagnosis.

### Three symptoms, three separate bugs, none reachable from simulation

```
  no sprites in Wing Force        base_spr pointed into its own tile ROM
  both games displaced alike      the clip rectangle was another game's
  toggle to make them appear      the reset came before the ROM load
```

Each was diagnosed from one sentence of hardware observation, and none of the
three is visible to the frame gate: the gate loads VRAM and sprite RAM
directly, never runs the loader, and composites with its own clip. This is the
same blind spot recorded above — the gate proves the renderer, not the path
that feeds it.

### A disabled layer was still fetching tile ROM

`layer_enable` reached only `solid` in `kaneko_tmap_fetch`:

```
  solid <= s3_valid && layer_enable && (s3_pix != 4'd0);
```

It suppressed the layer's OUTPUT while the layer went on reading tile ROM every
line. On the Blaze On board that is half the tile bandwidth spent on chip 1,
which `two_chips` masks and which can never be drawn, on a line 25% wider than
Explosive Breaker's.

It showed up on hardware exactly where a thin bandwidth margin shows up:
nothing on a static screen, and line-fetch overruns once Wing Force had heavy
sprites and tiles on screen together. Zero overruns on the warning screen said
nothing; the loaded scene said everything.

A disabled layer now reports done immediately — otherwise `running` never
clears and the line never finishes — and `out_solid` is gated by the enable so
the stale contents of a bank that stopped being written cannot show.

### kaneko_tmap_line had no positional test, and is the module nothing runs

```
                        boot harness   frame gate   real core
  kaneko_tmap_line           no            no          yes
```

The frame gate instantiates `kaneko_tmap_layer`, `kaneko_vuspr` and
`kaneko_mixer` and feeds pixels straight in; the boot harness has no video
output at all. The line buffer — widened from 256 to 320 this session with a
runtime `h_active` — existed only in the bitstream.

Its own testbench checked self-consistency and nothing else: the same line
twice, stalls change nothing, a different y differs, disabled layers blank. **A
buffer that duplicated every column by two pixels would have passed all of
it**, and it only ever ran at 256.

Added the invariant that needs no knowledge of the internals: **the visible
width must not change which pixels land in 0..255.** Same tilemap, same scroll;
widening only ADDS columns 256..319. Plus the same under random per-layer
stalls, and a check that the extra columns are genuinely fetched rather than
left blank.

Result: 518 checks, 0 fails. The line buffer is correct at 320, and the prime
suspect for the ghost is eliminated rather than assumed.

### What the ghost is NOT

Verified individually, each against MAME or by direct readout:

```
  CPU writes to the VIEW2 registers   match MAME, address and value
  the registers land                  L0=461 L1=459 delta=-2, exactly MAME
                                      747 strobes, all byte-enabled
  VRAM writes                         land in the right banks
  kaneko_vmem read mux                c0_t0_q <- chip0 layer0
  top-level vmem <-> line wiring      correct in both directions
  config latching                     once per frame at vblank end
  the renderer                        100% on MAME's own frame-60 dump
  kaneko_tmap_line at 320             518 checks, 0 fails
```

And the arithmetic says the two layers should coincide exactly:

```
  layer 0   dx 51 + scroll 461 = 512
  layer 1   dx 53 + scroll 459 = 512
```

which is the whole reason the game writes layer 1's scroll two lower. Nothing
in the tilemap path explains a two-pixel split, and the next discriminator is
whether the DEBUG OVERLAY ghosts too — it is drawn directly at exact pixel
positions and never touches tiles, VRAM or the line buffer. If it ghosts, the
fault is downstream of everything above, in the HDMI scaler or its filter, and
this build carries -0.032 ns on `pll_hdmi`.

### The two layers coincide correctly in RTL, and split on hardware

Blaze On draws the same tiles on both layers of VIEW2 chip 0 and lines them up
exactly. The hardware gives layer 1 a dx two greater; the game writes layer 1's
scroll two LOWER to cancel it:

```
  layer 0   dx 51 + (0x7340 >> 6 = 461) = 512   ->  map_x = x
  layer 1   dx 53 + (0x72c0 >> 6 = 459) = 512   ->  map_x = x
```

That is why some elements of the picture ghost and others do not: the stars sit
on one layer and stay crisp, the large artwork sits on both and is drawn twice
two pixels apart. It shows on static screens, which rules out anything to do
with clearing or trails.

`tb_kaneko_tmap_line` now asserts it directly — identical tile data on every
layer, the game's real dx and scroll values, and the two layers must emit the
same pixel in all 320 columns. **It passes.** 519 checks, 0 fails.

So the arithmetic, the register routing, the per-layer indexing and the line
buffer are all correct, and the hardware still splits them. The remaining
possibility is that the scroll registers hold different values on the board
from the ones simulation reads back, so rows 4 and 5 of the overlay now display
`c0r2` and `c0r0` as the top level sees them. Expect 7340 and 72c0; 0000 would
mean the register writes are not landing on hardware at all.

Recording the shape of this hunt, because it has been the pattern all day: the
frame gate proves the renderer, the boot harness proves the CPU, and every
video fault has lived in the seam between them. Three of those seams are now
closed with tests that fail on the real defect — the line buffer's placement at
320, the two-layer coincidence, and the SDRAM bases against the ROM layout.

### Two edits that did nothing, reported as done

`str.replace()` matched nothing on two occasions and the script printed a
success line regardless, because the print was unconditional. The overlay rows
were never restored to the OKI chain and the scroll-register probe was never
added. `git add Kaneko16.sv` then staged an unchanged file, the commit carried
only docs and a testbench, and Quartus rebuilt a **byte-identical bitstream**.

The identical md5 against the previous deploy is the only thing that caught it.
That is the second time in one day that the fix for a reported change was
"check the artefact actually changed" — the first was `Kaneko16_GOOD.rbf`
shadowing the real core for twelve hours.

Every scripted edit now asserts the anchor text exists before replacing, and
greps for the result afterwards. A rule is in CLAUDE.md.

### One sprite engine is enough: the second VU-002 is not needed

Measured on hardware, Wing Force in a busy scene: **sprite overruns zero**,
while the tilemap feeder's overruns run to three bars in the same frame. So the
sprite path finishes every frame with room, and the tilemap path is the one
short of time.

That settles one of the design study's §9 open items in the practical
direction. The Blaze On board carries TWO VU-002 chips reading ONE shared
sprite list at 0x700000 — `blazeon_map` has a single spriteram and a single
register block the device uses, with the second chip's registers at 0x980000
kept as plain RAM. MAME's own comment is "there is actually a 2nd sprite chip!
looks like our device emulation handles both at once", and the ROM list marks
`BZ_SP1.U68` and `BZ_SP2.U86` as duplicate copies "for 2nd sprite chip".

The second chip bought FILL RATE, not sprites and not graphics: a VU-002's
internal bitmap is finite and this board is 320 wide where the rest of the
driver is 256. An FPGA line buffer has no such limit, so one engine rendering
the shared list into a 320-wide bitmap produces what the two chips jointly
produced — and the overrun counter now says it does so inside the frame budget.

Implementing a second engine would cost block RAM and buy nothing measurable.
Revisit only if that row ever goes non-zero.

### The tilemap feeder overruns, and it is NOT raw bandwidth

```
  Explosive Breaker   4 layers x 256 = 1024 pixel-fetches per line   no overrun
  Blaze On board      2 layers x 320 =  640                          overruns
```

The board that fetches LESS is the one that misses, so volume is not the
constraint and the disabled-layer fetch fix — real and worth keeping — did not
clear it. Sprites are not starving it either, since the sprite engine finishes
every frame.

That leaves the access pattern. The two boards place their tile and sprite ROM
at different SDRAM offsets, and if Blaze On's land such that tile and sprite
fetches keep alternating rows within a bank, every switch costs a row activate
that Explosive Breaker's layout happens to avoid. Untested, and a separate
thread from the two-pixel split.
