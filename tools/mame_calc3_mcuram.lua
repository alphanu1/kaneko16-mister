-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16 / CALC3: how much SDRAM bandwidth would the MCU's 64 KB need?
--
--   mame -rompath <roms> shogwarr -autoboot_script tools/mame_calc3_mcuram.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 60 -video none -sound none
--
-- The MCU's RAM is 64 KB and the games use all of it. In block memory it costs
-- 56 M10K and takes the device to 95%, where MiSTer's HDMI PLL domain stops
-- meeting timing -- this core's own clocks are fine. Moving it to SDRAM frees
-- those blocks; the recorded objection was "latency on every MCU access",
-- written without a number behind it.
--
-- Latency per access is the wrong quantity. What matters is ACCESSES PER
-- FRAME against the 811,008 core clocks a frame holds, at roughly 20 clocks a
-- round trip. Measured on shogwarr:
--
--     steady state   ~2,650 a frame  (~2,600 reads, ~600 writes)   ~6.5%
--     startup peak   ~3,500 a frame                                ~8.6%
--
-- Affordable, and reads outnumber writes four to one -- which matters because
-- the SDRAM write path has never run on hardware.
--
-- shogwarr_map puts the MCU RAM at 200000-20ffff. Taps and notifiers MUST be
-- global or the subscription is collected and they stop with no error.
local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]
local FRAME_CLOCKS, ROUND_TRIP = 811008, 20

mcu_r, mcu_w, mcu_frames = 0, 0, 0
mcu_rt = space:install_read_tap (0x200000, 0x20ffff, "r", function(o,d,m) mcu_r = mcu_r + 1; return d end)
mcu_wt = space:install_write_tap(0x200000, 0x20ffff, "w", function(o,d,m) mcu_w = mcu_w + 1; return d end)

mcu_n = emu.add_machine_frame_notifier(function()
  mcu_frames = mcu_frames + 1
  if mcu_frames % 300 ~= 0 then return end
  local per = (mcu_r + mcu_w) / 300
  emu.print_info(string.format(
    "t=%3ds  reads %8d  writes %8d  = %7.1f accesses/frame  ~%5.2f%% of a frame",
    mcu_frames // 60, mcu_r, mcu_w, per, per * ROUND_TRIP / FRAME_CLOCKS * 100))
  mcu_r, mcu_w = 0, 0
end)
emu.print_info("CALC3 MCU RAM bandwidth census installed")
