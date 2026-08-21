// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// kaneko_spr_sys with its sprite RAM and its SDRAM modelled, and the parser's
// output stream brought out so the testbench can see the records that were
// actually resolved.
//
// That last part is what makes the test strong without re-deriving the parser.
// kaneko_vuspr is already verified against MAME and kaneko_vuspr_draw against
// the frame gate's compositor; what kaneko_spr_sys adds is the table between
// them, the double buffer, the parity mask and the mixer read port. Snooping
// the resolved records lets the testbench run the known-good draw reference on
// exactly what the parser produced and compare that to what comes back out of
// the mixer port — so a fault can only be in the parts under test.
`timescale 1ns/1ps
`default_nettype none

module kaneko_spr_sys_harness #(
    parameter int unsigned BMP_W_LOG2 = 8,
    parameter int unsigned BMP_H_LOG2 = 8,
    parameter int unsigned SPRITES    = 1024,
    parameter int unsigned SDR_AW     = 25,
    parameter int unsigned LATENCY    = 18
) (
    input  wire clk,
    input  wire rst,

    input  wire         frame_start,
    input  wire         keep_sprites,
    input  wire         skip_en,
    input  wire [10:0]  sprite_count,
    input  wire [9:0]   clip_x0, clip_x1, clip_y0, clip_y1,
    input  wire [8:0]   visarea_min_y,

    // Sprite RAM write port, for the testbench to load a list.
    input  wire         ram_we,
    input  wire [11:0]  ram_wa,
    input  wire [15:0]  ram_wd,

    input  wire [255:0] regs_flat,

    input  wire [BMP_W_LOG2-1:0] rd_x,
    input  wire [BMP_H_LOG2-1:0] rd_y,
    output wire [13:0]  spr_pix,
    output wire [1:0]   spr_prio,

    output wire         busy,
    output wire [15:0]  overrun,

    // Snoop of the resolved record stream.
    output wire         par_valid,
    output wire [16:0]  par_code,
    output wire [5:0]   par_colour,
    output wire [1:0]   par_prio,
    output wire         par_flipx, par_flipy,
    output wire [9:0]   par_x, par_y,

    // What the renderer actually latched out of the table.
    output wire [16:0]  dbg_scode,
    output wire [5:0]   dbg_scolour,
    output wire [46:0]  dbg_tblq,
    output wire [9:0]   dbg_tblra,

    output wire         dbg_bmp_we,
    output wire [15:0]  dbg_bmp_addr,
    output wire [15:0]  dbg_bmp_data,
    output wire         dbg_back,
    output wire [11:0]  dbg_ramaddr,
    output wire [15:0]  dbg_ramq,
    output wire         dbg_parstart,
    output wire         dbg_bvalid,
    output wire [3:0]   dbg_bpix,
    output wire         dbg_maskq,
    output wire [2:0]   dbg_state,
    output wire         dbg_ce,
    output wire [3:0]   dbg_xx, dbg_yy
);

    // ------------------------------------------------------- sprite RAM
    logic [15:0] sram [0:4095];
    wire  [11:0] ram_addr;
    logic [15:0] ram_q;

    always_ff @(posedge clk) begin
        if (ram_we) sram[ram_wa] <= ram_wd;
        ram_q <= sram[ram_addr];
    end

    // -------------------------------------------------------- SDRAM model
    // Answers LATENCY clocks after a request with eight bytes derived from the
    // word address, so the testbench can predict every byte the renderer sees.
    // One model per sprite port. They answer INDEPENDENTLY, which is the whole
    // point of there being two: the pair a sprite row needs is in flight at
    // the same time rather than one after the other.
    wire [1:0]            sdr_req;
    wire [1:0][SDR_AW:1]  sdr_addr;
    logic [1:0]           sdr_ack;
    logic [1:0][63:0]     sdr_dout;

    genvar m;
    generate
        for (m = 0; m < 2; m = m + 1) begin : g_mem
            logic [7:0] cnt;
            always_ff @(posedge clk) begin
                if (rst) begin
                    cnt <= 8'd0; sdr_ack[m] <= 1'b0;
                end else begin
                    sdr_ack[m] <= 1'b0;
                    if (sdr_req[m] && !sdr_ack[m]) begin
                        if (cnt == LATENCY[7:0]) begin
                            for (int k = 0; k < 8; k++)
                                sdr_dout[m][8*k +: 8] <=
                                    8'((32'(sdr_addr[m]) << 1) + k);
                            sdr_ack[m] <= 1'b1;
                            cnt        <= 8'd0;
                        end else cnt <= cnt + 8'd1;
                    end else cnt <= 8'd0;
                end
            end
        end
    endgenerate

    kaneko_spr_sys #(
        .BMP_W_LOG2(BMP_W_LOG2), .BMP_H_LOG2(BMP_H_LOG2),
        .SPRITES(SPRITES), .SDR_AW(SDR_AW)
    ) u_dut (
        .clk(clk), .rst(rst),
        .frame_start(frame_start),
        .keep_sprites(keep_sprites),
        .skip_en(skip_en),
        .sprite_count(sprite_count),
        .sprite_xoffs(16'd0), .sprite_yoffs(16'd0),
        .visarea_min_y(visarea_min_y),
        .wide_screen(1'b0), .fliptype(1'b0),
        .clip_x0(clip_x0), .clip_x1(clip_x1),
        .clip_y0(clip_y0), .clip_y1(clip_y1),
        .ram_addr(ram_addr), .ram_data(ram_q),
        .regs_flat(regs_flat),
        .rom_base({SDR_AW{1'b0}}),
        .sdr_req(sdr_req), .sdr_addr(sdr_addr),
        .sdr_ack(sdr_ack), .sdr_dout(sdr_dout),
        .rd_x(rd_x), .rd_y(rd_y),
        .spr_pix(spr_pix), .spr_prio(spr_prio),
        .busy(busy), .overrun(overrun)
    );

    // The parser lives inside the DUT; reach in for the stream rather than
    // adding observation ports to the module that ships.
    assign par_valid  = u_dut.par_valid;
    assign par_code   = u_dut.par_code;
    assign par_colour = u_dut.par_colour;
    assign par_prio   = u_dut.par_prio;
    assign par_flipx  = u_dut.par_flipx;
    assign par_flipy  = u_dut.par_flipy;
    assign par_x      = u_dut.par_x;
    assign par_y      = u_dut.par_y;

    assign dbg_scode   = u_dut.u_draw.s_code;
    assign dbg_scolour = u_dut.u_draw.s_colour;
    assign dbg_tblq    = u_dut.tbl_q;
    assign dbg_tblra   = u_dut.tbl_ra;
    assign dbg_bmp_we   = u_dut.dr_bmp_we;
    assign dbg_bmp_addr = 16'(u_dut.dr_bmp_addr);
    assign dbg_bmp_data = u_dut.dr_bmp_data;
    assign dbg_back     = u_dut.back;
    assign dbg_ramaddr  = ram_addr;
    assign dbg_ramq     = ram_q;
    assign dbg_parstart = u_dut.par_start;
    assign dbg_bvalid   = u_dut.u_draw.b_valid;
    assign dbg_bpix     = u_dut.u_draw.b_pix;
    assign dbg_maskq    = u_dut.u_draw.mask_q;
    assign dbg_state    = 3'(u_dut.u_draw.state);
    assign dbg_ce       = u_dut.dr_ce;
    assign dbg_xx       = u_dut.u_draw.xx;
    assign dbg_yy       = u_dut.u_draw.yy;
endmodule

`default_nettype wire
