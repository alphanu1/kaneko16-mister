-- How much of Shogun Warriors' 64 KB of MCU RAM is actually touched?
--
-- shogwarr_map declares 200000-20ffff, sixty-four kilobytes, and that costs
-- about 64 M10K blocks. This core has about 31 free, so the declared size does
-- not fit and the question is whether the games need it.
--
-- A read tap AND a write tap, because either alone would understate the range:
-- the CALC3 simulation writes tables the 68000 only reads, and the 68000
-- writes commands the MCU only reads. Both go through the 68000's program
-- space, so both taps see them.
--
-- Reports the highest address touched, which is what decides the size, and a
-- coarse map so a sparse layout is visible rather than being hidden behind a
-- single high outlier.
sw_cpu  = manager.machine.devices[":maincpu"]
sw_prog = sw_cpu.spaces["program"]
sw_lo, sw_hi = 0xffffffff, 0
sw_pages = {}          -- 1 KB granularity
sw_reads, sw_writes = 0, 0
sw_frames = 0

local function note(addr)
    local off = addr - 0x200000
    if off < sw_lo then sw_lo = off end
    if off > sw_hi then sw_hi = off end
    local p = off >> 10
    sw_pages[p] = (sw_pages[p] or 0) + 1
end

sw_tw = sw_prog:install_write_tap(0x200000, 0x20ffff, "mcuw",
    function (offset, data, mask) sw_writes = sw_writes + 1; note(offset); return data end)
sw_tr = sw_prog:install_read_tap(0x200000, 0x20ffff, "mcur",
    function (offset, data, mask) sw_reads = sw_reads + 1; note(offset); return data end)

sw_n = emu.add_machine_frame_notifier(function ()
    sw_frames = sw_frames + 1
    if sw_frames % 600 ~= 0 then return end
    local used, first, last = 0, nil, nil
    for p = 0, 63 do
        if sw_pages[p] then
            used = used + 1
            if not first then first = p end
            last = p
        end
    end
    print(string.format(
        "frame %5d  reads %8d writes %8d   touched %06x..%06x   %d of 64 KB-pages  (%d..%d)",
        sw_frames, sw_reads, sw_writes, sw_lo, sw_hi, used, first or -1, last or -1))
    if sw_frames >= 3600 then
        print("== per 1 KB page, accesses:")
        local line = "  "
        for p = 0, 63 do
            line = line .. string.format("%s", sw_pages[p] and "#" or ".")
        end
        print(line .. "   (page 0 at left, 63 at right)")
        print(string.format("== highest offset touched: %06x -- needs %d KB",
                            sw_hi, (sw_hi >> 10) + 1))
        manager.machine:exit()
    end
end)
