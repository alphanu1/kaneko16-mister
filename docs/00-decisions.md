# Decision record

Decisions are locked unless a milestone exit produces measurements that contradict them.
Each entry records what was decided, why, and what would reverse it.

---

## D1 — Target is the Kaneko 16-bit arcade hardware

No MiSTer core exists and no public WIP was found as of August 2026. Two custom
graphics devices to write — VIEW2 tilemaps and VU-002/KC-002 sprites — both extracted
as standalone, register-documented, BSD-3-Clause devices in MAME. Everything else in
the system is an existing drop-in core.

Reverses if: someone announces a Kaneko16 core with real progress.

---

## D2 — GPL-3.0-only, not or-later

Forced by fx68k, which grants no or-later. See `THIRD-PARTY.md` for the evidence.
This is narrower than the study originally assumed and narrower than most MiSTer
cores, which are GPL-2-or-later.

Reverses if: Jorge Cwik states an or-later grant for fx68k, or fx68k is replaced with
a differently-licensed 68000.

---

## D3 — Vertical games get an OSD rotation toggle, defaulted to vertical

Two titles in the library are vertical, and **they rotate in opposite directions**:

| Title | Set | MAME rotation |
|---|---|---|
| Explosive Breaker / Bakuretsu Breaker | `explbrkr` | **ROT90** |
| Wing Force | `wingforc` | **ROT270** |

Everything else — Magical Crystals, Blaze On, Shogun Warriors, B.Rap Boys, Bonk's
Adventure, Blood Warrior, GTMR 1/2 — is ROT0.

The core exposes a rotation toggle in the MiSTer OSD for the vertical titles, and it
**defaults to vertical**: the cabinet orientation the game was designed for, correct
on a rotated monitor and correct for anyone with a vertical setup. Players on a fixed
horizontal display flip it themselves.

Defaulting to vertical rather than to "fit the monitor" is the deliberate half of this
decision. The alternative — defaulting to a rotated-into-horizontal presentation —
makes the common case wrong for the audience most likely to care, and quietly
normalises a presentation the hardware never produced.

Two consequences to carry into the video work:

- **The direction is per-game, not global.** ROT90 and ROT270 are both present, so the
  toggle selects between "as the cabinet was" and "rotated for a horizontal display",
  with the per-title direction coming from the game's configuration — not a single
  hard-coded rotation.
- **Rotation is an output-stage concern only.** VIEW2 and VU-002 work in native
  orientation; MAME applies rotation when presenting. The RTL must render natively and
  rotate on the way out, or the M0 frame diff compares a rotated reference against an
  unrotated render. (`screen:pixels()` returns the native 256x224 buffer, which is why
  the gate works today.)

Reverses if: MiSTer framework conventions make a vertical default actively broken on
common setups — in which case the toggle stays and only the default moves.

---

## D4 — Bring-up title is Explosive Breaker, not Magical Crystals

Changed 2026-08-20. The design study picked Magical Crystals for its simple
sound path. The frame gate has since made a stronger argument for a different
title.

**Bring up on a game whose video path is provably exact**, so that any failure
during bring-up is attributable to the CPU, bus or memory rather than to the
renderer. As measured:

| | video gate | sound path | VIEW2 chips | sprites |
|---|---|---|---|---|
| `explbrkr` | **exact**, several frames, content-rich | 2x YM2149 + OKI, **no sound CPU** | 2 | 1024 |
| `blazeonj` | exact, but the frame is 91% black | **Z80** + YM2151 + sound latch | 1 | 512 |
| `mgcrystl` | 298 px wrong (open line-scroll anomaly) | 2x YM2149 + OKI, no sound CPU | 2 | 1024 |

Explosive Breaker is chosen over Blaze On on the **sound path**, which is the
deciding factor rather than the video. Its sound chips sit directly on the
68000 bus as register files, so there is no handshake for the main CPU to
satisfy and sound can be stubbed entirely without risking the boot. Blaze On
drives a Z80 through a sound latch with an NMI on data-pending; a game that
waits on a sound-CPU response would stall a core that has not implemented one,
and diagnosing that during first bring-up is exactly the confusion this
decision exists to avoid.

