#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Bootstrap upstream dependencies for the KanekoCALC3 core.
#
#   tools/bootstrap.sh              read-only clones into third_party/
#   tools/bootstrap.sh --fork       fork to your GitHub account first (needs gh)
#   tools/bootstrap.sh --no-mame    skip the MAME sparse checkout
#   tools/bootstrap.sh --update     re-pin deps.lock to current upstream HEADs
#
# Everything lands in third_party/, which is gitignored and never committed.
# Nothing is copied into rtl/ automatically: licence terms differ per
# dependency. Read the licence report this prints before lifting any code.
#
# Hard rule 3: a dependency added here must ALSO be added to
# git.ignoredRepositories in .vscode/settings.json, in the same change.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/third_party"
LOCK="$ROOT/deps.lock"

DO_FORK=0
DO_MAME=1
DO_UPDATE=0

for a in "$@"; do
  case "$a" in
    --fork)    DO_FORK=1 ;;
    --no-mame) DO_MAME=0 ;;
    --update)  DO_UPDATE=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------- dependencies
#
# name | repo | branch | role | licence | forkable
#
# fx68k: jtfpga/fx68k rather than upstream ijor/fx68k, deliberately.
#
# Its hdl/fx68k.sv is BYTE-IDENTICAL to ijor's apart from line endings — it is a
# repackaging, not a fork — but it additionally ships hdl/verilator/, a variant
# that flattens the s_nanod struct into individual wires. Upstream's version
# cannot be linted or simulated by Verilator at all:
#
#   %Error-BLKANDNBLK: Unsupported: Blocking and non-blocking assignments to
#                      same non-packed variable: 'Nanod'
#
# So synthesis takes hdl/ (which is upstream's code) and simulation takes
# hdl/verilator/. Using ijor's directly would mean the 68000 is the one block in
# this project with no simulation harness.

DEPS=(
  "template|MiSTer-devel/Template_MiSTer|master|core skeleton and sys/ framework|GPL-2.0-or-later|yes"
  "fx68k|jtfpga/fx68k|master|68000 main CPU|GPL-3.0-only|yes"
  "jt49|jotego/jt49|master|YM2149 PSG, 2x on the base board|GPL-3.0-or-later|yes"
  "jt6295|jotego/jt6295|master|OKI M6295 ADPCM, 1-2x depending on title|GPL-3.0-or-later|yes"
  "jt51|jotego/jt51|master|YM2151 FM, Blaze On / Wing Force sound path|GPL-3.0-or-later|yes"
  "t80|MiSTer-devel/T80|master|Z80, Blaze On / Wing Force sound path|BSD-3-Clause|yes"
)

# --------------------------------------------------------------------- helpers

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

have() { command -v "$1" >/dev/null 2>&1; }

pin() { # repo dir -> sha
  git -C "$1" rev-parse HEAD 2>/dev/null || echo "UNKNOWN"
}

pinned_sha() { # name -> sha recorded in the existing deps.lock, empty if none
  [ -f "$LOCK" ] || return 0
  awk -v n="$1" '$1 == n { print $3 }' "$LOCK"
}

# Move a fresh clone back onto its recorded pin.
#
# Without this the lock is decorative: every clone takes branch HEAD and then
# deps.lock is overwritten with whatever arrived, so the file records what you
# happened to get instead of constraining what you got. MAME is the oracle this
# project verifies against — it silently moving between two machines, or between
# two runs on the same machine, undermines every comparison made against it.
#
# GitHub permits fetching a reachable SHA directly, so this stays a shallow
# fetch rather than deepening the clone.
#
# Written with explicit if/return rather than `test && return 0` guards: this
# script runs under `set -e`, where a bare failing test as the final command of
# a && list is a well-known way to abort the whole run.
checkout_pin() { # name dir -> checks out the pinned sha if one is recorded
  local name="$1" dir="$2" want have
  if [ "$DO_UPDATE" = 1 ]; then return 0; fi
  want="$(pinned_sha "$name")"
  if [ -z "$want" ] || [ "$want" = "UNKNOWN" ]; then return 0; fi
  have="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)"
  if [ "$have" = "$want" ]; then return 0; fi
  if git -C "$dir" fetch --depth 1 -q origin "$want" 2>/dev/null; then
    git -C "$dir" checkout -q FETCH_HEAD
    echo "  $name: pinned to $want"
  else
    warn "  $name: pinned $want not fetchable, left at branch HEAD ($(pin "$dir"))"
    warn "  $name: rerun with --update to re-pin deliberately"
  fi
}

