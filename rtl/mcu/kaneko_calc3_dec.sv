// SPDX-License-Identifier: GPL-3.0-or-later
//
// CALC3 table decompressor: the per-byte transform.
//
// The CALC3 stores its tables encrypted in an external data ROM and decodes
// them into MCU RAM, where the 68000 then EXECUTES them -- the tables are
// 68000 subroutines, which is why nothing short of the real transform will do.
// A wrong byte here is not a wrong pixel, it is a wrong instruction.
//
// This is the transform for ONE byte, combinational, with the block's
// parameters and the byte's index supplied by the sequencer around it. It is
// split out because it is the part that has to be exactly right and the part
// that can be fuzzed on its own: no ROM data, no memory, no state.
//
// Transcribed from kaneko_calc3.cpp's decompress_table, and checked end to end
// through tools/calc3_ref.py, which reproduces MAME byte for byte on every
// table shogwarr and brapboys actually pull. See docs/findings.md.
//
// Two paths, chosen by whether the block carries an inline key table:
//
//   keyed   a 64-byte key selected by the block's key byte, one of four
//           subtract types, then a rotate whose direction alternates with the
//           byte index under alternate-swap modes 0 and 3.
//   inline  a key table of ANY length carried in the block itself, indexed
//           modulo its size, plus one of two magic byte arrays. MAME's own
//           comment says these "should be derived from the inline table
//           somehow" -- they are not understood, they are reproduced.
//
// The rotate is a LEFT rotate by (bits & 7). `8 - shift` with shift == 0 is 8,
// which masks to 0 and is the identity -- that is deliberate and matches the C.

