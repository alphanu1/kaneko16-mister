#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
"""Sort generated MRAs into the MiSTer release layout.

    releases/<Game> (Region).mra          appears in /_Arcade/

Every supported set goes at the top level. There are no alternatives at
present, and a supported set missing from PRIMARY is an error rather than a
quiet demotion -- see the note at the check.

Which is which comes from build_rom_regions.py's PRIMARY / ALT_PARENT tables,
so there is one description of it rather than a rule encoded twice.
"""
import os, re, shutil, sys, xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_rom_regions import PRIMARY, ALT_PARENT, SUPPORTED   # noqa: E402


def main():
    if len(sys.argv) < 3:
        print("usage: stage_release.py <mra_dir> <releases_dir>", file=sys.stderr)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    if not os.path.isdir(src):
        print(f"stage_release: no {src}/ — run 'make mra' first", file=sys.stderr)
        return 1

    staged = 0
    for f in sorted(os.listdir(src)):
        if not f.endswith(".mra"):
            continue
        path = os.path.join(src, f)
        try:
            setname = ET.parse(path).getroot().findtext("setname") or ""
        except ET.ParseError:
            print(f"stage_release: {f} is not valid XML", file=sys.stderr)
            return 1

        # THE SETNAME IS NOT ENOUGH OF A FILTER.
        #
        # build/mra accumulates diagnostic MRAs -- EB-A-cfg-after.mra,
        # EB-B-no-cfg.mra, ZZ-TEST-EB-as-game01.mra were all sitting there --
        # and every one of them carries a REAL setname, so a check on setname
        # alone waves them straight through. They were staged into releases/
        # looking exactly like shippable games, which is the last place a
        # debugging artefact should turn up.
        #
        # A release MRA is one this tool would itself have named. Anything
        # else is somebody's experiment.
        root = ET.parse(path).getroot()
        title = root.findtext("name") or ""
        expected = re.sub(r'[/\\:*?"<>|]', "-", title).strip() + ".mra"
        if f != expected:
            print(f"  skipping {f} — not a release name "
                  f"(its <name> says {expected!r})")
            continue

        if setname not in SUPPORTED:
            # See build_rom_regions.SUPPORTED: an MRA for a game the core
            # cannot run looks like a supported title and fails opaquely.
            print(f"  skipping {f} — core does not support {setname} yet")
            continue

        if setname not in PRIMARY:
            # EVERY SUPPORTED SET IS RELEASED AT THE TOP LEVEL. There are no
            # alternatives right now, and this raises rather than quietly
            # filing one away.
            #
            # MiSTer does not scan _alternatives/ -- a player copies from it by
            # hand -- so a set that lands there is a game the core supports and
            # nobody can find. That is exactly what happened to Blaze On: it is
            # the only dumped set of a fully working game, it was missing from
            # PRIMARY, and it was staged out of the menu while both the release
            # notes and the already-tracked file said it belonged in /_Arcade/.
            #
            # If a genuine variant ever appears -- a World Blaze On alongside
            # the Japan one -- decide THEN which leads, put it in PRIMARY and
            # the other in ALT_PARENT, and restore the branch this replaced.
            print(f"stage_release: {setname} is supported but not in PRIMARY.\n"
                  f"  Every supported set is released at the top level, so this\n"
                  f"  would have gone to _alternatives/ where MiSTer never looks.\n"
                  f"  Add it to PRIMARY in build_rom_regions.py.", file=sys.stderr)
            return 1

        out = os.path.join(dst, f)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        shutil.copy2(path, out)
        staged += 1

    print(f"  staged {staged} MRA(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
