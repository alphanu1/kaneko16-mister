#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
"""Sort generated MRAs into the MiSTer release layout.

    releases/<Game> (Region).mra          primary, appears in /_Arcade/
    releases/_alternatives/_<Game>/...    variants, copied by hand

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

        if setname in PRIMARY:
            out = os.path.join(dst, f)
        else:
            # Anything not named primary is a variant. Grouping by the game's
            # display name rather than the set name, because that is what the
            # _alternatives directories are named after.
            parent = ALT_PARENT.get(setname, setname)
            out = os.path.join(dst, "_alternatives", f"_{parent}", f)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        shutil.copy2(path, out)
        staged += 1

    print(f"  staged {staged} MRA(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
