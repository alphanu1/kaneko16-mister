-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 / Wing Force: WHAT IS ON SCREEN while the OKI is being driven.
--
--   mame -rompath <roms> wingforc -autoboot_script tools/mame_wf_screens.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 60 -sound none \
--        -snapshot_directory <dir>
--
-- This is the instrument that ended a long hunt for a defect that did not
-- exist. "Wing Force has no music in the attract demo" was treated as a fault
-- for hours; the sound path was diffed against MAME in every respect --
-- commands, order, latch handshake, interval, poll rates, timer flags -- and
-- all of it matched, because there was nothing wrong with it.
--
-- What was never checked was whether the ORACLE has music there. It does not:
--
--     t=20s  title screen        183 OKI writes in five seconds
--     t=35s  gameplay demo         0
--     t=50s  high-score screen     0
--
-- Counting writes alone cannot say that -- a zero looks the same whether the
-- thing is broken or was never there. Pairing the count with a screenshot at
-- the same instant is what makes it an answer.
--
-- Both flags are required, every time; the notifier and tap MUST be global.
local mach = manager.machine
local snd  = mach.devices[":audiocpu"]
local io   = snd.spaces["io"]
shot_f = 0; shot_oki = 0
shot_tap = io:install_write_tap(0x0a, 0x0a, "o", function(o,d,m) shot_oki = shot_oki + 1; return d end)
shot_n = emu.add_machine_frame_notifier(function()
  shot_f = shot_f + 1
  if shot_f % 300 == 0 then
    emu.print_info(string.format("SHOT t=%2ds  oki writes in last 5s = %d", shot_f//60, shot_oki))
    mach.video:snapshot()
    shot_oki = 0
  end
end)
