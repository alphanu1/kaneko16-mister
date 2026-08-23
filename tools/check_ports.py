#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
"""Fail the build if one of OUR modules has an input left off its instance.

A port declared on a module and omitted at the instance does not fail
synthesis. Quartus ties it to GND and says so in a warning nobody reads. The
per-game memory map shipped for eleven commits driving pg_wram and friends that
way, and the only symptom was one game working and another black.

Verilator's PINMISSING catches this in one line, but the top level is never
verilated because it instantiates VHDL and vendor IP, so the map report is the
only place it shows up here.

SCOPED TO kaneko_* ENTITIES ON PURPOSE. ascal, hps_io, sysmem_lite and the
Altera PLL between them leave 48 inputs dangling by design; a check that
counted those would fire on every build and be switched off within a week.
"""
import re, sys

def main(path):
    entity, bad = None, []
    try:
        lines = open(path, errors="ignore")
    except OSError as e:
        print(f"check_ports: cannot read {path}: {e}", file=sys.stderr)
        return 1
    for line in lines:
        m = re.search(r'Port Connectivity Checks:\s*"([^"]+)"', line)
        if m:
            entity = m.group(1)
            continue
        if "Declared by entity but not connected by instance" not in line:
            continue
        parts = [p.strip() for p in line.split(';')]
        if len(parts) > 3 and parts[2] == "Input" and entity:
            leaf = entity.split('|')[-1].split(':')[0]
            if leaf.lower().startswith("kaneko"):
                bad.append((entity, parts[1]))
    if bad:
        print("check_ports: INPUTS LEFT OFF AN INSTANCE — these read as GND:",
              file=sys.stderr)
        for e, p in bad:
            print(f"  {e}.{p}", file=sys.stderr)
        return 1
    print("ports: no kaneko_* input left unconnected")
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1
                  else "build/quartus/Kaneko16.map.rpt"))
