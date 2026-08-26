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

| | before Tier 2 | with Tier 2 | MCU RAM in SDRAM |
|---|---|---|---|
| ALMs | 16,670 (40%) | 21,456 (51%) | **14,187 (34%)** |
| **M10K blocks** | — | **522 / 553 (94%)** | **467 / 553 (84%)** |
| worst-case slack | — | **-0.771 ns, FAILS** | **+0.331 ns, closes** |

The third column is this branch as it stands, 2026-08-25: the CALC3 core with
the Tier 1 hardware it does not need stripped out and the MCU's 64 KB moved to
SDRAM. Both numbers that mattered moved the right way at once — 57 blocks back,
and a build that could not close timing now closes with room. `check_ports`
is clean, so no `kaneko_*` input is dangling.

**It has not run on hardware, and it cannot yet run a game.** The CALC3 MCU
itself is unwritten, so both titles will sit waiting on a device that never
answers. This build is a fit-and-timing measurement, not something to play.

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

**Its oracle exists, though, and that comes first.** `tools/mame_calc3_trace.lua`
records what MAME's CALC3 puts into MCU RAM: a per-frame diff of the 64 KB at
200000-20ffff, plus the final image and the `calc3_rom` the decompressor reads,
so the RTL is fed exactly the bytes MAME was fed. On `shogwarr`, 8 seconds is
475 frames and 134,554 changed words; the init burst lands at frame 188.

**The per-frame diff cannot see the MCU on `shogwarr`, and that matters.** The
68000 fills MCU RAM with a repeating 7-byte pattern (55 dd bb 99 00 ff aa) and
overwrites the MCU's output between two samples, so every apparent "MCU burst"
in that trace is the CPU's fill. `tools/mame_calc3_writes.lua` replaces it for
this purpose: it taps writes in order and keeps maximal ascending byte-stride
runs of 64 bytes or more, which is what the decompressor produces and the
fill does not.

**The decompressor is transcribed and verified.** `tools/calc3_ref.py` is the
reference model — the linked-list table walk, both encryption paths, four
subtract types, four alternate-swap modes, the keyed rotate and the inline key
table with its two magic arrays. It reads the key table out of MAME's source
rather than keeping a second copy, so there is one copy of that data and it
stays attributed.

Checked against MAME's own writes on both games, byte for byte:

| | tables the game pulled | result |
|---|---|---|
| `shogwarr` | 19, 80, 41, 10, 11 (216 to 4,102 bytes) | all five identical |
| `brapboys` | 10, 11, 16, 12, 1d, 1a twice (78 to 3,584 bytes) | all seven identical |

What comes out is 68000 machine code — `48e7fffe` MOVEM.L, `4e56ffbc` LINK A6.
The CALC3 decompresses subroutines into RAM and the game calls them, which is
why a stub cannot fake it. B.Rap Boys pulls table 1a twice to 202000 both
times, so the mode 06 write-pointer reset MAME hardcodes for that game is
real and observable rather than a guess.

**The command sequencer is written and checked too.** `Sequencer` in the same
file does `mcu_run`: the 0xff init reading its seven parameters, the ROM
checksum and EEPROM copy, then transfer commands, each decompressing a table to
a rolling write pointer and writing the header and a 32-bit data pointer back
to the address the command names.

`make calc3` is the check, on both games — `CALC3_SET` picks which. It captures
what MAME writes, replays the same command stream through the model, and diffs
both the ADDRESSES and the BYTES:

    table 19  207fe0    216 bytes  ok
    table 80  2080bc    686 bytes  ok
    table 41  20836e   4102 bytes  ok
    table 10  209378   1328 bytes  ok
    table 11  2098ac   1010 bytes  ok

B.Rap Boys passes the same way: tables 10, 11, 16, 12 and 1d at 200872, 200944,
200a44, 200bd0 and 200c22.

