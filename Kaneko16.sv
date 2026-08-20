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
	"O[10:9],Show,Tiles chip0,Tiles chip1,Sprites,Pattern;",
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

wire              p0_req;
wire [SDR_AW:1]   p0_addr;
wire [NPORTS-1:0]       p_ack_bus;
wire [NPORTS-1:0][63:0] p_dout_bus;
wire              p0_ack  = p_ack_bus[0];
wire [63:0]       p0_dout = p_dout_bus[0];

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

	.p_req  ({4'b0, p0_req}),
	.p_addr ({{4{{SDR_AW{1'b0}}}}, p0_addr}),
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

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_DE    = de;
assign VGA_HS    = hs;
assign VGA_VS    = vs;
assign VGA_R     = r;
assign VGA_G     = g;
assign VGA_B     = b;

endmodule

`default_nettype wire