Blaze On's gate result is also weaker: its captured frame is 91% black with 10
distinct colours, against Explosive Breaker's content-rich frames exact at
400, 600, 800, 900, 1000 and 1200.

ROT90 costs nothing here. The frame gate compares MAME's **native** buffer, so
rotation is purely an output-stage concern for the physical display (D3) and
does not complicate verification.

Magical Crystals is not abandoned — it is the one title exercising line scroll,
and its 298-pixel anomaly is the open question in the tilemap path. It gets
revisited once the rest of the system works, when a wrong picture can be
attributed with confidence.

Reverses if: Explosive Breaker turns out to need protection or I/O behaviour
that Blaze On does not, or if the Z80 path lands early enough to make Blaze
On's simpler video (one VIEW2, 512 sprites) the cheaper target.

---

## D5 — Sprites render into a bitmap, not a line buffer

VU-002 draws into a sprite bitmap once per frame and the bitmap is composited
during scanout. MAME says so directly (`kaneko_spr.cpp`): "actually
256x256x12bit (VU002) / 512x512x16bit (KC002), double buffered".

The obvious FPGA alternative — a per-scanline sprite renderer, as most arcade
cores use — was rejected on two grounds:

**It does not fit the timing.** A line is ~66 us. Scanning all 1024 records and
drawing those that intersect is up to 16,384 pixel writes; at 100 MHz a line
affords ~6,600 cycles. The bitmap spreads the same work over a whole frame:
1024 sprites x 256 pixels = 262,144 writes against ~1.7M cycles per frame,
which fits with room to spare.

**It would change behaviour.** A line renderer imposes a sprites-per-line
limit and the dropout that comes with it. VU-002 has no such limit, and
inventing one would be visible.

Cost is memory. A 16-bit cell (14-bit pen + 2-bit priority) over 320x256 is
160 KB per buffer, 320 KB double-buffered, against 691 KB of M10K. That is
affordable because the tilemap side needs little: 4 layers x 4 KB VRAM plus
4 KB palette is ~20 KB.

Double buffering is required, not optional: `render_sprites` flips `m_buffer`
each frame and draws into the new one while the old is composited.

Reverses if: the M10K budget tightens once the tile fetch path is built and
needs caching, in which case the fallback is a single buffer with drawing
confined to vblank, not a line renderer.

### Amended 2026-08-23 — the bitmap must move to SDRAM before Tier 3

The paragraph above is right for VU-002 and wrong about what happens next.
Measured against this device (553 M10K blocks, 5,662,720 bits):

| | bits | blocks | of device |
|---|---|---|---|
| VU-002 320x256x16, one buffer | 1,310,720 | 128 | 23% |
| VU-002 double-buffered (what we ship) | 2,621,440 | 256 | 46% |
| **KC-002 512x512x16, one buffer** | 4,194,304 | 410 | **74%** |
| **KC-002 double-buffered** | 8,388,608 | 819 | **148%** |

`kaneko_spr.cpp`: "actually 256x256x12bit (VU002) / 512x512x16bit (KC002),
double buffered". KC-002 is the Tier 3 chip — `gtmr`, and through it `gtmre`,
`gtmr2`, `bloodwar` and `bonkadv`.

**Its bitmap does not fit in this FPGA's block memory at all.** Not alongside
anything else, and not on its own: a single buffer is 74% of the device before
VRAM, palette, work RAM, the Z80 cache or ascal get a block.

**This retires the "separate RBF for Tier 3" fallback.** A separate bitstream
gives Tier 3 the whole device, and the whole device is still not enough — 819
blocks against 553. The constraint is capacity, not sharing, so splitting the
core cannot answer it. Moving the sprite bitmap into SDRAM is therefore a
PREREQUISITE for Tier 3 rather than an optimisation, and if it cannot be made
to work then Tier 3 is not reachable on this hardware by this design.

