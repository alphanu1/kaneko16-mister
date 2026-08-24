-- Do the games READ video memory back, or only write it?
--
-- kaneko_vmem's arrays are read at two addresses at once -- CPU read-back and
-- video fetch -- so Quartus duplicates every one, costing ~32 M10K blocks of a
-- device at 94%. Sharing the port needs a cycle-stealing arbiter. Deleting the
-- CPU read port needs nothing at all, and is correct if the games never read.
--
-- Counts reads and writes separately for each window. A read tap sees what a
-- memory watch cannot: reading leaves nothing behind.
vr_cpu  = manager.machine.devices[":maincpu"]
vr_prog = vr_cpu.spaces["program"]
vr = {}
vr_frames = 0

local function win(name, lo, hi)
    vr[name] = {r = 0, w = 0, first_rd_pc = nil}
    vr[name].tr = vr_prog:install_read_tap(lo, hi, name .. "r",
        function (o, d, m)
            local e = vr[name]; e.r = e.r + 1
            if not e.first_rd_pc then e.first_rd_pc = vr_cpu.state["PC"].value end
            return d
        end)
    vr[name].tw = vr_prog:install_write_tap(lo, hi, name .. "w",
        function (o, d, m) vr[name].w = vr[name].w + 1; return d end)
end

-- PER GAME. This was hardcoded to explbrkr's windows, and the answer it gave
-- there -- 1.4 VIEW2 reads a frame, chip 1 never read -- was used to justify
-- SHARING the VIEW2 read port in shared video code. A per-game fact measured
-- on one game and applied to all of them is hard rule 9 exactly, and the tool
-- could not have caught it because it could not address another game's map.
--
--   bakubrkr_map  view2_0 500000  view2_1 580000  spr 600000  pal 700000
--   mgcrystl_map  view2_0 600000  view2_1 680000  spr 700000  pal 500000
--   blazeon_map   view2_0 600000  (one chip)      spr 700000  pal 500000
local MAPS = {
    explbrkr = {v0 = 0x500000, v1 = 0x580000, spr = 0x600000, pal = 0x700000},
    bakubrkr = {v0 = 0x500000, v1 = 0x580000, spr = 0x600000, pal = 0x700000},
    mgcrystl = {v0 = 0x600000, v1 = 0x680000, spr = 0x700000, pal = 0x500000},
    blazeonj = {v0 = 0x600000, v1 = nil,      spr = 0x700000, pal = 0x500000},
    wingforc = {v0 = 0x600000, v1 = nil,      spr = 0x700000, pal = 0x500000},
}
local setname = emu.romname and emu.romname() or "explbrkr"
local M = MAPS[setname]
if not M then
    -- No plausible substitute. A wrong map taps addresses nothing uses and
    -- reports zero reads, which reads exactly like "this game never reads".
    error("mame_vram_reads: no window map for '" .. tostring(setname) .. "'")
end
print(string.format("-- windows for %s: v0 %06x  v1 %s  spr %06x  pal %06x",
      setname, M.v0, M.v1 and string.format("%06x", M.v1) or "none",
      M.spr, M.pal))

win("view2_0", M.v0, M.v0 + 0x3fff)
if M.v1 then win("view2_1", M.v1, M.v1 + 0x3fff) end
win("sprite ", M.spr, M.spr + 0x1fff)
win("palette", M.pal, M.pal + 0x0fff)

vr_n = emu.add_machine_frame_notifier(function ()
    vr_frames = vr_frames + 1
    if vr_frames % 900 ~= 0 then return end
    print(string.format("-- frame %d", vr_frames))
    for _, k in ipairs({"view2_0", "view2_1", "sprite ", "palette"}) do
        local e = vr[k]
        if e then
        print(string.format("   %s  reads %9d   writes %9d   %s",
            k, e.r, e.w,
            e.first_rd_pc and string.format("first read at PC %06x", e.first_rd_pc)
                           or "NEVER READ"))
        end
    end
    if vr_frames >= 2700 then manager.machine:exit() end
end)
