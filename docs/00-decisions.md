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
