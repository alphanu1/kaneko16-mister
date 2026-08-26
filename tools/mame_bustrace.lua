-- SPDX-License-Identifier: GPL-3.0-or-later
-- A 68000 DATA-access trace in the same format kaneko_cpumem emits, so the two
-- can be diffed line for line and the FIRST divergence found.
--
--   mame -rompath <roms> <set> -autoboot_script tools/mame_bustrace.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 2 -video none -sound none
--
-- Hard rule 6: a debugging session starts by getting MAME to the same point and
-- comparing. Shogun Warriors' 68000 in this core writes the palette 32,800
-- times and never touches work RAM or MCU RAM at all, while the real machine
-- hammers both -- so the two are running different code and the question is
-- where they part.
--
-- Format: "aaaaaa R dddd mmmm" / "aaaaaa W dddd mmmm", byte address, lower
-- case, no other text, one access a line.
local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]

local LIMIT = tonumber(os.getenv("TRACE_LIMIT") or "400000")
bt_n = 0
bt_f = io.open(os.getenv("TRACE_OUT") or "build/mame_bus.txt", "w")

-- Data only, and ROM is excluded because an instruction fetch is a read there
-- and would swamp the file. Everything the core's own trace records is here.
bt_rt = space:install_read_tap(0x100000, 0xffffff, "r", function(off, data, mask)
  if bt_n < LIMIT then
    bt_f:write(string.format("%06x R %04x %04x\n", off & 0xfffffe, data & 0xffff, mask))
    bt_n = bt_n + 1
  end
  return data
end)

bt_wt = space:install_write_tap(0x100000, 0xffffff, "w", function(off, data, mask)
  if bt_n < LIMIT then
    bt_f:write(string.format("%06x W %04x %04x\n", off & 0xfffffe, data & 0xffff, mask))
    bt_n = bt_n + 1
  end
  return data
end)

bt_stop = emu.add_machine_stop_notifier(function()
  bt_f:close()
  print(string.format("bustrace: %d accesses", bt_n))
end)