**The init parameters are MAME's documented ones, not inferred.**
`kaneko_calc3.cpp` records the command each game issues —
`00FF 0059 019E 030A FFFE 0042 0020 7FE0` for shogwarr and
`00FF 00C2 0042 0830 082E 00C8 0020 0872` for brapboys — being the busy flag,
DSW address, EEPROM address, future command base, poll address, checksum
address and a 32-bit write base. Four were guessed here first and two of those
guesses were wrong; every table still matched, because a table's content does
not depend on them. That is how a wrong value survives a passing test. The
write bases confirm the captures independently: shogwarr's first run landed at
207fe0 and brapboys' at 200872.

The addresses are the part that confirms the pointer arithmetic — each is the
previous plus `(length + 3) & ~1` where length counts the two header bytes.
Getting that wrong shifts every later table, which is why the test checks
placement and not only content. It fails when broken: changing the `+3` to `+4`
gives 8 failures and exit 1.

It also reports what it did NOT check. A 25-second capture holds four runs from
commands the recorded stream does not cover, and they are listed rather than
scored — otherwise the length of the MAME run decides whether the model passes.
Those four start at 202000, which is the mode 06 write-pointer reset: MAME's
comment calls that "reasonable for brapboys, not sure about shogwarr", and the
capture shows shogwarr using it as well.

**First RTL landed: `rtl/mcu/kaneko_calc3_dec.sv`**, the per-byte transform.
Combinational, no memory, no state — the sequencer supplies the block
parameters, the byte index's parity, and the inline or key byte for that index.
Split out because it is the part that has to be exactly right and the part that
can be fuzzed with no ROM data.

`tb_kaneko_calc3_dec` runs it exhaustively over the mode space and randomly
over the data: 614,400 checks, 0 fails, covering 409,600 inline-path and
204,800 keyed-path cases and 25,600 of the Shogun Warriors table 0x40 special
case. It fails when broken — swapping the rotate direction under alternate-swap
modes 0 and 3 is caught on the first few cases.

Two checks, and neither is sufficient alone. The fuzz takes every path but
invents its data, and its reference is a second transcription of the same C, so
by itself it shows agreement between two transcriptions. `make calc3` uses real
data — what MAME's CALC3 actually wrote — but only the paths those two games
take. Together they cover both axes.

The `shift` port is three bits where the block header holds four. Every use in
the C masks with `& 7`, and `8 - shift` feeds the same masked rotate, so bit 3
cannot change a result: `shift == 9` and `shift == 1` agree both ways round.

**Second piece: `rtl/mcu/kaneko_calc3_keys.sv`**, the key ROM. The keyed path
selects one of 256 64-byte keys, but only **36 of those 256 exist** — MAME fills
the other 220 entirely with -1. Storing the 36 with a 256-entry index is 2.3 KB
and about 2 M10K instead of 16 KB and about 13, which matters on the branch
where block memory was the binding constraint. `shogwarr` uses 23 distinct keys
and `brapboys` 18, all inside those 36.

A key byte with no key asserts `absent` and the sequencer must stop. That is a
refusal, not a default: decrypting with another row's key gives plausible bytes,
and those bytes are 68000 instructions the game executes. MAME calls
`fatalerror()` at the same point.

`tb_kaneko_calc3_keys` checks all 256 key bytes at all 64 indices — 16,384
checks, 2,304 present and 14,080 absent, and it fails if either count is zero.
It catches a one-byte slot offset, which is the fault worth having a test for:
the wrong row is still a *valid* key, so nothing downstream would notice.

The data is generated by `tools/gen_calc3_keys.py` from MAME's source
(BSD-3-Clause) and **committed**, with an explicit `.gitignore` exception —
the blanket `*.hex` would otherwise have swallowed it in silence, the same
shape as the blanket `*.rbf` that once ate a `git add releases/`. It is not
ROM-derived: the CALC3's internal ROM has never been dumped, so there is no
romset to load it from and nothing for an MRA to carry, and hard rule 2 does
not apply. Generating it at build time instead would make every build need a
MAME checkout.

**Third piece: `rtl/mcu/kaneko_calc3_walk.sv`**, the block walk. The data ROM
is a linked list with no index, so reaching block N means stepping over the N-1
before it — a block's length is only known once its header has been read. The
walk returns the block's parameters and its data base.

