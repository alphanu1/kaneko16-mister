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

- ~~Sprites~~ — **done**, `kaneko_spr_sys` is instantiated. 256x256 surfaces,
  double-buffered, parity mask, its own SDRAM port (port 6).
- **Rotation output stage** (decision D3). `screen_rotate` in
  `sys/arcade_video.v` does the work, but it needs `MISTER_FB=1`, the DDRAM
  ports wired up (they are currently tied off) and OSD entries. It is a
  **per-game fact** — `explbrkr` is ROT90, `wingforc` ROT270, `mgcrystl` and
  Blaze On ROT0 — so it belongs in the game table, not as a constant.
- Global layer flip is not implemented and no captured frame exercises it.

### 3. I/O

- ~~Controls and DIPs~~ — **done**. Two players, two buttons each, start, coin,
  service and pause, plus the board's two DIPs.
- Coin lockout: **there is nothing to do for this game.** `bakubrkr_map` has no
  write handler at `0xe40000`, so the four writes the CPU makes there are
  unmapped in MAME too. Other titles in the driver do have
  `coin_lockout_w`; that arrives with their memory maps.

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

## READ THIS FIRST — main does not close timing, 2026-08-24

The Tier 2 work below is committed and the simulation gate is green, but
**`make quartus` fails on timing**: worst-case setup slack -0.773 ns.

Roll back to **`59b4c4b`** for a tree that builds, closes timing and matches
the released bitstream's behaviour. Nothing in `releases/` is affected — it
still holds `d301c878`, the build that was played.

The failure is not in this core's logic. Its two clock domains actually
IMPROVED: SDRAM went from +1.126 to +1.261 ns and the core from +1.880 to
+2.182. What fails is `pll_hdmi`, the framework's HDMI path, and it fails
because the fitter has run out of room:

| | before Tier 2 | with Tier 2 |
|---|---|---|
| ALMs | 16,670 (40%) | 21,456 (51%) |
| **M10K blocks** | — | **522 / 553 (94%)** |

## THE BLOCK MEMORY IS THE BLOCKER FOR TIER 2

`shogwarr_map` wants 64 KB of MCU RAM at 200000. That costs about 64 M10K
blocks, and taking them starves `kaneko_vmem`, whose sprite and palette
memories are ONE WRITE TWO READS. An M10K cannot be that, so Quartus
duplicates them -- silently, and only while blocks are spare. With the spare
gone it builds registers instead: vmem alone asked for **65,563 registers** and
the fitter wanted 6,773 LABs against the device's 4,191. The same cliff
`kaneko_z80rom.sv`'s header describes, reached from the other side.

**Resolved: option 2. The MCU RAM is in SDRAM**, the full 64 KB, on SDRAM
port 10. It is no longer a placeholder and no longer costs a single M10K.

The three options were:

1. **Free the sprite bitmap's ~192 blocks.** Blocked on SDRAM bandwidth (D5),
   and they are the same 192 blocks Tier 3 needs. Tier 2 and Tier 3 are
   competing for one pool.
2. **Put the MCU RAM in SDRAM**, at the cost of latency on every MCU access.
   **Taken.** MAME measured the CALC3 MCU at ~2,650 accesses per frame, about
   6.5% of available clocks, so the latency is affordable where the block
   memory was not.
3. **Find out how much of the 64 KB the games actually touch.** Moot: in SDRAM
   the full 64 KB costs nothing worth economising on.

`kaneko_bus.sv` gained an `S_MCU` wait state that holds DTACK until the SDRAM
acknowledges, so a 68000 access to 200000 completes at SDRAM latency rather
than block-RAM latency. None of this has run on hardware yet.

## Tier 2 — where it stands, 2026-08-24

Shogun Warriors and B.Rap Boys. Both romsets verify, both MRAs match their
stream image byte for byte, and all six games still do. The gate is green
throughout: lint, nports-check and test.

**Done and verified in simulation:**

| | |
|---|---|
| ROM layouts | transcribed from `ROM_START` for both sets |
| SDRAM map | shogwarr 24.4 MB, brapboys 15.4 MB |
| Memory map | `shogwarr_map` in full — work RAM 100000, palette 380000, sprite RAM 580000, VIEW2 600000, watchdog a80000, inputs b80000 |
| Video | one VIEW2 chip, VU-002 sprites, `set_offset(0x33,-8)`, priorities {1,3,5,7}, `set_offsets(0xa00,-0x40)` |
| Second OKI | ports 400001 and 480001, SDRAM port 9, shared bank register at e00001 |
| Hit calculator | `kaneko_hit`, type 1, fuzzed 202,615 checks / 0 fails |
| MCU RAM | 64 KB at 200000, byte-enabled, **in SDRAM on port 10** — zero M10K |

