-- Count what MAME's Z80 writes to each sound port, per second of emulated
-- time, so "the core is silent here" can be compared against "the hardware is
-- silent here too".
--
-- Wing Force plays menu music and nothing in the attract demo. Before hunting
-- that as a defect, the oracle has to say whether the attract demo has any
-- sound at all -- a game that is simply quiet there would look exactly the
-- same from the core's side.
--
-- Ports, from kaneko16.cpp's blazeon_soundport / wingforc_soundport:
--   02,03  YM2151     06  sound latch (read)     0a  OKI     0c  OKI bank
--
-- Taps and notifiers MUST be global or the subscription is collected and they
-- stop with no error.
local cpu = manager.machine.devices[":audiocpu"]
if cpu == nil then print("NO audiocpu"); return end
local io = cpu.spaces["io"]

counts = {}
seconds = 0

wtap = io:install_write_tap(0x00, 0xff, "ports", function(offset, data, mask)
    local p = offset & 0xff
    counts[p] = (counts[p] or 0) + 1
    return data
end)

rtap = io:install_read_tap(0x00, 0xff, "portsr", function(offset, data, mask)
    local p = (offset & 0xff) | 0x100          -- 0x1xx marks a READ
    counts[p] = (counts[p] or 0) + 1
    return data
end)

frames = 0
notify = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames % 60 ~= 0 then return end
    seconds = seconds + 1
    local parts = {}
    for p, n in pairs(counts) do
        local tag = (p >= 0x100) and string.format("r%02x", p & 0xff)
                                  or string.format("w%02x", p)
        parts[#parts+1] = string.format("%s=%d", tag, n)
    end
    table.sort(parts)
    print(string.format("t=%2ds  %s", seconds, table.concat(parts, " ")))
    counts = {}
end)
print("z80 port census: installed")
