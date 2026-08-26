// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CALC hitbox calculator, TYPE 2 — B.Rap Boys.
//
// Same chip as Shogun Warriors' and a different device: type 1 is a 2D box
// intersection, type 2 is THREE dimensions with a mode register that changes
// how each axis reads its position and size. `brapboys(config)` in MAME calls
// set_type(2) after inheriting shogwarr's machine, which is hard rule 9 in one
// line — the board is not the game.
//
// Transcribed from kaneko_hit.cpp's type-2 handlers.
//
// EVERY REGISTER HAS TWO ADDRESSES. x1po is written at both 0x00 and 0x28,
// z1po at 0x38 and 0x50, and so on. That is not a mirror of the whole window:
// the pairs interleave, so 0x28 writes x1po while 0x2c writes x1so and 0x50
// writes z1po. Decoding a range or masking a bit would put values in the wrong
// registers, and the result is a collision result that is merely wrong rather
// than obviously broken.
//
// The registers hold what was written, unsigned. The arithmetic is SIGNED and
// goes negative -- a negative distance is how "no overlap" is reported, and the
// flags test for it -- so the working width is wider than the registers and the
// reads truncate back to 16 bits, exactly as returning an int through a
// uint16_t does in the C.

module kaneko_hit2 (
    input  wire        clk,
    input  wire        rst,

    // Word offset within the window, as type 1 takes it.
    input  wire [5:0]  addr,
    input  wire [15:0] din,
    input  wire        we,
    input  wire        uds,
    input  wire        lds,
    output logic [15:0] dout,

    input  wire [15:0] rnd
);

  // The C indexes by offset*4, so a word offset of n is index n*4. Keeping the
  // same numbering as the source makes the case labels checkable against it.
  wire [7:0] idx = {addr, 2'b00};

  logic [15:0] x1po, x1so, y1po, y1so, z1po, z1so;
  logic [15:0] x2po, x2so, y2po, y2so, z2po, z2so;
  // Bits 7:6 and 15:14 are NOT USED, and that is MAME's shape rather than an
  // oversight here: it reads the mode at shifts 0, 2, 4, 8, 10 and 12, so
  // one pair per axis with a gap between the two boxes.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0] mode;
  /* verilator lint_on UNUSEDSIGNAL */

  // Byte enables: the 68000 can write either half. Type 1 does the same.
  wire [15:0] wdata = {uds ? din[15:8] : 8'h00, lds ? din[7:0] : 8'h00};

  always_ff @(posedge clk) begin
    if (rst) begin
      x1po <= '0; x1so <= '0; y1po <= '0; y1so <= '0; z1po <= '0; z1so <= '0;
      x2po <= '0; x2so <= '0; y2po <= '0; y2so <= '0; z2po <= '0; z2so <= '0;
      mode <= '0;
    end else if (we) begin
      case (idx)
        8'h00, 8'h28: x1po <= wdata;
        8'h04, 8'h2c: x1so <= wdata;
        8'h08, 8'h30: y1po <= wdata;
        8'h0c, 8'h34: y1so <= wdata;
        8'h10, 8'h58: x2po <= wdata;
        8'h14, 8'h5c: x2so <= wdata;
        8'h18, 8'h60: y2po <= wdata;
        8'h1c, 8'h64: y2so <= wdata;
        8'h38, 8'h50: z1po <= wdata;
        8'h3c, 8'h54: z1so <= wdata;
        8'h20, 8'h68: z2po <= wdata;
        8'h24, 8'h6c: z2so <= wdata;
        8'h70:        mode <= wdata;
        // No default that stores anything: an unmapped write is a write MAME
        // logs and drops, and putting it in a register would be a value that
        // looks plausible later.
        default: ;
      endcase
    end
  end

  // ------------------------------------------------------------ geometry
  //
  // Each axis reads its position and size through one of four modes, two bits
  // each out of the mode register. x1 is the LEFT edge and s1 the width.
  function automatic void calc_org(input [1:0] m,
                                   input [15:0] x0, input [15:0] s0,
                                   output signed [31:0] x1,
                                   output signed [31:0] s1);
    begin
      case (m)
        2'd0: begin x1 = $signed({16'd0, x0});                       s1 = $signed({16'd0, s0}); end
        2'd1: begin x1 = $signed({16'd0, x0}) - $signed({17'd0, s0[15:1]}); s1 = $signed({16'd0, s0}); end
        2'd2: begin x1 = $signed({16'd0, x0}) - $signed({16'd0, s0}); s1 = $signed({16'd0, s0}); end
        2'd3: begin x1 = $signed({16'd0, x0}) - $signed({16'd0, s0}); s1 = $signed({15'd0, s0, 1'b0}); end
      endcase
    end
  endfunction

  // The overlap of two segments, negative when they do not meet.
  function automatic signed [31:0] compute(input signed [31:0] x1,
                                           input signed [31:0] w1,
                                           input signed [31:0] x2,
                                           input signed [31:0] w2);
    logic signed [31:0] lo, lo_w, hi;
    begin
      if (x2 >= x1 && (x2 + w2) <= (x1 + w1)) begin
        compute = w2;                       // second inside the first
      end else if (x1 >= x2 && (x1 + w1) <= (x2 + w2)) begin
        compute = w1;                       // first inside the second
      end else begin
        // Order them, then the overlap is the right edge of the left one minus
        // the left edge of the right one. The right one's width is not needed.
        if (x2 < x1) begin
          lo = x2; lo_w = w2; hi = x1;
        end else begin
          lo = x1; lo_w = w1; hi = x2;
        end
        compute = lo + lo_w - hi;
      end
    end
  endfunction

  logic signed [31:0] x1p, x1s, y1p, y1s, z1p, z1s;
  logic signed [31:0] x2p, x2s, y2p, y2s, z2p, z2s;
  logic signed [31:0] x_coll, y_coll, z_coll;
  logic [15:0]        flags;

  always_comb begin
    calc_org(mode[1:0],   x1po, x1so, x1p, x1s);
    calc_org(mode[3:2],   y1po, y1so, y1p, y1s);
    calc_org(mode[5:4],   z1po, z1so, z1p, z1s);
    calc_org(mode[9:8],   x2po, x2so, x2p, x2s);
    calc_org(mode[11:10], y2po, y2so, y2p, y2s);
    calc_org(mode[13:12], z2po, z2so, z2p, z2s);

    x_coll = compute(x1p, x1s, x2p, x2s);
    y_coll = compute(y1p, y1s, y2p, y2s);
    z_coll = compute(z1p, z1s, z2p, z2s);

    flags = 16'd0;
    // 4th nibble: Y absolute
    if      (y1p >  y2p) flags |= 16'h2000;
    else if (y1p == y2p) flags |= 16'h4000;
    else                 flags |= 16'h8000;
    if (y_coll < 0)      flags |= 16'h1000;
    // 3rd nibble: X absolute
    if      (x1p >  x2p) flags |= 16'h0200;
    else if (x1p == x2p) flags |= 16'h0400;
    else                 flags |= 16'h0800;
    if (x_coll < 0)      flags |= 16'h0100;
    // 2nd nibble: Z absolute
    if      (z1p >  z2p) flags |= 16'h0020;
    else if (z1p == z2p) flags |= 16'h0040;
    else                 flags |= 16'h0080;
    if (z_coll < 0)      flags |= 16'h0010;
    // 1st nibble: which pairs of axes overlap at once
    if (x_coll >= 0 && y_coll >= 0 && z_coll >= 0) flags |= 16'h0008;
    if (x_coll >= 0 && z_coll >= 0)                flags |= 16'h0004;
    if (y_coll >= 0 && z_coll >= 0)                flags |= 16'h0002;
    if (x_coll >= 0 && y_coll >= 0)                flags |= 16'h0001;
  end

  // The absolute distance between the two positions, as WRITTEN rather than
  // as adjusted by the mode.
  wire [15:0] x1tox2 = (x2po >= x1po) ? (x2po - x1po) : (x1po - x2po);
  wire [15:0] y1toy2 = (y2po >= y1po) ? (y2po - y1po) : (y1po - y2po);
  wire [15:0] z1toz2 = (z2po >= z1po) ? (z2po - z1po) : (z1po - z2po);

  always_comb begin
    case (idx)
      8'h00, 8'h10: dout = x_coll[15:0];
      8'h04, 8'h14: dout = y_coll[15:0];
      8'h18:        dout = z_coll[15:0];
      8'h08, 8'h1c: dout = flags;
      8'h28:        dout = rnd;
      8'h40: dout = x1po;  8'h44: dout = x1so;
      8'h48: dout = y1po;  8'h4c: dout = y1so;
      8'h50: dout = z1po;  8'h54: dout = z1so;
      8'h58: dout = x2po;  8'h5c: dout = x2so;
      8'h60: dout = y2po;  8'h64: dout = y2so;
      8'h68: dout = z2po;  8'h6c: dout = z2so;
      8'h80: dout = x1tox2;
      8'h84: dout = y1toy2;
      8'h88: dout = z1toz2;
      // MAME logs an unmapped read and returns 0. Zero is a real value here,
      // so this is one place a "plausible default" is the documented answer.
      default: dout = 16'd0;
    endcase
  end

endmodule