`tb_kaneko_calc3_walk` fuzzes it over generated ROM images: 4,030 checks, 0
fails, covering 188 blocks with inline tables, 44 zero-length blocks (the
control operations) and 37 requests past the end of the chain, and it fails if
any of those counts is zero. The walk's arithmetic depends only on structure and
never on table content, which is why a generated ROM exercises it as well as a
real one and lets this sit in `make test`.

The ROM read in that testbench answers with a **variable** latency, 0 to 3
cycles. On hardware this sits on SDRAM behind an arbiter and the latency is
whatever the arbiter gives it; a testbench that always answered next cycle would
pass a state machine that only works at a fixed latency.

**Every offset in the walk is against ROM+1**, because the C steps past the
table-count byte before it starts. Reading one byte low gives a header that
still looks plausible — a length, a mode, a key — and decodes to rubbish.
Injecting exactly that fault makes the fuzz fail on the first trial.

**Fourth piece: `rtl/mcu/kaneko_calc3_table.sv`**, which drives the other
three. It runs the walk, then streams the block's data a byte at a time, pulling
each byte's key from the inline table or the key ROM and pushing both through
the transform.

Two details in it are the ones most likely to be subtly wrong:

- **The inline index is a counter, not a modulo.** The inline table can be any
  length, odd or even, so `i % size` would be a divide per byte. The index
  counts and wraps, and `inline_half` — the C's `(i / size) & 1` — is a toggle
  on each wrap.
- **The first two decoded bytes are the data header, not table data.** They go
  back to the address the command names and never into the table's destination.

`tb_kaneko_calc3_table` fuzzes it over generated ROMs and a generated key table:
53,217 checks, 0 fails, 52,345 decoded bytes, across 179 inline tables (94 of
them an odd size), 93 keyed tables and 28 zero-length control blocks, with a
variable ROM latency throughout. Removing the `inline_half` toggle fails at
exactly the first wrap of the inline table; both faults above are the kind that
look right for a table's first few bytes.

The C reference is now one copy in `sim/mcu/calc3_model.h`, shared by both
testbenches. It was duplicated, and two transcriptions of an algorithm this
fiddly drift — the drift would read as an RTL bug.

**Fifth piece: `rtl/mcu/kaneko_calc3.sv`**, the command sequencer, and the
device is now complete in simulation. It watches MCU RAM for a command once all
four command registers have been written, clears the command word as the
handshake, and runs either the `0xff` init — seven parameters, the ROM
checksum, 64 words of EEPROM — or a run of table transfers, each writing its
bytes at a rolling pointer and its header and 32-bit address back where the
command says. The DSW goes in inverted at the top of every run, as MAME does.

`tb_kaneko_calc3` drives it exactly as the 68000 does and compares the **whole
64 KB** afterwards: 82 checks, 0 fails, 40 inits, 208 transfers, 3 pointer
resets. Comparing the whole image matters — checking only the bytes expected to
change would pass a device that also wrote somewhere it should not, and this is
RAM the 68000 uses for everything else.

**Three real faults, all found by that test:**

- **Two branches assigned `ram_addr` in the same cycle**, so the second won and
  the data pointer's low half was written over the *next* command's parameter
  block. It also raised `ram_rd` and `ram_wr` together. The corruption looked
  like the device fetching the wrong table, because by then it was.
- **The key ROM was read one cycle too early.** It registers its output, but
  the address was registered too, so the read landed on the same edge as the
  address and returned the byte for the previous index — every keyed table
  shifted by one key byte. The table's own fuzz had been *modelling the key ROM
  as combinational*, so it passed throughout. It now models a registered ROM,
  and still passes with the fix.
- **A refused transfer still wrote back.** When a block names a key that does
  not exist the device correctly emits nothing, but the sequencer stored a
  header left over from the previous table and advanced the write pointer by
  four — so every later table landed four bytes further along.

The byte handover is a single-cycle valid/ready handshake. A registered pulse
against a level ready was not enough: ready stays high through the cycle the
consumer is still deciding to take the previous byte, so the next one was
emitted into a consumer that had moved on and was dropped, leaving tables short
near their end.

