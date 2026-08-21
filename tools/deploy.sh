#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Copy the built core and its MRAs to a MiSTer, and verify what landed.
#
#   tools/deploy.sh                  core + every mra/*.mra
#   tools/deploy.sh --core-only      just the .rbf
#   MISTER=192.168.1.42 tools/deploy.sh
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
for a in "$@"; do
  case "$a" in
    --core-only) CORE_ONLY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
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
  mras=("$ROOT"/mra/*.mra)
  if [ ${#mras[@]} -eq 0 ]; then
    say "== mra: none in mra/ — run 'make mra' to build them"
  else
    say "== mra"
    for m in "${mras[@]}"; do
      scp "${SSHOPTS[@]}" -q "$m" "$MUSER@$MISTER:$MRA_DIR/"
      echo "  $(basename "$m")"
    done
  fi
fi

say "done"