**Not started: the CALC3 simulation itself.** It is the largest single piece
and it is what makes the games run at all — everything above is inert without
it.

`mcu_run` waits on all four command bits, then reads a command word from the
shared 64 KB RAM. `0xff` is init: eight parameters read out, a ROM checksum
written back, 64 words of EEPROM copied in. Every other command drives a
table-transfer engine that decrypts blocks out of `calc3_rom`. In RTL that is a
sequencer with read and write access to the MCU RAM, plus the decryption
machinery, and the machinery is most of the ~1,690 lines.

Two things to know before starting it:

- **The internal ROM is not dumped**, so there is no low-level option. This is
  a port of MAME's high-level simulation and its correctness standard is
  agreement with that simulation, nothing more.
- **B.Rap Boys needs hit type 2** despite being the same PCB with the same
  chip. MAME says that means at least one implementation must be wrong. Do not
  assume the two games share anything not shown to be shared.

**Also outstanding for the board, smaller:** the CALC3 command-port decode at
280000/290000/2b0000/2d0000, and per-game input words — shogwarr reads P1, P2,
SYSTEM and UNK at b80000, which have not been transcribed bit by bit yet.

---

## PICK UP HERE — the sprite bug and two blind instruments

**1. Explosive Breaker is missing enemy sprites**, reported from hardware
against the public release. Invisible but still firing, so the game logic runs
and the drawing does not.

The next step is one reading, not more code: **the debug overlay's WHITE row**,
which counts sprite passes that did not finish before the next frame.

- zero — every sprite is reached, so the fault is in WHAT is drawn
- non-zero — the pass is cut short, and the table is walked DOWNWARDS, so
  whatever sits late in the list is never reached. That matches the symptom
  exactly.

**Partly answered 2026-08-24**: the sprite code was never reduced modulo the
ROM region, so codes past its end fetched from outside it and drew nothing.
Fixed, with a per-game modulus -- but measured at only 283 on-screen sprites in
7081 attract frames, so it is not established to be the whole fault. See
`docs/findings.md`. The next measurement is gameplay rather than attract, and
the structural gap is that the frame gate does not render sprites at all.

Already ruled out: the offscreen skip (tester turned it Off, no change), the
sprite ROM layout (matches ROM_START including both ROM_RELOADs), keep_sprites
(low-byte write only, inverted bit 2, starts false), the list size and the
priorities.

**2. The frame gate does not render sprites.** It composites four tilemap
layers and passes zero for sprite pen and priority. No automated check here
could have caught the bug above. Fixing this is the systemic answer and is
worth more than the individual bug.

**3. Explosive Breaker's tilemaps are one pixel right of MAME**, on a frame
that can show it. Its "100.00%" came from a frame where xadj 0, 1 and 2 all
score zero — horizontally uniform enough to be blind. Run `SWEEP=1` on the
frame binary to see the grid.

Checked and matching the oracle: dx=91 from set_offset(0x5b,-8), the +2 on each
chip's layer 1, (scroll_x + linescroll) >> 6 adding before shifting, the
line-scroll enables at bits 11 and 3, and line scroll indexed by map row.
LSOFF=1 changes nothing, so line scroll is not involved on that frame.

**The pattern across all three: an instrument that has never failed has not
been shown to work.** The IPL counter counted edges where only a level could
answer. The overlay's address rows were unreadable over a bright picture. The
frame gate reports a pass it cannot fail. Each looked green. Make a gate fail
on purpose before trusting it.

---

## Open questions that carry real risk

1. **Tier 3 needs the SDRAM clock at 144 MHz first.** Measured on hardware
   2026-08-23: the bus is 73.6% occupied on an average line and **98.6% on the
   worst**, leaving 11 clocks. The sprite bitmap needs 377 and cannot stay in
   block memory either, since KC-002's surface is 148% of the device. Raising
   the clock to 3x the core lengthens the line to 1152 clocks and leaves 587
   free, which fits with margin and takes the worst line from 99% to 66%.
   Full working and the four pieces of work in `docs/00-decisions.md` D5. Do it
   before writing any of the bitmap move. Tier 2 is unaffected -- it uses
   VU-002 and the bitmap already built.

