// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// kaneko_irq: three scanline interrupts, held until acknowledged.
#include <cstdio>
#include <cstdint>
#include "Vkaneko_irq.h"
#include "verilated.h"

namespace {

Vkaneko_irq* dut;
int fails = 0, checks = 0;

void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

void ck(const char* what, int got, int want) {
    checks++;
    if (got != want) {
        fails++;
        std::printf("  FAIL %-42s got %d want %d\n", what, got, want);
    }
}

// Advance to a scanline the way the video timing would: one step per line.
void goto_line(int line) {
    dut->vcnt = line;
    tick();
    tick();
}

// A 68000 interrupt acknowledge: FC = 7, AS asserted, level on A3:A1.
void iack(int level) {
    dut->fc = 7;
    dut->a_level = level;
    dut->as = 1;
    tick();
    ck("vpa_n asserted during iack", dut->vpa_n, 0);
    ck("iack flagged", dut->iack, 1);
    tick();
    dut->as = 0;
    dut->fc = 0;
    tick();
    ck("vpa_n released after iack", dut->vpa_n, 1);
}

// Does NOT touch the levels. They are a per-game configuration that outlives a
// reset, and setting them here silently put the Tier 1 numbering back at the
// start of the CALC3 pass -- which then measured Tier 1 and reported the RTL
// broken.
void reset() {
    dut->rst = 1; dut->vcnt = 0; dut->fc = 0; dut->as = 0; dut->a_level = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->rst = 0;
    tick();
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vkaneko_irq;
    // Tier 1 levels: 5 at scanline 224, 4 at 64, 3 at 144. The CALC3
    // board's 4/3/2 are a second pass at the end.
    dut->lvl_a = 5; dut->lvl_b = 4; dut->lvl_c = 3;

    // ---------------------------------------------------- each level alone
    struct { int line; int level; const char* name; } LINES[] = {
        {  64, 4, "scanline 64 -> IRQ4"  },
        { 144, 3, "scanline 144 -> IRQ3" },
        { 224, 5, "scanline 224 -> IRQ5" },
    };
    for (auto& L : LINES) {
        reset();
        ck("idle ipl_n is 7", dut->ipl_n, 7);
        goto_line(L.line - 1);
        ck("no interrupt one line early", dut->ipl_n, 7);
        goto_line(L.line);
        ck(L.name, dut->ipl_n, (~L.level) & 7);
        // Held, not pulsed: several lines later it is still asserted.
        for (int i = 1; i <= 5; i++) goto_line(L.line + i);
        ck("level held until acknowledged", dut->ipl_n, (~L.level) & 7);
        iack(L.level);
        ck("cleared by its own acknowledge", dut->ipl_n, 7);
    }

    // -------------------------------------------------------- priority
    // All three pending at once: highest wins, and acknowledging it exposes
    // the next one down rather than clearing everything.
    reset();
    goto_line(64);  ck("only IRQ4 pending", dut->ipl_n, (~4) & 7);
    goto_line(144); ck("IRQ4 outranks IRQ3", dut->ipl_n, (~4) & 7);
    goto_line(224); ck("IRQ5 outranks both", dut->ipl_n, (~5) & 7);
    iack(5);        ck("after ack 5, IRQ4 shows", dut->ipl_n, (~4) & 7);
    iack(4);        ck("after ack 4, IRQ3 shows", dut->ipl_n, (~3) & 7);
    iack(3);        ck("after ack 3, idle", dut->ipl_n, 7);

    // An acknowledge for a level that is not pending must not disturb the
    // ones that are — the 68000 never does this, but a decode bug here would
    // silently eat interrupts and look like a game-logic fault.
    reset();
    goto_line(224);
    iack(4);
    ck("ack of an unraised level leaves IRQ5", dut->ipl_n, (~5) & 7);
    iack(5);
    ck("ack of the raised level clears it", dut->ipl_n, 7);

    // ------------------------------------------------- raise beats clear
    // A level re-raised on the same edge that acknowledges it must survive.
    // Losing it drops a frame exactly when the machine is busiest, which is
    // the hardest kind of fault to attribute.
    reset();
    goto_line(224);
    dut->fc = 7; dut->a_level = 5; dut->as = 1;
    dut->vcnt = 224;              // line_start coincides with the acknowledge
    dut->eval();
    tick();
    dut->as = 0; dut->fc = 0;
    tick();
    ck("acknowledged", dut->ipl_n, 7);

    // ------------------------------------------- a full frame, repeatedly
    // Three interrupts per frame, in scanline order, frame after frame.
    reset();
    int seen[8] = {0};
    for (int frame = 0; frame < 4; frame++) {
        for (int line = 0; line < 264; line++) {
            goto_line(line);
            int lvl = (~dut->ipl_n) & 7;
            if (lvl) { seen[lvl]++; iack(lvl); }
        }
    }
    ck("IRQ5 once per frame x4", seen[5], 4);
    ck("IRQ4 once per frame x4", seen[4], 4);
    ck("IRQ3 once per frame x4", seen[3], 4);
    ck("no other level ever raised", seen[1] + seen[2] + seen[6] + seen[7], 0);

    // ------------------------------------------------------ vpa is gated
    // VPAn must be released outside a CPU-space cycle: asserting it during a
    // normal access turns that access into a 6800-style synchronous cycle.
    reset();
    dut->as = 1; dut->fc = 1; tick();
    ck("vpa_n released in a normal cycle", dut->vpa_n, 1);
    ck("iack low in a normal cycle", dut->iack, 0);
    dut->fc = 5; tick();
    ck("vpa_n released in supervisor data", dut->vpa_n, 1);

    // ------------------------------------------- the CALC3 board's levels
    //
    // shogwarr_interrupt raises 4 at scanline 224, 3 at 64 and 2 at 144 --
    // every level one below Tier 1, and IRQ2 is a level the older boards never
    // use. Both CALC3 games inherit that machine. With the Tier 1 numbering the
    // game's main handler is never called: the 68000 runs, never reaches the
    // code that talks to its MCU, and the screen stays black with nothing else
    // to see. This pass exists so that cannot come back.
    dut->lvl_a = 4; dut->lvl_b = 3; dut->lvl_c = 2;
    reset();

    // ASCENDING, and one acknowledge each. goto_line walks the counter up to
    // the target, so jumping to 144 first passes 64 and raises that interrupt
    // as well -- which then outranks the one under test and the reading is of
    // the wrong level entirely.
    struct { int line; int level; const char* name; } CALC3[] = {
        {  64, 3, "CALC3: scanline 64 -> IRQ3" },
        { 144, 2, "CALC3: scanline 144 -> IRQ2" },
        { 224, 4, "CALC3: scanline 224 -> IRQ4" },
    };
    for (auto& L : CALC3) {
        goto_line(L.line);
        ck(L.name, dut->ipl_n, (~L.level) & 7);
        iack(L.level);
        tick();
        ck("CALC3: cleared by its acknowledge", dut->ipl_n, 7);
    }

    // The highest LEVEL wins, and the clear must match BY LEVEL rather than by
    // a fixed case on 5/4/3 -- such a case would leave IRQ2 pending for ever
    // and the 68000 would take it again the instant it returned.
    reset();
    goto_line(144);
    goto_line(64);
    goto_line(224);
    ck("CALC3: IRQ4 outranks 3 and 2", dut->ipl_n, (~4) & 7);
    iack(4); tick();
    ck("CALC3: IRQ3 next", dut->ipl_n, (~3) & 7);
    iack(3); tick();
    ck("CALC3: IRQ2 last", dut->ipl_n, (~2) & 7);
    iack(2); tick();
    ck("CALC3: all cleared", dut->ipl_n, 7);

    std::printf("kaneko_irq: checks=%d fails=%d\n", checks, fails);
    delete dut;
    return fails ? 1 : 0;
}
