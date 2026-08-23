-- What a WORKING Wing Force driver writes to the YM2151, by register.
--
-- The core writes the chip at MAME's rate -- about fifteen times a frame --
-- and jt51 produces nothing, so the counts are right and the CONTENT is the
-- open question. Counting got as far as it can; this says which registers a
-- healthy driver actually touches.
--
-- The YM2151 is written as a pair: register number to the address port, value
-- to the data port. Tapping the device's own write handler gives the decoded
-- pair rather than the two halves.
--
-- Registers that decide whether anything is audible at all:
--   0x08        KEY ON/OFF -- no writes here means no notes, whatever else
--               is going on
--   0x0f        noise enable
--   0x10-0x14   timer A/B period and control. The driver polls the timer
--               flags about seven thousand times a second, so if these are
--               never set up the flag it waits for never arrives.
--   0x20-0x3f   per-channel connection, feedback, key code
--   0x60-0x7f   total level -- all 0x7f is silence with everything else
--               looking perfectly healthy
--
-- Assign taps and notifiers to GLOBALS or the subscription is collected.
local ym = manager.machine.devices[":ymsnd"]
if ym == nil then
    for tag, dev in pairs(manager.machine.devices) do
        if tag:find("ym") then print("candidate: " .. tag) end
    end
    print("NO :ymsnd -- see candidates above")
    return
end

local io = manager.machine.devices[":audiocpu"].spaces["io"]
regs = {}
last_addr = -1
frames = 0

wtap = io:install_write_tap(0x00, 0xff, "ym", function(offset, data, mask)
    local p = offset & 0xff
    if p == 0x02 then
        last_addr = data & 0xff              -- address half
    elseif p == 0x03 and last_addr >= 0 then
        regs[last_addr] = (regs[last_addr] or 0) + 1
    end
    return data
end)

notify = emu.add_machine_frame_notifier(function()
    frames = frames + 1
    if frames ~= 900 then return end          -- ~15 s in, demo running
    local keys = {}
    for r in pairs(regs) do keys[#keys+1] = r end
    table.sort(keys)
    print(string.format("== YM2151 register writes over %d frames", frames))
    local line = ""
    for _, r in ipairs(keys) do
        line = line .. string.format("%02x:%-5d ", r, regs[r])
        if #line > 90 then print("   " .. line); line = "" end
    end
    if #line > 0 then print("   " .. line) end
    manager.machine:exit()
end)
print("ym register census: installed")