# ------------------------------------------------------------------ toolchain

say "== toolchain"
need git
for t in verilator yosys; do
  if have "$t"; then echo "  $t        $(command -v $t)"
  else warn "  $t        MISSING — 'make test' and 'make area' will not run"; fi
done
# Hard rule 7: 17.0 only, by absolute path. Quartus is deliberately NOT on
# PATH — 24.1std is also installed here, it accepts Cyclone V, and a stray
# PATH entry is exactly how the wrong toolchain gets used without anyone
# noticing.
QROOT="${QUARTUS_ROOT:-/home/ben/intelFPGA_lite/17.0/quartus}"
if [ -x "$QROOT/bin/quartus_map" ]; then
  qv="$("$QROOT/bin/quartus_map" --version 2>/dev/null | grep -oE 'Version [0-9]+\.[0-9]+' | head -1 | cut -d' ' -f2)"
  if [ "$qv" = "17.0" ]; then
    echo "  quartus    $qv at $QROOT"
  else
    warn "  quartus    $qv at $QROOT — hard rule 7 wants 17.0. 'make quartus' will refuse."
  fi
else
  warn "  quartus    not found at $QROOT — 'make quartus' will refuse. Set QUARTUS_ROOT."
fi
if have quartus_map; then
  warn "  quartus    WARNING: a quartus_map is on PATH ($(command -v quartus_map))."
  warn "             Hard rule 7 builds by absolute path; a PATH entry is how the"
  warn "             wrong version gets used silently. Consider removing it."
fi
if have mame; then echo "  mame       $(command -v mame)"
else warn "  mame       MISSING — the oracle. Every open question here is answered by running it."; fi
if [ "$DO_FORK" = 1 ]; then
  need gh
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run 'gh auth login'"
  echo "  gh         $(gh api user --jq .login) (fork mode)"
fi
echo

# -------------------------------------------------------------------- vendors

mkdir -p "$VENDOR"
: > "$LOCK.tmp"
echo "# Pinned upstream revisions. Regenerate with tools/bootstrap.sh --update" >> "$LOCK.tmp"
echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOCK.tmp"

say "== dependencies"
for entry in "${DEPS[@]}"; do
  IFS='|' read -r name repo branch role lic forkable <<< "$entry"
  dest="$VENDOR/$name"
  url="https://github.com/$repo.git"

  if [ "$DO_FORK" = 1 ] && [ "$forkable" = "yes" ]; then
    user="$(gh api user --jq .login)"
    if gh repo view "$user/$(basename "$repo")" >/dev/null 2>&1; then
      echo "  $name: fork already exists at $user/$(basename "$repo")"
    else
      echo "  $name: forking $repo -> $user"
      gh repo fork "$repo" --clone=false --remote=false >/dev/null
    fi
    url="https://github.com/$user/$(basename "$repo").git"
  elif [ "$DO_FORK" = 1 ]; then
    warn "  $name: not forked ($lic licence — see licence report below)"
  fi

  if [ -d "$dest/.git" ]; then
    if [ "$DO_UPDATE" = 1 ]; then
      echo "  $name: updating"
      git -C "$dest" fetch --depth 1 origin "$branch" -q
      git -C "$dest" checkout -q FETCH_HEAD
    else
      echo "  $name: present, skipping (use --update to re-pin)"
      want="$(pinned_sha "$name")"
      if [ -n "$want" ] && [ "$want" != "UNKNOWN" ] \
         && [ "$(pin "$dest")" != "$want" ]; then
        warn "  $name: DRIFT — on disk $(pin "$dest"), lock says $want"
      fi
    fi
  else
    echo "  $name: cloning $repo"
    git clone --depth 1 --branch "$branch" -q "$url" "$dest"
    # Keep upstream reachable even when working from a fork.
    git -C "$dest" remote add upstream "https://github.com/$repo.git" 2>/dev/null || true
    checkout_pin "$name" "$dest"
  fi

  printf '%-14s %s %s\n' "$name" "$repo" "$(pin "$dest")" >> "$LOCK.tmp"
done

