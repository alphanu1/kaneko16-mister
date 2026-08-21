-- SPDX-License-Identifier: GPL-3.0-or-later
-- Kaneko16: trace every 68000 bus access from reset, as the oracle for the
-- core's own trace (`make boot`).
--
--   mame -rompath <roms> explbrkr -autoboot_script tools/mame_bus_trace.lua \
--        -skip_gameinfo -autoboot_delay 0 -seconds_to_run 20 \
--        -video none -sound none -nothrottle
--
-- Both flags are required, every time: without -skip_gameinfo the warning
-- screen blocks autoboot and this script silently never loads; without
-- -autoboot_delay 0 the script installs after the exchange it meant to capture.
-- Taps and notifiers are assigned to GLOBALS — a local is collected and the
-- callback stops with no error and no output.
--
-- FROM RESET, NOT FROM AUTOBOOT
--
-- Autoboot runs at the first frame, by which point the 68000 has already
-- executed a frame's worth of code, so a trace started there cannot be lined
-- up against a core coming out of reset. The taps go on first, then the machine
-- is soft-reset and the log cleared, so access 1 really is the first read of
-- the reset vector.
--
-- Address map is explbrkr / bakubrkr_map, kaneko16.cpp:314.

local MAX = tonumber(os.getenv("BUS_TRACE_COUNT") or "20000")
local OUT = os.getenv("BUS_TRACE_OUT") or "mame_bus_trace.txt"

-- DATA ONLY: skip the ROM window entirely.
--
-- Instruction fetches are ~77% of all accesses and the differ drops them
-- anyway, because fx68k and MAME prefetch differently. Not tapping them at all
-- removes 77% of the Lua callbacks, which is what limits how many frames the
-- oracle can cover — and reaching explbrkr's self-test completion at frame 229
-- needs about 9.5 M accesses, which is not reachable with the full tap.
--
-- Nothing writes to the ROM window, so nothing is lost.
local DATA_ONLY = (os.getenv("BUS_TRACE_DATA_ONLY") or "0") ~= "0"
local TAP_LO    = DATA_ONLY and 0x080000 or 0x000000

local mach  = manager.machine
local space = mach.devices[":maincpu"].spaces["program"]

-- WRITTEN AS IT GOES, NOT BUFFERED IN A TABLE
--
-- MAME segfaults part-way through this capture on explbrkr (see findings), and
-- a trace accumulated in a Lua table is lost entirely when it does — which
-- turns "where does it die" into a bisection over whole runs. Streaming to the
-- file and flushing periodically means a crashed run still leaves every access
-- up to the fatal one, and the answer is in the tail.
local fh, n, done, armed = nil, 0, false, false

local function record(rw, offset, data, mask)
  if done or not armed then return end
  n = n + 1
  fh:write(string.format("%06x %s %04x %04x\n", offset & 0xffffff, rw,
                         data & 0xffff, mask & 0xffff))
  if (n & 0x3ff) == 0 then fh:flush() end
  if n >= MAX then done = true end
end

-- FINISHING IS DONE FROM A FRAME NOTIFIER, NOT FROM THE TAP
--
-- Two reasons, both of which cost a run. Calling machine:exit() from inside a
-- tap tears the machine down underneath the access that is still in flight.
-- And leaving the taps installed after the limit is reached does not stop the
-- cost: every one of the 68000's ~3 M accesses per second still crosses into
-- Lua to be dropped on the floor, which turned a 4000-access capture into a
-- run that had to be killed. The taps come off explicitly.
local function finish()
  armed = false
  _G.tap_r:remove(); _G.tap_w:remove()
  fh:flush(); fh:close()
  print(string.format("bus trace: %d accesses -> %s", n, OUT))
  mach:exit()
end

