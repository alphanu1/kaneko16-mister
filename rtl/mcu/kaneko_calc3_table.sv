// SPDX-License-Identifier: GPL-3.0-or-later
//
// CALC3 table decompressor: walk a block, then stream its decoded bytes.
//
// Drives kaneko_calc3_walk to find the block, then reads its data a byte at a
// time, fetches the matching key byte -- from the block's inline table or from
// the key ROM -- and pushes both through kaneko_calc3_dec.
//
// THE FIRST TWO DECODED BYTES ARE NOT TABLE DATA. They are the data header,
// which the sequencer writes back to the address the command names, and they
// are not written into the table's destination. Missing that shifts every byte
// of every table by two, and since tables are 68000 subroutines the result is
// not corrupt data but corrupt instructions. `hdr_valid` marks them; `out_valid`
// marks the rest.
//
// The inline index is a COUNTER, not a modulo. The inline table can be any
// length, odd or even, so `i % size` would be a divide per byte; instead the
// index counts up and wraps at the size, and `inline_half` toggles on each
// wrap because the C's `(i / size) & 1` is exactly "how many times has it
// wrapped, odd or even".

module kaneko_calc3_table #(
    parameter int unsigned AW = 17
) (
    input  wire            clk,
    input  wire            rst_n,

    input  wire            start,
    input  wire [7:0]      tabnum,

    // Byte-serial ROM read, shared with the walk. Variable latency.
    output logic [AW-1:0]  rom_addr,
    output logic           rom_rd,
    input  wire [7:0]      rom_data,
    input  wire            rom_valid,

    // Key ROM, one cycle.
    output logic [7:0]     key_sel,
    output logic [5:0]     key_idx,
    input  wire [7:0]      key_data,
    input  wire            key_absent,

    output logic           busy,
    output logic           done,
    output logic           bad_table,     // no such table
    output logic           key_missing,   // block names a key that does not exist
    output logic [7:0]     mode,          // for the zero-length control cases
    output logic [15:0]    length,        // the block's length, header included

    output logic [7:0]     out_byte,
    output logic           out_valid,     // a table byte
    output logic           hdr_valid      // one of the two header bytes
);

  // ------------------------------------------------------------------ walk
  logic          w_start;
  logic [AW-1:0] w_rom_addr;
  logic          w_rom_rd;
  logic          w_done, w_busy, w_bad;
  logic [7:0]    w_mode, w_key, w_isize;
  // The walk reports blocksize_offset because it describes the block
  // layout and its own testbench checks it; nothing downstream needs it,
  // since inline_size and data_base are already derived from it there.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0]    w_bso;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [2:0]    w_shift;
  logic [1:0]    w_sub, w_alt;
  logic [AW-1:0] w_ibase, w_dbase;
  logic [15:0]   w_len;

  kaneko_calc3_walk #(.AW(AW)) u_walk (
      .clk(clk), .rst_n(rst_n),
      .start(w_start), .tabnum(tabnum),
      .rom_addr(w_rom_addr), .rom_rd(w_rom_rd),
      .rom_data(rom_data), .rom_valid(rom_valid),
      .busy(w_busy), .done(w_done), .bad_table(w_bad),
      .blocksize_offset(w_bso), .mode(w_mode), .shift(w_shift),
      .subtracttype(w_sub), .alternateswaps(w_alt), .key_byte(w_key),
      .inline_base(w_ibase), .inline_size(w_isize),
      .data_base(w_dbase), .length(w_len)
  );

  // --------------------------------------------------------------- decoder
  logic [7:0] d_dat, d_inline, d_key, d_iidx;
  logic       d_half, d_odd;

  kaneko_calc3_dec u_dec (
      .dat_in(d_dat), .idx_odd(d_odd),
      .shift(w_shift), .subtracttype(w_sub), .alternateswaps(w_alt),
      .inline_size(w_isize), .inline_byte(d_inline),
      .inline_idx(d_iidx), .inline_half(d_half),
      .key_byte(d_key), .dat_out(out_byte)
  );

  // ------------------------------------------------------------------ loop
  typedef enum logic [2:0] {
    S_IDLE, S_WALK, S_DATA, S_AUX, S_KEYWAIT, S_EMIT, S_DONE
  } state_t;

  state_t      state;
  logic [AW-1:0] l_rom_addr;
  logic          l_rom_rd;
  logic [15:0] i;              // byte index within the table
  logic [7:0]  iidx;           // index into the inline table
  logic        half;           // (i / inline_size) & 1, kept as a toggle

  wire have_inline = (w_isize != 8'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      w_start     <= 1'b0;
      l_rom_rd    <= 1'b0;
      busy        <= 1'b0;
      done        <= 1'b0;
      bad_table   <= 1'b0;
      key_missing <= 1'b0;
      out_valid   <= 1'b0;
      hdr_valid   <= 1'b0;
    end else begin
      w_start   <= 1'b0;
      l_rom_rd  <= 1'b0;
      done      <= 1'b0;
      out_valid <= 1'b0;
      hdr_valid <= 1'b0;

      case (state)
        S_IDLE: if (start) begin
          busy        <= 1'b1;
          bad_table   <= 1'b0;
          key_missing <= 1'b0;
          i           <= 16'd0;
          iidx        <= 8'd0;
          half        <= 1'b0;
          w_start     <= 1'b1;
          state       <= S_WALK;
        end

        S_WALK: if (w_done) begin
          mode   <= w_mode;
          length <= w_len;
          if (w_bad) begin
            bad_table <= 1'b1;
            busy <= 1'b0; done <= 1'b1; state <= S_IDLE;
          end else if (w_len == 16'd0) begin
            // A control operation, not a table. The mode says which, and that
            // is the sequencer's business rather than this module's.
            busy <= 1'b0; done <= 1'b1; state <= S_IDLE;
          end else begin
            l_rom_addr <= w_dbase;
            l_rom_rd   <= 1'b1;
            state    <= S_DATA;
          end
        end

        S_DATA: if (rom_valid) begin
          d_dat <= rom_data;
          d_odd <= i[0];
          if (have_inline) begin
            l_rom_addr <= w_ibase + AW'(iidx);
            l_rom_rd   <= 1'b1;
            d_iidx   <= iidx;
            d_half   <= half;
            state    <= S_AUX;
          end else begin
            key_sel <= w_key;
            key_idx <= i[5:0];
            state   <= S_KEYWAIT;
          end
        end

        S_AUX: if (rom_valid) begin
          d_inline <= rom_data;
          state    <= S_EMIT;
        end

        // The key ROM is registered, so its answer is here the cycle after the
        // address was presented.
        S_KEYWAIT: begin
          d_key <= key_data;
          if (key_absent) begin
            // REFUSE. Another row's key decrypts to plausible bytes, and those
            // bytes are instructions the 68000 executes.
            key_missing <= 1'b1;
            busy <= 1'b0; done <= 1'b1; state <= S_IDLE;
          end else begin
            state <= S_EMIT;
          end
        end

        // dat_out is combinational from the registers set above, so it is
        // valid in this state.
        S_EMIT: begin
          if (i < 16'd2) hdr_valid <= 1'b1;
          else           out_valid <= 1'b1;

          if (i + 16'd1 >= w_len) begin
            busy <= 1'b0; done <= 1'b1; state <= S_IDLE;
          end else begin
            i <= i + 16'd1;
            if (have_inline) begin
              if (iidx + 8'd1 >= w_isize) begin
                iidx <= 8'd0;
                half <= ~half;        // one more pass over the inline table
              end else begin
                iidx <= iidx + 8'd1;
              end
            end
            l_rom_addr <= w_dbase + AW'(i) + AW'(1);
            l_rom_rd   <= 1'b1;
            state    <= S_DATA;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // ONE driver for the shared ROM port. The walk owns it while it runs and the
  // byte loop owns it afterwards; both sides keep their own registers and this
  // only selects between them, because driving one signal from two processes is
  // a multiple-driver error and, where a tool tolerates it, a latch.
  always_comb begin
    rom_addr = w_busy ? w_rom_addr : l_rom_addr;
    rom_rd   = w_busy ? w_rom_rd   : l_rom_rd;
  end

endmodule
