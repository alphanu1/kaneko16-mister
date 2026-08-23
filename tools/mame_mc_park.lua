-- Does a WORKING Magical Crystals ever reach the park loop our core ends in?
--
-- Our 68000 traps, runs a handler ending in RTE, and lands at 01f81a:
--     01f81a  LEA $00603000,A7
--     01f820  ADDQ.W #1,$300006
--     01f826  JMP *-6              <- infinite
--
-- 0x300006 is therefore a counter that ONLY the park loop increments. A write
-- tap on it answers the question outright: if MAME never writes it, the park
-- is ours and the game is trapping on something the core gets wrong.
--
-- A write tap, not a memory watch -- and a global, or the subscription is
-- collected and the callback silently stops (CLAUDE.md).
mc_cpu  = manager.machine.devices[":maincpu"]
mc_prog = mc_cpu.spaces["program"]
mc_hits = 0
mc_first_pc = nil
mc_frames = 0

mc_tap = mc_prog:install_write_tap(0x300006, 0x300007, "park",
    function (offset, data, mask)
        mc_hits = mc_hits + 1
        if not mc_first_pc then
            mc_first_pc = mc_cpu.state["PC"].value
            print(string.format("!! wrote 300006 at frame %d, PC=%06x, data=%04x",
                                mc_frames, mc_first_pc, data))
        end
        return data
    end)

mc_sub = emu.add_machine_frame_notifier(function ()
    mc_frames = mc_frames + 1
    if mc_frames % 120 == 0 then
        print(string.format("frame %4d  PC=%06x  writes to 300006 so far: %d",
                            mc_frames, mc_cpu.state["PC"].value, mc_hits))
    end
    if mc_frames >= 600 then
        print(string.format("== done: %d frames, %d writes to 300006", mc_frames, mc_hits))
        if mc_hits == 0 then
            print("== MAME NEVER PARKS -- the trap is ours")
        end
        manager.machine:exit()
    end
end)
