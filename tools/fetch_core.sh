#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Copy the core OFF a MiSTer, and report what is actually there.
#
#   tools/fetch_core.sh              -> build/fromboard/Kaneko16.rbf
#   MISTER=192.168.1.42 tools/fetch_core.sh
#
# WHY THIS EXISTS
#
# Nothing enters releases/ until a person has played THAT build, and the build
# a person has played lives on their SD card -- not necessarily anywhere else.
# build/quartus/Kaneko16.rbf is overwritten by the next `make quartus`, and on
# 2026-08-24 the bitstream running on the board had no copy in the repository
# and no recorded md5, so the one build known to work could not be released.
# This is how that build gets recovered.
#
# It also lists everything in cores/ matching Kaneko16, because MiSTer resolves
# <rbf>Kaneko16</rbf> by keeping the LEXICOGRAPHICALLY GREATEST name beginning
# Kaneko16 followed by '.' or '_', and '_' (0x5F) beats '.' (0x2E). So
# Kaneko16_GOOD.rbf silently wins over Kaneko16.rbf -- which once cost twelve
# hours of measuring a bitstream nobody meant to be running. If this prints
# more than one file, the one the FPGA loads is the last one listed.
#
# Auth matches tools/deploy.sh: ssh only reaches for SSH_ASKPASS when it has no
# controlling terminal, so SSH_ASKPASS_REQUIRE=force is what makes the helper
# run. No setsid -- detaching the process group wedged a whole session once.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MISTER="${MISTER:-192.168.1.105}"
MUSER="${MUSER:-root}"
CORE_DIR="/media/fat/_Arcade/cores"
MRA_DIR="/media/fat/_Arcade"
OUT="$ROOT/build/fromboard"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

if [ -z "${SSH_ASKPASS:-}" ]; then
  for c in /usr/bin/ksshaskpass /usr/lib/gcr-ssh-askpass \
           /usr/bin/ssh-askpass /usr/libexec/openssh/ssh-askpass; do
    [ -x "$c" ] && { export SSH_ASKPASS="$c"; break; }
  done
fi
export SSH_ASKPASS_REQUIRE=force
export DISPLAY="${DISPLAY:-:0}"

CTL="$(mktemp -u /tmp/kaneko-fetch-%C.XXXXXX)"
SSHOPTS=(-o StrictHostKeyChecking=no
         -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=60
         -o ConnectTimeout=10)
cleanup() { ssh "${SSHOPTS[@]}" -O exit "$MUSER@$MISTER" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$OUT"
say "== $MUSER@$MISTER"
ssh "${SSHOPTS[@]}" "$MUSER@$MISTER" true \
  || die "cannot reach $MISTER. Is it powered on and on the network?"

say "== every core matching Kaneko16 (the LAST is the one that loads)"
ssh "${SSHOPTS[@]}" "$MUSER@$MISTER" \
  "ls -1 $CORE_DIR | grep -i '^Kaneko16' | sort" || true
echo
ssh "${SSHOPTS[@]}" "$MUSER@$MISTER" \
  "md5sum $CORE_DIR/Kaneko16*.rbf 2>/dev/null" || true

say "== copying $CORE_DIR/Kaneko16.rbf"
scp "${SSHOPTS[@]}" -q "$MUSER@$MISTER:$CORE_DIR/Kaneko16.rbf" "$OUT/Kaneko16.rbf"

# Verify rather than trust: a short copy leaves a file that is present,
# plausible and wrong.
want="$(ssh "${SSHOPTS[@]}" "$MUSER@$MISTER" "md5sum $CORE_DIR/Kaneko16.rbf" | cut -d' ' -f1)"
got="$(md5sum "$OUT/Kaneko16.rbf" | cut -d' ' -f1)"
[ "$want" = "$got" ] || die "checksum mismatch: remote $want, local $got"
say "== MRAs on the card, against releases/"
# The MRA and the RBF are a pair whenever the SDRAM layout is involved: an
# older MRA with a newer core loads every ROM region at the wrong offset, and
# that shows as graphics missing or wrong rather than as a failure. So the
# question "is the board running what we shipped" is not answered by the core
# alone.
mkdir -p "$OUT/mra"
ssh "${SSHOPTS[@]}" "$MUSER@$MISTER" "ls -1 $MRA_DIR/*.mra 2>/dev/null" \
  | while IFS= read -r remote; do
      [ -n "$remote" ] || continue
      base="$(basename "$remote")"
      scp "${SSHOPTS[@]}" -q "$MUSER@$MISTER:$remote" "$OUT/mra/$base" 2>/dev/null || continue
    done

shopt -s nullglob
for f in "$OUT"/mra/*.mra; do
  base="$(basename "$f")"
  if [ -f "$ROOT/releases/$base" ]; then
    if cmp -s "$f" "$ROOT/releases/$base"; then
      printf "  same      %s\n" "$base"
    else
      printf "  \033[31mDIFFERS\033[0m   %s  (card %s / releases %s)\n" "$base" \
        "$(md5sum "$f" | cut -c1-8)" "$(md5sum "$ROOT/releases/$base" | cut -c1-8)"
    fi
  else
    printf "  on card only: %s\n" "$base"
  fi
done
for f in "$ROOT"/releases/*.mra; do
  base="$(basename "$f")"
  [ -f "$OUT/mra/$base" ] || printf "  in releases only: %s\n" "$base"
done

say "== ok"
echo "  $OUT/Kaneko16.rbf  $got"
echo "  $(stat -c%s "$OUT/Kaneko16.rbf") bytes"
