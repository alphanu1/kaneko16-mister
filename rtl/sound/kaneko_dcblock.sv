// SPDX-License-Identifier: GPL-3.0-or-later
//
// DC blocker: a first-order high pass, as the board's coupling capacitors are.
//
// WHY THIS EXISTS
//
// jt49's `sound` is 10-bit UNSIGNED and its silence is ZERO, not mid-scale.
// The 68000 boards' mix centres it by subtracting a fixed midpoint, which is
// right for a signal swinging about that point and wrong for a silent one:
// Explosive Breaker keeps both YM2149 volumes at zero, so the pair reads 0 and
// centring puts a CONSTANT -1024 into the mix. Through the x4 and the x6 that
// is -24576 -- three quarters of the negative rail, permanently.
//
// It cost twice. The offset ate the headroom the OKI needed, which is why that
// game was quiet however much the gain was raised; and once the music control
// could scale it, anything above 140% pushed the offset past the rail and
// every sound stopped, effects included.
//
// A real board never has this problem: its output is AC-coupled and a DC level
// from a silent DAC does not reach the speaker. This is that capacitor.
//
// The estimate is a leaky integrator -- acc grows by the error each clock, and
// the DC is acc shifted down -- so the corner is set by K and the clock. At
// 48 MHz with K = 20 the time constant is 2^20 / 48e6, about 22 ms, or a
// corner near 7 Hz: below anything audible, and slow enough that a sustained
// bass note is not treated as level.

module kaneko_dcblock #(
    parameter int unsigned W = 17,
    // Time constant, in clocks, as a power of two.
    parameter int unsigned K = 20
) (
    input  wire clk,
    input  wire rst,

    input  wire signed [W-1:0] din,
    output wire signed [W-1:0] dout
);

  // The accumulator holds the DC scaled up by 2^K, so the estimate keeps K
  // fractional bits and a slow drift is not quantised away to nothing.
  logic signed [W+K-1:0] acc;

  wire signed [W-1:0] dc = acc[W+K-1:K];

  always_ff @(posedge clk) begin
    if (rst) acc <= '0;
    // acc += (din - dc): the error, once per clock. Settles on the mean.
    else     acc <= acc + {{K{din[W-1]}}, din} - {{K{dc[W-1]}}, dc};
  end

  // The AC part. Subtracting an estimate that is at most the input's own range
  // cannot overflow W bits by more than one, and the mixes downstream saturate.
  assign dout = din - dc;

endmodule
