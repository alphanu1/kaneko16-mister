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
