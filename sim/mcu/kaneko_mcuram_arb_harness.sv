// SPDX-License-Identifier: GPL-3.0-or-later
//
// Harness for kaneko_mcuram_arb: one flat port per master.
//
// A packed [NM-1:0][SDR_AW:1] is exposed to C++ as a single scalar or a word
// array, NOT as one entry per master -- so indexing it from the testbench
// addresses the wrong bits and produces a testbench that reports the arbiter
// swapping data between masters. That is a convincing-looking lie, and it is
// already on record against kaneko_sdram_harness for the same reason.
module kaneko_mcuram_arb_harness #(
    parameter int unsigned SDR_AW = 25,
    parameter int unsigned NM     = 4
) (
    input  wire clk,
    input  wire rst_n,

    input  wire            m0_req, m1_req, m2_req, m3_req,
    input  wire [SDR_AW:1] m0_addr, m1_addr, m2_addr, m3_addr,
    input  wire            m0_we,  m1_we,  m3_we,
    input  wire [15:0]     m0_din, m1_din, m3_din,
    output logic           m0_ack, m1_ack, m2_ack, m3_ack,
    output logic [63:0]    m_dout,

    output logic            s_req,
    output logic [SDR_AW:1] s_addr,
    output logic            s_we,
    output logic [15:0]     s_din,
    output logic [1:0]      s_be,
    input  wire             s_ack,
    input  wire [63:0]      s_dout
);

  wire [NM-1:0]           m_req  = {m3_req, m2_req, m1_req, m0_req};
  wire [NM-1:0][SDR_AW:1] m_addr = {m3_addr, m2_addr, m1_addr, m0_addr};
  // Master 2 is the data ROM fetch: a reader, and its write signals are tied
  // off here exactly as they are in the core.
  // Master 2 is the data ROM fetch and never writes; master 3 is the boot RAM
  // self-test, which does.
  wire [NM-1:0]           m_we   = {m3_we, 1'b0, m1_we, m0_we};
  wire [NM-1:0][15:0]     m_din  = {m3_din, 16'd0, m1_din, m0_din};
  wire [NM-1:0][1:0]      m_be   = {2'b11, 2'b11, 2'b11, 2'b11};
  wire [NM-1:0]           m_ack;

  assign {m3_ack, m2_ack, m1_ack, m0_ack} = m_ack;

  kaneko_mcuram_arb #(.SDR_AW(SDR_AW), .NM(NM)) u_arb (
      .clk(clk), .rst_n(rst_n),
      .m_req(m_req), .m_addr(m_addr), .m_we(m_we), .m_din(m_din),
      .m_be(m_be), .m_ack(m_ack), .m_dout(m_dout),
      .s_req(s_req), .s_addr(s_addr), .s_we(s_we), .s_din(s_din),
      .s_be(s_be), .s_ack(s_ack), .s_dout(s_dout)
  );

endmodule
