-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shogun Warriors: what the 68000 does before it first talks to the CALC3.
--
--   mame -rompath <roms> shogwarr -autoboot_script tools/mame_sw_boot.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 6 -video none -sound none
--
-- Both Tier 2 games come up black on hardware with a running 68000 that never
-- writes the MCU's four command registers. This says what the real machine does
-- in that window: which interrupts it takes, and the PC of the first write to
-- each command register, so the core can be compared against it rather than
-- reasoned about.
local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]

sw_first = {}
sw_irq   = {}
sw_frames = 0

-- The four command registers, at addresses that are NOT contiguous.
for _, a in ipairs({0x280000, 0x290000, 0x2b0000, 0x2d0000}) do
  local addr = a
  local tap = space:install_write_tap(addr, addr + 1, "com", function(off, data, mask)
    if not sw_first[addr] then
      sw_first[addr] = {pc = cpu.state["PC"].value, frame = sw_frames, data = data}
      print(string.format("first write to %06x at frame %d, PC %06x, data %04x",
                          addr, sw_frames, cpu.state["PC"].value, data))
    end
    return data
  end)
  sw_irq[#sw_irq + 1] = tap        -- keep it alive; a collected tap stops silently
end

-- Where the autovectors point, so the levels the board uses are visible rather
-- than inferred: an unused level points at whatever the ROM left there.
sw_note = emu.add_machine_frame_notifier(function()
  sw_frames = sw_frames + 1
  if sw_frames == 2 then
    for lvl = 1, 7 do
      local v = space:read_u32(0x60 + lvl * 4)
      print(string.format("  autovector IRQ%d -> %08x", lvl, v))
    end
  end
end)

sw_stop = emu.add_machine_stop_notifier(function()
  print(string.format("== %d frames", sw_frames))
  for _, a in ipairs({0x280000, 0x290000, 0x2b0000, 0x2d0000}) do
    if not sw_first[a] then print(string.format("  %06x NEVER written", a)) end
  end
end)
