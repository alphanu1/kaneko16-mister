//============================================================================
//  Kaneko 16-bit arcade core for MiSTer FPGA
//  Copyright (C) 2026 alphanu1
//  SPDX-License-Identifier: GPL-3.0-or-later
//
//  BRING-UP TOP LEVEL. There is no 68000 in this build.
//
//  This exists to prove on hardware the things simulation cannot: that the
//  SDRAM controller works against the real module at the real clock, that the
//  ROM loader survives the actual HPS, that the PLL and video timing produce a
//  signal a display accepts, and that the tile decode is right end to end.
//
//  It loads the MRA stream into SDRAM and then renders a WALL OF TILES
//  straight out of the tile ROM — no CPU, no VRAM, no game. Whatever appears is
//  real Explosive Breaker artwork fetched through the same pipeline the finished
//  core will use, so a correct picture exercises the loader, the SDRAM path, the
//  fetch pipeline and the video output at once, and a wrong one localises which.
//============================================================================

`default_nettype none

module emu
(
	`include "sys/emu_ports.vh"
);

// ---------------------------------------------------------------- unused
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign AUDIO_S   = 0;
assign AUDIO_L   = 0;
assign AUDIO_R   = 0;
assign AUDIO_MIX = 0;

assign LED_USER  = ioctl_download;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

assign VGA_SL      = 0;
assign VGA_F1      = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;

// Aspect: the visible area is 256x224 and the game is ROT90, but this build
// deliberately shows the NATIVE orientation. Rotation is decision D3 and an
// output-stage concern; putting it in before the picture is trusted would mean
// debugging two things at once.
assign VIDEO_ARX = status[8] ? 12'd16 : 12'd4;
assign VIDEO_ARY = status[8] ? 12'd9  : 12'd3;

`include "build_id.v"
localparam CONF_STR = {
	"Kaneko16;;",
	"-;",
	"O[8],Aspect ratio,4:3,16:9;",
	"O[5:4],SDRAM capture,CL+1,CL+0,CL+2,CL+3;",
	"O[10:9],Show,Tiles chip0,Tiles chip1,Sprites,Palette+CPU;",
	"-;",
	"V,v",`BUILD_DATE
};

// ------------------------------------------------------------------ clocks
// One clock for the core AND the SDRAM: no clock-domain crossing in this
// build. See rtl/pll/pll.v.
wire clk_sys, clk_spare, pll_locked;
wire clk_sdram;

pll pll
(
	.refclk   (CLK_50M),
	.rst      (0),
	.outclk_0 (clk_sdram),
	.outclk_1 (clk_sys),
	.outclk_2 (clk_spare),
	.locked   (pll_locked)
);

// 48 MHz core clock. ce_pix = /8 gives the 6 MHz derived in
// kaneko_video_timing.sv; ce_cpu = /4 gives the PCB-verified 12 MHz. Both are
// exact integer divisions, so no fractional division and no phase error.
reg [2:0] ce_div;
always @(posedge clk_sys) ce_div <= ce_div + 3'd1;
wire ce_pix = (ce_div == 3'd0);

wire rst_sys = ~pll_locked;

// ------------------------------------------------------------------ HPS
wire [63:0] status;
wire        ioctl_download, ioctl_wr, ioctl_wait;
wire [15:0] ioctl_index, ioctl_dout;
wire [26:0] ioctl_addr;
wire [15:0] joystick_0, joystick_1;
wire        forced_scandoubler;
wire [21:0] gamma_bus;
wire        direct_video;

hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),

	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.status(status)
);

// ------------------------------------------------------------------ SDRAM
// COL_BITS 10 = 64 MB, matching the module in use. NP: one write port for the
// loader plus one read port for the tile fetch. The finished core will grow
// this; the controller takes the count as a parameter.
localparam int unsigned SDR_COL = 10;
localparam int unsigned SDR_AW  = 2 + 13 + SDR_COL;   // 25
// FIVE ports, not one. The controller sizes its arbiter state from NP, and at
// NP=1 that state is a single bit while the logic indexes three — it does not
// elaborate. Five is also the configuration its testbench covers, so this build
// runs the arrangement that is actually verified. Port 0 is the tile fetch;
// 1..4 are tied idle and cost nothing but arbiter slots.
localparam int unsigned NPORTS  = 5;

wire              mem_ready;
wire              ldr_wr_req, ldr_wr_ack;
wire [SDR_AW:1]   ldr_wr_addr;
wire [15:0]       ldr_wr_din;
wire [1:0]        ldr_wr_be;

wire              p0_req;          // video tile fetch
wire [SDR_AW:1]   p0_addr;
wire              p1_req;          // 68000 ROM fetch
wire [SDR_AW:1]   p1_addr;
wire [NPORTS-1:0]       p_ack_bus;
wire [NPORTS-1:0][63:0] p_dout_bus;
wire              p0_ack  = p_ack_bus[0];
wire [63:0]       p0_dout = p_dout_bus[0];
wire              p1_ack  = p_ack_bus[1];
wire [63:0]       p1_dout = p_dout_bus[1];

