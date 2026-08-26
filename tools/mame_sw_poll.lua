-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shogun Warriors: what the 68000 reads while it is getting to the MCU.
--
-- It does not write a command register until frame 339, five and a half
-- seconds in. Something occupies it until then, and if the core answers that
-- something differently the game never arrives. A census by address says what
-- it is asking, rather than leaving it to be guessed.
local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]

sw_rd = {}
sw_pc = {}
sw_frames = 0

-- Everything outside work RAM, MCU RAM and ROM: the I/O the core has to answer.
sw_tap = space:install_read_tap(0x380000, 0xffffff, "census", function(off, data, mask)
  local page = off & 0xfff00000
  sw_rd[off] = (sw_rd[off] or 0) + 1
  return data
end)

sw_note = emu.add_machine_frame_notifier(function()
  sw_frames = sw_frames + 1
  -- Where it sits, sampled once a frame.
  local pc = cpu.state["PC"].value
  sw_pc[pc] = (sw_pc[pc] or 0) + 1
end)

sw_stop = emu.add_machine_stop_notifier(function()
  print(string.format("== %d frames", sw_frames))
  local a = {}
  for addr, n in pairs(sw_rd) do a[#a+1] = {addr, n} end
  table.sort(a, function(x, y) return x[2] > y[2] end)
  print("  most-read I/O addresses:")
  for i = 1, math.min(#a, 10) do
    print(string.format("    %06x  %d reads", a[i][1], a[i][2]))
  end
  local p = {}
  for pc, n in pairs(sw_pc) do p[#p+1] = {pc, n} end
  table.sort(p, function(x, y) return x[2] > y[2] end)
  print("  where it sits, by frame sample:")
  for i = 1, math.min(#p, 8) do
    print(string.format("    PC %06x  %d frames", p[i][1], p[i][2]))
  end
end)
