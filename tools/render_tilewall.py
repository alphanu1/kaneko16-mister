#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
"""Render what rtl/video/kaneko_tilewall.sv should put on screen.

The bring-up core shows a contact sheet of the tile ROM in greyscale, which
looks like a jumble whether it is right or wrong. This produces the same image
from the ROM on disk, so "looks like garbage" can be settled by comparison
rather than by eye alone.

Mirrors the RTL exactly: 16 tiles across, index = row*16 + column, four 8x8
sub-tiles at byte 0/32/64/96 with 4-byte rows, and the nibble order selected by
region (tiles LSB-first, sprites MSB-first).

    tools/render_tilewall.py build/roms/explbrkr_view2_0.bin out.png [tiles|sprites]
"""
import sys, struct, zlib

W, H, V_START = 256, 224, 16


def render(rom, sprites=False):
    px = bytearray(W * H)
    for row in range(H):
        screen_y = V_START + row            # the RTL uses the raw scanline
        tile_y = screen_y >> 4
        fine_y = screen_y & 15
        for col in range(W):
            tile_x = (col >> 4) & 15
            fine_x = col & 15
            tile = (tile_y << 4) | tile_x

            run = (tile << 7) + ((fine_y >> 3) << 6) + ((fine_x >> 3) << 5) \
                + ((fine_y & 7) << 2)
            byte_off = run + ((fine_x & 7) >> 1)
            b = rom[byte_off % len(rom)]

            hi = (not (fine_x & 1)) if sprites else bool(fine_x & 1)
            v = (b >> 4) if hi else (b & 0xf)
            px[row * W + col] = (v << 4) | v
    return px


def write_png(path, w, h, gray):
    raw = b"".join(b"\x00" + bytes(gray[y * w:(y + 1) * w]) for y in range(h))
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    open(path, "wb").write(png)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    rom = open(sys.argv[1], "rb").read()
    mode = sys.argv[3] if len(sys.argv) > 3 else "tiles"
    write_png(sys.argv[2], W, H, render(rom, sprites=(mode == "sprites")))
    print(f"  wrote {sys.argv[2]}  {W}x{H}  from {sys.argv[1]} ({mode} nibble order)")