# ------------------------------------------------------------------ MAME
#
# MAME is enormous. Blobless partial clone plus a non-cone sparse checkout
# pulls only the reference sources this project reads, a few MB rather than
# several GB.
#
# src/mame/kaneko/ is the whole driver family in one directory: kaneko16.cpp,
# kaneko_tmap (VIEW2), kaneko_spr (VU-002 / KC-002), kaneko_calc3 and
# kaneko_toybox. The device models under src/devices/ are the sound and CPU
# parts the board wires to those customs.

if [ "$DO_MAME" = 1 ]; then
  echo
  say "== mame (sparse reference checkout)"
  dest="$VENDOR/mame"
  if [ -d "$dest/.git" ]; then
    echo "  present, skipping"
  else
    git clone --filter=blob:none --no-checkout --depth 1 -q \
      https://github.com/mamedev/mame.git "$dest"
    git -C "$dest" sparse-checkout init --no-cone
    git -C "$dest" sparse-checkout set \
      '/src/mame/kaneko/*' \
      '/src/devices/cpu/m68000/m68000.h' \
      '/src/devices/cpu/m68000/m68kcpu.*' \
      '/src/devices/cpu/m68000/m68kmusashi.*' \
      '/src/devices/cpu/m68000/m68kcommon.*' \
      '/src/devices/cpu/z80/*' \
      '/src/devices/sound/okim6295.*' \
      '/src/devices/sound/okiadpcm.*' \
      '/src/devices/sound/ay8910.*' \
      '/src/devices/sound/ym2151.*' \
      '/src/devices/sound/ymfm*' \
      '/src/devices/machine/eepromser.*' \
      '/src/devices/machine/eeprom.*' \
      '/src/devices/machine/gen_latch.*' \
      '/src/devices/machine/watchdog.*' \
      '/src/emu/tilemap.*' \
      '/src/emu/drawgfx.*' \
      '/src/emu/digfx.*' \
      '/src/emu/emupal.*' \
      '/src/emu/video/generic.*' \
      '/src/emu/video.*' \
      '/src/emu/screen.*' \
      '/src/frontend/mame/luaengine.cpp' \
      '/LICENSE.md'
    # Pin only AFTER sparse-checkout is configured. The clone is --no-checkout,
    # so checking out a ref before the sparse patterns exist would materialise
    # all ~31k tracked files and demand every blob — gigabytes, on a clone whose
    # entire purpose is to stay at a few MB.
    checkout_pin "mame" "$dest"
    git -C "$dest" checkout -q
    echo "  checked out $(find "$dest/src" -type f 2>/dev/null | wc -l) reference files"
  fi
  printf '%-14s %s %s\n' "mame" "mamedev/mame" "$(pin "$dest")" >> "$LOCK.tmp"
fi

# Preserve pins for anything vendored by hand rather than by this script — a
# local reference core copied in under hard rule 5, for instance. Without this
# the rewritten lock would silently drop them.
if [ -f "$LOCK" ]; then
  while read -r name repo sha; do
    case "$name" in \#*|"") continue ;; esac
    if ! awk -v n="$name" '$1 == n { found = 1 } END { exit !found }' "$LOCK.tmp"; then
      if [ -d "$VENDOR/$name/.git" ]; then
        printf '%-14s %s %s\n' "$name" "$repo" "$(pin "$VENDOR/$name")" >> "$LOCK.tmp"
      fi
    fi
  done < "$LOCK"
fi

mv "$LOCK.tmp" "$LOCK"

# --------------------------------------------------------------------- report

# fx68k reads its microcode with $readmemb at RUN time, relative to the working
# directory rather than to the source file. Symlinked into the root so a
# harness started from there finds them; without these fx68k elaborates and
# then executes an all-X microcode, which looks like a CPU that fetches once
# and stops.
if [ -f "$VENDOR/fx68k/hdl/microrom.mem" ]; then
    ln -sf third_party/fx68k/hdl/microrom.mem "$ROOT/microrom.mem"
    ln -sf third_party/fx68k/hdl/nanorom.mem  "$ROOT/nanorom.mem"
fi

