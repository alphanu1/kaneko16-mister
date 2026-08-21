-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16: dump VIEW2 tilemap and VU-002 sprite register state at a frame.
--
--   mame -rompath <roms> explbrkr -autoboot_script tools/mame_view2_census.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 12
--
-- Both flags are required, every time: without -skip_gameinfo the warning
-- screen blocks autoboot and this script silently never loads; without
-- -autoboot_delay 0 the script installs after the exchange it meant to capture.
--
-- The notifier is assigned to a GLOBAL. A local is collected and the callback
-- stops with no error and no output.
--
-- Address map is explbrkr / bakubrkr_map, kaneko16.cpp:314.

local FRAME  = tonumber(os.getenv("CENSUS_FRAME") or "600")
local VIEW2_0_REGS, VIEW2_1_REGS = 0x800000, 0xb00000
local SPR_REGS,     SPR_RAM      = 0x900000, 0x600000

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]
local frame = 0

local function w(addr) return space:read_u16(addr) end

-- Layer control register (reg 4, byte offset 0x008), decoded as
-- kaneko_tmap.cpp prepare_common() does.
--
-- The disable bits are 12 and 4. An earlier version of this decode read bit 15
-- for layer 0 and reported a layer that is always enabled as always disabled;
-- bit 15 is not used. Flip is bits 8 and 9 and applies to BOTH layers — there
-- is no second pair at bits 0/1.
--
-- Layer 0 takes regs 2/3 and the 0x3000 scroll window; layer 1 takes regs 0/1
-- and the 0x2000 one. The numbering runs opposite to the byte order throughout.
local function decode_layerctl(v)
  return string.format(
    "L0: dis=%d linescr=%d | L1: dis=%d linescr=%d | flipX=%d flipY=%d",
    (v >> 12) & 1, (v >> 11) & 1,
    (v >>  4) & 1, (v >>  3) & 1,
    (v >>  9) & 1, (v >>  8) & 1)
end

_G.census_sub = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame ~= FRAME then return end

  print(string.format("== frame %d ==", frame))
  for i, base in ipairs({ VIEW2_0_REGS, VIEW2_1_REGS }) do
    print(string.format("VIEW2[%d] regs @ %06x", i - 1, base))
    print(string.format("  FG scroll  X=%04x Y=%04x", w(base + 0x00), w(base + 0x02)))
    print(string.format("  BG scroll  X=%04x Y=%04x", w(base + 0x04), w(base + 0x06)))
    local ctl = w(base + 0x08)
    print(string.format("  layerctl   %04x  %s", ctl, decode_layerctl(ctl)))
  end

  local sr = w(SPR_REGS)
  print(string.format("VU-002 regs @ %06x", SPR_REGS))
  print(string.format("  reg0       %04x  disable=%d keeponscreen=%d flipX=%d flipY=%d",
    sr, (sr >> 15) & 1, (sr >> 2) & 1, (sr >> 1) & 1, sr & 1))

  -- First four sprite records, 4 words each. kaneko_spr.cpp record format.
  print("first 4 sprite records (attr, code, x<<6, y<<6):")
  local live = 0
  for s = 0, 1023 do
    local a = SPR_RAM + s * 8
    local attr, code = w(a), w(a + 2)
    if attr ~= 0 or code ~= 0 then
      live = live + 1
      if live <= 4 then
        print(string.format("  [%4d] attr=%04x code=%04x x=%04x y=%04x  colour=%02x pri=%d%d",
          s, attr, code, w(a + 4), w(a + 6), (attr >> 2) & 0x3f, (attr >> 9) & 1, (attr >> 8) & 1))
      end
    end
  end
  print(string.format("non-empty sprite records: %d / 1024", live))

  mach.video:snapshot()
  print("snapshot written")
  mach:exit()
end)
