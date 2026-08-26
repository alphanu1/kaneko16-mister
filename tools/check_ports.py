#!/usr/bin/env python3
"""Fail the build when one of OUR modules has an input port connected to nothing.

WHY THIS EXISTS

kaneko_gamecfg computed seven per-game memory-map window pages and kaneko_bus
declared an input for each. The top level instantiated both and left the bus's
inputs off the instance. Quartus does not error on that: it ties the port to
GND and writes a warning. Every window then decoded at page 0x00 — which is
where the ROM lives — and the core shipped that way for eleven commits. One
game worked, another was black, and the difference looked like an RTL bug.

The warning was in build/quartus/KanekoCALC3.map.rpt on every single build:

  ; pg_wram ; Input ; Warning ; Declared by entity but not connected by
  ;                             instance ... the port will be connected to GND

Verilator's PINMISSING catches this class in one line, but the top level is
never verilated — it instantiates VHDL (T80) and vendor IP (pll, hps_io) — so
the build report is the only instrument that can see it.

WHY IT IS SCOPED

MiSTer's sys/ framework leaves ~48 inputs dangling by design (unused joystick
rumble, analog axes, SDRAM pins on boards without them). Flagging those would
make the check noise and it would be turned off within a week, which is worse
than not having it. So it flags only entities this repository owns.
"""
import re
import sys

MSG = "Declared by entity but not connected by instance"
HEADER = re.compile(r'Port Connectivity Checks:\s*"([^"]+)"')
ROW = re.compile(r"^;\s*([A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?)\s*;\s*Input\s*;")

# Entities this repository owns. A dangling input on anything else is somebody
# else's design decision and not ours to fail the build over.
def ours(path):
    # path looks like emu:emu|kaneko_bus:u_bus|altsyncram:...
    entity = path.split("|")[-1].split(":")[0]
    return entity.startswith("kaneko_") or entity == "emu"


def scan(lines):
    found, inst = [], None
    for line in lines:
        h = HEADER.search(line)
        if h:
            inst = h.group(1)
            continue
        if inst and MSG in line:
            m = ROW.match(line)
            if m and ours(inst):
                found.append((inst, m.group(1)))
    return found


SELFTEST = """
; Port Connectivity Checks: "emu:emu|kaneko_bus:u_bus"                      ;
; pg_wram  ; Input  ; Warning  ; Declared by entity but not connected by instance. If a default value exists, it will be used.  Otherwise, the port will be connected to GND. ;
; snd_we   ; Output ; Warning  ; Declared by entity but not connected by instance. Logic that only feeds a dangling port will be removed. ;
; in_unk   ; Input  ; Info     ; Stuck at VCC ;
; Port Connectivity Checks: "sys_top:sys_top|hps_io:hps_io"                 ;
; joystick_0_rumble ; Input ; Warning ; Declared by entity but not connected by instance. If a default value exists, it will be used.  Otherwise, the port will be connected to GND. ;
"""


def selftest():
    got = scan(SELFTEST.splitlines())
    # The real fault must be caught; an OUTPUT must not be; a framework input
    # must not be. A check that cannot fail is the thing it is guarding against.
    want = [("emu:emu|kaneko_bus:u_bus", "pg_wram")]
    if got != want:
        print(f"SELFTEST FAILED: got {got}, want {want}")
        return 1
    print("check_ports selftest: 1 caught, 1 output ignored, 1 framework input ignored, 0 fails")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(selftest())
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], errors="replace") as f:
        bad = scan(f)
    if not bad:
        sys.exit(0)
    print("\nINPUT PORTS CONNECTED TO NOTHING — Quartus tied these to GND:\n")
    for inst, port in bad:
        print(f"    {inst}\n        {port}")
    print("\nConnect them, or give the port a default in its declaration.")
    print("A memory-map page tied to GND decodes at 0x00, where the ROM lives.")
    sys.exit(1)
