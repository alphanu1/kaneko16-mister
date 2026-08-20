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
-- The picture returned by scr:pixels() at frame N was rendered from the
-- register/VRAM state as it stood at frame N-1. Measured: explbrkr's chip1
-- scroll_x decrements 0x100 (4 pixels) per frame while scrolling, and frame
-- 400's picture matches frame 399's register value exactly — a +4 pixel offset
-- took frame 400 from 17,218 mismatches to ZERO.
--
-- So the tile state is captured STATE_LAG frames before the reference picture.
--
-- BUT this is NOT settled and the default is 0. STATE_LAG=1 makes explbrkr
-- frame 400 exact, and simultaneously takes mgcrystl frame 600 from 642
-- mismatches to 9,725 — with mgcrystl's tile registers provably IDENTICAL
-- across frames 598-600, so the regression comes from its VRAM/palette, not
-- its registers. The two games disagree about the correct alignment and the
-- mechanism is not understood. Default 0 preserves the better overall result;
-- STATE_LAG=1 reproduces the explbrkr-exact behaviour. See docs/findings.md.
local STATE_LAG = tonumber(os.getenv("STATE_LAG") or "0")

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
  -- blazeon_map: ONE VIEW2 chip, and only 0x1000 bytes of sprite RAM (512
  -- records, not 1024). 0x980000 is the second sprite chip's registers, which
  -- MAME treats as plain RAM and ignores.
  blazeonj = { view2_0 = 0x600000, spriteram = 0x700000, palette = 0x500000,
               regs0 = 0x800000, sregs = 0x900000, chips = 1, sprbytes = 0x1000 },
  wingforc = { view2_0 = 0x600000, spriteram = 0x700000, palette = 0x500000,
               regs0 = 0x800000, sregs = 0x900000, chips = 1, sprbytes = 0x1000 },
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

-- Scanline-accurate capture, as a single linear flow.
--
-- The driver does, at scanline 224:
--     render_sprites(m_spriteram->buffer());   // draws from the buffer
--     m_spriteram->copy();                     // buffer <- live
--
-- so the sprites visible in frame N were drawn from live RAM as it stood at
-- scanline 224 of frame N-1. An end-of-frame notifier fires ~32 lines LATE.
-- Capture at scanline 223 instead, for both N-1 and N-2, so a one-frame and a
-- two-frame lag can be told apart. MAME's own comment says "2 frame delayed
-- normaly; differs per PCB?", so neither is assumed.
--
-- This is written as ONE coroutine flow rather than a frame notifier that
-- resumes a second coroutine. That earlier arrangement was resumed both by the
-- notifier and by emu.wait's own scheduling, so it advanced twice per frame and
-- captured the wrong ones — mgcrystl scored 71% with 13,204 TILE misses, which
-- sprite RAM cannot cause. An instrument that perturbs what it measures reads
-- like a result. Autoboot scripts already run in a coroutine, so emu.wait works
-- directly here and no second coroutine is needed.

local scr = manager.machine.screens[":screen"]

while true do
    emu.wait_next_frame()
    frame = frame + 1

    if frame == FRAME - 2 or frame == FRAME - 1 then
        emu.wait(scr:time_until_pos(223, 0))
        dump(frame == FRAME - 1 and "spriteram_buf1.bin" or "spriteram_buf2.bin",
             M.spriteram, (M.sprbytes or 0x2000) / 2)
    end

    -- Tile state, captured STATE_LAG frames before the reference picture.
    if frame == FRAME - STATE_LAG then
        -- MAME renders the frame at VBLANK BEGIN, not at end of frame:
        -- screen_device::vblank_begin calls update_if_primary() unless the
        -- driver sets VIDEO_UPDATE_AFTER_VBLANK, which kaneko16 does not. The
        -- Lua frame notifier fires later still, in video_manager::frame_update
        -- after finish_screen_updates(). So an end-of-frame capture is up to a
        -- whole vblank period newer than the picture.
        --
        -- DUMP_AT=vblank waits for the real vblank start rather than guessing a
        -- scanline; the visible area ends at line 239 here, so a hardcoded 223
        -- is still inside the active display.
        local at = os.getenv("DUMP_AT") or "vblank"   -- default: the instant MAME renders
        if at == "vblank" then
            emu.wait(scr:time_until_vblank_start())
        elseif tonumber(at) then
            emu.wait(scr:time_until_pos(tonumber(at), 0))
        end

        print(string.format("== state at frame %d (picture at %d)", frame, FRAME))

        dump("view2_0_vram.bin", M.view2_0, 0x4000 / 2)
        dump("view2_0_regs.bin", M.regs0, 16)
        if (M.chips or 2) == 2 then
            dump("view2_1_vram.bin", M.view2_1, 0x4000 / 2)
            dump("view2_1_regs.bin", M.regs1, 16)
        end
        dump("spriteram.bin",    M.spriteram, (M.sprbytes or 0x2000) / 2)
        dump("spr_regs.bin",     M.sregs, 16)
        dump("palette.bin",      M.palette, 0x1000 / 2)

        local f = assert(io.open(DIR .. "/frame.txt", "w"))
        f:write(string.format("state_frame=%d\npicture_frame=%d\n", frame, FRAME))
        local reglist = (M.chips or 2) == 2 and { M.regs0, M.regs1 } or { M.regs0 }
        for chip, base in ipairs(reglist) do
            f:write(string.format("view2_%d_regs=", chip - 1))
            for i = 0, 15 do f:write(string.format("%04x ", space:read_u16(base + i * 2))) end
            f:write("\n")
        end
        f:write("spr_regs=")
        for i = 0, 15 do f:write(string.format("%04x ", space:read_u16(M.sregs + i * 2))) end
        f:write("\n")
        f:write(string.format("width=%d\nheight=%d\n", scr.width, scr.height))
        f:close()

        -- Picture, read in the SAME block as the state rather than at a later
        -- frame notifier.
        --
        -- Frame identity is not reliable across runs: emu.wait() inside this
        -- loop resumes on a timer, not on a frame notifier, so the counter
        -- stops tracking rendered frames. Two runs differing only by an
        -- emu.wait captured demonstrably DIFFERENT pictures for "frame 600"
        -- while every byte of state was identical. (Frameskip was ruled out —
        -- -noautoframeskip -frameskip 0 changes nothing.)
        --
        -- Reading the picture here removes the question entirely: whatever
        -- frame this is, the state and the picture describe the same instant.
        -- One line past the end of the visible area, so vblank_begin's
        -- update_if_primary() has run.
        emu.wait(scr:time_until_pos(scr.height + 1, 0))
        manager.machine.video:snapshot()
        local px = scr:pixels()
        local pf = assert(io.open(DIR .. "/frame.raw", "wb"))
        pf:write(px)
        pf:close()
        print(string.format("  frame.raw            %d x %d, %d bytes",
                            scr.width, scr.height, #px))
        manager.machine:exit()
        return
    end
end
