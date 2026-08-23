-- What does Wing Force's 68000 send to the sound latch, and when?
--
-- Measured on the board: our Z80 writes the YM2151 14 times a frame, which is
-- inside MAME's range, and writes the OKI ZERO times ever. So the sound driver
-- runs and never reaches its effect code. The chip is exonerated -- jt6295's
-- status read returns {4'hf, busy|start}, the same shape as MAME's
-- 0xf0 | playing-flags -- so the question is what reaches the Z80 at all.
--
-- The latch is at e00000 on the Blaze On board. A write tap says what the
-- 68000 sends and how often; if it only ever sends one value, the effects are
-- never being ASKED for and the fault is on the 68000 side, not the Z80's.
wf_cpu  = manager.machine.devices[":maincpu"]
wf_prog = wf_cpu.spaces["program"]
wf_vals, wf_n, wf_frames = {}, 0, 0

wf_tap = wf_prog:install_write_tap(0xe00000, 0xe00001, "latch",
    function (offset, data, mask)
        local v = data & 0xff
        wf_vals[v] = (wf_vals[v] or 0) + 1
        wf_n = wf_n + 1
        return data
    end)

wf_note = emu.add_machine_frame_notifier(function ()
    wf_frames = wf_frames + 1
    if wf_frames % 300 == 0 then
        local keys = {}
        for v in pairs(wf_vals) do keys[#keys+1] = v end
        table.sort(keys)
        local parts = {}
        for _, v in ipairs(keys) do
            parts[#parts+1] = string.format("%02x:%d", v, wf_vals[v])
        end
        print(string.format("frame %4d  latch writes %d  values %s",
                            wf_frames, wf_n, table.concat(parts, " ")))
    end
    if wf_frames >= 1500 then manager.machine:exit() end
end)
