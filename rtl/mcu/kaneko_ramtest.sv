// SPDX-License-Identifier: GPL-3.0-or-later
//
// Boot-time self-test of the MCU's shared RAM, over the path the 68000 uses.
//
// WHY THIS EXISTS
//
// Shogun Warriors verifies that RAM before it will do anything else: a loop at
// 0x02222e writes a byte, reads it back, compares, and branches away on a
// mismatch, kicking the watchdog each pass. MAME counts 262,378 BYTE writes
// into it in the first six seconds, and the game masks every interrupt for the
// whole 356 frames it takes -- so a board sitting in that loop shows a running
// 68000, no interrupts, and a black screen, which is exactly what this core
// does.
//
// That RAM is in SDRAM here, reached through the arbiter, the 2:1 crossing and
// the controller. The SDRAM WRITE path has never run on hardware in this
// core's life. Everything about it passes in simulation, and simulation has
// been wrong about this device twice already -- the arbiter dropped one-cycle
// requests and no testbench could see it, and the byte writes the game leans on
// hardest were the one case the crossing's test never wrote.
//
// So this asks the board directly. It runs once, out of reset, before the CPU
// can reach that memory, and reports one bit: did every pattern read back.
//
// WHAT IT WRITES, AND WHY THOSE
//
//   walking ones and zeros   catches a stuck or shorted data line
//   address-in-data          catches an address line that does not decode
//   both byte halves alone   catches a byte enable that writes the wrong half,
//                            which is the case the game does 262,378 times
//
// It is not a memory test in the manufacturing sense and does not try to be:
// it is a test of the PATH, and every pattern is chosen so that a plausible
// wrong answer -- zero, the other half, the previous word -- is distinguishable
// from the right one.

