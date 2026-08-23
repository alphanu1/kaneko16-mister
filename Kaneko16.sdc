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
      "Kaneko16.sdc: no core PLL clocks matched *|pll|pll_inst|altera_pll_i|*. \
       The PLL hierarchy does not match sys_top.sdc, so its clock groups are a \
       silent no-op and this build is NOT timed. See rtl/pll/pll.v."
    post_message -type error "Kaneko16.sdc: refusing to constrain a design that is not timed."
}

# THERE IS DELIBERATELY NO set_clock_groups FOR THE CORE PLL OUTPUTS.
#
# There used to be one, cutting general[0..2] as -asynchronous. It arrived with
# this file from the Model 2 core and carried that core's comment: "80 MHz
# SDRAM, 32 MHz video, 25 MHz i960 ... nothing crosses between them". Both
# halves were false here, and Quartus said so on every build:
#
#   Warning (332049): Ignored set_clock_groups at Kaneko16.sdc(36): Argument
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
      "Kaneko16.sdc: expected TWO core PLL output counters, general[0] (96 MHz\
       SDRAM) and general[1] (48 MHz core), and did not find both. Outputs with\
       identical frequency and phase share one counter -- see rtl/pll/pll.v."
}
