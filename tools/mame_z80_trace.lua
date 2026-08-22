-- Dump the Blaze On board's Z80 program-fetch addresses, so the core's ROM
-- cache can be measured against real sound code instead of guessed at.
--
-- kaneko_z80rom is a 32-line, 8-byte direct-mapped cache -- 256 bytes -- and
-- a miss stalls the Z80 by holding its clock enable low. Whether that costs a
-- few percent or half the CPU depends entirely on the access pattern, which
-- cannot be reasoned about: the driver's main loop and its NMI handler may or
-- may not collide in a 32-line index.
--
-- There is no simulation of the Z80 in this repository -- T80 is VHDL, so
-- Verilator cannot build it -- which is why the trace has to come from here.
--
-- Assign the tap to a GLOBAL or the subscription is collected and it silently
-- stops. Same for the frame notifier.
local set = manager.machine.devices[":audiocpu"]
if set == nil then print("NO audiocpu"); return end

local sp = set.spaces["program"]
out = assert(io.open(os.getenv("Z80_TRACE") or "z80_trace.bin", "wb"))
count = 0
local LIMIT = tonumber(os.getenv("Z80_LIMIT") or "4000000")

tap = sp:install_read_tap(0x0000, 0xbfff, "z80fetch", function(offset, data, mask)
    if count < LIMIT then
        -- little-endian u16; the window is 48 KB so 16 bits is enough
        out:write(string.char(offset & 0xff, (offset >> 8) & 0xff))
        count = count + 1
    end
    return data
end)

notify = emu.add_machine_frame_notifier(function()
    if count >= LIMIT then
        if out then out:close(); out = nil
           print(string.format("z80 trace: %d fetches", count))
           manager.machine:exit()
        end
    end
end)
print("z80 trace: tap installed")
