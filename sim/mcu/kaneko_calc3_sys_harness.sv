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
module kaneko_calc3_sys_harness #(
    parameter int unsigned SDR_AW    = 25,
    parameter int unsigned AW        = 17,
    parameter int unsigned ROM_BYTES = 4096
) (
    input  wire clk,
    input  wire rst,

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
    output logic [15:0] dbg_crc
);

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

  kaneko_mcuram_arb #(.SDR_AW(SDR_AW), .NM(3)) u_arb (
      .clk(clk), .rst_n(~rst),
      .m_req(arb_req), .m_addr(arb_addr), .m_we(arb_we),
      .m_din(arb_din), .m_be(arb_be),
      .m_ack(arb_ack), .m_dout(arb_dout),
      .s_req(s_req), .s_addr(s_addr), .s_we(s_we),
      .s_din(s_din), .s_be(s_be), .s_ack(s_ack), .s_dout(s_dout)
  );

endmodule
