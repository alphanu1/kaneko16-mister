-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16: does the 68000 command the Z80, and does the Z80 answer?
--
--   mame -rompath <roms> wingforc -autoboot_script tools/mame_wf_sound.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 180
--
-- Wing Force plays its in-game music and nothing else: no OKI effects and a
-- silent attract demo. Measured on hardware with the overlay's OKI chain, the
-- FIRST stage is what fails during attract -- the Z80 never writes port 0a at
-- all -- while on the title screen all four stages run. So the chip is fine
-- and the commands are not arriving.
--
-- That puts the question one level up, and this answers it: the 68000 writes
-- its sound command to the latch at e00000 (blazeon_map, and wingforc shares
-- that map), which raises the Z80's NMI; the Z80 reads it back at port 06.
--
--   latch_w   the 68000 asked for a sound
--   port06_r  the Z80's NMI handler ran and collected it
--   w0a/w0c   the Z80 drove the OKI
--   w02/w03   the Z80 drove the YM2151
--
-- Reported per second, so a silent stretch can be lined up against what is on
-- screen. If latch_w is busy while w0a is zero, the Z80 is being told and not
-- acting; if latch_w is zero too, the 68000 never asked.
--
-- Both flags are required, every time: without -skip_gameinfo the warning
-- screen blocks autoboot and this silently never loads; without
-- -autoboot_delay 0 it installs after the exchange it meant to capture.
-- Taps and notifiers MUST be global or the subscription is collected.
local mach = manager.machine
local main = mach.devices[":maincpu"]
local snd  = mach.devices[":audiocpu"]
if snd == nil then print("NO audiocpu"); return end

local prog = main.spaces["program"]
local io   = snd.spaces["io"]

wf_c = { latch_w = 0, p06 = 0, w0a = 0, w0c = 0, w02 = 0, w03 = 0 }
wf_frames = 0

-- The latch is a BYTE write at an even address; MAME maps e00000 exactly.
-- The COMMAND BYTE matters as much as the count. On hardware this core shows
-- the 68000 sending 0x17 for the title screen, which plays, and 0x01 for the
-- attract demo, which is silent. Whether 0x01 is what the board really sends
-- is the whole question.
wf_cmds = {}
wf_ltap = prog:install_write_tap(0xe00000, 0xe00001, "latch",
    function(offset, data, mask)
        wf_c.latch_w = wf_c.latch_w + 1
        local b = data & 0xff
        if b == 0 then b = (data >> 8) & 0xff end   -- byte lane, either half
        wf_cmds[#wf_cmds+1] = string.format("%3ds:%02x", wf_frames // 60, b)
        return data
    end)

wf_rtap = io:install_read_tap(0x00, 0xff, "pr", function(offset, data, mask)
    if (offset & 0xff) == 0x06 then wf_c.p06 = wf_c.p06 + 1 end
    return data
end)

wf_wtap = io:install_write_tap(0x00, 0xff, "pw", function(offset, data, mask)
    local p = offset & 0xff
    if     p == 0x0a then wf_c.w0a = wf_c.w0a + 1
    elseif p == 0x0c then wf_c.w0c = wf_c.w0c + 1
    elseif p == 0x02 then wf_c.w02 = wf_c.w02 + 1
    elseif p == 0x03 then wf_c.w03 = wf_c.w03 + 1 end
    return data
end)

wf_n = emu.add_machine_frame_notifier(function()
    wf_frames = wf_frames + 1
    if wf_frames % 60 ~= 0 then return end
    emu.print_info(string.format(
        "t=%3ds  latch_w=%-5d p06=%-5d | OKI w0a=%-5d w0c=%-3d | YM w02=%-5d w03=%-5d",
        wf_frames // 60, wf_c.latch_w, wf_c.p06, wf_c.w0a, wf_c.w0c, wf_c.w02, wf_c.w03))
    if #wf_cmds > 0 then
        emu.print_info("        commands: " .. table.concat(wf_cmds, "  "))
        wf_cmds = {}
    end
    for k in pairs(wf_c) do wf_c[k] = 0 end
end)
emu.print_info("wingforc sound-path census installed")
