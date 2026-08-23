-- When does a working Magical Crystals unmask interrupts, and where is the
-- 68000 before it does?
--
-- The core reaches mgcrystl's self-test screen and then goes black with a
-- healthy bus-cycle count and ZERO interrupts acknowledged, which means the
-- 68000 never lowers its interrupt mask. This says when MAME's does, so the
-- bus-trace diff can be pointed at the right depth instead of guessing.
--
-- Globals, or the subscription is collected and the callback silently stops.
mc_cpu   = manager.machine.devices[":maincpu"]
mc_state = mc_cpu.state
mc_frame = 0
mc_seen  = false
mc_hist  = {}

mc_sub = emu.add_machine_frame_notifier(function ()
    mc_frame = mc_frame + 1
    local sr = mc_state["SR"].value
    local pc = mc_state["PC"].value
    local mask = (sr >> 8) & 7

    -- Keep a short rolling window of where it is while still masked.
    mc_hist[#mc_hist + 1] = string.format("frame %4d  PC=%06x  SR=%04x  mask=%d",
                                          mc_frame, pc, sr, mask)
    if #mc_hist > 6 then table.remove(mc_hist, 1) end

    if not mc_seen and mask < 5 then
        mc_seen = true
        print("== mgcrystl UNMASKED interrupts")
        for _, l in ipairs(mc_hist) do print("   " .. l) end
        print(string.format("   -> first frame with mask<5: %d", mc_frame))
    end

    if mc_frame % 60 == 0 then
        print(string.format("frame %4d  PC=%06x  SR=%04x  mask=%d", mc_frame, pc, sr, mask))
    end
    if mc_frame >= 600 then
        print(string.format("== stopping at frame %d (unmasked=%s)", mc_frame, tostring(mc_seen)))
        manager.machine:exit()
    end
end)