module kaneko_calc3_dec (
    // The encrypted byte, and the PARITY of its index within the table.
    // Only the parity is used -- every branch that looks at the index asks
    // whether it is odd -- so the port carries that rather than the index,
    // and the sequencer keeps the counter.
    input  wire [7:0]  dat_in,
    input  wire        idx_odd,

    // Block parameters, all straight out of the block header.
    // THREE bits, not the header's four. Every use in the C masks with & 7:
    // rotate does, and `8 - shift` feeds the same masked rotate, so bit 3
    // cannot change any result. shift == 9 and shift == 1 give identical
    // output both ways round. The sequencer passes the low three bits.
    input  wire [2:0]  shift,
    input  wire [1:0]  subtracttype,
    input  wire [1:0]  alternateswaps,

    // Inline path: the size selects it (zero means the keyed path), and
    // `inline_byte` is the inline table entry for this index, fetched by the
    // sequencer at inline_base + (idx % inline_size).
    input  wire [7:0]  inline_size,
    input  wire [7:0]  inline_byte,
    // idx % inline_size and (idx / inline_size) & 1, computed by the
    // sequencer. A modulo by an arbitrary 8-bit size is a divide, and doing it
    // once in a sequencer that is already counting is far cheaper than
    // inferring one here per byte.
    input  wire [7:0]  inline_idx,
    input  wire        inline_half,

    // Keyed path: key[idx & 0x3f], fetched by the sequencer.
    input  wire [7:0]  key_byte,

    output wire [7:0]  dat_out
);

  // EXTRA and EXTRA2, indexed by inline_idx >> 1. 31 and 30 bytes; neither is
  // a power of two and they are not the same length, so this is a case rather
  // than anything cleverer. Out-of-range reads cannot happen: inline_idx is
  // always below inline_size, and a block whose inline table is longer than
  // these arrays would index past them in MAME too.
  function automatic [7:0] extra1(input [7:0] i);
    case (i)
      8'd0:  extra1 = 8'h14;  8'd1:  extra1 = 8'hf0;  8'd2:  extra1 = 8'hf8;
      8'd3:  extra1 = 8'hd2;  8'd4:  extra1 = 8'hbe;  8'd5:  extra1 = 8'hfc;
      8'd6:  extra1 = 8'hac;  8'd7:  extra1 = 8'h86;  8'd8:  extra1 = 8'h64;
      8'd9:  extra1 = 8'h08;  8'd10: extra1 = 8'h0c;  8'd11: extra1 = 8'h74;
      8'd12: extra1 = 8'hd6;  8'd13: extra1 = 8'h6a;  8'd14: extra1 = 8'h24;
      8'd15: extra1 = 8'h12;  8'd16: extra1 = 8'h1a;  8'd17: extra1 = 8'h72;
      8'd18: extra1 = 8'hba;  8'd19: extra1 = 8'h48;  8'd20: extra1 = 8'h76;
      8'd21: extra1 = 8'h66;  8'd22: extra1 = 8'h4a;  8'd23: extra1 = 8'h7c;
      8'd24: extra1 = 8'h5c;  8'd25: extra1 = 8'h82;  8'd26: extra1 = 8'h0a;
      8'd27: extra1 = 8'h86;  8'd28: extra1 = 8'h82;  8'd29: extra1 = 8'h02;
      8'd30: extra1 = 8'he6;
      default: extra1 = 8'h00;
    endcase
  endfunction

  function automatic [7:0] extra2(input [7:0] i);
    case (i)
      8'd0:  extra2 = 8'h2f;  8'd1:  extra2 = 8'h04;  8'd2:  extra2 = 8'hd1;
      8'd3:  extra2 = 8'h69;  8'd4:  extra2 = 8'had;  8'd5:  extra2 = 8'heb;
      8'd6:  extra2 = 8'h10;  8'd7:  extra2 = 8'h95;  8'd8:  extra2 = 8'hb0;
      8'd9:  extra2 = 8'h2f;  8'd10: extra2 = 8'h0a;  8'd11: extra2 = 8'h83;
      8'd12: extra2 = 8'h7d;  8'd13: extra2 = 8'h4e;  8'd14: extra2 = 8'h2a;
      8'd15: extra2 = 8'h07;  8'd16: extra2 = 8'h89;  8'd17: extra2 = 8'h52;
      8'd18: extra2 = 8'hca;  8'd19: extra2 = 8'h41;  8'd20: extra2 = 8'hf1;
      8'd21: extra2 = 8'h4f;  8'd22: extra2 = 8'haf;  8'd23: extra2 = 8'h1c;
      8'd24: extra2 = 8'h01;  8'd25: extra2 = 8'he9;  8'd26: extra2 = 8'h89;
      8'd27: extra2 = 8'hd2;  8'd28: extra2 = 8'haf;  8'd29: extra2 = 8'hcd;
      default: extra2 = 8'h00;
    endcase
  endfunction

  // Left rotate by (bits & 7). Zero is the identity, which is what makes
  // `8 - shift` safe when shift is 0.
  function automatic [7:0] rot(input [7:0] d, input [2:0] bits);
    begin
      rot = (bits == 3'd0) ? d : ((d << bits) | (d >> (4'd8 - {1'b0, bits})));
    end
  endfunction

  // 8 - shift, kept to three bits: with shift == 0 this is 8, which truncates
  // to 0, and 0 is the identity rotate. That is exactly what the C does when it
  // passes `8 - m_shift` into a function that masks with & 7.
  // 8 - shift in three bits is the negation, and with shift == 0 it is 0 --
  // the identity rotate, which is what & 7 gives the C for the same input.
  wire [2:0] shift_c = 3'(0) - shift;
  wire [2:0] shift_t = shift;
  wire       ii_odd  = inline_idx[0];
  wire [7:0] ex1     = extra1(inline_idx >> 1);
  wire [7:0] ex2     = extra2(inline_idx >> 1);

  // ---------------------------------------------------------------- inline
  logic [7:0] ipath;
  always_comb begin
    if (subtracttype == 2'd3 && alternateswaps == 2'd0) begin
      // Shogun Warriors table 0x40 takes its own path in MAME: no rotate at
      // all, and EXTRA only on even positions within the inline table.
      ipath = dat_in - inline_byte;
      if (!ii_odd) ipath = ipath - ex1;
    end else if (!inline_half) begin
      if (ii_odd) begin
        ipath = rot(dat_in - inline_byte, shift_t);
      end else begin
        ipath = (subtracttype != 2'd2) ? (dat_in - inline_byte - ex1)
                                       : (dat_in + inline_byte + ex1);
        ipath = rot(ipath, shift_c);
      end
    end else begin
      if (!ii_odd) begin
        ipath = rot(dat_in - inline_byte, shift_t);
      end else begin
        // The second half drops the inline byte entirely and uses EXTRA2.
        ipath = (subtracttype != 2'd2) ? (dat_in - ex2) : (dat_in + ex2);
        ipath = rot(ipath, shift_c);
      end
    end
  end

  // ----------------------------------------------------------------- keyed
  logic [7:0] kpath;
  always_comb begin
    case (subtracttype)
      2'd0: kpath = dat_in;
      2'd1: kpath = idx_odd ? (dat_in + key_byte) : (dat_in - key_byte);
      2'd2: kpath = idx_odd ? (dat_in - key_byte) : (dat_in + key_byte);
      2'd3: kpath = dat_in - key_byte;
    endcase

    case (alternateswaps)
      // 3 is the same as 0. MAME writes both out; keeping them together here
      // rather than collapsing them keeps the correspondence readable.
      2'd0, 2'd3: kpath = idx_odd ? rot(kpath, shift_t) : rot(kpath, shift_c);
      2'd1:       kpath = rot(kpath, shift_c);
      2'd2:       kpath = rot(kpath, shift_t);
    endcase
  end

  assign dat_out = (inline_size != 8'd0) ? ipath : kpath;

endmodule
