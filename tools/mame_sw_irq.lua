-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shogun Warriors: does the real machine take interrupts during its RAM test?
--
-- The board shows ZERO interrupts acknowledged per frame while the game sits in
-- its boot RAM test. That reads like a fault, but this core's own notes record
-- that zero is normal while a game masks them during self-test -- explbrkr does
-- exactly that for its first few seconds. So the question is what the ORACLE
-- does in the same window, before any more time goes into interrupts.
--
-- The handlers are at 0x100 (IRQ2), 0x102 (IRQ3) and 0x136 (IRQ4), from the
-- game's own vector table. An instruction fetch is a read, so a read tap on
-- those addresses catches the handler being entered.
local mach  = manager.machine
local cpu   = mach.devices[":maincpu"]
local space = cpu.spaces["program"]

sw_h = {}
sw_sr = {}
sw_frames = 0
sw_taps = {}

for _, e in ipairs({{0x100, "IRQ2"}, {0x102, "IRQ3"}, {0x136, "IRQ4"}}) do
  local addr, name = e[1], e[2]
  sw_h[name] = 0
  sw_taps[#sw_taps + 1] = space:install_read_tap(addr, addr + 1, name,
      function(off, data, mask) sw_h[name] = sw_h[name] + 1; return data end)
end

sw_note = emu.add_machine_frame_notifier(function()
  sw_frames = sw_frames + 1
  -- The interrupt mask, bits 10:8 of the status register. 7 means everything
  -- below level 7 is masked, which is how a self-test keeps itself alone.
  local sr = cpu.state["SR"].value
  local mask = (sr >> 8) & 7
  sw_sr[mask] = (sw_sr[mask] or 0) + 1
  if sw_frames == 100 or sw_frames == 250 or sw_frames == 350 then
    print(string.format("  frame %3d: IRQ2 %d, IRQ3 %d, IRQ4 %d, SR mask %d",
                        sw_frames, sw_h.IRQ2, sw_h.IRQ3, sw_h.IRQ4, mask))
  end
end)

sw_stop = emu.add_machine_stop_notifier(function()
  print(string.format("== %d frames; handlers entered: IRQ2 %d, IRQ3 %d, IRQ4 %d",
                      sw_frames, sw_h.IRQ2, sw_h.IRQ3, sw_h.IRQ4))
  print("  interrupt mask, frames at each level:")
  for m, n in pairs(sw_sr) do
    print(string.format("    mask %d: %d frames%s", m, n,
                        m == 7 and "   (everything masked)" or ""))
  end
end)
