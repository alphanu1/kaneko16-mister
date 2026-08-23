-- Does Wing Force's 68000 read the fourth input word at c00004, and what does
-- it do with it?
--
-- The core drove that word as 0x0000 where MAME reads 0xffff. If the game
-- never reads it, the divergence is real but harmless and the missing OKI
-- effects are something else. A READ tap, because a read leaves nothing in
-- memory for a watch to find.
wf_cpu  = manager.machine.devices[":maincpu"]
wf_prog = wf_cpu.spaces["program"]
wf_unk, wf_sys, wf_p1 = 0, 0, 0
wf_first = nil
wf_frames = 0

wf_t_unk = wf_prog:install_read_tap(0xc00004, 0xc00005, "unk",
    function (o, d, m)
        wf_unk = wf_unk + 1
        if not wf_first then
            wf_first = wf_cpu.state["PC"].value
            print(string.format("!! first c00004 read at frame %d, PC=%06x", wf_frames, wf_first))
        end
        return d
    end)
wf_t_sys = wf_prog:install_read_tap(0xc00006, 0xc00007, "sys",
    function (o, d, m) wf_sys = wf_sys + 1; return d end)
wf_t_p1 = wf_prog:install_read_tap(0xc00000, 0xc00001, "p1",
    function (o, d, m) wf_p1 = wf_p1 + 1; return d end)

wf_n = emu.add_machine_frame_notifier(function ()
    wf_frames = wf_frames + 1
    if wf_frames % 300 == 0 then
        print(string.format("frame %4d  c00000=%d  c00004(UNK)=%d  c00006(SYSTEM)=%d",
                            wf_frames, wf_p1, wf_unk, wf_sys))
    end
    if wf_frames >= 1500 then
        print(string.format("== 1500 frames: UNK read %d times", wf_unk))
        if wf_unk == 0 then print("== WING FORCE NEVER READS c00004 -- in_unk cannot be the cause") end
        manager.machine:exit()
    end
end)
