// SPDX-License-Identifier: GPL-3.0-or-later
//
// Two masters, one SDRAM port, for the CALC3 board's shared MCU RAM.
//
// The 64 KB at 200000 is shared between the 68000 and the CALC3 -- that is what
// makes it the communication channel, and both reach it through SDRAM here.
//
// ONE PORT, ARBITRATED, rather than a port each. Two ports would work and the
// controller would serialise them, but it would put a SECOND writer on the
// SDRAM, and this core has exactly one -- the harness that checks the write
// path models one, and the write path is the part that has never run on
// hardware. Sharing one port also makes coherency structural: the two masters
// cannot have overlapping accesses in flight, so a read cannot pass a write to
// the same address. With two ports that ordering would be a hope.
//
// ALTERNATING PRIORITY, not fixed. The CALC3 issues a long run of accesses when
// it decompresses a table -- thousands, back to back -- and a fixed priority
// either way starves the other master for the whole run. The 68000 stalls on
// DTACK while it waits, so starving it stalls the game.

module kaneko_mcuram_arb #(
    parameter int unsigned SDR_AW = 25
) (
    input  wire        clk,
    input  wire        rst_n,

    // Master A: the 68000, through kaneko_bus.
    input  wire            a_req,
    input  wire [SDR_AW:1] a_addr,
    input  wire            a_we,
    input  wire [15:0]     a_din,
    input  wire [1:0]      a_be,
    output logic           a_ack,
    output logic [63:0]    a_dout,

    // Master B: the CALC3.
    input  wire            b_req,
    input  wire [SDR_AW:1] b_addr,
    input  wire            b_we,
    input  wire [15:0]     b_din,
    input  wire [1:0]      b_be,
    output logic           b_ack,
    output logic [63:0]    b_dout,

    // The SDRAM port.
    output logic           s_req,
    output logic [SDR_AW:1] s_addr,
    output logic           s_we,
    output logic [15:0]    s_din,
    output logic [1:0]     s_be,
    input  wire            s_ack,
    input  wire [63:0]     s_dout
);

  typedef enum logic [1:0] { S_IDLE, S_A, S_B } state_t;
  state_t state;
  logic   last_was_a;          // for the alternation

  // Whose turn it is when both ask at once.
  wire a_first = !last_was_a;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      s_req      <= 1'b0;
      a_ack      <= 1'b0;
      b_ack      <= 1'b0;
      last_was_a <= 1'b0;
    end else begin
      // Acknowledges are single-cycle pulses, as every master here expects.
      a_ack <= 1'b0;
      b_ack <= 1'b0;

      case (state)
        S_IDLE: begin
          if (a_req && (a_first || !b_req)) begin
            s_req  <= 1'b1;
            s_addr <= a_addr;
            s_we   <= a_we;
            s_din  <= a_din;
            s_be   <= a_be;
            state  <= S_A;
          end else if (b_req) begin
            s_req  <= 1'b1;
            s_addr <= b_addr;
            s_we   <= b_we;
            s_din  <= b_din;
            s_be   <= b_be;
            state  <= S_B;
          end
        end

        S_A: if (s_ack) begin
          s_req      <= 1'b0;
          a_dout     <= s_dout;
          a_ack      <= 1'b1;
          last_was_a <= 1'b1;
          state      <= S_IDLE;
        end

        S_B: if (s_ack) begin
          s_req      <= 1'b0;
          b_dout     <= s_dout;
          b_ack      <= 1'b1;
          last_was_a <= 1'b0;
          state      <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
