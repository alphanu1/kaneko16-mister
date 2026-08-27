# Core-specific timing constraints.
#
# THE GUARD BELOW IS THE POINT OF THIS FILE.
#
# sys/sys_top.sdc groups the core's PLL outputs by matching a hierarchy PATH:
#
#   -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
#
# An empty `get_clocks` makes `set_clock_groups` a silent no-op. So a PLL whose
# instance path does not match that pattern is not constrained at all, the core
# clocks get timed against the HDMI and audio PLLs, and the build reports
# SUCCESS and emits an .rbf while missing setup by tens of nanoseconds.
#
# docs/mister-integration.md has warned about this since before this core
# existed, quoting -87 ns. It happened here anyway, at -36.5 ns, because the
# first `rtl/pll/pll.v` instantiated `altera_pll` directly inside `pll` and so
# had no `pll_inst` level -- functionally identical, constraint-wise fatal.
#
# A warning in a document did not prevent it. This does: the build now FAILS
# rather than passing vacuously.

set core_clks [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
if {[llength $core_clks] == 0} {
    post_message -type error \
      "KanekoCALC3.sdc: no core PLL clocks matched *|pll|pll_inst|altera_pll_i|*. \
       The PLL hierarchy does not match sys_top.sdc, so its clock groups are a \
       silent no-op and this build is NOT timed. See rtl/pll/pll.v."
    post_message -type error "KanekoCALC3.sdc: refusing to constrain a design that is not timed."
}

# THERE IS DELIBERATELY NO set_clock_groups FOR THE CORE PLL OUTPUTS.
#
# There used to be one, cutting general[0..2] as -asynchronous. It arrived with
# this file from an earlier core by the same author and carried that core's comment: "80 MHz
# SDRAM, 32 MHz video, 25 MHz i960 ... nothing crosses between them". Both
# halves were false here, and Quartus said so on every build:
#
#   Warning (332049): Ignored set_clock_groups at KanekoCALC3.sdc(36): Argument
#   -group with value [get_clocks {*|...|general[1].*|divclk}] contains zero
#   elements
#
# Groups 1 and 2 matched nothing, because all three outputs had identical
# settings and the IP collapsed them into ONE counter. One clock cannot be cut
# from itself, so the whole statement was a no-op and nobody noticed.
#
# clk_sdram is 96 MHz and clk_sys is 48 MHz now, both from a 480 MHz VCO by
# integer divides, so they are phase-aligned and SYNCHRONOUS. The port
# handshakes in kaneko_sdram genuinely cross between them. Cutting them would
# tell the fitter to ignore exactly the paths this split depends on -- and the
# build would pass while the hardware failed. sys_top.sdc already groups the
# core PLL outputs away from the HDMI and audio PLLs, which is what is wanted:
# cut from unrelated clocks, timed against each other.
#
# The guard below is the same idea as the one above. If the two ever collapse
# back into one counter -- which takes only two outputs sharing a frequency and
# phase -- the design silently stops being two domains.
set sdram_clk [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]
set core_clk  [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[1].*|divclk}]
if {[llength $sdram_clk] == 0 || [llength $core_clk] == 0} {
    post_message -type error \
      "KanekoCALC3.sdc: expected TWO core PLL output counters, general[0] (96 MHz\
       SDRAM) and general[1] (48 MHz core), and did not find both. Outputs with\
       identical frequency and phase share one counter -- see rtl/pll/pll.v."
}

# ---------------------------------------------------------------- SDRAM I/O
#
# THE SDRAM INTERFACE WAS ENTIRELY UNTIMED, and a build reported timing closed
# while it was. The report says so plainly once it is read:
#
#     Unconstrained Input Ports   20      <- SDRAM_DQ[0..15] among them
#     Unconstrained Output Ports  87      <- SDRAM_A[*], SDRAM_BA[*], the rest
#
# Nothing in this file or in sys/sys_top.sdc referenced an SDRAM pin, so the
# fitter routed them to suit itself and STA never asked whether data arrives
# inside the sampling window. Every simulation passes regardless -- simulation
# has no I/O delays -- so this is invisible to the entire test gate and shows
# up only as memory that reads back wrong on the board, intermittently.
#
# The pin clock is outclk_2: 96 MHz, 180 degrees from the controller's
# outclk_0, which is what SDRAM_CLK is assigned from in KanekoCALC3.sv. A
# generated clock on the PORT is what makes the rest of these mean anything --
# without it there is no reference for the data to be late or early against.
create_generated_clock -name SDRAM_CLK_pin \
    -source [get_pins {*|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    [get_ports {SDRAM_CLK}]

# Numbers for a W9825G6KH-6 class part, which is what the MiSTer SDRAM modules
# carry, plus about 1 ns of board routing:
#   input  max  tAC 5.4 + 1.0     data valid this long after the clock edge
#   input  min  tOH 0   + 1.0     and held at least this long
#   output max  tSU 1.5           the device needs setup this far ahead
#   output min  tH -0.8           and hold this far after
# CHECK THESE AGAINST THE MODULE ACTUALLY FITTED before trusting a pass: a
# wrong number here does not fail, it moves the window, which is the same
# class of fault as a default that returns a plausible value.
set sdram_out [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML \
                          SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS \
                          SDRAM_nWE SDRAM_CKE}]

set_input_delay  -clock SDRAM_CLK_pin -max 6.4  [get_ports {SDRAM_DQ[*]}]
set_input_delay  -clock SDRAM_CLK_pin -min 1.0  [get_ports {SDRAM_DQ[*]}]
set_output_delay -clock SDRAM_CLK_pin -max 1.5  $sdram_out
set_output_delay -clock SDRAM_CLK_pin -min -0.8 $sdram_out

# THE CAPTURING EDGE IS THE NEXT ONE, and saying so is the difference between
# a report that means something and a 9 ns violation on an interface that
# demonstrably works. SDRAM_CLK_pin is 180 degrees from the controller clock,
# so read data launched by the pin clock is captured by the controller edge
# AFTER the one a default single-cycle analysis picks -- it compares against an
# edge 5.2 ns too early and reports -9.259 ns.
#
# A build that fits and streams graphics and sound out of this memory is not
# 9 ns short. Where a measurement and a working board disagree, the measurement
# is wrong until shown otherwise -- which is the same rule that has caught
# three testbenches in this repository.
set_multicycle_path -setup -end 2 -from [get_ports {SDRAM_DQ[*]}]
set_multicycle_path -hold  -end 1 -from [get_ports {SDRAM_DQ[*]}]
