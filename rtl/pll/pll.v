// SPDX-License-Identifier: GPL-3.0-or-later
//
// Kaneko 16-bit arcade core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// PORTED from an earlier core by the same author, rtl/pll/pll.v, with this
// core's frequencies. Two things carried over unchanged because they are
// hard-won and not obvious:
//
//   - the module MUST be named `pll`, and the two-level hierarchy
//     pll -> pll_inst -> altera_pll_i is LOAD-BEARING. sys/sys_top.sdc matches
//     on that instance path; flatten it and the clock groups match nothing,
//     timing passes vacuously and the build emits an .rbf with -36.5 ns of
//     setup slack. See the note below, which is the later core's, paid for once.
//   - pll.qip carries the instance assignments the IP generator would write.
//
// THE MODULE MUST BE NAMED `pll`. MiSTer's `sys/sys_top.sdc` writes its
// clock-group constraints against that name. Rename it and the constraints match
// nothing, timing analysis passes vacuously, and the build fails on hardware
// with no failing report to point at. This is a standing rule in
// docs/mister-integration.md, paid for once already.
//
// Written by hand rather than generated, because the earlier core's `pll_0002.v` shows
// the IP tool emits a plain parameterised instantiation of `altera_pll` rather
// than a Qsys black box. The parameter set below is that instantiation's, with
// this core's frequencies. `rtl/pll/pll.qip` carries the instance assignments
// the generator would have written.
//
// THE TWO-LEVEL HIERARCHY IS LOAD-BEARING AND MUST NOT BE FLATTENED.
// `sys/sys_top.sdc` line 14 reads:
//
//     -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
//
// It matches on the INSTANCE PATH, so the inner instance must be named
// `pll_inst` and the `altera_pll` inside it `altera_pll_i`. The first version of
// this file put `altera_pll` directly inside `pll`, which is functionally
// identical and constraint-wise fatal: the group matched nothing, the core
// clocks were left related to the HDMI and audio PLLs, and the build reported
// **-36.5 ns** of setup slack on a 31.25 ns clock while still emitting an .rbf.
//
// That is the failure mode CLAUDE.md and docs/mister-integration.md both warn
// about -- "a passing build fails on hardware" -- reached by a route neither
// anticipated. The rule is not only about the module NAME.
//
// SDRAM AT 40 MHz, DELIBERATELY AND TEMPORARILY.
//
// The board returns data that changes with the read capture phase but is never
// correct at any of the four settings. Wrong logic would fail in simulation too,
// and it does not: the controller passes 74,729 checks at 32 MB and 58,739 at
// 128 MB against the device model, and the loader-to-readback path passes as
// well. A capture window merely misplaced would be fixed by one of the phases.
//
// Neither fits, and both are consistent with MARGINAL TIMING: at 80 MHz the
// device is clocked on the inverse of the controller clock, which gives it only
// a half period of skew and no true phase shift. Halving the clock doubles every
// margin without changing a line of logic, so if the data comes back correct the
// cause is timing and the fix is a properly phase-shifted SDRAM_CLK. If it is
// still wrong, timing is exonerated and the fault is elsewhere.
//
// T_REFI follows the clock: 8192 rows in 64 ms is one refresh every 7.8125 us,
// which is 312 cycles at 40 MHz rather than 625 at 80.
//
// FREQUENCIES, AND WHY THESE
//
// The Kaneko pixel clock is NOT known. MAME declares explbrkr with
// `set_refresh_hz(59)` and `set_size(256,256)` but never calls `set_raw()`, so
// the true pixel rate and blanking are unrecorded — this is the open question
// in docs/findings.md and the design study's section 9.
//
// 48 MHz is therefore chosen for divisibility rather than authenticity: a
// single core clock that divides exactly to both rates we need, so no
// fractional division and no accumulated phase error.
//
//   ce_pix = /8  ->  6 MHz pixel clock, a common rate for this era
//   ce_cpu = /4  -> 12 MHz, which IS verified: MAME annotates explbrkr's
//                   68000 as XTAL(12'000'000) "verified on pcb"
//
// The 6 MHz is a placeholder and is marked as such wherever it appears. When a
// PCB capture or a same-era reference settles the real timing, this is the one
// number that changes.
//
//   outclk_0   96 MHz   SDRAM controller
//   outclk_1   48 MHz   core: ce_pix /8 = 6 MHz, ce_cpu /4 = 12 MHz
//   outclk_2   96 MHz   SDRAM_CLK pin, 180 degrees from outclk_0
//
// THE THREE OUTPUTS MUST NOT ALL CARRY THE SAME SETTINGS. They did until
// 2026-08-23 -- 48 MHz, 0 ps, 50% duty, three times -- and the IP responded by
// giving all three ONE output counter, so the whole core was a single clock
// domain. The timing netlist contained exactly one `emu|pll` clock and its
// Fmax was 54.74 MHz: the 68000, the video path and the memory controller all
// held down to the slowest path among them.
//
// The VCO runs at 480 MHz (50 x 48/5), so 96 (/5) and 48 (/10) are both exact
// integer divides and the two clocks stay phase-aligned -- every clk_sys edge
// coincides with an even clk_sdram edge. That is what makes the crossing
// synchronous rather than a CDC problem, and it is why Kaneko16.sdc must TIME
// the two against each other instead of cutting them apart.
//                       (study §5.5), so this is the reference speed and not a
//                       limit we are pushing against.

`timescale 1 ps / 1 ps

module pll (
    input  wire  refclk,     // 50 MHz from the board
    input  wire  rst,
    output wire  outclk_0,   // 96 MHz  SDRAM controller
    output wire  outclk_1,   // 48 MHz  core (ce_pix /8 = 6 MHz, ce_cpu /4 = 12 MHz)
    output wire  outclk_2,   // 96 MHz  SDRAM_CLK pin, 180 deg from outclk_0
    output wire  locked
  );

  // Instance name `pll_inst`: see the note above. Not cosmetic.
  pll_core pll_inst (
    .refclk   (refclk),
    .rst      (rst),
    .outclk_0 (outclk_0),
    .outclk_1 (outclk_1),
    .outclk_2 (outclk_2),
    .locked   (locked)
  );

endmodule

module pll_core (
    input  wire  refclk,
    input  wire  rst,
    output wire  outclk_0,
    output wire  outclk_1,
    output wire  outclk_2,
    output wire  locked
  );

  altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("50.0 MHz"),
    .operation_mode("direct"),
    .number_of_clocks(3),
    .output_clock_frequency0("96.000000 MHz"),
    .phase_shift0("0 ps"),
    .duty_cycle0(50),
    .output_clock_frequency1("48.000000 MHz"),
    .phase_shift1("0 ps"),
    .duty_cycle1(50),
    // 5208 ps is half of 96 MHz's 10416.67 ps period: the same 180-degree
    // relationship the board has always run, since `SDRAM_CLK = ~clk_sdram` is
    // what rd_lat_sel was characterised against. The difference is the ROUTE.
    // An inverter feeding an output pin goes through general fabric and
    // arrives with whatever skew the fitter leaves; a PLL output takes the
    // dedicated clock path. Tune against the board with rd_lat_sel, which the
    // OSD already exposes.
    .output_clock_frequency2("96.000000 MHz"),
    .phase_shift2("5208 ps"),
    .duty_cycle2(50),
    .pll_type("General"),
    .pll_subtype("General")
  ) altera_pll_i (
    .rst        (rst),
    .outclk     ({outclk_2, outclk_1, outclk_0}),
    .locked     (locked),
    .fboutclk   ( ),
    .fbclk      (1'b0),
    .refclk     (refclk)
  );

endmodule
