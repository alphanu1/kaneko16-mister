-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 / CALC3: isolate the MCU's writes into MCU RAM.
--
--   mame -rompath <roms> shogwarr -autoboot_script tools/mame_calc3_writes.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 8 -video none -sound none
--
-- WHY NOT THE PER-FRAME DIFF. tools/mame_calc3_trace.lua samples the 64 KB once
-- a frame and reports what changed. That cannot see the MCU here: shogwarr's
-- 68000 fills MCU RAM with a repeating 7-byte pattern (55 dd bb 99 00 ff aa),
-- and it overwrites the MCU's output between two samples. Every "MCU burst" in
-- that trace is the CPU's fill. The measurement said something and the
-- something was not the MCU -- check the instrument could have seen it.
--
-- This taps writes instead, in order. A tap cannot name the initiator, but the
-- MCU's decompressor writes a table BYTE BY BYTE AT ASCENDING ADDRESSES in one
-- uninterrupted run, which the CPU's fill does not do at that length. So the
-- run structure separates them: emit every write, tag each maximal ascending
-- byte-stride run, and the long ones are tables.
--
-- Output: build/calc3/<set>-writes.txt, and one file per detected run holding
-- the raw bytes, which is what tools/calc3_ref.py has to reproduce exactly.
local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]
local BASE, SIZE = 0x200000, 0x10000
local setname = emu.romname()
local dir = "build/calc3"
os.execute("mkdir -p " .. dir)

cw_log   = io.open(dir .. "/" .. setname .. "-writes.txt", "w")
cw_run   = {}          -- bytes of the run being accumulated
cw_start = nil         -- its first address
cw_next  = nil         -- the address that would continue it
cw_runs  = 0
cw_total = 0

-- A run has to be long enough that the CPU's own scattered writes cannot
-- masquerade as one. Table lengths run to thousands; 64 is comfortably above
-- incidental ascending pairs and below the smallest real table.
local MIN_RUN = 64

local function flush()
  if cw_start and #cw_run >= MIN_RUN then
    cw_runs = cw_runs + 1
    local name = string.format("%s/%s-run%02d-%06x.bin", dir, setname, cw_runs, cw_start)
    local f = io.open(name, "wb")
    f:write(table.concat(cw_run))
    f:close()
    cw_log:write(string.format("run %2d  %06x  %6d bytes  -> %s\n",
                               cw_runs, cw_start, #cw_run, name))
  end
  cw_run, cw_start, cw_next = {}, nil, nil
end

cw_tap = space:install_write_tap(BASE, BASE + SIZE - 1, "calc3w", function(off, data, mask)
  cw_total = cw_total + 1
  -- Byte writes only continue a run; the decompressor uses write_byte.
  local isbyte = (mask == 0x00ff) or (mask == 0xff00)
  local addr
  if mask == 0x00ff then addr = off + 1
  elseif mask == 0xff00 then addr = off
  else addr = off end

  if isbyte and cw_next and addr == cw_next then
    local b = (mask == 0x00ff) and (data & 0xff) or ((data >> 8) & 0xff)
    cw_run[#cw_run + 1] = string.char(b)
    cw_next = addr + 1
  else
    flush()
    if isbyte then
      local b = (mask == 0x00ff) and (data & 0xff) or ((data >> 8) & 0xff)
      cw_run  = { string.char(b) }
      cw_start = addr
      cw_next  = addr + 1
    end
  end
  return data
end)

cw_stop = emu.add_machine_stop_notifier(function()
  flush()
  cw_log:write(string.format("# %d writes seen, %d runs of >= %d bytes\n",
                             cw_total, cw_runs, MIN_RUN))
  cw_log:close()
  print(string.format("calc3: %s %d writes, %d runs -> %s/",
                      setname, cw_total, cw_runs, dir))
end)
