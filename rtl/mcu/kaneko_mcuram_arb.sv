// SPDX-License-Identifier: GPL-3.0-or-later
//
// N masters, one SDRAM port, for the CALC3 board.
//
// Three masters share it: the 68000 reaching the MCU's shared RAM, the CALC3
// reaching that same RAM, and the CALC3 reading its external data ROM.
//
// ONE PORT, ARBITRATED, rather than a port each. Three reasons, in order of
// how much they cost to get wrong:
//
//   A port each puts a SECOND WRITER on the SDRAM. This core has exactly one,
//   the harness that checks the write path models one, and that path has never
//   run on hardware. Two writers is not the change to make in the same step as
//   bringing up a new device.
//
//   One port makes coherency STRUCTURAL. The 68000 and the MCU share that RAM
//   as their communication channel; with one access ever in flight a read
//   cannot pass a write to the same address. Across two ports that ordering
//   would be a hope.
//
//   Every extra port is another entry in seven harnesses and a per-port switch
//   in tb_kaneko_sdram. That churn is where the last port-count change went
//   wrong twice.
//
// ROUND ROBIN, not fixed priority. The CALC3 issues thousands of back-to-back
// accesses while decompressing a table, and a fixed order starves whoever sits
// below it for the whole run -- the 68000 waits on DTACK, so starving it stalls
// the game.

module kaneko_mcuram_arb #(
    parameter int unsigned SDR_AW = 25,
    parameter int unsigned NM     = 3      // masters
) (
    input  wire clk,
    input  wire rst_n,

    // Masters, flattened. Master 0 is the 68000, 1 the CALC3's RAM port, 2 its
    // data ROM fetch. Only master 0 and 1 ever write; the ROM fetch is a reader
    // and ties its we low.
    input  wire [NM-1:0]            m_req,
    input  wire [NM-1:0][SDR_AW:1]  m_addr,
    input  wire [NM-1:0]            m_we,
    input  wire [NM-1:0][15:0]      m_din,
    input  wire [NM-1:0][1:0]       m_be,
    output logic [NM-1:0]           m_ack,
    output logic [63:0]             m_dout,     // shared: valid with m_ack

    // The SDRAM port.
    output logic            s_req,
    output logic [SDR_AW:1] s_addr,
    output logic            s_we,
    output logic [15:0]     s_din,
    output logic [1:0]      s_be,
    input  wire             s_ack,
    input  wire [63:0]      s_dout
);

  localparam int unsigned MW = (NM <= 1) ? 1 : $clog2(NM);

  logic              busy;
  logic [MW-1:0]     grant;
  logic [MW-1:0]     last;        // who went last, for the rotation

  // The next requester at or after `start`, searched in rotation order so no
  // master can be passed over twice while it is asking.
  function automatic [MW-1:0] pick(input [MW-1:0] from, input [NM-1:0] asking);
    logic [MW-1:0] c;
    begin
      pick = from;
      for (int k = 0; k < NM; k++) begin
        c = MW'((int'(from) + k) % NM);
        if (asking[c]) begin
          pick = c;
          break;
        end
      end
    end
  endfunction

  wire [MW-1:0] next_start = MW'((int'(last) + 1) % NM);
  wire          any_req    = |m_req;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy  <= 1'b0;
      s_req <= 1'b0;
      m_ack <= '0;
      last  <= '0;
      grant <= '0;
    end else begin
      m_ack <= '0;                     // single-cycle pulses

      if (!busy) begin
        if (any_req) begin
          grant  <= pick(next_start, m_req);
          s_req  <= 1'b1;
          s_addr <= m_addr[pick(next_start, m_req)];
          s_we   <= m_we  [pick(next_start, m_req)];
          s_din  <= m_din [pick(next_start, m_req)];
          s_be   <= m_be  [pick(next_start, m_req)];
          busy   <= 1'b1;
        end
      end else if (s_ack) begin
        s_req         <= 1'b0;
        m_dout        <= s_dout;
        m_ack[grant]  <= 1'b1;
        last          <= grant;
        busy          <= 1'b0;
      end
    end
  end

endmodule
