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

-- explbrkr / bakubrkr_map windows.
win("view2_0", 0x500000, 0x503fff)
win("view2_1", 0x580000, 0x583fff)
win("sprite ", 0x600000, 0x601fff)
win("palette", 0x700000, 0x700fff)

vr_n = emu.add_machine_frame_notifier(function ()
    vr_frames = vr_frames + 1
    if vr_frames % 900 ~= 0 then return end
    print(string.format("-- frame %d", vr_frames))
    for _, k in ipairs({"view2_0", "view2_1", "sprite ", "palette"}) do
        local e = vr[k]
        print(string.format("   %s  reads %9d   writes %9d   %s",
            k, e.r, e.w,
            e.first_rd_pc and string.format("first read at PC %06x", e.first_rd_pc)
                           or "NEVER READ"))
    end
    if vr_frames >= 2700 then manager.machine:exit() end
end)
