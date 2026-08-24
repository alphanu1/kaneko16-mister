-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16: census the VIEW2 tile CODES a game uses, against its ROM region.
--
--   mame -rompath <roms> explbrkr -autoboot_script tools/mame_view2_codes.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 120
--
-- The sprite side of this is tools/mame_spr_codes.lua and the reasoning is the
-- same. MAME draws tiles through gfx_element, which bounds the code by the
-- number of elements in the region; this core forms the address as
-- `{1'b0, code, 7'd0}` and fetches, with nothing bounding it.
--
-- A VIEW2 tile is gfx_8x8x4_row_2x2_group_packed_lsb -- 16x16, 128 bytes, the
-- same size as a sprite and the LSB nibble order rather than MSB. Explosive
-- Breaker's two regions are 0x100000 each, so 8192 elements against a code
-- field that is a full 16 bits.
--
-- Reported from hardware: the big boss at the start of Explosive Breaker is
-- not drawn, and it is tilemap rather than sprite -- it disappears when the
-- Tilemaps option is turned off.
--
-- VRAM layout, from kaneko_vmem and the driver: the 0x4000-byte window is
-- layer 1 VRAM, layer 0 VRAM, layer 1 scroll, layer 0 scroll, each 0x1000.
-- Layer 1 is FIRST. A tile entry is two words, attr then code.
--
-- Both flags are required, every time: without -skip_gameinfo the warning
-- screen blocks autoboot and this silently never loads; without
-- -autoboot_delay 0 it installs too late. The notifiers are GLOBALS.
local CHIPS = { [0] = tonumber(os.getenv("V2_0") or "0x500000"),
                [1] = tonumber(os.getenv("V2_1") or "0x580000") }
local NCHIP    = tonumber(os.getenv("V2_CHIPS") or "2")
local ELEMENTS = tonumber(os.getenv("V2_ELEM")  or "8192")   -- 0x100000/128

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]

local frames, total, over, max_code = 0, 0, 0, 0
local hist = {}
local per_layer = {}   -- "chip.layer" -> count of out-of-range

local function scan()
  for c = 0, NCHIP - 1 do
    local base = CHIPS[c]
    -- layer 1 at +0x0000, layer 0 at +0x1000
    for l = 0, 1 do
      local lbase = base + (l == 1 and 0x0000 or 0x1000)
      for i = 0, 1023 do
        local code = space:read_u16(lbase + i * 4 + 2)
        total = total + 1
        if code > max_code then max_code = code end
        if code >= ELEMENTS then
          over = over + 1
          hist[code] = (hist[code] or 0) + 1
          local k = string.format("chip%d layer%d", c, l)
          per_layer[k] = (per_layer[k] or 0) + 1
        end
      end
    end
  end
end

function v2_tick()
  frames = frames + 1
  scan()
  if frames % 600 == 0 then
    emu.print_info(string.format(
      "frame %5d  entries %9d  AT OR ABOVE %d: %9d  max 0x%04x",
      frames, total, ELEMENTS, over, max_code))
  end
end

function v2_stop()
  emu.print_info("---- VIEW2 tile code census ----")
  emu.print_info(string.format("frames scanned        : %d", frames))
  emu.print_info(string.format("tile entries read     : %d", total))
  emu.print_info(string.format("elements in a region  : %d (0x%x)", ELEMENTS, ELEMENTS))
  emu.print_info(string.format("codes AT OR ABOVE it  : %d", over))
  emu.print_info(string.format("highest code seen     : 0x%04x", max_code))
  for k, v in pairs(per_layer) do
    emu.print_info(string.format("   %s : %d out of range", k, v))
  end
  local keys = {}
  for k in pairs(hist) do keys[#keys+1] = k end
  table.sort(keys)
  emu.print_info(string.format("distinct offending codes: %d", #keys))
  for n = 1, math.min(#keys, 12) do
    emu.print_info(string.format("   0x%04x seen %7d times -> wraps to 0x%04x",
                                 keys[n], hist[keys[n]], keys[n] % ELEMENTS))
  end
end

v2_sub      = emu.add_machine_frame_notifier(v2_tick)
v2_stop_sub = emu.add_machine_stop_notifier(v2_stop)
emu.print_info("VIEW2 tile code census installed")