**A missing key is tested directly, not fuzzed.** MAME calls `fatalerror()`
there and stops the machine, so no real data ROM contains one — fuzzing it only
compares two arbitrary choices. The directed test states the expectation: raise
`key_missing`, write nothing, leave the pointer alone. The only writes it
tolerates are the command-word handshake and the DSW.

### Wiring it in

Two pieces the device needs from the core, and the shape chosen for each:

**Its data ROM reads go through `kaneko_tilerom`**, the byte feeder the OKI
already uses — an 8-byte cache in front of one SDRAM port, fuzzed at 240,001
checks. Reusing it beats writing another adapter, and the cache matters: the
checksum scan reads all 128 KB at reset, which is eight times fewer round trips
through a line than byte by byte. `base_calc3rom` is byte 0x40000 on both games,
now a named base checked against the ROM layout by `check_bases` — and that
check fails when the base is wrong, verified by making it wrong.

**Everything the CALC3 touches shares port 10**, through
`rtl/mcu/kaneko_mcuram_arb.sv` — three masters: the 68000 reaching the shared
RAM, the CALC3 reaching that same RAM, and the CALC3's data ROM fetch. So
`NPORTS` stays 11 and the data ROM does not get a port of its own.

Three reasons, in order of what they cost to get wrong:

- A port each puts a **second writer** on the SDRAM. This core has exactly one,
  the harness that checks the write path models one, and that path has never run
  on hardware. Two writers is not the change to make in the same step as
  bringing up a new device.
- One port makes coherency **structural**. The 68000 and the MCU share that RAM
  as their channel; with one access ever in flight a read cannot pass a write to
  the same address. Across two ports that ordering would be a hope.
- Every extra port is another entry in seven harnesses and a per-port switch in
  `tb_kaneko_sdram` — the churn where the last port-count change went wrong
  twice in one evening.

**Round robin, not fixed priority.** The CALC3 issues thousands of back-to-back
accesses while decompressing a table, and a fixed order starves whoever sits
below it for the whole run; the 68000 waits on DTACK, so starving it stalls the
game. `tb_kaneko_mcuram_arb` holds all three requests high for 200,000 cycles
and requires an even split: 257,068 checks, 0 fails, 19,021 / 19,022 / 19,021
served. Making the order fixed sends two masters to zero and fails it.

The testbench goes through a harness with one flat port per master. A packed
`[NM-1:0][SDR_AW:1]` reaches C++ as a single scalar, not one entry per master,
so indexing it addresses the wrong bits and reports the arbiter swapping data
between masters — a convincing-looking lie, already on record against
`kaneko_sdram_harness` for the same reason.

### It is wired in

`KanekoCALC3.sv` now carries the device, its ROM feeder and the arbiter. The parts
that needed a decision rather than a connection:

**The command registers.** `kaneko_bus` decodes 280000, 290000, 2b0000 and
2d0000 as four separate write strobes. They are NOT contiguous, and 2c0000 sits
in the gap carrying MAME's comment *"run calc 3? or irq ack?"* — decoding the
range instead of the four addresses would swallow it and hide whatever it is.

**The tick** is `vbl_rise`. MAME runs the device off a 59.1854 Hz timer, which
is a frame.

**The DSW is a constant, `0xE5`,** and not an OSD option yet: flip screen off,
demo sounds on, difficulty 0x20 of 0x38, can-join, continue-coin — MAME's
default positions. Bit 1 is **not defined by the port**, and MAME reads
undefined port bits as zero, so it is 0 and not 1. That is the same rule that
made Blaze On's idle SYSTEM word 0xFF00 rather than 0xFFFF. The device inverts
it, as MAME does. Confirmation the chain is right: MAME delivers this byte to
`200059`, and `dsw_addr` in the captured init parameters is `0x0059`.

**The EEPROM's backup port is shared** between the HPS's save/restore and the
MCU's init copy. The HPS keeps priority whenever it is *writing*: stealing the
address from a write sends that word to the wrong place and corrupts saved data,
where a stolen read only gives the MCU a stale word on a boot where the HPS
happens to be loading at the same instant. `eep_rd` says when the MCU is using
it rather than muxing on the address alone.

