-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shogun Warriors: which memory the boot loop is testing.
--
-- The loop at 0x02222e writes a byte, reads it back and compares, branching
-- away on a mismatch and kicking the watchdog each pass. So the game verifies
-- RAM before it does anything else, and a byte that does not read back stops it
-- there. This says WHICH memory, and whether the accesses are bytes or words --
-- the CALC3's RAM is in SDRAM in this core and that write path has never run on
-- hardware.
local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]

sw_w = {}
sw_b = {}
sw_frames = 0

local function bump(t, region) t[region] = (t[region] or 0) + 1 end

sw_wt = space:install_write_tap(0x100000, 0x2fffff, "wr", function(off, data, mask)
  local region = (off < 0x200000) and "work RAM 10xxxx" or "MCU RAM 20xxxx"
  bump(sw_w, region)
  -- A byte access leaves one half of the mask clear.
  if mask == 0xffff then bump(sw_b, region .. " word")
  else                   bump(sw_b, region .. " BYTE") end
  return data
end)

sw_rt = space:install_read_tap(0x100000, 0x2fffff, "rd", function(off, data, mask)
  local region = (off < 0x200000) and "work RAM 10xxxx" or "MCU RAM 20xxxx"
  bump(sw_w, region .. " read")
  return data
end)

sw_note = emu.add_machine_frame_notifier(function() sw_frames = sw_frames + 1 end)

sw_stop = emu.add_machine_stop_notifier(function()
  print(string.format("== %d frames", sw_frames))
  local k = {}
  for r, n in pairs(sw_w) do k[#k+1] = {r, n} end
  table.sort(k, function(a, b) return a[2] > b[2] end)
  for _, e in ipairs(k) do print(string.format("  %-24s %d", e[1], e[2])) end
  print("  access width:")
  for r, n in pairs(sw_b) do print(string.format("    %-24s %d", r, n)) end
end)
