// SPDX-License-Identifier: GPL-3.0-or-later
//
// CALC3 MCU: the command sequencer.
//
// The CALC3 is a custom MCU sharing 64 KB of RAM with the 68000. Its internal
// ROM has never been dumped, so this reproduces the BEHAVIOUR MAME's
// high-level simulation has established, which is what the games depend on.
//
// The 68000 writes a command word into that shared RAM and pokes four separate
// registers; the MCU acts once all four have been written, and it clears the
// command word to say it is done. Commands are:
//
//   0xff   init. Seven parameters follow it in RAM -- DSW address, EEPROM
//          address, where future commands live, a poll address, where to put
//          the data ROM's checksum, and a 32-bit base for decompressed data.
//          The MCU writes the checksum and copies 64 words of EEPROM in.
//   n      transfer n tables. Each has two parameter words: a table number
//          with a displacement, and an address to write the result's header
//          and pointer back to.
//
// Decompressed tables are 68000 SUBROUTINES which the game then calls. That is
// the whole point of the device, and it is why every part of this is checked
// byte for byte rather than by eye: a wrong byte is a wrong instruction.
//
// The golden model is tools/calc3_ref.py, which reproduces MAME exactly on
// every table shogwarr and brapboys pull; `make calc3` is the check.

module kaneko_calc3 #(
    parameter int unsigned AW = 17,        // 128 KB data ROM, byte addressed
    parameter int unsigned ROM_BYTES = 32'h20000
) (
    input  wire        clk,
    input  wire        rst_n,

    // The four command registers. Any write sets a bit; the MCU runs only
    // once all four are set, exactly as MAME's mcu_status does.
    input  wire [3:0]  com_w,
    // One pulse a frame. The device runs off a 59.1854 Hz timer in MAME, which
    // is a frame; nothing here depends on the exact rate.
    input  wire        tick,

    // Data ROM, byte serial, variable latency. Shared between the checksum
    // scan at reset and the table core afterwards.
    output logic [AW-1:0] rom_addr,
    output logic          rom_rd,
    input  wire  [7:0]    rom_data,
    input  wire           rom_valid,

    // Shared MCU RAM, 16-bit with byte enables, variable latency.
    output logic [15:0] ram_addr,          // BYTE address within the 64 KB
    output logic        ram_rd,
    output logic        ram_wr,
    output logic [1:0]  ram_be,
    output logic [15:0] ram_wdata,
    input  wire  [15:0] ram_rdata,
    input  wire         ram_valid,

    // EEPROM contents for the init command's copy.
    output logic [5:0]  eep_addr,
    input  wire  [15:0] eep_data,

    // The DIP switches. MAME writes these into MCU RAM at the top of every
    // run, with the comment that the game reads them back live every frame.
    input  wire  [7:0]  dsw,

    output logic        busy,
    output logic        crc_ready,
    output logic        key_missing        // sticky: a block named a missing key
);

  // ------------------------------------------------------------ status bits
  logic [3:0] status;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) status <= 4'd0;
    else        status <= status | com_w;
  end

  // ------------------------------------------------------------- table core
  logic          t_start;
  logic [7:0]    t_tabnum;
  logic [AW-1:0] t_rom_addr;
  logic          t_rom_rd;
  logic          t_busy, t_done, t_bad, t_keymiss;
  logic [7:0]    t_mode, t_byte;
  logic [15:0]   t_len;
  logic          t_out_valid, t_hdr_valid;
  // Ready only while the sequencer is actually watching for a byte.
  wire           t_ready = (state == S_XFER_RUN);
  // `done` is a pulse and the sequencer can be mid-write when it fires,
  // so it is latched rather than sampled.
  logic          t_done_seen;

  logic [7:0] k_sel, k_data;
  logic [5:0] k_idx;
  logic       k_absent;

  kaneko_calc3_keys u_keys (
      .clk(clk), .key_sel(k_sel), .key_idx(k_idx),
      .key_data(k_data), .absent(k_absent)
  );

  kaneko_calc3_table #(.AW(AW)) u_table (
      .clk(clk), .rst_n(rst_n),
      .start(t_start), .tabnum(t_tabnum),
      .rom_addr(t_rom_addr), .rom_rd(t_rom_rd),
      .rom_data(rom_data), .rom_valid(rom_valid),
      .key_sel(k_sel), .key_idx(k_idx),
      .key_data(k_data), .key_absent(k_absent),
      .busy(t_busy), .done(t_done), .bad_table(t_bad),
      .key_missing(t_keymiss), .mode(t_mode), .length(t_len),
      .out_ready(t_ready),
      .out_byte(t_byte), .out_valid(t_out_valid), .hdr_valid(t_hdr_valid)
  );

  // --------------------------------------------------------------- the loop
  typedef enum logic [4:0] {
    S_CRC, S_CRC_WAIT,
    S_IDLE, S_DSW,
    S_CMD_RD, S_CMD_ACK,
    S_INIT_RD, S_INIT_STORE, S_INIT_CRC, S_INIT_CSUM_W,
    S_INIT_EEP, S_INIT_EEP_W,
    S_XFER_P1, S_XFER_P2, S_XFER_RUN, S_XFER_WB0, S_XFER_WB1, S_XFER_WB2,
    S_XFER_WB3, S_XFER_NEXT,
    S_WRITE_BYTE,
    S_DONE
  } state_t;

  state_t state, ret_state;

  // The checksum scan's own request registers; see the mux at the end.
  logic [AW-1:0] s_rom_addr;
  logic          s_rom_rd;

  logic [15:0] cmd_off;        // where the command word lives
  logic [15:0] cmd;            // the command being run
  logic [31:0] write_cur;      // rolling destination, a FULL 68000 address
  logic [15:0] dsw_addr, eep_base, csum_addr;
  logic        dsw_valid;          // init has named a DSW address
  wire  [7:0]  dsw_n = ~dsw;
  // Captured because init supplies it, and UNUSED because MAME does not
  // act on it either -- its note calls it "probably polled by MCU, needs
  // to be kept alive (cleared by main cpu)". Kept so the parameter block
  // is read in full rather than skipped over.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0] poll_addr;
  // The table core reports a bad table number; nothing acts on it yet.
  logic        t_bad_seen;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [15:0] crc;
  logic [AW-1:0] crc_ptr;
  logic [7:0]  xfer_left;
  logic [15:0] p1, p2;
  logic [7:0]  hdr0, hdr1;
  logic [1:0]  hdr_cnt;
  logic [15:0] init_left;
  logic [2:0]  init_idx;
  logic [15:0] wr_ptr;         // byte address for the next decoded byte
  logic [15:0] tbl_bytes;      // decoded bytes written for this table

  // A byte write into a 16-bit memory picks its lane from address bit 0. The
  // 68000 is big-endian, so byte 0 of a word is the HIGH half.
  wire [1:0]  byte_be = wr_ptr[0] ? 2'b01 : 2'b10;
  wire [15:0] byte_wd = {t_byte, t_byte};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= S_CRC;
      s_rom_rd    <= 1'b0;
      ram_rd      <= 1'b0;
      ram_wr      <= 1'b0;
      t_start     <= 1'b0;
      busy        <= 1'b0;
      crc         <= 16'd0;
      crc_ptr     <= '0;
      crc_ready   <= 1'b0;
      cmd_off     <= 16'd0;
      dsw_valid   <= 1'b0;
      t_bad_seen  <= 1'b0;
      key_missing <= 1'b0;
      write_cur   <= 32'd0;
    end else begin
      s_rom_rd <= 1'b0;
      ram_rd  <= 1'b0;
      ram_wr  <= 1'b0;
      t_start <= 1'b0;

      // The decoded stream is captured wherever it arrives: the table core
      // runs on its own and does not wait for these writes.
      if (t_done) t_done_seen <= 1'b1;

      if (t_hdr_valid) begin
        if (hdr_cnt == 2'd0) hdr0 <= t_byte;
        else                 hdr1 <= t_byte;
        hdr_cnt <= hdr_cnt + 2'd1;
      end

      case (state)
        // -------------------------------------------------- ROM checksum
        // A 16-bit sum of the whole 128 KB data ROM, which the init command
        // hands back to the game. Done once, at reset.
        S_CRC: begin
          s_rom_addr <= crc_ptr;
          s_rom_rd   <= 1'b1;
          state      <= S_CRC_WAIT;
        end

        S_CRC_WAIT: if (rom_valid) begin
          crc <= crc + {8'd0, rom_data};
          if (crc_ptr == AW'(ROM_BYTES - 1)) begin
            crc_ready <= 1'b1;
            state     <= S_IDLE;
          end else begin
            crc_ptr <= crc_ptr + AW'(1);
            state   <= S_CRC;
          end
        end

        // ------------------------------------------------------ the poll
        S_IDLE: if (tick && status == 4'hf) begin
          busy <= 1'b1;
          // The DSW goes in first, INVERTED, and only once init has named an
          // address for it. MAME does this at the top of mcu_run every frame
          // because the game reads it back live.
          if (dsw_valid) begin
            ram_addr  <= {dsw_addr[15:1], 1'b0};
            ram_wdata <= {dsw_n, dsw_n};
            ram_be    <= dsw_addr[0] ? 2'b01 : 2'b10;
            ram_wr    <= 1'b1;
            state     <= S_DSW;
          end else begin
            ram_addr <= cmd_off;
            ram_rd   <= 1'b1;
            state    <= S_CMD_RD;
          end
        end else begin
          busy <= 1'b0;
        end

        S_DSW: if (ram_valid) begin
          ram_addr <= cmd_off;
          ram_rd   <= 1'b1;
          state    <= S_CMD_RD;
        end

        S_CMD_RD: if (ram_valid) begin
          cmd <= ram_rdata;
          if (ram_rdata == 16'd0) begin
            busy  <= 1'b0;
            state <= S_IDLE;
          end else begin
            // Clear the command word first: it is the handshake the 68000
            // polls, and MAME clears it before doing any of the work.
            ram_addr  <= cmd_off;
            ram_wdata <= 16'd0;
            ram_be    <= 2'b11;
            ram_wr    <= 1'b1;
            state     <= S_CMD_ACK;
          end
        end

        S_CMD_ACK: if (ram_valid) begin
          if (cmd == 16'h00ff) begin
            init_idx <= 3'd0;
            ram_addr <= 16'd2;              // parameters start at word 1
            ram_rd   <= 1'b1;
            state    <= S_INIT_RD;
          end else begin
            xfer_left <= cmd[7:0];
            ram_addr  <= cmd_off + 16'd2;
            ram_rd    <= 1'b1;
            state     <= S_XFER_P1;
          end
        end

        // ---------------------------------------------------------- init
        S_INIT_RD: if (ram_valid) begin
          case (init_idx)
            3'd0: begin dsw_addr <= ram_rdata; dsw_valid <= 1'b1; end
            3'd1: eep_base  <= ram_rdata;
            3'd2: cmd_off   <= ram_rdata;
            3'd3: poll_addr <= ram_rdata;
            3'd4: csum_addr <= ram_rdata;
            3'd5: write_cur[31:16] <= ram_rdata;
            3'd6: write_cur[15:0]  <= ram_rdata;
            default: ;
          endcase
          state <= S_INIT_STORE;
        end

        S_INIT_STORE: begin
          if (init_idx == 3'd6) begin
            state <= S_INIT_CRC;
          end else begin
            init_idx <= init_idx + 3'd1;
            ram_addr <= 16'd4 + {12'd0, init_idx, 1'b0};
            ram_rd   <= 1'b1;
            state    <= S_INIT_RD;
          end
        end

        S_INIT_CRC: begin
          ram_addr  <= csum_addr;
          ram_wdata <= crc;
          ram_be    <= 2'b11;
          ram_wr    <= 1'b1;
          init_left <= 16'd0;
          eep_addr  <= 6'd0;
          state     <= S_INIT_CSUM_W;
        end

        // Wait for the checksum write SEPARATELY from issuing the first
        // EEPROM word. These were one state, so the loop came back to a state
        // that waits for an acknowledge with no request outstanding and stopped
        // there for good -- the whole init hung on the second EEPROM word.
        S_INIT_CSUM_W: if (ram_valid) state <= S_INIT_EEP;

        // 64 words of EEPROM into the address init named. ISSUES; the wait is
        // the state after it.
        S_INIT_EEP: begin
          ram_addr  <= eep_base + {init_left[14:0], 1'b0};
          ram_wdata <= eep_data;
          ram_be    <= 2'b11;
          ram_wr    <= 1'b1;
          state     <= S_INIT_EEP_W;
        end

        S_INIT_EEP_W: if (ram_valid) begin
          if (init_left == 16'd63) begin
            state <= S_DONE;
          end else begin
            init_left <= init_left + 16'd1;
            eep_addr  <= eep_addr + 6'd1;
            state     <= S_INIT_EEP;
          end
        end

        // ------------------------------------------------------ transfers
        S_XFER_P1: if (ram_valid) begin
          p1 <= ram_rdata;
          ram_addr <= ram_addr + 16'd2;
          ram_rd   <= 1'b1;
          state    <= S_XFER_P2;
        end

        S_XFER_P2: if (ram_valid) begin
          p2        <= ram_rdata;
          t_tabnum  <= p1[15:8];
          t_start   <= 1'b1;
          hdr_cnt     <= 2'd0;
          tbl_bytes   <= 16'd0;
          t_done_seen <= 1'b0;
          wr_ptr    <= write_cur[15:0];
          state     <= S_XFER_RUN;
        end

        S_XFER_RUN: begin
          // t_ready is high in this state, so a byte offered here is taken on
          // this edge and the core advances on the same one.
          if (t_out_valid) begin
            // One decoded byte, straight into MCU RAM.
            ram_addr  <= {wr_ptr[15:1], 1'b0};
            ram_wdata <= byte_wd;
            ram_be    <= byte_be;
            ram_wr    <= 1'b1;
            ret_state <= S_XFER_RUN;
            state     <= S_WRITE_BYTE;
          end else if (t_done || t_done_seen) begin
            if (t_keymiss) key_missing <= 1'b1;
            if (t_bad)     t_bad_seen  <= 1'b1;
            // A zero-length table is a control operation. Mode 6 resets the
            // write pointer; MAME hardcodes 202000 and says it is a guess that
            // fits brapboys. Both games are observed doing it.
            // A REFUSED table writes nothing and moves nothing.
            //
            // This used to fall through to the writeback: it stored a header
            // left over from the PREVIOUS table and advanced the write pointer
            // by four, so every table after it landed four bytes further along
            // and the pointer handed to the game named the wrong place. MAME
            // calls fatalerror() here; a core cannot stop, so it skips the
            // transfer and leaves key_missing raised.
            if (t_keymiss || t_bad) begin
              state <= S_XFER_NEXT;
            end else if (t_len == 16'd0) begin
              if (t_mode == 8'h06) write_cur <= 32'h00202000;
              state <= S_XFER_NEXT;            // nothing to write back
            end else begin
              ram_addr  <= {p2[15:1], 1'b0};
              ram_wdata <= p2[0] ? {8'd0, hdr0} : {hdr0, 8'd0};
              ram_be    <= p2[0] ? 2'b01 : 2'b10;
              ram_wr    <= 1'b1;
              state     <= S_XFER_WB0;
            end
          end
        end

        S_WRITE_BYTE: if (ram_valid) begin
          wr_ptr    <= wr_ptr + 16'd1;
          tbl_bytes <= tbl_bytes + 16'd1;
          state     <= ret_state;
        end

        // The header's two bytes go to the address the command named.
        S_XFER_WB0: if (ram_valid) begin
          ram_addr  <= {p2[15:1] + {14'd0, p2[0]}, 1'b0};
          ram_wdata <= p2[0] ? {hdr1, 8'd0} : {8'd0, hdr1};
          ram_be    <= p2[0] ? 2'b10 : 2'b01;
          ram_wr    <= 1'b1;
          state     <= S_XFER_WB1;
        end

        // Then the 32-bit address of the data, at p2 displaced by a SIGNED
        // byte out of p1's low half.
        S_XFER_WB1: if (ram_valid) begin
          ram_addr  <= p2 + {{8{p1[7]}}, p1[7:0]};
          ram_wdata <= write_cur[31:16];
          ram_be    <= 2'b11;
          ram_wr    <= 1'b1;
          state     <= S_XFER_WB2;
        end

        // The low half of the pointer, in its OWN state.
        //
        // This and the move to the next transfer were one state, and both
        // assigned ram_addr in the same cycle -- so the second won and the
        // pointer's low half was written over the NEXT command's parameter
        // block instead of its own address. It also raised ram_rd and ram_wr
        // together, which no memory can answer. The corruption looked like the
        // device fetching the wrong table, because by then it was.
        S_XFER_WB2: if (ram_valid) begin
          ram_addr  <= p2 + {{8{p1[7]}}, p1[7:0]} + 16'd2;
          ram_wdata <= write_cur[15:0];
          ram_be    <= 2'b11;
          ram_wr    <= 1'b1;
          state     <= S_XFER_WB3;
        end

        S_XFER_WB3: if (ram_valid) begin
          // length counts the two header bytes: advance by the bytes written
          // plus 2, plus 3, rounded down to even -- the C's (length + 3) & ~1.
          write_cur <= write_cur + 32'({1'b0, ((tbl_bytes + 16'd5) & 16'hfffe)});
          state     <= S_XFER_NEXT;
        end

        // One place decides whether another transfer follows, so the address
        // for the next parameter read has a single driver.
        S_XFER_NEXT: begin
          if (xfer_left == 8'd1) begin
            state <= S_DONE;
          end else begin
            xfer_left <= xfer_left - 8'd1;
            ram_addr  <= cmd_off + 16'd2 +
                         {6'd0, (cmd[7:0] - xfer_left + 8'd1), 2'd0};
            ram_rd    <= 1'b1;
            state     <= S_XFER_P1;
          end
        end

        S_DONE: begin
          busy  <= 1'b0;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // ONE driver for the shared ROM port. The table core owns it whenever it is
  // running and the checksum scan owns it before that. This was left as a
  // stub that assigned the port to itself, which meant the table core's reads
  // reached nothing at all and it would have waited for data that never came.
  always_comb begin
    rom_addr = t_busy ? t_rom_addr : s_rom_addr;
    rom_rd   = t_busy ? t_rom_rd   : s_rom_rd;
  end

endmodule
