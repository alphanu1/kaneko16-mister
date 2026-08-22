#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Copy the built core and its MRAs to a MiSTer, and verify what landed.
#
#   tools/deploy.sh                  core + every releases/*.mra
#   tools/deploy.sh --core-only      just the .rbf
#   tools/deploy.sh --core-only --test-mra 'build/mra/Blaze On (Japan).mra'
#   MISTER=192.168.1.42 tools/deploy.sh
#
# --test-mra exists because nothing enters releases/ until it has passed on
# hardware, and an MRA cannot pass on hardware until it is on the hardware.
# It takes a path to any MRA and copies it without going through releases/,
# so a game under test can be tried without staging it as shipped.
#
# WHY THIS IS A SCRIPT AND NOT A LINE OF SSH
#
# ssh only reaches for SSH_ASKPASS when it has no controlling terminal, so the
# reflex is to wrap it in `setsid`. Doing that here detached the process group
# and wedged the calling shell so hard that every later command — `true`
# included — failed with no output, and the session had to be restarted.
#
# OpenSSH 8.4 added SSH_ASKPASS_REQUIRE=force, which asks the helper regardless
# of the terminal. That is the whole fix: no setsid, no detaching, nothing left
# holding the shell open. This box runs OpenSSH 10.4.
#
# One ControlMaster connection carries every copy, so the password is asked once
# rather than once per file.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MISTER="${MISTER:-192.168.1.105}"
MUSER="${MUSER:-root}"
RBF="$ROOT/build/quartus/Kaneko16.rbf"
CORE_DIR="/media/fat/_Arcade/cores"
MRA_DIR="/media/fat/_Arcade"

CORE_ONLY=0
TEST_MRAS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --core-only) CORE_ONLY=1 ;;
    --test-mra)  shift; [ $# -gt 0 ] || { echo "--test-mra needs a path" >&2; exit 1; }
                 TEST_MRAS+=("$1") ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$RBF" ] || die "no bitstream at $RBF — run 'make quartus' first."

# Pick an askpass helper. Without one and without keys, ssh would block forever
# on a password prompt nobody can see.
if [ -z "${SSH_ASKPASS:-}" ]; then
  for c in /usr/bin/ksshaskpass /usr/lib/gcr-ssh-askpass \
           /usr/bin/ssh-askpass /usr/libexec/openssh/ssh-askpass; do
    [ -x "$c" ] && { export SSH_ASKPASS="$c"; break; }
  done
fi
export SSH_ASKPASS_REQUIRE=force
export DISPLAY="${DISPLAY:-:0}"

CTL="$(mktemp -u /tmp/kaneko-deploy-%C.XXXXXX)"
SSHOPTS=(-o StrictHostKeyChecking=no
         -o ControlMaster=auto -o ControlPath="$CTL" -o ControlPersist=60
         -o ConnectTimeout=10)

cleanup() { ssh "${SSHOPTS[@]}" -O exit "$MUSER@$MISTER" 2>/dev/null || true; }
trap cleanup EXIT

say "== $MUSER@$MISTER"
ssh "${SSHOPTS[@]}" "$MUSER@$MISTER" true \
  || die "cannot reach $MISTER. Is it powered on and on the network?"

say "== core"
scp "${SSHOPTS[@]}" -q "$RBF" "$MUSER@$MISTER:$CORE_DIR/Kaneko16.rbf"

# Verify rather than trust. A short or interrupted copy leaves a file that is
# present, plausible and wrong, and the core then fails on hardware in a way
# that looks like an RTL bug.
want="$(md5sum "$RBF" | cut -d' ' -f1)"
got="$(ssh "${SSHOPTS[@]}" "$MUSER@$MISTER" "md5sum $CORE_DIR/Kaneko16.rbf" | cut -d' ' -f1)"
[ "$want" = "$got" ] || die "checksum mismatch: local $want, remote $got"
echo "  Kaneko16.rbf  $want  ok"

if [ "$CORE_ONLY" = 0 ]; then
  shopt -s nullglob
  # From releases/, not build/mra. `make mra` writes an MRA for every game the
  # ROM tables describe, including ones the core cannot run yet; releases/ is
  # the filtered set, staged through SUPPORTED. Copying the unfiltered set puts
  # entries in the arcade menu that look supported and fail undiagnosably.
  #
  # This looked in mra/ at the repository root, which has never existed, so it
  # always printed "none" and no MRA was ever deployed. Harmless while the
  # SDRAM map never moved; not harmless now that the map is sized for four
  # games and the RBF and its MRA are a matched pair.
  mras=("$ROOT"/releases/*.mra)
  if [ ${#mras[@]} -eq 0 ]; then
    say "== mra: none in releases/ — run 'make release'"
  else
    say "== mra"
    for m in "${mras[@]}"; do
      scp "${SSHOPTS[@]}" -q "$m" "$MUSER@$MISTER:$MRA_DIR/"
      echo "  $(basename "$m")"
    done
  fi
fi

# Test MRAs go on regardless of --core-only: the point of --core-only is to
# keep the SHIPPED set unchanged while debugging, and a test MRA is not in it.
if [ ${#TEST_MRAS[@]} -gt 0 ]; then
  say "== mra (TEST — not from releases/, not shipped)"
  for m in "${TEST_MRAS[@]}"; do
    [ -f "$m" ] || die "no such MRA: $m"
    scp "${SSHOPTS[@]}" -q "$m" "$MUSER@$MISTER:$MRA_DIR/"
    # Verified like the bitstream. An MRA that lands short is an MRA that
    # loads a truncated ROM stream, which looks exactly like an RTL bug.
    w="$(md5sum "$m" | cut -d' ' -f1)"
    g="$(ssh "${SSHOPTS[@]}" "$MUSER@$MISTER" "md5sum '$MRA_DIR/$(basename "$m")'" | cut -d' ' -f1)"
    [ "$w" = "$g" ] || die "checksum mismatch on $(basename "$m"): local $w, remote $g"
    echo "  $(basename "$m")  $w  ok"
  done
fi

say "done"