# ------------------------------------------------------------------- sys/
#
# A MiSTer core builds against the framework's sys/ directory. Most cores commit
# a copy; this one does not, for the same reason third_party/ is not committed —
# it is upstream code that bootstrap places, so there is one rule rather than
# two. It is gitignored.
if [ -d "$VENDOR/template/sys" ]; then
    say "== sys/ framework"
    rm -rf "$ROOT/sys"
    cp -r "$VENDOR/template/sys" "$ROOT/sys"
    echo "  copied $(find "$ROOT/sys" -type f | wc -l) files from template"
fi

cat <<'REPORT'

================================ LICENCE REPORT ================================

Read this before copying a single line out of third_party/.

  template     GPL-2.0-or-later
               The repo LICENSE file is a GPLv2 copy, but the per-file headers
               in sys/ read "either version 2 of the License, or (at your
               option) any later version". That or-later clause is what makes
               the next line legal.

  fx68k        GPL-3.0-ONLY — verified against the files, 2026-08-20.
               The design study section 8 says "or-later". That is not what the
               repo grants. LICENSE is a bare GPLv3 text and fx68k.sv carries
               only "Copyright (c) 2018,2021 by Jorge Cwik" — no version
               clause, no or-later grant. The "any later version" strings in
               LICENSE are inside the licence's own how-to-apply appendix, not
               a statement by the author. Absent that grant, GPLv3 is
               version-only.
               GPL-3 and GPL-2-ONLY cannot be combined. They are compatible
               here only because MiSTer's sys/ is GPL-2-OR-LATER, which can be
               upgraded to GPL-3. CONSEQUENCE: taking fx68k forces this entire
               core to ship as GPL-3.0-only. Most MiSTer cores are
               GPL-2-or-later and this one will not be interchangeable with
               them. If or-later matters, ask Jorge Cwik for the grant rather
               than assuming it.

  jt49         GPL-3.0-or-later — verified, 2026-08-20.
  jt6295       GPL-3.0-or-later — verified, 2026-08-20.
  jt51         GPL-3.0-or-later — verified, 2026-08-20.
               Jotego's cores. Each hdl/ source carries the full or-later
               clause ("either version 3 of the License, or (at your option)
               any later version"), so unlike fx68k these genuinely are
               or-later. Compatible with the GPL-3 position above.
               Re-check on every --update: jotego has relicensed cores before,
               and the header in the file is what governs, not the LICENSE.

  t80          BSD-3-Clause — verified against the files, 2026-08-20.
               Not LGPL-2.1, which is what it is widely described as.
               MiSTer-devel/T80 ships NO licence file at all; the terms live in
               the T80.vhd header — Daniel Wallner's opencores BSD grant, with
               the retain-notice, synthesized-form and no-endorsement clauses,
               i.e. 3-clause. Sorgelig's 2018 version-350 additions add a bare
               copyright line and no separate terms.
               BSD-3-Clause is GPL-3 compatible and permissive, so this is the
               least constrained dependency here. The retain-the-notice and
               no-endorsement clauses still bind: keep the header intact on any
               file lifted, and do not use the authors' names to endorse.
               Only needed for the Blaze On / Wing Force sound path.

  mame         Mixed. The kaneko/ files vendored here carry BSD-3-Clause
               headers (Luca Elia, David Haywood). MAME as a whole is GPL-2.0.
               Check the header of every file you read, not the repo licence.
               BSD-3-Clause is readable AND adaptable — it is the reference of
               record for the two custom chips.

================================================================================
REPORT

cat <<'NEXT'
Useful paths now available:

  third_party/mame/src/mame/kaneko/kaneko16.cpp        board, clocks, memory map
  third_party/mame/src/mame/kaneko/kaneko_tmap.cpp     VIEW2 tilemaps  (novel RTL)
  third_party/mame/src/mame/kaneko/kaneko_spr.cpp      VU-002/KC-002   (novel RTL)
  third_party/mame/src/mame/kaneko/kaneko_calc3.cpp    CALC3 MCU, tier 2
  third_party/mame/src/mame/kaneko/kaneko_toybox.cpp   TOYBOX MCU, tier 3
  third_party/fx68k/hdl/fx68k.sv                       68000 (synthesis)
  third_party/fx68k/hdl/verilator/                     68000 (simulation)
  third_party/template/sys/                            MiSTer framework

The two files that matter first are kaneko_tmap.cpp and kaneko_spr.cpp. They
are the whole of M0 and the only parts of this core nobody has written before.

Next: make lint && make test    (hard rule 4 — before any Quartus build)
NEXT
