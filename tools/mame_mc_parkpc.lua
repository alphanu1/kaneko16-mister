-- Does MAME's Magical Crystals ever EXECUTE the loop our core parks in?
--
-- Ours ends at:
--     01f81a  LEA $00603000,A7
--     01f820  ADDQ.W #1,$300006
--     01f826  JMP *-6
--
-- 0x300006 turned out to be a hot variable (MAME writes it 2.7M times in 600
-- frames), so a write tap on it proves nothing. The discriminating question is
-- whether the PC ever reaches 01f81a/01f820 at all. Those are ROM addresses,
-- so a READ tap catches the instruction fetch -- a memory watch could not,
-- because a fetch leaves nothing behind (CLAUDE.md).
mc_cpu  = manager.machine.devices[":maincpu"]
mc_prog = mc_cpu.spaces["program"]
mc_park = 0
mc_lea  = 0
mc_frames = 0

mc_tap_lea = mc_prog:install_read_tap(0x01f81a, 0x01f81b, "lea",
    function (offset, data, mask) mc_lea = mc_lea + 1; return data end)

mc_tap_park = mc_prog:install_read_tap(0x01f820, 0x01f821, "park",
    function (offset, data, mask) mc_park = mc_park + 1; return data end)

mc_sub = emu.add_machine_frame_notifier(function ()
    mc_frames = mc_frames + 1
    if mc_frames % 150 == 0 then
        print(string.format("frame %4d  PC=%06x  fetches 01f81a=%d  01f820=%d",
                            mc_frames, mc_cpu.state["PC"].value, mc_lea, mc_park))
    end
    if mc_frames >= 600 then
        print(string.format("== 600 frames: 01f81a fetched %d times, 01f820 fetched %d times",
                            mc_lea, mc_park))
        if mc_park == 0 then
            print("== MAME NEVER EXECUTES THE PARK LOOP -- our core is trapping")
        end
        manager.machine:exit()
    end
end)
