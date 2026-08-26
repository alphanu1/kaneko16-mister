// SPDX-License-Identifier: GPL-3.0-or-later
//
// The CALC3 AS THE CORE WIRES IT: the device, the byte feeder that serves its
// data ROM, and the arbiter that puts all three of its masters on one SDRAM
// port. Same topology as KanekoCALC3.sv, in a harness a testbench can drive.
//
// This exists because every test before it checked one module against an
// idealised memory that was always free and answered in a fixed way. Behind an
// arbiter nothing is always free, and the first thing hardware did was hang --
// the MCU's checksum scan never finished, and nothing in simulation could have
// told me that, because nothing simulated these three together.
//
// REAL_MEM puts the REAL memory stack underneath: the 2:1 clock crossing, the
// controller, and the device model -- so the only thing left between this and
// the board is the physical part. With it off the testbench drives the port
// itself, which is quicker to reason about; with it on, the port 10 the MCU
// uses is a port that has never been exercised on hardware in either
// direction, and this is the only place that can be found out cheaply.
module kaneko_calc3_sys_harness #(
    parameter int unsigned SDR_AW    = 25,
    parameter int unsigned AW        = 17,
    parameter int unsigned ROM_BYTES = 4096,
    parameter bit          REAL_MEM  = 1,
    parameter int unsigned NP        = 11,   // the core's port count
    parameter int unsigned P10       = 10,   // the MCU's port index
    parameter int unsigned COL_BITS  = 9
) (
    // ONE CLOCK IN. The slow one is DERIVED here, from the same fast clock and
    // the same reset the crossing divides, because the crossing generates its
    // own slow phase internally and a separately driven slow clock can sit in
    // ANTIPHASE to it -- and then every slow-side handshake is sampled on the
    // wrong edge. That is not a subtle skew, it is the difference between the
    // loader's writes landing and reading back as zeros, which is exactly what
    // this harness did before. The real core has the two from one PLL at 2:1.
    input  wire clk_fast,
    input  wire rst,

    // Loader port, for filling the device model before the run.
    // Masks the port request exactly as the core's rom_loaded does, so the
    // MCU's reads go unacknowledged until the data ROM is in memory. The core
    // does NOT hold the device in reset for this -- it gates the port -- and
    // the difference matters: the device starts scanning out of reset either
    // way, and only the gate stops it summing empty memory.
    input  wire            port_gate,
    input  wire            ld_req,
    input  wire [SDR_AW:1] ld_addr,
    input  wire [15:0]     ld_din,
    output logic           ld_ack,
    output logic           mem_ready,

    input  wire [3:0]  com_w,
    input  wire        tick,
    input  wire [7:0]  dsw,

    // The 68000's side of the shared RAM, as kaneko_bus drives it: a request
    // HELD until its acknowledge.
    input  wire            cpu_req,
    input  wire [SDR_AW:1] cpu_addr,
    input  wire            cpu_we,
    input  wire [15:0]     cpu_din,
    input  wire [1:0]      cpu_be,
    output logic           cpu_ack,
    output logic [63:0]    cpu_dout,

    input  wire [SDR_AW:1] base_mcuram,
    input  wire [SDR_AW:1] base_calc3rom,

    // The single SDRAM port everything shares.
    output logic            s_req,
    output logic [SDR_AW:1] s_addr,
    output logic            s_we,
    output logic [15:0]     s_din,
    output logic [1:0]      s_be,
    input  wire             s_ack,
    input  wire [63:0]      s_dout,

    input  wire [15:0] eep_data,

    output logic       busy,
    output logic       crc_ready,
    output logic       key_missing,
    output logic [7:0] dbg_cmds,
    output logic [15:0] dbg_cmd,
    output logic [3:0] dbg_status,
    output logic [15:0] dbg_crc,
    output logic [16:0] dbg_rom_addr,
    output logic [7:0]  dbg_rom_byte,
    output logic        dbg_rom_valid
);

  logic clk_div;
  always_ff @(posedge clk_fast or posedge rst)
      if (rst) clk_div <= 1'b0; else clk_div <= ~clk_div;
  wire clk = clk_div;

  wire [AW-1:0] c3_rom_addr;
  wire          c3_rom_rd;
  wire [15:0]   c3_ram_addr;
  wire          c3_ram_rd, c3_ram_wr;
  wire [1:0]    c3_ram_be;
  wire [15:0]   c3_ram_wdata;
  wire [5:0]    c3_eep_addr;
  wire          c3_eep_rd;

  wire [7:0]  c3_rom_byte;
  wire        c3_rom_ok;
  wire        c3_romp_req;
  wire [SDR_AW:1] c3_romp_addr;
  wire [2:0]  arb_ack;
  wire [63:0] arb_dout;

  kaneko_calc3 #(.AW(AW), .ROM_BYTES(ROM_BYTES)) u_calc3 (
      .clk(clk), .rst_n(~rst), .com_w(com_w), .tick(tick), .dsw(dsw),
      .rom_addr(c3_rom_addr), .rom_rd(c3_rom_rd),
      .rom_data(c3_rom_byte), .rom_valid(c3_rom_valid),
      .ram_addr(c3_ram_addr), .ram_rd(c3_ram_rd), .ram_wr(c3_ram_wr),
      .ram_be(c3_ram_be), .ram_wdata(c3_ram_wdata),
      .ram_rdata(c3_ram_rdata), .ram_valid(c3_ram_valid),
      .eep_addr(c3_eep_addr), .eep_data(eep_data), .eep_rd(c3_eep_rd),
      .busy(busy), .crc_ready(crc_ready), .key_missing(key_missing),
      .dbg_cmds(dbg_cmds), .dbg_cmd(dbg_cmd),
      .dbg_status(dbg_status), .dbg_crc(dbg_crc)
  );

  kaneko_tilerom #(.NREQ(1), .SDR_AW(SDR_AW)) u_calc3rom (
      .clk(clk), .rst(rst),
      .req_addr({{(24-AW){1'b0}}, c3_rom_addr}),
      .base_addr(base_calc3rom),
      .req_data(c3_rom_byte),
      .port_ready(c3_rom_ok),
      .sdr_req(c3_romp_req), .sdr_addr(c3_romp_addr),
      .sdr_ack(arb_ack[2]), .sdr_dout(arb_dout)
  );

  logic c3_rom_pending;
  always_ff @(posedge clk) begin
      if (rst)                c3_rom_pending <= 1'b0;
      else if (c3_rom_rd)     c3_rom_pending <= 1'b1;
      else if (c3_rom_valid)  c3_rom_pending <= 1'b0;
  end
  wire c3_rom_valid = c3_rom_pending && c3_rom_ok;
  assign dbg_rom_addr  = c3_rom_addr;
  assign dbg_rom_byte  = c3_rom_byte;
  assign dbg_rom_valid = c3_rom_valid;

  wire c3_ram_req = c3_ram_rd | c3_ram_wr;
  wire [SDR_AW:1] c3_ram_sdr_addr = base_mcuram + SDR_AW'(c3_ram_addr[15:1]);
  logic [1:0] c3_ram_lane;
  always_ff @(posedge clk) if (c3_ram_req) c3_ram_lane <= c3_ram_addr[2:1];
  wire [15:0] c3_ram_rdata = arb_dout[{c3_ram_lane, 4'd0} +: 16];
  wire        c3_ram_valid = arb_ack[1];

  wire [2:0]            arb_req  = {c3_romp_req, c3_ram_req, cpu_req};
  wire [2:0][SDR_AW:1]  arb_addr = {c3_romp_addr, c3_ram_sdr_addr, cpu_addr};
  wire [2:0]            arb_we   = {1'b0, c3_ram_wr, cpu_we};
  wire [2:0][15:0]      arb_din  = {16'd0, c3_ram_wdata, cpu_din};
  wire [2:0][1:0]       arb_be   = {2'b11, c3_ram_be, cpu_be};

  assign cpu_ack  = arb_ack[0];
  assign cpu_dout = arb_dout;

  logic            a_req, a_we;
  logic [SDR_AW:1] a_addr;
  logic [15:0]     a_din;
  logic [1:0]      a_be;
  logic            a_ack;
  logic [63:0]     a_dout;

  kaneko_mcuram_arb #(.SDR_AW(SDR_AW), .NM(3)) u_arb (
      .clk(clk), .rst_n(~rst),
      .m_req(arb_req), .m_addr(arb_addr), .m_we(arb_we),
      .m_din(arb_din), .m_be(arb_be),
      .m_ack(arb_ack), .m_dout(arb_dout),
      .s_req(a_req), .s_addr(a_addr), .s_we(a_we),
      .s_din(a_din), .s_be(a_be), .s_ack(a_ack), .s_dout(a_dout)
  );

  generate
  if (!REAL_MEM) begin : g_tb_mem
      // The testbench is the memory.
      assign s_req  = a_req;  assign s_addr = a_addr; assign s_we = a_we;
      assign s_din  = a_din;  assign s_be   = a_be;
      assign a_ack  = s_ack;  assign a_dout = s_dout;
      assign ld_ack = 1'b0;   assign mem_ready = 1'b1;
  end else begin : g_real_mem
      // THE REAL STACK. The MCU sits on port P10 exactly as it does in the
      // core, with every other port tied off -- what is under test is that
      // port, which no hardware run has ever used.
      assign s_req = 1'b0; assign s_addr = '0; assign s_we = 1'b0;
      assign s_din = '0;   assign s_be = 2'b11;

      wire [NP-1:0]           f_req, f_ack, f_we;
      wire [NP-1:0][SDR_AW:1] f_addr;
      wire [NP-1:0][15:0]     f_din;
      wire [NP-1:0][1:0]      f_be;
      wire [NP-1:0][63:0]     f_dout;
      wire                    f_wr_req, f_wr_ack;
      wire [SDR_AW:1]         f_wr_addr;
      wire [15:0]             f_wr_din;
      wire [1:0]              f_wr_be;

      wire [NP-1:0]           s_req_v, s_we_v;
      wire [NP-1:0][SDR_AW:1] s_addr_v;
      wire [NP-1:0][15:0]     s_din_v;
      wire [NP-1:0][1:0]      s_be_v;
      wire [NP-1:0]           s_ack_v;
      wire [NP-1:0][63:0]     s_dout_v;

      genvar q;
      for (q = 0; q < NP; q = q + 1) begin : g_tie
          assign s_req_v[q]  = (q == P10) ? (a_req & port_gate) : 1'b0;
          assign s_addr_v[q] = (q == P10) ? a_addr : '0;
          assign s_we_v[q]   = (q == P10) ? a_we   : 1'b0;
          assign s_din_v[q]  = (q == P10) ? a_din  : 16'd0;
          assign s_be_v[q]   = (q == P10) ? a_be   : 2'b11;
      end
      assign a_ack  = s_ack_v[P10];
      assign a_dout = s_dout_v[P10];

      kaneko_sdram_x2 #(.NP(NP), .AW(SDR_AW)) u_x2 (
          .clk_fast(clk_fast),
          .s_req(s_req_v), .s_addr(s_addr_v),
          .s_we(s_we_v), .s_din(s_din_v), .s_be(s_be_v),
          .f_we(f_we), .f_din(f_din), .f_be(f_be),
          .s_ack(s_ack_v), .s_dout(s_dout_v),
          .s_wr_req(ld_req), .s_wr_addr(ld_addr), .s_wr_din(ld_din),
          .s_wr_be(2'b11), .s_wr_ack(ld_ack),
          .f_req(f_req), .f_addr(f_addr), .f_ack(f_ack), .f_dout(f_dout),
          .f_wr_req(f_wr_req), .f_wr_addr(f_wr_addr), .f_wr_din(f_wr_din),
          .f_wr_be(f_wr_be), .f_wr_ack(f_wr_ack)
      );

      wire sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
      wire [1:0]  sd_ba, sd_dqm;
      wire [12:0] sd_a;
      wire [15:0] sd_dq_o, sd_dq_i;

      // URGENT as the core sets it: port 10 NOT urgent.
      kaneko_sdram #(.COL_BITS(COL_BITS), .NP(NP), .T_REFI(700),
                     .INIT_NOP(600), .URGENT(11'b0_11_0011_1111)) u_ctrl (
          .clk(clk_fast), .rst_n(~rst), .ready(mem_ready), .rd_lat_sel(2'd3),
          .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n),
          .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_ba(sd_ba),
          .sd_a(sd_a), .sd_dqm(sd_dqm),
          .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(sd_dq_i),
          .wr_req(f_wr_req), .wr_addr(f_wr_addr), .wr_din(f_wr_din),
          .wr_be(f_wr_be), .wr_ack(f_wr_ack),
          .p_req(f_req), .p_addr(f_addr), .p_din(f_din),
          .p_be(f_be), .p_we(f_we),
          .p_ack(f_ack), .p_dout(f_dout),
          .dbg_req(), .dbg_grant()
      );

      sdram_model #(.COL_BITS(COL_BITS), .T_REFI(750), .REFI_SLACK(9)) u_dram (
          .clk(clk_fast), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
          .cas_n(sd_cas_n), .we_n(sd_we_n), .ba(sd_ba), .a(sd_a),
          .dqm(sd_dqm), .dq_i(sd_dq_o), .dq_oe_i(sd_dq_oe), .dq_o(sd_dq_i),
          .violations(), .v_flags()
      );
  end
  endgenerate

endmodule