Tier 2 is unaffected: `shogwarr` and, through it, `brapboys` both instantiate
KANEKO_VU002_SPRITE, so they run on the bitmap we already have.

### Measured 2026-08-23 — the bandwidth is the constraint, not the capacity

Capacity was never the question: 1 MB of bitmap in 128 MB of SDRAM is 0.8%.
Bandwidth is, and the first measurement says the obvious scheme does not fit.

`tb_kaneko_sdram` now carries a tenth port modelling the bitmap against a
per-line deadline, with the other nine streaming. A scanline is 384 core clocks
= 768 SDRAM clocks, and the bus delivers about **490 words** in that time at the
measured 0.638 words/clk.

| per line | words | |
|---|---|---|
| tile feeders, 4 layers x 320 px x 4bpp | 320 | already spent |
| sprite bitmap, full-width scanout | 320 | |
| **total** | **640** | **131% of the line — does not fit** |

Reading the bitmap only where the coverage mask claims a pixel changes the
arithmetic: 352 words at 10% sprite coverage, 416 at 30%, 480 at 50%. That
fits, and it removes the frame clear as well — nothing reads a pixel the mask
does not claim, so stale data is never seen and the 81,920 words a frame of
zeroing never happen. Sprites are 16 pixels wide, so coverage arrives in runs
of at least four bursts and stays burst-efficient.

**The headroom is small either way**, and that is the part to be careful about.
The tile feeders alone want two thirds of the line. The bitmap is competing for
what is left rather than moving into empty space, which is a different and much
tighter proposition than the capacity figures suggest.

The saturated-bus model in the harness has all nine masters requesting flat out
— port 0 alone on 83% of cycles — which is far more than the board presents. It
bounds the problem; it does not settle it. **What would settle it is real
per-master utilisation measured on hardware**, and `bw_monitor` exists for
exactly that but is instantiated only in the simulation harness. Putting it in
the core is the next step, before any of `kaneko_spr_sys` is touched.

The mask stays in block RAM regardless: 16 blocks against the bitmap's 256, and
the renderer hits it randomly every clock, which is the worst pattern SDRAM has.

### MEASURED ON HARDWARE 2026-08-23 — the bitmap cannot move to SDRAM

Explosive Breaker, in play, counted in the 96 MHz domain. Every figure is
clocks out of the 768 a scanline lasts.

| | clocks | of the line |
|---|---|---|
| total occupancy | 565 | 73.6% |
| of which tile feeders | 283 | 36.8% |
| of which sprite ROM | 64 | 8.3% |
| everything else — 68000, OKI, Z80 | 218 | 28.4% |
| **peak on any line in the frame** | **757** | **98.6%** |

Free on an average line: **203 clocks**. Free on the worst line: **11**.

What the bitmap would need, per line, with four-word write combining:

| | clocks |
|---|---|
| writes, row-hit | 257 |
| sparse reads at 30% coverage, row-hit | 120 |
| **best case total** | **377** |
| typical total | 603 |

**377 needed against 203 free, and 11 free on the worst line.** It does not
fit, and the peak is the part that ends the argument: some scanlines are
already at 98.6%, so any added traffic overruns them immediately rather than
degrading gracefully.

One estimate was badly wrong and is worth correcting: the tile feeders were
predicted at 65% of the line and measure 36.8%. Bursts are far more efficient
than the wandering-cursor benchmark suggested. That correction makes the result
*worse*, not better — it means the 28.4% spent by the 68000, OKI and Z80 is
larger than the entire tile path, and that is where any future headroom would
have to come from.

**Consequences.**

Tier 3 is not reachable by this design. KC-002's 512x512x16 double-buffered
surface is 148% of the device's block memory, so it cannot stay on-chip, and
the bandwidth to move it off-chip does not exist. Both routes are closed.

**Tier 2 is unaffected and should proceed.** `shogwarr` and `brapboys` both
instantiate KANEKO_VU002_SPRITE and run on the bitmap already built. Nothing
about this measurement touches them.

If Tier 3 is wanted later, the routes worth investigating, in order of promise:

