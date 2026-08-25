// SPDX-License-Identifier: GPL-3.0-or-later
//
// CALC3 block walk: find a table's parameters in the data ROM.
//
// The data ROM is a linked list. Byte 0 is the number of tables; everything
// after it is a chain of blocks, and reaching block N means stepping over the
// N-1 before it, because a block's length is only known once its header has
// been read. There is no index.
//
// Each block is:
//
//   +0            blocksize_offset  -- also where the length sits, and how big
//                                      an inline key table the block carries
//   +1            mode
//   +2            packed: shift in the top nibble, subtract type in bits 1:0,
//                 alternate swaps in bits 3:2
//   +3            key byte, used only when there is no inline table
//   +4 ...        inline key table, present when blocksize_offset > 3,
//                 of blocksize_offset - 3 bytes and ANY length, odd or even
//   +bso+1        length, 16-bit little-endian
//   +bso+3        the encrypted data
//
// EVERY OFFSET HERE IS AGAINST ROM+1, not ROM. The C increments its pointer
// past the table count before walking, so a block at "offset 0" is at byte 1
// of the region. Reading this one byte low gives a header that still looks
// plausible -- a length, a mode, a key -- and decodes to rubbish.
//
// A length of 0 means the block is a control operation rather than a table:
// mode 6 resets the write pointer, mode 8 saves the EEPROM. The walk reports
// it and lets the sequencer decide, because the meaning is the sequencer's.

module kaneko_calc3_walk #(
    // The data ROM is 128 KB on both CALC3 games, so 17 bits of byte address.
    parameter int unsigned AW = 17
) (
    input  wire            clk,
    input  wire            rst_n,

    input  wire            start,
    input  wire [7:0]      tabnum,

    // Byte-serial ROM read. `rd` is a single-cycle request; `valid` returns
    // the byte some cycles later. The latency is not fixed -- this sits on
    // SDRAM behind an arbiter -- so nothing here counts cycles.
    output logic [AW-1:0]  rom_addr,
    output logic           rom_rd,
    input  wire [7:0]      rom_data,
    input  wire            rom_valid,

    output logic           busy,
    output logic           done,          // one cycle
    output logic           bad_table,     // tabnum > the count in byte 0

    output logic [7:0]     blocksize_offset,
    output logic [7:0]     mode,
    output logic [2:0]     shift,
    output logic [1:0]     subtracttype,
    output logic [1:0]     alternateswaps,
    output logic [7:0]     key_byte,
    output logic [AW-1:0]  inline_base,
    output logic [7:0]     inline_size,
    output logic [AW-1:0]  data_base,
    output logic [15:0]    length
);

  typedef enum logic [3:0] {
    S_IDLE,
    S_COUNT,        // read byte 0, the number of tables
    S_SKIP_BSO,     // skipping a block: its blocksize_offset
    S_SKIP_L0, S_SKIP_L1,
    S_HDR_BSO, S_HDR_MODE, S_HDR_ALT, S_HDR_KEY,
    S_LEN0, S_LEN1,
    S_DONE
  } state_t;

  state_t      state;
  logic [AW-1:0] offset;      // against ROM+1, as above
  logic [7:0]  remaining;     // blocks still to step over
  // Only the LOW byte needs latching: the high byte arrives last and is
  // consumed in the same cycle it lands.
  logic [7:0]  skip_len_lo;

  // One outstanding read at a time. `rom_rd` is a pulse and the state does not
  // advance until `rom_valid`, so there is never a second request in flight.
  task automatic issue(input [AW-1:0] a);
    begin
      rom_addr <= a;
      rom_rd   <= 1'b1;
    end
  endtask

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= S_IDLE;
      rom_rd    <= 1'b0;
      busy      <= 1'b0;
      done      <= 1'b0;
      bad_table <= 1'b0;
      offset    <= '0;
    end else begin
      done   <= 1'b0;
      rom_rd <= 1'b0;

      case (state)
        S_IDLE: if (start) begin
          busy      <= 1'b1;
          bad_table <= 1'b0;
          offset    <= '0;
          remaining <= tabnum;
          issue('0);                       // byte 0 of the region: the count
          state     <= S_COUNT;
        end

        S_COUNT: if (rom_valid) begin
          // "tabnum > numregions" -- greater than, not >=, exactly as the C.
          if (tabnum > rom_data) begin
            bad_table <= 1'b1;
            busy      <= 1'b0;
            done      <= 1'b1;
            state     <= S_IDLE;
          end else if (remaining == 8'd0) begin
            issue(AW'(1));                 // block 0 starts at ROM+1
            state <= S_HDR_BSO;
          end else begin
            issue(AW'(1));
            state <= S_SKIP_BSO;
          end
        end

        // ------------------------------------------------ step over a block
        S_SKIP_BSO: if (rom_valid) begin
          offset <= offset + AW'(rom_data) + AW'(1);
          issue(AW'(1) + offset + AW'(rom_data) + AW'(1));
          state  <= S_SKIP_L0;
        end

        S_SKIP_L0: if (rom_valid) begin
          skip_len_lo <= rom_data;
          issue(AW'(1) + offset + AW'(1));
          state <= S_SKIP_L1;
        end

        S_SKIP_L1: if (rom_valid) begin
          offset <= offset + AW'({rom_data, skip_len_lo}) + AW'(2);
          remaining <= remaining - 8'd1;
          if (remaining == 8'd1) begin
            issue(AW'(1) + offset + AW'({rom_data, skip_len_lo}) + AW'(2));
            state <= S_HDR_BSO;
          end else begin
            issue(AW'(1) + offset + AW'({rom_data, skip_len_lo}) + AW'(2));
            state <= S_SKIP_BSO;
          end
        end

        // ------------------------------------------------- the target block
        S_HDR_BSO: if (rom_valid) begin
          blocksize_offset <= rom_data;
          // An inline table exists only when the header is longer than the
          // four fixed bytes, and it is whatever is left over.
          inline_size <= (rom_data > 8'd3) ? (rom_data - 8'd3) : 8'd0;
          inline_base <= AW'(1) + offset + AW'(4);
          issue(AW'(1) + offset + AW'(1));
          state <= S_HDR_MODE;
        end

        S_HDR_MODE: if (rom_valid) begin
          mode <= rom_data;
          issue(AW'(1) + offset + AW'(2));
          state <= S_HDR_ALT;
        end

        S_HDR_ALT: if (rom_valid) begin
          // One byte carries three fields. shift keeps three bits: every use
          // masks with & 7, so the fourth cannot change a result.
          shift          <= rom_data[6:4];
          subtracttype   <= rom_data[1:0];
          alternateswaps <= rom_data[3:2];
          issue(AW'(1) + offset + AW'(3));
          state <= S_HDR_KEY;
        end

        S_HDR_KEY: if (rom_valid) begin
          key_byte <= rom_data;
          issue(AW'(1) + offset + AW'(blocksize_offset) + AW'(1));
          state <= S_LEN0;
        end

        S_LEN0: if (rom_valid) begin
          length[7:0] <= rom_data;
          issue(AW'(1) + offset + AW'(blocksize_offset) + AW'(2));
          state <= S_LEN1;
        end

        S_LEN1: if (rom_valid) begin
          length[15:8] <= rom_data;
          data_base <= AW'(1) + offset + AW'(blocksize_offset) + AW'(3);
          busy <= 1'b0;
          done <= 1'b1;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
