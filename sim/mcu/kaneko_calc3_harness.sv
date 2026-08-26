// SPDX-License-Identifier: GPL-3.0-or-later
//
// Harness for kaneko_calc3: the device with a SMALL data ROM.
//
// The real part scans all 128 KB at reset to compute the checksum the init
// command hands back. At a few cycles a byte that is most of a million cycles
// before the testbench can do anything, times every trial. The scan's logic
// does not depend on the size, so the harness sets 4 KB and the testbench
// checksums the same 4 KB.
//
// Passing the parameter rather than assuming it is the point: the first
// version of this testbench computed a 4 KB checksum and left the device on
// its 128 KB default, and every trial timed out waiting for a scan that was
// thirty-two times longer than the guard allowed.
module kaneko_calc3_harness #(
    parameter int unsigned AW = 17,
    parameter int unsigned ROM_BYTES = 4096
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [3:0]  com_w,
    input  wire        tick,
    input  wire [7:0]  dsw,

    output logic [AW-1:0] rom_addr,
    output logic          rom_rd,
    input  wire  [7:0]    rom_data,
    input  wire           rom_valid,

    output logic [15:0] ram_addr,
    output logic        ram_rd,
    output logic        ram_wr,
    output logic [1:0]  ram_be,
    output logic [15:0] ram_wdata,
    input  wire  [15:0] ram_rdata,
    input  wire         ram_valid,

    output logic [5:0]  eep_addr,
    input  wire  [15:0] eep_data,
    output logic        eep_rd,

    output logic        busy,
    output logic        crc_ready,
    output logic        key_missing,

    // Taps for the testbench: the decoded byte stream as it is handed over.
    // Comparing final RAM alone cannot say whether a wrong byte came from the
    // decode or from where it was put.
    output logic [7:0]  dbg_out_byte,
    output logic        dbg_out_valid,
    output logic        dbg_out_ready,
    output logic        dbg_start,
    output logic        dbg_tbusy,
    output logic [15:0] dbg_len,
    output logic        dbg_bad,
    output logic        dbg_done,
    output logic [7:0]  dbg_tab,
    output logic [31:0] dbg_wcur,
    output logic [15:0] dbg_tbytes
);

  assign dbg_wcur      = u_calc3.write_cur;
  assign dbg_tbytes    = u_calc3.tbl_bytes;
  assign dbg_len       = u_calc3.t_len;
  assign dbg_bad       = u_calc3.t_bad;
  assign dbg_done      = u_calc3.t_done;
  assign dbg_tab       = u_calc3.t_tabnum;
  assign dbg_start     = u_calc3.t_start;
  assign dbg_tbusy     = u_calc3.t_busy;
  assign dbg_out_byte  = u_calc3.t_byte;
  assign dbg_out_valid = u_calc3.t_out_valid;
  assign dbg_out_ready = u_calc3.t_ready;

  kaneko_calc3 #(.AW(AW), .ROM_BYTES(ROM_BYTES)) u_calc3 (
      .clk(clk), .rst_n(rst_n), .com_w(com_w), .tick(tick), .dsw(dsw),
      .rom_addr(rom_addr), .rom_rd(rom_rd),
      .rom_data(rom_data), .rom_valid(rom_valid),
      .ram_addr(ram_addr), .ram_rd(ram_rd), .ram_wr(ram_wr), .ram_be(ram_be),
      .ram_wdata(ram_wdata), .ram_rdata(ram_rdata), .ram_valid(ram_valid),
      .eep_addr(eep_addr), .eep_data(eep_data), .eep_rd(eep_rd),
      .busy(busy), .crc_ready(crc_ready), .key_missing(key_missing)
  );

endmodule