wire sd_dq_oe;
wire [15:0] sd_dq_o;
assign SDRAM_DQ  = sd_dq_oe ? sd_dq_o : 16'bZ;
// The device is clocked on the inverse of the controller clock. That is why
// the capture-depth default differs between the model and the board, and why
// the OSD exposes the setting at all — see kaneko_sdram.sv.
assign SDRAM_CLK = ~clk_sdram;

kaneko_sdram #(.COL_BITS(SDR_COL), .NP(NPORTS), .T_REFI(300)) u_sdram
(
	.clk(clk_sdram), .rst_n(pll_locked), .ready(mem_ready),
	.rd_lat_sel(status[5:4]),

	.sd_cke(SDRAM_CKE), .sd_cs_n(SDRAM_nCS), .sd_ras_n(SDRAM_nRAS),
	.sd_cas_n(SDRAM_nCAS), .sd_we_n(SDRAM_nWE), .sd_ba(SDRAM_BA),
	.sd_a(SDRAM_A), .sd_dqm({SDRAM_DQMH, SDRAM_DQML}),
	.sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(SDRAM_DQ),

	.wr_req(ldr_wr_req), .wr_addr(ldr_wr_addr), .wr_din(ldr_wr_din),
	.wr_be(ldr_wr_be), .wr_ack(ldr_wr_ack),

	.p_req  ({3'b0, p1_req, p0_req}),
	.p_addr ({{3{{SDR_AW{1'b0}}}}, p1_addr, p0_addr}),
	.p_din  ({5{16'd0}}),
	.p_be   ({5{2'b11}}),
	.p_we   (5'b0),
	.p_ack  (p_ack_bus),
	.p_dout (p_dout_bus)
);

wire rom_loaded, ldr_overflow;

kaneko_rom_loader #(.SDR_AW(SDR_AW)) u_loader
(
	.clk(clk_sdram), .rst(~pll_locked), .mem_ready(mem_ready),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.sdr_wr_req(ldr_wr_req), .sdr_wr_addr(ldr_wr_addr),
	.sdr_wr_din(ldr_wr_din), .sdr_wr_be(ldr_wr_be), .sdr_wr_ack(ldr_wr_ack),
	.rom_loaded(rom_loaded), .overflow(ldr_overflow)
);

// -------------------------------------------------------------------- CPU
// 12 MHz from the 48 MHz core clock: the CPU clock is clk/4 and enPhi1/enPhi2
// are its two halves, two cycles apart. 12 MHz is PCB-verified — MAME
// annotates explbrkr's 68000 as XTAL(12'000'000) "verified on pcb".
reg [1:0] cpu_phase;
always @(posedge clk_sys) cpu_phase <= cpu_phase + 2'd1;
wire enPhi1 = (cpu_phase == 2'd0);
wire enPhi2 = (cpu_phase == 2'd2);

// Held in reset until the ROM is in SDRAM. Fetching before then reads whatever
// the module powered up with, and the 68000 would take that as its reset
// vectors — a crash with no evidence of why.
wire cpu_rst = rst_sys | ~rom_loaded;

wire        ASn, LDSn, UDSn, eRWn, DTACKn;
wire [15:0] oEdb, iEdb;
wire [23:1] eab;

fx68k u_cpu
(
	.clk(clk_sys), .HALTn(1'b1),
	.extReset(cpu_rst), .pwrUp(cpu_rst),
	.enPhi1(enPhi1), .enPhi2(enPhi2),
	.eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
	.E(), .VMAn(), .FC0(), .FC1(), .FC2(),
	.BGn(), .oRESETn(), .oHALTEDn(),
	.DTACKn(DTACKn), .VPAn(1'b1), .BERRn(1'b1),
	.BRn(1'b1), .BGACKn(1'b1),
	.IPL0n(1'b1), .IPL1n(1'b1), .IPL2n(1'b1),
	.iEdb(iEdb), .oEdb(oEdb), .eab(eab)
);

wire        vram0_we, vram1_we, spr_we, pal_we;
wire        v2r0_we, v2r1_we, sprreg_we;
wire [12:0] vmem_addr;
wire [15:0] vmem_din;
wire [3:0]  reg_addr;
wire [15:0] reg_din;
wire [15:0] q_vram0, q_vram1, q_spr, q_pal;
wire        unmapped_hit;

kaneko_bus #(.SDR_AW(SDR_AW), .ROM_BASE(25'd0)) u_bus
(
	.clk(clk_sys), .rst(cpu_rst),
	.eab(eab), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .eRWn(eRWn),
	.oEdb(oEdb), .iEdb(iEdb), .DTACKn(DTACKn),

	.rom_req(p1_req), .rom_addr(p1_addr), .rom_ack(p1_ack), .rom_dout(p1_dout),

	.vram0_we(vram0_we), .vram1_we(vram1_we), .spr_we(spr_we), .pal_we(pal_we),
	.vmem_addr(vmem_addr), .vmem_din(vmem_din),
	.vram0_q(q_vram0), .vram1_q(q_vram1), .spr_q(q_spr), .pal_q(q_pal),

	.v2r0_we(v2r0_we), .v2r1_we(v2r1_we), .sprreg_we(sprreg_we),
	.reg_addr(reg_addr), .reg_din(reg_din),
	.v2r0_q(16'h0000), .v2r1_q(16'h0000), .sprreg_q(16'h0000),

	// Nothing pressed. The EEPROM is not implemented yet, so anything the game
	// reads from it comes back as an unwritten device.
	.in_p1(16'hffff), .in_p2(16'hffff),
	.in_system(16'hffff), .in_unk(16'hffff),

	.unmapped_hit(unmapped_hit), .unmapped_addr()
);

// Video-side read ports. Only the palette is consumed in this build; the
// others are wired so the memories are real and the CPU's writes go somewhere.
wire [10:0] pal_rd_addr;
wire [15:0] pal_rd_q;

kaneko_vmem u_vmem
(
	.clk(clk_sys),
	.cpu_addr(vmem_addr), .cpu_din(vmem_din),
	.we_vram0(vram0_we), .we_vram1(vram1_we),
	.we_spr(spr_we), .we_pal(pal_we),
	.uds(~UDSn), .lds(~LDSn),
	.q_vram0(q_vram0), .q_vram1(q_vram1), .q_spr(q_spr), .q_pal(q_pal),
	.v0_addr(13'd0), .v0_q(),
	.v1_addr(13'd0), .v1_q(),
	.spr_addr(12'd0), .spr_q(),
	.pal_addr(pal_rd_addr), .pal_q(pal_rd_q)
);

// CPU liveness, counted per frame. A number the display can show beats
// inferring "it is running" from a picture that might be static for other
// reasons.
reg [19:0] bus_cycles, bus_cycles_lat;
reg        dtack_d;
always @(posedge clk_sys) begin
	dtack_d <= ~DTACKn;
	if (vbl_rise) begin bus_cycles_lat <= bus_cycles; bus_cycles <= 20'd0; end
	else if (~DTACKn && !dtack_d) bus_cycles <= bus_cycles + 20'd1;
end

// ------------------------------------------------------------------ video
wire [9:0] hcnt, vcnt;
wire [8:0] screen_x, screen_y;
wire hs, vs, hb, vb, de, vbl_rise;

kaneko_video_timing u_timing
(
	.clk(clk_sys), .rst(rst_sys), .ce_pix(ce_pix),
	.hcnt(hcnt), .vcnt(vcnt), .screen_x(screen_x), .screen_y(screen_y),
	.hsync(hs), .vsync(vs), .hblank(hb), .vblank(vb), .de(de),
	.vblank_rise(vbl_rise)
);

wire [7:0] r, g, b;

kaneko_tilewall #(.SDR_AW(SDR_AW)) u_wall
(
	.clk(clk_sys), .rst(rst_sys), .ce_pix(ce_pix),
	.rom_loaded(rom_loaded),
	.mode(status[10:9]),
	.screen_x(screen_x), .screen_y(screen_y), .de(de),
	.sdr_req(p0_req), .sdr_addr(p0_addr), .sdr_ack(p0_ack), .sdr_dout(p0_dout),
	.r(r), .g(g), .b(b)
);

// ----------------------------------------------------- palette / CPU view
// Mode 3 shows PALETTE RAM as a grid of swatches: 64 across by 32 down, each
// cell 4 x 7 pixels, covering all 2048 entries in 256 x 224.
//
// This is the cheapest proof that the CPU is running. The palette is RAM the
// game writes; if colours appear where the core powered up black, the 68000 is
// executing and its writes are reaching the right memory through the right
// decode. A tile view cannot show that — tiles come from ROM and look the same
// whether the CPU runs or not.
wire [5:0] sw_col = screen_x[7:2];
wire [4:0] sw_row = 5'((screen_y - 9'(16)) / 9'd7);
assign pal_rd_addr = {sw_row, sw_col};

wire [7:0] pal_r = {pal_rd_q[9:5],   pal_rd_q[9:7]};
wire [7:0] pal_g = {pal_rd_q[14:10], pal_rd_q[14:12]};
wire [7:0] pal_b = {pal_rd_q[4:0],   pal_rd_q[4:2]};

// A bar across the top whose length follows bus cycles per frame, so "the CPU
// is alive" is visible even if every palette entry is still black.
wire [8:0] alive_len = (bus_cycles_lat > 20'd65535) ? 9'd255
                                                    : 9'(bus_cycles_lat >> 8);
wire in_alive_bar = (screen_y < 9'(16 + 4)) && (screen_x < alive_len);

wire show_pal = (status[10:9] == 2'd3);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_DE    = de;
assign VGA_HS    = hs;
assign VGA_VS    = vs;
assign VGA_R = in_alive_bar ? 8'h00 : (show_pal ? pal_r : r);
assign VGA_G = in_alive_bar ? 8'hff : (show_pal ? pal_g : g);
assign VGA_B = in_alive_bar ? 8'h00 : (show_pal ? pal_b : b);

endmodule

`default_nettype wire
