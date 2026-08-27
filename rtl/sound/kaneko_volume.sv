// SPDX-License-Identifier: GPL-3.0-or-later
//
// Output volume, in eighths, with saturation.
//
// A separate module for one multiply, because this core has already shipped a
// broken one. Wing Force's YM was scaled with `(18'sd13 * x) >>> 6` written
// into an 18-bit wire: 13 x 32768 needs 20 bits, the product truncated, and
// the music started fine and turned to noise a second in. A Verilog multiply is
// evaluated at the width of its TARGET, not the width the product needs, and
// nothing warns. So the intermediate here is derived from the widths rather
// than chosen, and the module has a testbench that sweeps both extremes.
//
// SATURATION, NOT WRAPPING. An overflow that wraps inverts the waveform: it
// sounds like a broken chip rather than a loud one, which is the harder fault
// to recognise by ear, and it is why every mix upstream saturates too.

module kaneko_volume #(
    // The source's own width. The 68000 board's parts are 17 bits and the Z80
    // board's are 18; feeding either through a 16-bit stage would clip a
    // signal that was in range before the volume touched it.
    parameter int unsigned W = 17
) (
    // Eighths of unity: 8 is 100%, 16 is 200%, 4 is 50%. Zero is silence, which
    // is a setting and not a special case.
    input  wire [4:0]           gain8,
    input  wire signed [W-1:0]  din,
    output wire signed [W-1:0]  dout
);

  // W signed by 5 unsigned needs W+5; +8 is slack, so the width is obviously
  // right rather than exactly right. That distinction is what failed before.
  localparam int unsigned P = W + 8;

  wire signed [P-1:0] scaled  = $signed(din) * $signed({1'b0, gain8});
  wire signed [P-1:0] shifted = scaled >>> 3;

  // TYPED LOCALPARAMS, not sizing casts. Quartus 17.0 will not take (P)'(expr)
  // -- it is a syntax error there though Verilator accepts it, and the build
  // dies in analysis with the module ignored. Hard rule 7: a construct 17.0
  // rejects is a construct to rewrite, not a reason to reach for 24.
  localparam signed [P-1:0] HI =  (1 <<< (W - 1)) - 1;
  localparam signed [P-1:0] LO = -(1 <<< (W - 1));

  assign dout = (shifted > HI) ? HI[W-1:0]
              : (shifted < LO) ? LO[W-1:0]
                               : shifted[W-1:0];

endmodule