**Both remaining gaps are closed.**

`rtl/io/kaneko_hit2.sv` is the type-2 hitbox calculator. Same chip as Shogun
Warriors' and a different device: type 1 is a 2D box intersection, type 2 is
three axes with a mode register that changes how each reads its position and
size, and a flags word built from nine comparisons. `brapboys(config)` calls
`set_type(2)` after inheriting shogwarr's machine — hard rule 9 in one line,
since both games sit on the same board. Both calculators are instantiated and
the game picks; only the write strobe is steered, so the unselected one never
sees a write.

Fuzzed at 1,260,000 checks, 0 fails, with 7,797 overlapping cases and 29,826
misses — the values are clustered small most of the time on purpose, because a
uniform 16-bit spread almost never makes two boxes meet and the overlap paths
would go untested. **Every register has two write addresses and the pairs
interleave** (x1po at 0x00 and 0x28, x1so at 0x04 and 0x2c, z1po at 0x38 and
0x50), so the fuzz writes through both at random: 27,767 alias writes. Pointing
one alias at the wrong register fails by trial 16.

**EEPROM defaults** are loaded for both games, from
`tools/gen_eeprom_defaults.py`. They matter on a first boot where the HPS has no
saved file, and B.Rap Boys' array is not just title text — it carries coinage,
difficulty and a service counter, so an erased 0xffff device is not the same as
a defaulted one.

Two details worth keeping. The generator **strips block comments first**:
`kaneko16.cpp` carries two arrays named `shogwarr_default_eeprom`, an earlier
one commented out with the note that it "looks corrupt, some of the text is
wrong", and the live one below it — a parser taking the first match would take
the corrupt one, and both contain readable text, so nothing would look wrong.
And the load runs **when the ROM download finishes, not at reset**: `game_id`
arrives from the MRA over ioctl long after reset, so at reset no game looks like
one with defaults. That is the same late-config trap this core has already paid
for once.

### It builds

| | MCU RAM in SDRAM | CALC3 wired in | + type 2 and EEPROM defaults |
|---|---|---|---|
| ALMs | 14,187 (34%) | 15,014 (36%) | **15,686 (37%)** |
| M10K | 467 / 553 (84%) | 471 / 553 (85%) | **471 / 553 (85%)** |
| slack | +0.331 ns | +0.464 ns | **+0.470 ns** |

The MCU costs about 830 ALMs and 4 blocks; the second hitbox calculator about
670 ALMs and no blocks. `check_ports` is clean on every one of these.

**The key ROM took two goes to become a ROM, and the second attempt proved
nothing on its own.** It was built from LOGIC — 378 ALMs, zero M10K — because
the read was conditional:

```
key_data <= (slot == NONE) ? 8'h00 : keys[addr];   // reads on one branch only
```

A conditional read defeats inference outright, which is already on record here.
Padding the array to a power of two was necessary too — with 36 slots most
12-bit addresses are out of range and Quartus will not infer a memory it cannot
prove is bounded — but padding **alone changed nothing**, and the way that
showed was a **byte-identical bitstream**. That is the same tell as the edit
script that silently matched nothing. Reading unconditionally and applying the
absent case afterwards turned 378 ALMs into 15.1 and 0 blocks into 4.

Nothing here has run on hardware.

A diff rather than a write tap deliberately — a tap sees every access through
the space and cannot say who made it, so the 68000's own use of that RAM would
be indistinguishable from the MCU's. The MCU writes in bursts from a timer
callback between frames, which a once-a-frame sample captures whole.

Read `kaneko_calc3.cpp` alongside it. `mcu_run` (1591) waits on all four
command bits, then reads a command word: `0xff` is init — seven parameters out
of MCU RAM, then the ROM checksum and 64 EEPROM words written back — and any
other value is a count of table transfers. Each transfer runs
`decompress_table` (1227), a byte-serial walk of a linked list of blocks with
per-block mode, shift, subtract type, alternate swaps and an optional inline
key table. It is sequential and runs once per command rather than per pixel,
so it suits a slow state machine; it is also ~300 lines of C with many modes,
and every one of them has to be diffed against this trace.

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
