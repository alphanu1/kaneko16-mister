# Handoff — state of play

Read `CLAUDE.md` first, then this. `docs/findings.md` is the measured record;
`docs/00-decisions.md` is what was decided and what would reverse it.

**Status: Explosive Breaker boots, renders and makes sound on hardware.** The
68000 runs its main loop, the tilemap layers draw, the EEPROM saves and
restores, and OKI sample playback works. Sprites and inputs are the two blocks
between here and a playable core.

One open defect: frame pacing is uneven when a large detailed object is on
screen. Suspected tile-fetch bandwidth, not measured yet — see `findings.md`.

Bring-up title is **Explosive Breaker**, changed from Magical Crystals on
2026-08-20 (`docs/00-decisions.md` D4).

---

## What runs on hardware

| | |
|---|---|
| ROM loader, SDRAM controller, PLL, video timing | yes |
| 68000 (fx68k) + bus decode | yes — matches MAME exactly over 100k bus accesses |
| ROM line cache | 16 lines x 4 words, ~0.1% miss; CPU at MAME's bus rate |
| Scanline interrupts | IRQ5/4/3 autovectored, all three taken once per frame |
| VIEW2 tilemaps | rendering, no visible artefacts |
| VIEW2 / sprite register files | `kaneko_regs16`, byte-enabled |
| 93C46 EEPROM | 20,910 reads replayed against MAME, zero mismatches; Save Backup RAM works |
| YM2149 x2 (jt49) | wired and mixed; the game keeps their volumes at zero |
| OKI M6295 (jt6295) | **working on hardware** — sound effects play |

## What is left

Ordered as the owner asked for it: **sound, then finish video, then I/O.**

### 1. Sound

- ~~OKI M6295~~ — **done and confirmed on hardware.** Root cause and the two
  `default:` clauses that hid it are in `findings.md`.
- **Music is absent and may not be a fault.** This board's music is OKI
  samples; the game keeps the YM2149 volumes at zero. Check against MAME
  before treating it as a bug.
- Z80 + YM2151 subsystem for Blaze On and Wing Force. Different board: the
  68000 writes a latch at `e00000`, which NMIs the Z80, which drives the
  YM2151 on ports 0x02/0x03. T80 and jt51 are already pinned in `deps.lock`.

### 2. Video

- **Sprites.** `kaneko_vuspr_draw.sv` is written and fuzzed clean but not
  instantiated. Needs `BMP_W_LOG2` split into separate width and height first;
  320x256 chosen, about 170 M10K.
- **Rotation output stage** (decision D3). `screen_rotate` in
  `sys/arcade_video.v` does the work, but it needs `MISTER_FB=1`, the DDRAM
  ports wired up (they are currently tied off) and OSD entries. It is a
  **per-game fact** — `explbrkr` is ROT90, `wingforc` ROT270, `mgcrystl` and
  Blaze On ROT0 — so it belongs in the game table, not as a constant.
- Global layer flip is not implemented and no captured frame exercises it.

### 3. I/O

- Controls and DIPs; inputs currently read as `0xffff`.
- Coin lockout.

### 4. Per-game support

The core is compiled for `explbrkr` alone. The memory map is `bakubrkr_map`
and the screen offsets, colour base, sprite priorities, layer count and OKI
`MAX_BANK` are constants. Everything above needs a game configuration table
selected by the MRA's `<rom index="1">`, and the SDRAM map has to grow —
`kan_spr` from 0x240000 to 0x280000 — before `mgcrystl` fits. Only `explbrkr`
ships an MRA until then, because shipping one for a game the core cannot run
looks like support and fails undiagnosably.

### 5. Verification debt

- **There is no whole-core frame gate against MAME.** The M0 gate compares the
  RTL renderer against a MAME frame dump; nothing compares the assembled core.
  This is the single biggest gap, and it is what would have caught the OKI
  burst bug in minutes.

---

## Open questions that carry real risk

1. **Screen timing is not PCB-verified.** MAME uses `set_refresh_hz(60)` with
   no `set_raw()`. We run 384x264 at 6 MHz, 59.1856 Hz. No amount of simulation
   resolves this — it needs a hardware reference or a PCB capture. Wing Force's
   `59.1854` Hz is the only precise figure in the driver.
2. **`mgcrystl` still shows a 298-pixel line-scroll difference** in the M0 gate.
   `explbrkr`, `blazeonj` and `wingforc` are exact.
3. **Line-scroll RAM is read live, where MAME snapshots it.** Not yet shown to
   matter on any captured frame.
4. **An OSD reset still looks like it loses the EEPROM** — two orange bars for
   4-5 seconds on the next boot. Unresolved; a cold power-up reads the saved
   contents correctly.
5. **Sprite lag: one-frame beats two-frame but is not distinguishable from
   none.** Needs a frame where sprite RAM moves late.
6. **Blaze On has two VU-002 chips** and MAME ignores the second register set at
   `0x980000`. A real hardware behaviour that will need solving for that title.

---

## The thing that keeps going wrong

Four devices have now been "wired" and found not to work, and every one was
diagnosed the same way: build the instrument, compare against MAME, and find
that some link in the chain was never tested. The OKI is the clearest case —
the chip, the bank map and the ROM feeder were all correct, and the SDRAM port
underneath them was handing out two valid bytes in eight.

`make lint && make test` is the gate, and it only covers what has a harness.
When a device is added, its *integration* is the thing to test, not the
third-party core inside it.
