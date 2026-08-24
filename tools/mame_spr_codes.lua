-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16: census the sprite CODES a game actually uses, against the size of
-- its sprite ROM region.
--
--   mame -rompath <roms> explbrkr -autoboot_script tools/mame_spr_codes.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 120
--
-- WHY
--
-- kaneko_spr.cpp draws through gfx_element, which bounds the code:
--
--     const u8 *source_base = gfx->get_data(code % gfx->elements());
--
-- That is a MODULO. A VU-002 sprite is gfx_8x8x4_row_2x2_group_packed_msb,
-- whose gfx_layout ends `16*16*4` -- BITS, so 128 bytes per 16x16 sprite and
-- not the 256 an 8bpp tile would take. Explosive Breaker's region is 0x240000,
-- so elements is 0x240000/128 = 0x4800 = 18432, which is not a power of two. This core does no such bound --
-- it forms rom_addr as code*256 and fetches -- so any code at or above 0x2400
-- reads past the end of the sprite region instead of wrapping into it. Past
-- the region is the OKI sample ROM, whose bytes are not tile data, and a tile
-- of zero nibbles is fully transparent: the sprite becomes INVISIBLE while its
-- game logic keeps running.
--
-- That is the shape of the reported fault -- enemies missing but still firing
-- -- so this measures whether the codes to cause it are ever used, rather than
-- leaving it as a plausible story.
--
-- Both flags are required, every time: without -skip_gameinfo the warning
-- screen blocks autoboot and this script silently never loads; without
-- -autoboot_delay 0 the script installs after the exchange it meant to
-- capture. The notifier is a GLOBAL -- a local is collected and the callback
-- stops with no error and no output.
local SPR_RAM  = tonumber(os.getenv("SPR_RAM")  or "0x600000")
local COUNT    = tonumber(os.getenv("SPR_COUNT") or "1024")
local ELEMENTS = tonumber(os.getenv("SPR_ELEM")  or "18432")  -- 0x240000/128

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]

local frames    = 0
local over      = 0      -- records seen with code >= ELEMENTS
local total     = 0      -- records seen with a non-zero code
local max_code  = 0
local hist      = {}     -- code -> times seen, for the offenders only

-- kaneko_spr.cpp parse_sprite: 8 bytes per record,
--   +0 attr  +2 code  +4 x  +6 y
-- The code is the whole 16-bit word for VU-002; KC-002 adds bit 16 from y,
-- which explbrkr does not have.
-- The EFFECTIVE code, which is not always the record's own.
--
-- kaneko_spr.cpp walks the list keeping a latch:
--
--     if (flags & USE_LATCHED_CODE) s->code = ++code;   // latched code + 1
--     else                          code    = s->code;  // .. or latch this
--
-- so a run of records with bit 15 set walks the code UPWARDS from whatever the
-- last record without it left behind. That is a mechanism for exceeding the
-- region all by itself, and it is the reason counting each record's own word
-- is not the measurement wanted here.
--
-- Position is carried through the same way so off-screen records can be
-- excluded: only a sprite that would actually appear can be seen to be
-- missing.
local SPR_REGS = tonumber(os.getenv("SPR_REGS") or "0x900000")

local function scan()
  local code, x, y = 0, 0, 0
  local min_y = tonumber(os.getenv("SPR_MINY") or "16")

  for i = 0, COUNT - 1 do
    local base = SPR_RAM + i * 8
    local attr = space:read_u16(base + 0)
    local rcod = space:read_u16(base + 2)
    local rx   = space:read_u16(base + 4)
    local ry   = space:read_u16(base + 6)

    -- USE_LATCHED_CODE is bit 15, XY is bit 13.
    local eff
    if (attr >> 15) & 1 == 1 then
      code = (code + 1) & 0xffff
      eff  = code
    else
      code = rcod
      eff  = rcod
    end

    if (attr >> 13) & 1 == 1 then
      x = (x + rx) & 0xffff
      y = (y + ry) & 0xffff
    else
      x, y = rx, ry
    end

    -- The global offset pair selected by attr bits 12:11, then the sign
    -- extraction kaneko_spr.cpp does: ((v & 0x7fc0) - (v & 0x8000)) / 0x40.
    local sel   = (attr >> 11) & 3
    local xoffs = space:read_u16(SPR_REGS + 0x10 + sel * 4 + 0)
    local yoffs = space:read_u16(SPR_REGS + 0x10 + sel * 4 + 2)
    local gy    = space:read_u16(SPR_REGS + 0x02)

    local fx = (xoffs + x) & 0xffff
    local fy = (yoffs - gy + (min_y << 6) + y) & 0xffff
    local sx = ((fx & 0x7fc0) - (fx & 0x8000)) // 0x40
    local sy = ((fy & 0x7fc0) - (fy & 0x8000)) // 0x40

    -- explbrkr is 256x224 from line 16. A 16x16 sprite is on screen if its
    -- box overlaps at all.
    local on = sx > -16 and sx < 256 and sy > (min_y - 16) and sy < 240

    if on then
      total = total + 1
      if eff > max_code then max_code = eff end
      if eff >= ELEMENTS then
        over = over + 1
        hist[eff] = (hist[eff] or 0) + 1
      end
    end
  end