-- Arm on the reset, so access 1 is the first read of the reset vector rather
-- than whatever the machine happened to be doing when autoboot fired.
-- THE TAPS GO ON INSIDE THE RESET, NOT BEFORE IT
--
-- Installing them first and then calling soft_reset() segfaults MAME a frame
-- and a half later, deterministically, part-way through the boot code's VIEW2
-- VRAM clear. The reset reinstalls the address map and the tap objects are left
-- dangling; nothing complains until one of them is next used. Without the
-- soft_reset the same taps carry 100,000 accesses without trouble, which is
-- what identifies the reset rather than the taps as the problem.
--
-- Installing them from the reset notifier gets both: the map has been rebuilt
-- by the time they go on, and they are live before the 68000 fetches its reset
-- vector, so access 1 is still 000000.
--
-- MATCH THE ARCHITECTURAL STATE, NOT JUST THE PROGRAM COUNTER
--
-- A 68000 RESET loads SSP and PC from the vectors and touches nothing else:
-- D0-D7 and A0-A6 keep whatever they held. MAME has already run a frame by the
-- time an autoboot script can install anything, so after soft_reset its
-- registers carry values from that frame while a core coming out of power-on
-- reset has zeros.
--
-- The boot code pushes registers it has not initialised yet — MOVEM.L
-- D0/D7/A0-A3,-(SP) at 016dde — and the traces diverged there on A1 and D7,
-- with MAME holding 00700000 and 7fffffff against the core's zeros. Ten
-- thousand accesses of exact agreement, then a difference that was entirely
-- the instrument's doing.
-- A SYNTHETIC RESET, NOT machine:soft_reset()
--
-- Three things went wrong with resetting the machine, and each one produced a
-- trace that looked plausible:
--
--   1. Taps installed before soft_reset() segfault MAME a frame and a half
--      later, deterministically, mid-way through the boot code's VIEW2 VRAM
--      clear. The reset rebuilds the address map and leaves the tap objects
--      dangling. Without the reset the same taps carry 100,000 accesses.
--   2. MAME re-runs an autoboot script on machine reset, so any "open the file
--      on reset" logic runs again from a fresh chunk, truncating the file while
--      the previous chunk's handle keeps its offset. The result was a
--      1,900,000-byte file that was sparse NULs plus a few hundred lines —
--      exactly the right size, almost entirely empty.
--   3. A 68000 RESET loads SSP and PC and touches nothing else, so D0-D7 and
--      A0-A6 keep whatever the pre-reset frame left in them. The boot code
--      pushes registers it has not initialised — MOVEM.L D0/D7/A0-A3,-(SP) at
--      016dde — and the traces diverged there on A1 and D7, MAME holding
--      00700000 and 7fffffff against the core's power-on zeros.
--
-- So the reset is performed on the CPU rather than on the machine: registers
-- zeroed, SSP and PC loaded from the vectors, SR set to supervisor with
-- interrupts masked. The memory map is never rebuilt, the script never re-runs,
-- and the architectural state matches a core leaving power-on reset.
local frames = 0

_G.frame_sub = emu.add_machine_frame_notifier(function()
  frames = frames + 1

  if frames == 1 then
    local st = mach.devices[":maincpu"].state
    for i = 0, 7 do st["D" .. i].value = 0 end
    for i = 0, 6 do st["A" .. i].value = 0 end
    st["SP"].value = (space:read_u16(0) << 16) | space:read_u16(2)
    st["PC"].value = (space:read_u16(4) << 16) | space:read_u16(6)
    st["SR"].value = 0x2700          -- supervisor, IPL 7, as after RESET

    fh, armed, n = io.open(OUT, "w"), true, 0

    -- Kept in globals: a tap held only by a local is collected and stops
    -- firing with no error and no output.
    _G.tap_r = space:install_read_tap(TAP_LO, 0xffffff, "bustrace_r",
      function(offset, data, mask) record("R", offset, data, mask) end)
    _G.tap_w = space:install_write_tap(TAP_LO, 0xffffff, "bustrace_w",
      function(offset, data, mask) record("W", offset, data, mask) end)
    return
  end

  if done then finish()
  elseif frames > 600 then
    print(string.format("bus trace: only %d accesses in %d frames", n, frames))
    finish()
  end
end)
