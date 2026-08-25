-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 / Wing Force: WHICH YM2151 registers the Z80 writes, and what the
-- status byte reads back.
--
--   mame -rompath <roms> wingforc -autoboot_script tools/mame_wf_ym.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 60
--
-- Measured on hardware, this core polls the YM status at MAME's rate -- 120 a
-- frame against the oracle's ~117 -- and issues 120 WRITES a frame where the
-- oracle issues about 8. One write per poll is the signature of a driver
-- clearing something every time it looks, which is what a stuck timer flag
-- would produce.
--
-- So the two things worth knowing from the oracle are the register histogram
-- and the STATUS BYTE. If MAME's status alternates and ours is stuck, that is
-- the fault; if MAME writes 0x14 as often as we do, the pattern is normal and
-- the fault is elsewhere.
--
-- Ports: 02 is the address latch (A0=0), 03 is data (A0=1). A register write
-- is therefore a write to 02 followed by a write to 03.
--
-- Both flags are required, every time. Taps and notifiers MUST be global.
local mach = manager.machine
local snd  = mach.devices[":audiocpu"]
if snd == nil then print("NO audiocpu"); return end
local io = snd.spaces["io"]

ym_addr_latch = 0
ym_regs   = {}     -- register -> writes
ym_status = {}     -- status byte value -> times read
ym_frames = 0
ym_reads  = 0
ym_writes = 0

ym_wtap = io:install_write_tap(0x02, 0x03, "ymw", function(offset, data, mask)
    local p = offset & 0xff
    if p == 0x02 then
        ym_addr_latch = data & 0xff
    else
        ym_regs[ym_addr_latch] = (ym_regs[ym_addr_latch] or 0) + 1
        ym_writes = ym_writes + 1
    end
    return data
end)

ym_rtap = io:install_read_tap(0x03, 0x03, "ymr", function(offset, data, mask)
    local v = data & 0xff
    ym_status[v] = (ym_status[v] or 0) + 1
    ym_reads = ym_reads + 1
    return data
end)

ym_n = emu.add_machine_frame_notifier(function()
    ym_frames = ym_frames + 1
    if ym_frames % 600 ~= 0 then return end
    emu.print_info(string.format("---- frame %d (%.0f s) ----", ym_frames, ym_frames/60))
    emu.print_info(string.format("  status reads %d (%.1f/frame)   register writes %d (%.1f/frame)",
        ym_reads, ym_reads/600, ym_writes, ym_writes/600))
    local keys = {}
    for k in pairs(ym_regs) do keys[#keys+1] = k end
    table.sort(keys, function(a,b) return ym_regs[a] > ym_regs[b] end)
    local line = "  top registers:"
    for i = 1, math.min(#keys, 6) do
        line = line .. string.format("  %02x=%d", keys[i], ym_regs[keys[i]])
    end
    emu.print_info(line)
    local sk = {}
    for k in pairs(ym_status) do sk[#sk+1] = k end
    table.sort(sk, function(a,b) return ym_status[a] > ym_status[b] end)
    local sl = "  status bytes :"
    for i = 1, math.min(#sk, 6) do
        sl = sl .. string.format("  %02x=%d", sk[i], ym_status[sk[i]])
    end
    emu.print_info(sl)
    ym_regs = {}; ym_status = {}; ym_reads = 0; ym_writes = 0
end)
emu.print_info("wingforc YM register census installed")
