-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16: capture the 93C46's three lines from MAME, with timestamps.
--
--   mame -rompath <roms> explbrkr -autoboot_script tools/mame_eeprom_capture.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 30 \
--        -video none -sound none -nothrottle
--
-- WHY THIS IS NOT EXTRACTED FROM THE BUS TRACE
--
-- It was, and it could not check the part that matters. After a WRITE the host
-- polls DO for "programming finished", and whether that reads busy or ready is
-- a question about elapsed time — MAME holds it busy for 111.8 us. A stimulus
-- with no timestamps replays at whatever rate the testbench happens to clock
-- at, so the busy window either never opens or never closes, and the replay
-- reports hundreds of mismatches that say nothing about the model.
--
-- The chip's lines come from three places, so they are reassembled here:
--     d00000 low byte   eeprom_w: bit 0 clk, bit 1 di
--     40021e            YM2149 #1 port B, chip select
--     40021c            YM2149 #1 port A, data out — the value to check
--
-- Output, times in microseconds of emulated machine time:
--     S <t> <cs> <sk> <di>          apply this state
--     R <t> <cs> <sk> <di> <do>     apply it and check DO
--
-- The result is ROM-derived and belongs under build/ (hard rule 2).

local MAX = tonumber(os.getenv("EE_CAP_COUNT") or "200000")
local OUT = os.getenv("EE_CAP_OUT") or "ee_stim.txt"

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]

local fh = io.open(OUT, "w")
local cs, sk, di, n, done = 0, 0, 0, 0, false

local function now_us() return mach.time:as_double() * 1e6 end

local function emit(kind, extra)
  if done then return end
  n = n + 1
  if extra then
    fh:write(string.format("%s %.3f %d %d %d %d\n", kind, now_us(), cs, sk, di, extra))
  else
    fh:write(string.format("%s %.3f %d %d %d\n", kind, now_us(), cs, sk, di))
  end
  if (n & 0x3ff) == 0 then fh:flush() end
  if n >= MAX then done = true end
end

_G.tw_cs = space:install_write_tap(0x40021e, 0x40021f, "eecs", function(o, d, m)
  cs = ((d & 0xff) ~= 0) and 1 or 0
  emit("S")
end)

-- Only the low byte is the EEPROM; the high byte of this word is coin lockout
-- and a write touching only it must not clock the part.
_G.tw_ck = space:install_write_tap(0xd00000, 0xd00001, "eeck", function(o, d, m)
  if (m & 0x00ff) == 0 then return end
  sk = d & 1
  di = (d >> 1) & 1
  emit("S")
end)

_G.tr_do = space:install_read_tap(0x40021c, 0x40021d, "eedo", function(o, d, m)
  emit("R", d & 1)
end)

local frames = 0
_G.sub = emu.add_machine_frame_notifier(function()
  frames = frames + 1
  if done or frames > 900 then
    _G.tw_cs:remove(); _G.tw_ck:remove(); _G.tr_do:remove()
    fh:flush(); fh:close()
    print(string.format("eeprom capture: %d events -> %s", n, OUT))
    mach:exit()
  end
end)