module kaneko_ramtest #(
    parameter int unsigned SDR_AW = 25,
    // Words to cover. The fault this is looking for is in the path, not in the
    // silicon, so a short sweep at both ends of a page is enough and keeps the
    // test inside a frame.
    parameter int unsigned WORDS  = 64
) (
    input  wire clk,
    input  wire rst,

    // Held low until the ROM download finishes; the SDRAM ports are gated on
    // it, so starting earlier means every request stalls.
    input  wire            enable,
    input  wire [SDR_AW:1] base_mcuram,

    // One master on the arbiter, same shape as everything else there.
    output logic            req,
    output logic [SDR_AW:1] addr,
    output logic            we,
    output logic [15:0]     din,
    output logic [1:0]      be,
    input  wire             ack,
    input  wire [63:0]      dout,

    output logic       running,
    output logic       done,
    output logic       pass,
    // Which stage failed, so a failure says something more than "failed".
    output logic [3:0] fail_stage,
    output logic [15:0] fail_got,
    output logic [15:0] fail_want
);

  typedef enum logic [2:0] {
    S_IDLE, S_WR, S_WR_W, S_RD, S_RD_W, S_NEXT, S_DONE
  } state_t;

  state_t state;
  logic [15:0] idx;
  logic [2:0]  stage;        // 0 walking, 1 address, 2 low byte, 3 high byte
  logic [1:0]  lane;

  // The pattern for a word, by stage. Every one differs from zero and from its
  // neighbours, so a read that returns the wrong word is not mistaken for a
  // pass.
  // Eight bits of index is all the patterns use; WORDS is far below 256.
  function automatic [15:0] pattern(input [2:0] st, input [7:0] i);
    // EVERY STAGE DIFFERS FROM THE ONE BEFORE IT, IN BOTH HALVES.
    //
    // Stages 3, 4 and 5 all fell through to one default, so a byte stage wrote
    // exactly the word the stage before it had written -- and then a memory
    // that ignored byte enables altogether, writing whole words every time,
    // read back correct and the self-test passed it. A self-test that passes a
    // broken memory is worse than none: it gets deployed, comes back green, and
    // is taken as proof the path is sound.
    //
    // 5a and a5 are there so the byte stages differ from stage 3 in the half
    // they do NOT write, which is what makes an ignored or swapped enable show.
    case (st)
      3'd0:    pattern = 16'h0001 << i[3:0];          // walking one
      3'd1:    pattern = ~(16'h0001 << i[3:0]);       // walking zero
      3'd2:    pattern = {i, ~i};                     // address in data
      3'd3:    pattern = {~i, i};
      3'd4:    pattern = {8'h5a, i};                  // low half written
      default: pattern = {i, 8'ha5};                  // high half written
    endcase
  endfunction

  // Byte stages write one half and must leave the other alone.
  wire [1:0]  stage_be   = (stage == 3'd4) ? 2'b01 : (stage == 3'd5) ? 2'b10 : 2'b11;
  wire [15:0] stage_data = pattern(stage, idx[7:0]);
  // What a correct read gives back: for a byte stage, the half just written
  // over the half the previous stage left there.
  // The previous stages' patterns as WIRES, then indexed.
  //
  // Quartus 17.0 will not index the result of a function call --
  // pattern(...)[15:8] is a syntax error there, though Verilator takes it. A
  // construct 17.0 rejects is a construct to rewrite; reaching for the newer
  // toolchain instead is what hard rule 7 exists to stop.
  // Only the half each byte stage does NOT write is needed from the stage
  // before it, so these are the halves rather than the whole words.
  wire [15:0] prev3_full = pattern(3'd3, idx[7:0]);
  wire [15:0] prev4_full = pattern(3'd4, idx[7:0]);
  wire [7:0]  prev3_hi   = prev3_full[15:8];
  wire [7:0]  prev4_lo   = prev4_full[7:0];
  /* verilator lint_off UNUSEDSIGNAL */
  wire [7:0]  prev3_lo_unused = prev3_full[7:0];
  wire [7:0]  prev4_hi_unused = prev4_full[15:8];
  /* verilator lint_on UNUSEDSIGNAL */

  wire [15:0] expect_w =
      (stage == 3'd4) ? {prev3_hi, stage_data[7:0]}
    : (stage == 3'd5) ? {stage_data[15:8], prev4_lo}
                      : stage_data;

  always_ff @(posedge clk) begin
    if (rst) begin
      state      <= S_IDLE;
      req        <= 1'b0;
      running    <= 1'b0;
      done       <= 1'b0;
      pass       <= 1'b0;
      fail_stage <= 4'd0;
      idx        <= 16'd0;
      stage      <= 3'd0;
    end else begin
      case (state)
        S_IDLE: if (enable && !done) begin
          running <= 1'b1;
          idx     <= 16'd0;
          stage   <= 3'd0;
          state   <= S_WR;
        end

        S_WR: begin
          req  <= 1'b1;
          addr <= base_mcuram + SDR_AW'(idx);
          we   <= 1'b1;
          din  <= stage_data;
          be   <= stage_be;
          lane <= idx[1:0];
          state <= S_WR_W;
        end

        S_WR_W: if (ack) begin
          req   <= 1'b0;
          state <= S_RD;
        end

        S_RD: begin
          req  <= 1'b1;
          // Aligned down: lane selects within the burst, and the burst starts
          // where it is told. The write above stays exact -- only the read
          // needs the boundary.
          addr <= base_mcuram + SDR_AW'({idx[15:2], 2'b00});
          we   <= 1'b0;
          be   <= 2'b11;
          state <= S_RD_W;
        end

        S_RD_W: if (ack) begin
          req <= 1'b0;
          if (dout[{lane, 4'd0} +: 16] != expect_w) begin
            fail_stage <= {1'b0, stage};
            fail_got   <= dout[{lane, 4'd0} +: 16];
            fail_want  <= expect_w;
            running    <= 1'b0;
            done       <= 1'b1;
            pass       <= 1'b0;
            state      <= S_DONE;
          end else begin
            state <= S_NEXT;
          end
        end

        S_NEXT: begin
          if (idx == 16'(WORDS - 1)) begin
            idx <= 16'd0;
            // Stages 0 to 3 are word patterns; 4 and 5 write one byte half
            // each, in that order, because stage 5 checks that stage 4's half
            // SURVIVED -- which is the failure a wrong byte enable produces.
            if (stage == 3'd5) begin
              running <= 1'b0;
              done    <= 1'b1;
              pass    <= 1'b1;
              state   <= S_DONE;
            end else begin
              stage <= stage + 3'd1;
              state <= S_WR;
            end
          end else begin
            idx   <= idx + 16'd1;
            state <= S_WR;
          end
        end

        S_DONE: state <= S_DONE;      // once, and it holds its answer

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