1. **Find the 28.4%.** It is unattributed and larger than the tile path. If the
   68000's ROM line cache is thrashing, recovering even half of it changes the
   arithmetic. Measuring it needs per-port occupancy rather than the three
   groups counted here.
2. **Band rendering.** Keep a horizontal band of the surface on-chip and make
   several passes over the sprite list. This is what the earlier core does. It
   trades SDRAM bandwidth for repeated list walks and does not impose the
   per-line sprite limit that D5 rejected.
3. Neither, and Tier 3 stays out of scope.

Order follows from that: do the SDRAM move **before** Tier 2, while only four
games depend on the sprite subsystem. Doing it afterwards means the same
surgery re-verified across thirteen sets instead of four, and hard rule 9 says
every one of them gets checked.

---

## D6 — The MRA owns the SDRAM layout; the loader maps it as the identity

Stream byte N is SDRAM byte N. The MRA pads each region and emits them in the
order the map expects, and `rtl/io/kaneko_rom_loader.sv` does no per-region
base arithmetic at all.

Tier 1 map, encoded once in `tools/build_rom_regions.py` (`SDRAM_MAP`) and
reproduced by the MRA:

```
  0x000000  maincpu   512 KB    68000 program
  0x080000  view2_0     1 MB    VIEW2 chip 0 tiles
  0x180000  view2_1     1 MB    VIEW2 chip 1 tiles
  0x280000  kan_spr  2.25 MB    sprites
  0x4c0000  oki1        1 MB    OKI samples
  0x5c0000  end       5.75 MB
```

The alternative — a loader carrying region offsets computed from each other —
is where the bugs are. From the ported loader's own header: it *"does not fail
at load time, it fails much later as a game that boots to garbage, and the
evidence points at the CPU rather than at the loader"*. Making the MRA
responsible means a region can only be misplaced by editing the MRA, where it
is visible, rather than by arithmetic in RTL.

Consequence: `tools/build_rom_regions.py` and the MRA are two descriptions of
one thing and **must agree**. They are kept in one table, and the MRA should be
generated from it rather than written a second time.

Sized for Tier 1. Later tiers have larger sprite ROMs; growing the map means
editing that table and the MRA together, and never RTL.

Reverses if: a game needs a region that cannot be padded into a fixed slot, in
which case the loader gains a per-index base — one number per download index,
not per region, and still not arithmetic over the stream.

## D7 — The 68000's byte swap lives in kaneko_bus, not in the MRA or the loader

The stream the HPS delivers is little-endian with respect to the ROM files:
`hps_io` is built with `WIDE=1`, and in WIDE mode file byte *n* arrives in
`ioctl_dout[7:0]` with byte *n+1* in `[15:8]`. The loader stores that word
verbatim, so SDRAM word *n* is `{file[2n+1], file[2n]}`.

The graphics path is built around exactly that order and is pixel-exact against
MAME for three of the four Tier 1 titles. The stream is therefore correct and
is not the thing to change.

The 68000 is big-endian — byte *n* is the **high** half of its word — so
something has to convert. Three places could:

- **The MRA**, with a byte-swapping `<interleave>` over the `maincpu` part.
  Rejected: it would split the description of the stream between the MRA and
  `tools/build_rom_regions.py --stream`, which `tools/verify_mra.py` exists to
  keep identical, and it would make the stream no longer a plain concatenation
  of the region files the frame gate reads.
- **The loader**, swapping while writing. Rejected: the loader would then need
  to know which region each word belongs to, which is precisely the knowledge
  D6 moved out to the host.
- **`kaneko_bus`, on the ROM read.** Chosen. It is the endian boundary — the
  only point in the design where a byte order becomes a *CPU's* byte order —
  and it is one line at the place a reader would look for it.

Nothing else needs the swap: the CPU's writes to work RAM, video RAM, sprite RAM
and palette carry `oEdb` unaltered, which is already the word MAME would write,
and the video side reads those same words back.

See findings, "The 68000 read the ROM with its bytes the wrong way round".
