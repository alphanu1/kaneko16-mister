# Handoff — state of play

Read `CLAUDE.md` first, then this. `docs/findings.md` is the measured record;
`docs/00-decisions.md` is what was decided and what would reverse it.

**Status: M0 in progress. M1 not started.** The two hardest *novel* pieces are
under way; the bulk of first bring-up is conventional integration that has not
begun.

---

## What exists

| | |
|---|---|
| `rtl/video/kaneko_tmap.sv` | VIEW2 coordinate pipeline — scroll, line scroll, tile lookup, attribute decode, tile-ROM pixel address. 236 yosys cells. |
| `rtl/video/kaneko_vuspr.sv` | VU-002 sprite list parser with multisprite latching, plus sprite pixel address. 1231 cells, 216 FF. |
| `sim/` | Two fuzz harnesses (3.0M + 41k checks, both clean) and the frame gate. |
| `tools/` | `bootstrap.sh`, `build_rom_regions.py`, `mame_dump_frame.lua`, `mame_view2_census.lua`. |
| `Makefile` | `lint`, `test`, `area`, `frame`, `quartus` (17.0-guarded). |

ROMs: all nine sets verify and boot, covering all three tiers.

**These are address engines, not a video path.** They compute where a pixel
comes from. Nothing yet stores, fetches, mixes or outputs one.

## What the M0 gate says

```
mgcrystl f600   diff=298   99.48%
explbrkr f900   diff=0    100.00%   PASS
blazeonj f600   diff=0    100.00%   PASS
wingforc f600   diff=0    100.00%   PASS
```

M0's gate is scanline-exact. Neither passes. The tilemap path is close — under
1% on `explbrkr`. The sprite path is where the error is, and the sprite
measurement is not yet trustworthy (see below).

---

## What is left before Explosive Breaker boots

(Bring-up title changed from Magical Crystals 2026-08-20 — see
`docs/00-decisions.md` D4. Its video renders pixel-exact, so a bring-up failure
points at the CPU or memory rather than the renderer.)

Ordered roughly by dependency. Items marked **novel** have no drop-in source.

### 1. Finish the video path (partially started)

- **novel** VRAM, scroll RAM, palette and sprite RAM in M10K — ~32 KB tile +
  4 KB palette + 8 KB sprite
- **novel** tile/sprite ROM fetch from SDRAM (1 MB + 1 MB tiles, 2.5 MB
  sprites — far too large for M10K)
- **novel** pixel pipeline and line buffers
- **novel** priority mixer as RTL. It currently exists only as C++ inside the
  frame harness; the mixing model is understood and written down, but no gate
  covers an RTL implementation.
- **novel** double-buffered sprite bitmap with the mask semantics
  (first-writer-wins, drawn last-to-first)
- video timing generator, and the **rotation output stage** (decision D3)

### 2. CPU and bus

- fx68k integration — drop-in core, but needs bus glue and wait states
- address decode for `mgcrystl_map`, and 64 KB work RAM
- interrupts: IRQ5 at scanline 224, IRQ4 at scanline 64, plus the third the
  driver mentions and does not explain
- watchdog

### 3. Memory

- SDRAM controller, single module (decision: single-stick is a hard target)
- MRA ROM loader over the HPS interface, and region mapping matching
  `ROM_START` — `tools/build_rom_regions.py` already encodes those layouts for
  simulation and is the reference for it

### 4. Sound

- jt49 x2, including YM2149 port B (EEPROM chip select **and** OKI banking —
  register I/O, not a separate chip)
- jt6295 with sample ROM in SDRAM
- audio mixing and output

### 5. I/O

- 93C46 EEPROM (persisted via the HPS)
- controls and DIPs, coin lockout

### 6. Framework and build

- `sys/` integration, `sys_top`, OSD config string (including the D3 rotation
  toggle)
- PLL: 12 MHz main domain, 2 MHz sound domains
- Quartus 17.0 project — `.qpf/.qsf/.sdc`, `files.qip`. `make quartus` already
  guards the toolchain version but has no project to build.
- MRA for `mgcrystl`

---

## Open questions that carry real risk into M1

1. **Screen timing is not PCB-verified.** MAME uses `set_refresh_hz(60)` with
   no `set_raw()`, and annotates `vblank_time` `/* not accurate */`. Exact
   pixel clock and blanking are unknown. This sets the PLL and the video
   timing generator, so it is on the critical path, and no amount of
   simulation resolves it — it needs a hardware reference or a PCB capture.
   Wing Force's `59.1854` Hz is the only precise figure anywhere in the driver
   and is worth chasing first.
2. **Sprite lag: one-frame is measured better than two-frame, but is not
   distinguishable from no lag.** The capture now happens at scanline 223,
   immediately before the driver's `copy()`. One-frame beats two-frame on the
   only frame that can separate them (6600 vs 6896) — evidence against MAME's
   own `// 2 frame delayed normaly` for this board. But the one-frame snapshot
   is byte-identical to the no-lag snapshot on both dumps, so that half is
   still open and needs a frame where sprite RAM moves late.
3. **The line-scroll index is unconfirmed against a frame.** Well-supported by
   reading `tilemap.cpp`, but every frame tried so far is degenerate. Needs
   Blaze On's 2nd demo level, which needs harness support for a one-chip,
   512-sprite configuration.
4. **Global layer flip is not implemented** and no captured frame exercises it.
5. **Blaze On has two VU-002 chips** and MAME ignores the second register set
   at `0x980000`. Deferred, but it is a real hardware behaviour that will need
   solving for that title.

---

## Honest sizing

The novel graphics work — the reason this core did not already exist — is
perhaps a third done: the hard arithmetic is written and partially verified
against the oracle. Everything in sections 2 through 6 above is conventional
MiSTer core integration with existing parts, but it is *all* of first bring-up
and none of it is started.

The nearest genuinely useful milestone is not "it boots". It is **closing the
M0 gate to exact on `mgcrystl`**, because every later mistake is diagnosed
against a video path known to be right.
