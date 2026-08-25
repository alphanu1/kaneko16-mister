#!/usr/bin/env python3
"""Check kaneko_gamecfg's SDRAM base addresses against the ROM layout tables.

TWO DESCRIPTIONS OF ONE THING, AND NOTHING CHECKED THEY AGREED.

`tools/build_rom_regions.py` owns where each region lands in SDRAM. The RTL
repeats those addresses as `base_trom0`, `base_trom1`, `base_spr` and
`base_oki` in `kaneko_gamecfg.sv`, as WORD addresses — half the byte offset.
Nothing compared them, and they drifted: base_spr was selected on
`blazeon_board`, but Blaze On and Wing Force share a PCB and NOT an SDRAM
layout. Wing Force's sprite fetcher read the middle of its own tile ROM and the
game drew no sprites, while Blaze On drew them and looked like a different bug.

`make mra` already cross-checks the MRA against the same tables because a
region misplaced there loads without error and shows up much later as garbage.
This is that check, one layer further in.
"""
import importlib.util
import re
import sys

# base_z80 was NOT checked here until the Z80 started reading SDRAM. While its
# ROM was a block-RAM copy filled by snooping the loader, a wrong base simply
# missed the window and left the memory empty -- the Z80 then did nothing at
# all, which is loud. Reading from SDRAM makes the same mistake quiet: the CPU
# fetches whatever happens to live at that address and runs it. Only two of the
# four games have a Z80, so the entry is allowed to be absent.
REGION = {"base_trom0": "view2_0", "base_trom1": "view2_1",
          "base_spr": "kan_spr", "base_oki": "oki1",
          "base_z80": "audiocpu"}


def load_tool():
    spec = importlib.util.spec_from_file_location("b", "tools/build_rom_regions.py")
    m = importlib.util.module_from_spec(spec)
    saved, sys.argv = sys.argv, ["check_bases"]
    try:
        spec.loader.exec_module(m)
    finally:
        sys.argv = saved
    return m


def rtl_bases(path="rtl/io/kaneko_gamecfg.sv"):
    """Every 25'hXXXXXX literal on each base_* assignment, in source order."""
    src = open(path).read()
    out = {}
    # base_mcuram is checked too, though it is not a loaded region and so has
    # no entry in REGION. It is scanned the same way.
    for name in list(REGION) + ["base_mcuram"]:
        m = re.search(rf"assign\s+{name}\s*=(.*?);", src, re.S)
        if not m:
            if name == "base_mcuram":
                out[name] = []          # this core may not have an MCU at all
                continue
            sys.exit(f"{name}: no assignment found in {path}")
        out[name] = [int(h, 16) for h in re.findall(r"25'h([0-9a-fA-F]+)", m.group(1))]
    return out


def main():
    tool = load_tool()
    rtl = rtl_bases()
    bad = 0
    for game in sorted(tool.SDRAM_MAPS):
        layout = {r: b for r, b, _ in tool.SDRAM_MAPS[game]}
        for name, region in REGION.items():
            if region not in layout:
                continue          # absent region: the base is a don't-care
            want = layout[region] // 2      # word address
            if want not in rtl[name]:
                print(f"  {game}: {name} must include word {want:#08x} "
                      f"(byte {layout[region]:#08x}) for {region}; "
                      f"RTL has {[hex(v) for v in rtl[name]]}")
                bad += 1
    # THE MCU RAM IS NOT A LOADED REGION, so it is not in SDRAM_MAPS and the
    # loop above cannot see it. It still has to agree: it sits above the ROM
    # stream, and a base that landed inside the stream would put the CALC3's
    # working memory on top of the sprite ROM -- which loads without error and
    # looks like an MCU fault rather than an address fault.
    if hasattr(tool, "mcuram_base"):
        for game in ("shogwarr", "brapboys"):
            if game not in tool.SDRAM_MAPS:
                continue
            want = tool.mcuram_base(game) // 2
            if want not in rtl.get("base_mcuram", []):
                print(f"  {game}: base_mcuram must include word {want:#08x} "
                      f"(byte {tool.mcuram_base(game):#08x}); "
                      f"RTL has {[hex(v) for v in rtl.get('base_mcuram', [])]}")
                bad += 1

    if bad:
        print("\nkaneko_gamecfg's SDRAM bases disagree with the ROM layout.")
        print("A base that points into another region loads without error and")
        print("shows up as missing or garbled graphics, per game.")
        return 1
    print(f"bases: {len(tool.SDRAM_MAPS)} game(s) agree with the ROM layout")
    return 0


if __name__ == "__main__":
    sys.exit(main())
