-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 / CALC3: the oracle for the MCU simulation.
--
--   mame -rompath <roms> shogwarr -autoboot_script tools/mame_calc3_trace.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 30 -video none -sound none
--
-- Hard rule 6 says build the instrument before debugging, and the CALC3 is the
-- one device in this core with no oracle yet written. Its RTL has to reproduce
-- what MAME's high-level simulation puts into MCU RAM, byte for byte, so this
-- records exactly that: a per-frame DIFF of the 64 KB at 200000-20ffff.
--
-- A diff rather than a write tap on purpose. A tap sees every access through
-- the space and cannot say who made it, so the 68000's own writes are
-- indistinguishable from the MCU's. The MCU writes in bursts from a timer
-- callback between frames; sampling the region once a frame and emitting what
-- changed captures those bursts as whole units, which is the shape the RTL
-- produces too. CPU writes land in the trace as well -- they are noise here,
-- and they are labelled by being spread thinly rather than arriving in runs.
--
-- Output, under build/calc3/:
--   <set>-trace.txt   frame, address, before -> after, one line per changed word
--   <set>-final.bin   the whole 64 KB at the end of the run
--   <set>-calc3rom.bin  the data ROM the decompressor reads, for the RTL's input
--
-- Taps and notifiers MUST be global or the subscription is collected and the
-- callback stops with no error.
local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]

local BASE, SIZE = 0x200000, 0x10000
local setname = emu.romname()
local dir = "build/calc3"

os.execute("mkdir -p " .. dir)

c3_prev   = {}
c3_frames = 0
c3_lines  = 0
c3_trace  = io.open(dir .. "/" .. setname .. "-trace.txt", "w")

c3_trace:write("# CALC3 MCU RAM diff, per frame. address is a 68000 BYTE address.\n")
c3_trace:write("# frame  addr      before -> after\n")

-- Seed the shadow so frame 0 does not report the whole region as changed.
for a = 0, SIZE - 2, 2 do c3_prev[a] = space:read_u16(BASE + a) end

local function sample()
  c3_frames = c3_frames + 1
  local changed = 0
  for a = 0, SIZE - 2, 2 do
    local v = space:read_u16(BASE + a)
    if v ~= c3_prev[a] then
      -- A cap, so a runaway does not fill the disk. Reaching it is itself a
      -- finding and says so rather than truncating in silence.
      if c3_lines < 2000000 then
        c3_trace:write(string.format("%6d  %06x  %04x -> %04x\n",
                                     c3_frames, BASE + a, c3_prev[a], v))
        c3_lines = c3_lines + 1
      elseif c3_lines == 2000000 then
        c3_trace:write("# CAP REACHED at 2,000,000 lines -- trace truncated\n")
        c3_lines = c3_lines + 1
      end
      c3_prev[a] = v
      changed = changed + 1
    end
  end
  return changed
end

c3_note = emu.add_machine_frame_notifier(function() sample() end)

c3_stop = emu.add_machine_stop_notifier(function()
  sample()
  local f = io.open(dir .. "/" .. setname .. "-final.bin", "wb")
  for a = 0, SIZE - 1 do f:write(string.char(space:read_u8(BASE + a))) end
  f:close()

  -- The decompressor's input. Dumped from the same run so the RTL is fed
  -- exactly the bytes MAME read, not a separately extracted copy that might
  -- differ in interleave.
  local rgn = mach.memory.regions[":calc3_rom"]
  if rgn then
    local r = io.open(dir .. "/" .. setname .. "-calc3rom.bin", "wb")
    for a = 0, rgn.size - 1 do r:write(string.char(rgn:read_u8(a))) end
    r:close()
    print(string.format("calc3: %s calc3_rom %d bytes", setname, rgn.size))
  else
    print("calc3: NO :calc3_rom region -- the RTL has no input to match")
  end

  c3_trace:write(string.format("# %d frames, %d changed words recorded\n",
                               c3_frames, c3_lines))
  c3_trace:close()
  print(string.format("calc3: %s %d frames, %d changed words -> %s/",
                      setname, c3_frames, c3_lines, dir))
end)
