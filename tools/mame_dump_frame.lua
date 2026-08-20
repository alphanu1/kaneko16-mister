-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16: dump the complete video state at a chosen frame, plus MAME's own
-- rendered frame, so the RTL can be diffed against the oracle.
--
--   DUMP_DIR=/path DUMP_FRAME=600 \
--   mame -rompath <roms> mgcrystl -autoboot_script tools/mame_dump_frame.lua \
--        -skip_gameinfo -autoboot_delay 0 -video none -sound none \
--        -nothrottle -seconds_to_run 20
--
-- Both flags are mandatory every time: without -skip_gameinfo the warning
-- screen blocks autoboot and this never loads; without -autoboot_delay 0 it
-- installs after the frame it meant to capture. The notifier is a GLOBAL or it
-- is collected and stops silently.
--
-- Address map is mgcrystl_map, kaneko16.cpp:574. Every region is read through
-- the 68000 program space, which routes VRAM and register reads through the
-- devices exactly as the game sees them. Nothing here has read side effects;
-- the watchdog at 0xa00000 is deliberately not touched.

local DIR   = os.getenv("DUMP_DIR")   or "."
local FRAME = tonumber(os.getenv("DUMP_FRAME") or "600")
local SET   = os.getenv("DUMP_SET")   or "mgcrystl"

-- The memory maps differ per game and are NOT interchangeable. mgcrystl_map
-- puts the palette at 0x500000 and the VIEW2 windows at 0x600000/0x680000;
-- bakubrkr_map puts the VIEW2 windows at 0x500000/0x580000 and the palette at
-- 0x700000. Dumping one game with the other's map yields files of the right
-- size holding the wrong regions.
local MAPS = {
  mgcrystl = { view2_0 = 0x600000, view2_1 = 0x680000, spriteram = 0x700000,
               palette = 0x500000, regs0 = 0x800000, regs1 = 0xb00000,
               sregs = 0x900000 },
  explbrkr = { view2_0 = 0x500000, view2_1 = 0x580000, spriteram = 0x600000,
               palette = 0x700000, regs0 = 0x800000, regs1 = 0xb00000,
               sregs = 0x900000 },
}
local M = MAPS[SET] or error("no memory map for set '" .. SET .. "'")

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]
local frame = 0

-- Little-endian 16-bit, matching how the harness reads it back.
local function dump(name, base, words)
    local f = assert(io.open(DIR .. "/" .. name, "wb"))
    local t = {}
    for i = 0, words - 1 do
        local v = space:read_u16(base + i * 2)
        t[#t + 1] = string.char(v & 0xff, (v >> 8) & 0xff)
        if #t >= 4096 then f:write(table.concat(t)); t = {} end
    end
    if #t > 0 then f:write(table.concat(t)) end
    f:close()
    print(string.format("  %-20s %06x  %5d words", name, base, words))
end

_G.dump_sub = emu.add_machine_frame_notifier(function()
    frame = frame + 1

    -- Sprite RAM is BUFFERED and read a frame late. At scanline 224 the driver
    -- does render_sprites(m_spriteram->buffer()) and only THEN
    -- m_spriteram->copy() — so the sprites visible in frame N were rendered
    -- from the live RAM as it stood during frame N-1. Reading 0x700000 returns
    -- m_spriteram->live() (kaneko16.cpp:255), which is already the NEXT
    -- frame's data. Capture the previous frame's live copy as well, and let
    -- the renderer use that one. MAME's own comment says "2 frame delayed
    -- normaly; differs per PCB?" and kaneko_spr.cpp carries "TODO: verify
    -- sprite lag frames", so treat this as the best available guess, not a
    -- settled fact.
    if frame == FRAME - 1 then
        dump("spriteram_prev.bin", M.spriteram, 0x2000 / 2)
        return
    end

    if frame ~= FRAME then return end

    print(string.format("== dumping frame %d to %s", frame, DIR))

    -- VIEW2 chip 0 at 0x600000, chip 1 at 0x680000. Within each window,
    -- vram_map is: 0x0000 vram_1, 0x1000 vram_0, 0x2000 scroll_1, 0x3000
    -- scroll_0 — layer 1 sits at the LOW half, which is the trap.
    dump("view2_0_vram.bin", M.view2_0, 0x4000 / 2)
    dump("view2_1_vram.bin", M.view2_1, 0x4000 / 2)

    dump("view2_0_regs.bin", M.regs0, 16)
    dump("view2_1_regs.bin", M.regs1, 16)

    dump("spriteram.bin",    M.spriteram, 0x2000 / 2)
    dump("spr_regs.bin",     M.sregs, 16)

    dump("palette.bin",      M.palette, 0x1000 / 2)

    -- MAME's rendered frame, for the pixel diff.
    mach.video:snapshot()
    print("  snapshot written")

    -- Record what the frame actually contained, so a dump can be sanity
    -- checked without re-running.
    local f = assert(io.open(DIR .. "/frame.txt", "w"))
    f:write(string.format("frame=%d\n", frame))
    for chip, base in ipairs({ M.regs0, M.regs1 }) do
        f:write(string.format("view2_%d_regs=", chip - 1))
        for i = 0, 15 do f:write(string.format("%04x ", space:read_u16(base + i * 2))) end
        f:write("\n")
    end
    f:write("spr_regs=")
    for i = 0, 15 do f:write(string.format("%04x ", space:read_u16(M.sregs + i * 2))) end
    f:write("\n")
    -- MAME 0.289's Lua screen has no visible_area property; width()/height()
    -- report the visible area directly, and pixels() hands back the frame as
    -- raw data, which is a better diff target than decoding the PNG.
    local scr = mach.screens[":screen"]
    local w, h = scr.width, scr.height   -- properties, not methods, in 0.289
    f:write(string.format("width=%d\nheight=%d\n", w, h))
    f:close()

    local px = scr:pixels()
    local pf = assert(io.open(DIR .. "/frame.raw", "wb"))
    pf:write(px)
    pf:close()
    print(string.format("  frame.raw            %d x %d, %d bytes", w, h, #px))

    mach:exit()
end)