1. **Rotation: the 180 setting was missing. Added 2026-08-24, UNTESTED on a
   turned monitor.** Reported from hardware 2026-08-23 as "rotated in every
   position, right in none" on a physically portrait monitor. The reason turns
   out to be plain: with Off, CW and CCW the OSD offered three of the four
   quarter turns, so if the correct one was the half turn no setting could
   reach it.

   `screen_rotate` asks for a half turn by NOT rotating and raising `flip`
   (`do_flip <= no_rotate && flip`), keeping the framebuffer because
   `fb_en <= ~no_rotate | flip`. This core had `flip` tied to `1'b0`, so the
   option existed in the framework and not in the menu. Now `O[26:24]`, five
   positions: Off, Auto, CW 90, CCW 90, 180.

   Still to confirm on the turned monitor. If 180 is also wrong then the
   original reading stands -- the option needs to express the DISPLAY's
   orientation rather than the rotation to apply, because on a portrait
   monitor a ROT90 game wants no rotation while a ROT0 game wants 90 degrees.

1. **Tier 2 and Tier 3 should become their own core. NOT branched yet, by
   decision -- finish Tier 1 first.** Recorded 2026-08-24.

   The bisect that found the Magical Crystals regression measured what Tier 2
   costs this device, and the numbers say it does not belong in the same
   bitstream as Tier 1:

   | commit | state |
   |---|---|
   | `bc2f4d1` second OKI, NPORTS 9->10 | good, +0.548 ns |
   | `67ea051` hit calculator + 64 KB MCU RAM | **cannot fit** -- 6773 LABs against the device's 4191 |
   | `239d83f` MCU RAM cut to 8 KB | **cannot close timing** -- -0.773 ns |
   | `355bf50` VIEW2 read port shared | fits and times, but **breaks Magical Crystals** |

   Read in order that is one story: Tier 2 did not fit, the port sharing was
   done to make room, and the room was bought by breaking a Tier 1 game. The
   64 KB of MCU RAM alone asks for more logic than the whole device has,
   because it does not infer into M10K.

   So the plan is a separate core for the CALC3 board, branched from a
   commit verified on hardware, with Tier 1 keeping the block memory and the
   nine SDRAM ports it actually needs. Two candidates for the branch point:

   - `bc2f4d1` -- the newest commit VERIFIED GOOD on hardware that already
     carries the CALC3 second OKI. Needs the two-line `p9_ack`/`p9_dout`
     declaration fix that `239d83f` supplied, because it does not compile as
     pushed.
   - `f8c00ac` -- current main, which carries the hit calculator and the ROM
     tables as well, none of it hardware-verified.

   Nothing is branched yet. Branching fixes a point in history and there was
   no reason to fix one before Tier 1 was finished.

1. **Folding the sprite mask into the bitmap: 20 blocks, and NOT free.**
   Attempted 2026-08-25 and backed out before it could ship.

   The idea is sound and the geometry supports it. The bitmap is 81,920 words
   of 16 declared bits, of which twelve are used, and the fitter puts it in
   2048x5 mode three blocks wide -- fifteen bits of storage per word. Bits
   13:10 are a hole that is already being paid for. The two 1-bit mask arrays
   cost **20 M10K blocks** and could live in that hole.

   Two obstacles, both real, neither noticed until the layout was actually
   read rather than assumed:

   - **The transparency test would break.** `kaneko_mixer` has
     `spr_here = |spr_pix` where `spr_pix` is `mix_word[13:0]` -- it ORs the
     hole. A mask bit anywhere in 13:10 makes every marked-but-not-drawn pixel
     opaque. Fixable: only `mix_word[9:0]` carries anything, so `spr_pix`
     can be `{4'd0, mix_word[9:0]}`, which is identical today and frees the
     hole properly.
   - **The mask needs a partial write.** A losing sprite pixel marks the mask
     without writing a colour, and the clear wipes the mask every pass but the
     pixels only when `keep_sprites` is false. So the two halves of the word
     are written independently, which means a read-modify-write or byte
     enables on a 13-bit word -- and a conditional or split write to an
     inferred array is the shape that has stopped M10K inference here twice,
     once costing 194,328 ALMs against the device's 41,910.

   Worth doing, with `tb_kaneko_spr_sys` covering first-writer-wins so a
   mistake is caught in simulation rather than on hardware. Not worth doing
   in a hurry.

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