end

-- ------------------------------------------------------------- gameplay
--
-- Attract mode is not what the fault was reported against, and the two do not
-- draw the same sprites. With PLAY=1 this drops a coin, presses start, and
-- then holds fire and walks, so the census covers a level rather than a demo.
-- The player dies eventually and the game returns to attract, which is why the
-- coin and start are re-pressed on a cycle rather than once.
local PLAY = (os.getenv("SPR_PLAY") or "0") ~= "0"

-- Port tags carry a LEADING COLON -- ":SYSTEM", not "SYSTEM". The first
-- version of this looked them up without it, got nil for every port, and
-- returned quietly; the census then reported the attract loop's numbers
-- unchanged and looked exactly like an answer. A missing port or field is an
-- error here for that reason, not a no-op.
local function hold(port, field, on)
  local p = mach.ioport.ports[port]
  if not p then error("no such ioport: " .. port) end
  local f = p.fields[field]
  if not f then error("no such field: " .. port .. " / " .. field) end
  f:set_value(on and 1 or 0)
end

local function play_tick()
  -- A short repeating script: coin, start, then fire and move. Frame numbers
  -- are relative to a 900-frame cycle so a death and return to attract is
  -- picked up again rather than leaving the rest of the run in the demo.
  local t = frames % 900
  if     t ==  60 then hold(":SYSTEM", "Coin 1", true)
  elseif t ==  66 then hold(":SYSTEM", "Coin 1", false)
  elseif t == 120 then hold(":SYSTEM", "1 Player Start", true)
  elseif t == 126 then hold(":SYSTEM", "1 Player Start", false)
  elseif t == 180 then hold(":P1", "P1 Button 1", true)
  elseif t > 180 then
    -- Sweep left and right so the level scrolls and new enemies spawn.
    local phase = (t // 120) % 2 == 0
    hold(":P1", "P1 Left",  phase)
    hold(":P1", "P1 Right", not phase)
  end
end

function census_tick()
  frames = frames + 1
  if PLAY then play_tick() end
  scan()
  if frames % 300 == 0 then
    emu.print_info(string.format(
      "frame %5d  ON-SCREEN sprites: %7d   AT OR ABOVE %d: %7d   max code seen: 0x%04x",
      frames, total, ELEMENTS, over, max_code))
  end
end

function census_stop()
  emu.print_info("---- sprite code census ----")
  emu.print_info(string.format("frames scanned        : %d", frames))
  emu.print_info(string.format("ON-SCREEN sprites     : %d", total))
  emu.print_info(string.format("elements in the region: %d (0x%x)", ELEMENTS, ELEMENTS))
  emu.print_info(string.format("codes AT OR ABOVE it  : %d", over))
  emu.print_info(string.format("highest code seen     : 0x%04x", max_code))
  if over > 0 then
    emu.print_info("offending codes, and what MAME wraps them to:")
    local keys = {}
    for k in pairs(hist) do keys[#keys+1] = k end
    table.sort(keys)
    for n = 1, math.min(#keys, 40) do
      local c = keys[n]
      emu.print_info(string.format("   0x%04x seen %6d times -> wraps to 0x%04x",
                                   c, hist[c], c % ELEMENTS))
    end
    if #keys > 40 then
      emu.print_info(string.format("   ... and %d more distinct codes", #keys - 40))
    end
  end
end

census_sub  = emu.add_machine_frame_notifier(census_tick)
census_stop_sub = emu.add_machine_stop_notifier(census_stop)
emu.print_info("sprite code census installed")
