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

// Audio. Both YM2149s are mono into the cabinet's single speaker, so the two
// outputs are summed and sent to both channels. AUDIO_S = 0: jt49's `sound` is
// an unsigned 10-bit level, not a signed sample.
//
// The OKI M6295 is not connected yet; when it is, it mixes in here.
assign AUDIO_S   = 1;
assign AUDIO_L   = ym_mix;
assign AUDIO_R   = ym_mix;
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
	"O[9],Show,Game,Palette+CPU;",
	"O[11],Debug overlay,Off,On;",
	"-;",
	"O[13],Flip screen,Off,On;",
	"O[14],Service switch,Off,On;",
	"O[15],Sprite offscreen skip,On,Off;",
	"O[16],Sprites,On,Off;",
	"-;",
	"R[12],Reset;",
	"-;",
	"J1,Shot,Bomb,Start,Coin,Pause,Service Coin;",
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

// POWER-ON RESET AND CORE RESET ARE NOT THE SAME THING
//
// rst_por is the PLL coming up. rst_sys adds the user's reset — the OSD entry,
// the physical button, and the HPS RESET line — and is what the CPU, the video
// timing and the rest of the logic use.
//
// The EEPROM takes rst_por ONLY. It is a non-volatile part: resetting the board
// does not erase it, and a core reset that wiped the game's settings and high
// scores would be wrong in a way that looks like the EEPROM not working at all.
// ------------------------------------------------------ save backup RAM
//
// The 93C46 holds the game's settings, high scores and whatever it calibrates
// on first boot. It is non-volatile on the board, so it has to be non-volatile
// here too — otherwise the game finds a blank part every time and spends about
// four seconds reformatting it before it will start.
//
// Index 2 is the arcade convention; the MRA declares
// `<nvram index="2" size="128"/>` and the HPS keeps a 128-byte file for it,
// which is 64 words of 16 bits.
localparam [7:0] NVRAM_INDEX = 8'd2;

wire        ioctl_upload;
wire [15:0] ioctl_din;
wire        nv_sel = (ioctl_index[7:0] == NVRAM_INDEX);

// GAME ID, from MRA <rom index="1">.
//
// One bitstream serves every game and selects its memory-map pages and video
// constants from this byte. It arrives before the ROM stream, so it is settled
// long before the 68000 leaves reset. Held through a core reset and cleared
// only by power-on, because the OSD reset must not lose which game is loaded.
localparam [7:0] CFG_INDEX = 8'd1;
reg [7:0] game_id;
always @(posedge clk_sys) begin
	if (rst_por)
		game_id <= 8'd0;
	else if (ioctl_wr && (ioctl_index[7:0] == CFG_INDEX))
		game_id <= ioctl_dout[7:0];
end

// ------------------------------------------------------- the game table
// Hard rule 9: a per-game fact belongs here, not wired into shared code. Every
// entry below differs between the two games and every one of them, wrong,
// renders a plausible picture rather than failing.
//
// Pages are a[23:16] of each window that moves; sizes do not move and stay in
// kaneko_bus. Read from bakubrkr_map / mgcrystl_map and from the frame gate's
// table, which is pixel-exact on both.
//
//   id 0  explbrkr    id 1  mgcrystl
wire mg = (game_id == 8'd1);

wire [7:0] PG_WRAM = mg ? 8'h30 : 8'h10;
wire [7:0] PG_V2W0 = mg ? 8'h60 : 8'h50;
wire [7:0] PG_V2W1 = mg ? 8'h68 : 8'h58;
wire [7:0] PG_SPR  = mg ? 8'h70 : 8'h60;
wire [7:0] PG_PAL  = mg ? 8'h50 : 8'h70;
wire [7:0] PG_WDOG = mg ? 8'ha0 : 8'ha8;
wire [7:0] PG_IN   = mg ? 8'hc0 : 8'he0;

// m_view2_2_pri: chip 1 writes its category, or zero. 1 for explbrkr, 0 for
// mgcrystl — the single most load-bearing per-game bit in the mixer.
wire VIEW2_2_PRI = ~mg;
// set_priorities(): {8,8,8,8} above everything on explbrkr, {2,3,5,7}
// interleaved with the tile layers on mgcrystl.
wire [15:0] SPR_PRI_SEL = mg ? 16'h7532 : 16'h8888;

// WIDE=1, so ioctl_addr counts bytes and advances by two per word.
wire [5:0]  bk_addr = ioctl_addr[6:1];
wire [15:0] bk_din  = ioctl_dout;
wire        bk_we   = ioctl_download && ioctl_wr && nv_sel;
wire [15:0] bk_q;

// Driven only during an upload; hps_io ignores it otherwise, and gating it
// keeps the EEPROM's read port out of the picture the rest of the time.
assign ioctl_din = ioctl_upload ? bk_q : 16'd0;

// THE FRAMEWORK ASKS; THE CORE ONLY HAS TO SAY YES
//
// There is no menu entry to add. For arcade cores MiSTer checks
// UIO_CHK_UPLOAD each time the OSD is opened (menu.cpp MENU_SAVE_CHECK) and
// writes the file if the core says it has something — that is what "Autosave
// flushes when you open the OSD" actually is. hps_io answers that check from
// ioctl_upload_req, so all the core does is raise it when the EEPROM changes.
//
// Held rather than pulsed, and cleared when the upload finishes: hps_io latches
// the rising edge, so a write that happens while a save is already in flight
// still produces a fresh edge afterwards and is not lost.
wire bk_dirty;
reg  bk_save_req;
reg  upload_d;
always @(posedge clk_sys) begin
	upload_d <= ioctl_upload;
	if (rst_por)                        bk_save_req <= 1'b0;
	else if (bk_dirty)                  bk_save_req <= 1'b1;
	else if (upload_d && !ioctl_upload) bk_save_req <= 1'b0;   // save taken
end

// Clear the EEPROM's flag once the request is registered, so the next write
// sets it again.
wire bk_dirty_clr = bk_save_req;

wire [1:0] buttons;
wire rst_por = ~pll_locked;
wire rst_sys = rst_por | RESET | status[12] | buttons[1];

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

	// Save Backup RAM. The EEPROM is the only non-volatile thing on this
	// board, and index 2 is the arcade convention the MRA's <nvram> element
	// names. hps_io asks the HPS to read the data back when upload_req pulses.
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(bk_save_req),
	.ioctl_upload_index(8'd2),
	.ioctl_din(ioctl_din),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.status(status),
	.buttons(buttons)
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
localparam int unsigned NPORTS  = 8;

wire              mem_ready;
wire              ldr_wr_req, ldr_wr_ack;
wire [SDR_AW:1]   ldr_wr_addr;
wire [15:0]       ldr_wr_din;
wire [1:0]        ldr_wr_be;

wire              p0_req;          // tile feeder, layer 0
wire [SDR_AW:1]   p0_addr;
wire              p1_req;          // 68000 ROM fetch
wire [SDR_AW:1]   p1_addr;
wire              p2_req, p3_req, p4_req;   // tile feeder, one per layer
wire [SDR_AW:1]   p2_addr, p3_addr, p4_addr;
wire              p5_req;                   // OKI M6295 sample fetch
wire [SDR_AW:1]   p5_addr;
// Two ports for the sprite ROM, not one: a sprite row needs a block from each
// half of its address space and they are fetched CONCURRENTLY. See the header
// of kaneko_sprrom for the derivation of that pattern.
wire [1:0]            p67_req;
wire [1:0][SDR_AW:1]  p67_addr;
wire [1:0]            p67_ack;
wire [1:0][63:0]      p67_dout;
wire [NPORTS-1:0]       p_ack_bus;
wire [NPORTS-1:0][63:0] p_dout_bus;
wire              p0_ack  = p_ack_bus[0];
wire [63:0]       p0_dout = p_dout_bus[0];
wire              p1_ack  = p_ack_bus[1];
wire [63:0]       p1_dout = p_dout_bus[1];
wire              p2_ack  = p_ack_bus[2];
wire [63:0]       p2_dout = p_dout_bus[2];
wire              p3_ack  = p_ack_bus[3];
wire [63:0]       p3_dout = p_dout_bus[3];
wire              p4_ack  = p_ack_bus[4];
wire [63:0]       p4_dout = p_dout_bus[4];
wire              p5_ack  = p_ack_bus[5];
wire [63:0]       p5_dout = p_dout_bus[5];
assign p67_ack  = {p_ack_bus[7],  p_ack_bus[6]};
assign p67_dout = {p_dout_bus[7], p_dout_bus[6]};

wire sd_dq_oe;
wire [15:0] sd_dq_o;
assign SDRAM_DQ  = sd_dq_oe ? sd_dq_o : 16'bZ;
// The device is clocked on the inverse of the controller clock. That is why
// the capture-depth default differs between the model and the board, and why
// the OSD exposes the setting at all — see kaneko_sdram.sv.
assign SDRAM_CLK = ~clk_sdram;

// Declared above the controller because its port gating uses rom_loaded.
wire rom_loaded, ldr_overflow;

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

	// NOBODY READS SDRAM UNTIL THE ROM IS IN IT.
	//
	// Every reader — four tile layers, the CPU, the OKI and two sprite ports —
	// runs from power-up, so during the ROM download eight ports hammer the
	// controller while the loader tries to write. The write is prioritised over
	// reads but only when the pipeline is free, and with eight readers that
	// window closes. The download then crawls or stalls, `rom_loaded` never
	// asserts, the 68000 stays in reset, the palette stays zero and the screen
	// is black with every debug counter dead.
	//
	// It was latent at seven ports and tipped over at eight. There is nothing
	// to read before the ROM is there — the data would be garbage — so the
	// readers are simply held off. Requesters hold `req` until acknowledged and
	// the controller latches on its rising edge, so masking here parks them and
	// they resume the moment it lifts.
	//
	// The boot harness has carried a `video_idle` input for exactly this since
	// it was written. The core never had the equivalent.
	.p_req  (rom_loaded ? {p67_req, p5_req, p4_req, p3_req, p2_req, p1_req, p0_req}
	                    : 8'b0),
	.p_addr ({p67_addr, p5_addr, p4_addr, p3_addr, p2_addr, p1_addr, p0_addr}),
	.p_din  ({8{16'd0}}),
	.p_be   ({8{2'b11}}),
	.p_we   (8'b0),
	.p_ack  (p_ack_bus),
	.p_dout (p_dout_bus)
);


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
wire [2:0]  cpu_fc;
wire [2:0]  cpu_ipl_n;
wire        cpu_vpa_n, cpu_iack;

fx68k u_cpu
(
	.clk(clk_sys), .HALTn(1'b1),
	.extReset(cpu_rst), .pwrUp(cpu_rst),
	.enPhi1(enPhi1), .enPhi2(enPhi2),
	.eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
	.E(), .VMAn(), .FC0(cpu_fc[0]), .FC1(cpu_fc[1]), .FC2(cpu_fc[2]),
	.BGn(), .oRESETn(), .oHALTEDn(),
	.DTACKn(DTACKn), .VPAn(cpu_vpa_n), .BERRn(1'b1),
	.BRn(1'b1), .BGACKn(1'b1),
	.IPL0n(cpu_ipl_n[0]), .IPL1n(cpu_ipl_n[1]), .IPL2n(cpu_ipl_n[2]),
	.iEdb(iEdb), .oEdb(oEdb), .eab(eab)
);

wire        vram0_we, vram1_we, spr_we, pal_we;
wire        ym0_we, ym1_we, eeprom_we, oki_we;
wire [7:0]  oki_din, oki_dout;
wire [3:0]  ym_addr;
wire [7:0]  ym_din, eeprom_din;
wire        v2r0_we, v2r1_we, sprreg_we;
wire [12:0] vmem_addr;
wire [15:0] vmem_din;
wire [3:0]  reg_addr;
wire [15:0] reg_din;
wire [15:0] q_vram0, q_vram1, q_spr, q_pal;
wire [15:0] q_v2r0, q_v2r1, q_sprreg;

// VIEW2 video-side ports: a tile entry {code, attr} and a scroll word per
// layer, per chip.
wire [9:0]  c0_t0_addr, c0_t1_addr, c1_t0_addr, c1_t1_addr;
wire [31:0] c0_t0_q,    c0_t1_q,    c1_t0_q,    c1_t1_q;
wire [10:0] c0_s0_addr, c0_s1_addr, c1_s0_addr, c1_s1_addr;
wire [15:0] c0_s0_q,    c0_s1_q,    c1_s0_q,    c1_s1_q;
wire [255:0] v2r0_flat, v2r1_flat, sprreg_flat;
wire        unmapped_hit;

kaneko_bus #(.SDR_AW(SDR_AW), .ROM_BASE(25'd0)) u_bus
(
	.clk(clk_sys), .rst(cpu_rst),
	.eab(eab), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .eRWn(eRWn),
	.oEdb(oEdb), .iEdb(iEdb), .DTACKn(DTACKn), .cpu_space(cpu_iack),

	.rom_req(p1_req), .rom_addr(p1_addr), .rom_ack(p1_ack), .rom_dout(p1_dout),

	.vram0_we(vram0_we), .vram1_we(vram1_we), .spr_we(spr_we), .pal_we(pal_we),
	.vmem_addr(vmem_addr), .vmem_din(vmem_din),
	.vram0_q(q_vram0), .vram1_q(q_vram1), .spr_q(q_spr), .pal_q(q_pal),

	.ym0_we(ym0_we), .ym1_we(ym1_we), .ym_addr(ym_addr), .ym_din(ym_din),
	.ym0_q(ym0_q), .ym1_q(ym1_q),
	.eeprom_we(eeprom_we), .eeprom_din(eeprom_din),
	.oki_we(oki_we), .oki_din(oki_din), .oki_dout(oki_dout),

	.v2r0_we(v2r0_we), .v2r1_we(v2r1_we), .sprreg_we(sprreg_we),
	.reg_addr(reg_addr), .reg_din(reg_din),
	.v2r0_q(q_v2r0), .v2r1_q(q_v2r1), .sprreg_q(q_sprreg),

	// Nothing pressed. The EEPROM is not implemented yet, so anything the game
	// reads from it comes back as an unwritten device.
	.in_p1(in_p1), .in_p2(in_p2),
	.in_system(in_system), .in_unk(16'hffff),

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
	.c0_t0_addr(c0_t0_addr), .c0_t0_q(c0_t0_q),
	.c0_t1_addr(c0_t1_addr), .c0_t1_q(c0_t1_q),
	.c0_s0_addr(c0_s0_addr), .c0_s0_q(c0_s0_q),
	.c0_s1_addr(c0_s1_addr), .c0_s1_q(c0_s1_q),
	.c1_t0_addr(c1_t0_addr), .c1_t0_q(c1_t0_q),
	.c1_t1_addr(c1_t1_addr), .c1_t1_q(c1_t1_q),
	.c1_s0_addr(c1_s0_addr), .c1_s0_q(c1_s0_q),
	.c1_s1_addr(c1_s1_addr), .c1_s1_q(c1_s1_q),
	.spr_addr(spr_ram_addr), .spr_q(spr_ram_q),
	.pal_addr(pal_rd_addr), .pal_q(pal_rd_q)
);

// ------------------------------------------------------------- sound / EEPROM
//
// Two YM2149s at 12 MHz / 6, "verified on pcb". Only their register files
// matter today — the sound outputs are not connected yet — but they cannot be
// stubbed, because the EEPROM hangs off chip 1's ports:
//
//     CS   YM2149 #1 port B, written at 40021e
//     DO   YM2149 #1 port A, read at 40021c
//
// and the CLK/DI half arrives separately at d00001. The game reads real data
// back out during boot and will not finish its self-test without it.
//
// jt49 rather than a hand-rolled register file: it already models the port
// direction bits and the per-register read masks, and it is the sound chip this
// core will use anyway.
reg [4:0] ym_div;
always @(posedge clk_sys) ym_div <= (ym_div == 5'd23) ? 5'd0 : ym_div + 5'd1;
wire ym_cen = (ym_div == 5'd0);        // 48 MHz / 24 = 2 MHz

// oki1: byte 0x4c0000 on explbrkr, 0x500000 on mgcrystl (its kan_spr is
// larger). Word addresses.
wire [SDR_AW:1] OKI_BASE = mg ? SDR_AW'(25'h280000) : SDR_AW'(25'h260000);

wire [7:0] ym0_q, ym1_q;
wire [7:0] ym0_iob_out;
wire [9:0] ym0_snd, ym1_snd;

// Two 10-bit unsigned levels summed to 11 bits, then shifted up to fill the
// framework's 16-bit sample. Both chips are routed to the same speaker at the
// same gain in MAME (add_route(ALL_OUTPUTS, "mono", 0.5) each), so a plain sum
// is the right mix and the 0.5 is just MAME avoiding clipping its own bus.
wire [10:0] ym_sum = {1'b0, ym0_snd} + {1'b0, ym1_snd};

// Both parts made signed before mixing. jt49's level is unsigned around a
// midpoint; jt6295's sample is already signed. AUDIO_S is 1 accordingly.
wire signed [11:0] ym_ctr = $signed({1'b0, ym_sum}) - 12'sd1024;
wire signed [16:0] snd_mix = {{3{ym_ctr[11]}}, ym_ctr, 2'd0}      // YM, scaled
                           + {{3{oki_snd[13]}}, oki_snd};         // OKI
wire [15:0] ym_mix = snd_mix[16:1];
wire [7:0] ym1_ioa_in = {7'h7f, eeprom_do};
wire [7:0] ym1_iob_out;

jt49 u_ym0
(
	.rst_n(~cpu_rst), .clk(clk_sys), .clk_en(ym_cen),
	.addr(ym_addr), .cs_n(~ym0_we), .wr_n(~ym0_we), .din(ym_din),
	.sel(1'b1), .dout(ym0_q),
	.sound(ym0_snd), .A(), .B(), .C(), .sample(),
	.IOA_in(8'hff), .IOA_out(), .IOA_oe(),
	.IOB_in(8'hff), .IOB_out(ym0_iob_out), .IOB_oe()
);

jt49 u_ym1
(
	.rst_n(~cpu_rst), .clk(clk_sys), .clk_en(ym_cen),
	.addr(ym_addr), .cs_n(~ym1_we), .wr_n(~ym1_we), .din(ym_din),
	.sel(1'b1), .dout(ym1_q),
	.sound(ym1_snd), .A(), .B(), .C(), .sample(),
	.IOA_in(ym1_ioa_in), .IOA_out(), .IOA_oe(),
	.IOB_in(8'hff), .IOB_out(ym1_iob_out), .IOB_oe()
);

// eeprom_w at d00001 carries clk and di; they are held between writes, so they
// are latched rather than pulsed.
reg [7:0] eeprom_ctl;
always @(posedge clk_sys) begin
	if (cpu_rst)        eeprom_ctl <= 8'd0;
	else if (eeprom_we) eeprom_ctl <= eeprom_din;
end

wire eeprom_do;
kaneko_eeprom93c46 u_eeprom
(
	.clk(clk_sys), .rst(rst_por),
	// MAME passes the whole port B byte to cs_write(), so any bit asserts it.
	.cs(|ym1_iob_out),
	.sk(eeprom_ctl[0]), .di(eeprom_ctl[1]),
	.do_out(eeprom_do),
	.bk_addr(bk_addr), .bk_din(bk_din), .bk_we(bk_we), .bk_q(bk_q),
	.dirty(bk_dirty), .dirty_clr(bk_dirty_clr),
	.dbg_state(), .dbg_busy(), .dbg_wen(), .dbg_cmd(), .dbg_cmd_valid()
);

// --------------------------------------------------------------- OKI M6295
//
// This is the whole soundtrack. The YM2149s are wired up and audible in
// principle, but explbrkr sets all their channel volumes to zero at frame 229
// and never raises them — it uses those chips for the EEPROM's port pins and
// nothing else. Everything you hear is samples from here.
//
// 12 MHz / 6 = 2 MHz with PIN7 high, so the same clock enable the YM2149s use.
// jt6295 documents cen as 1 MHz; at 2 MHz every rate doubles and the sample
// rate lands on 2 MHz / 132 = 15.15 kHz, which is what MAME runs.
wire [17:0] oki_rom_addr;
wire [7:0]  oki_rom_data;
wire [0:0]  oki_rom_ok;
wire signed [13:0] oki_snd;

// Bank switching: chip 0's port B drives oki_bank0_w<7>, and the OKI's window
// is laid out by common_oki_bank_install(0, 0x20000, 0x20000):
//
//   0x00000-0x1ffff   fixed, the first 128 KB of the region
//   0x20000-0x3ffff   bank b at region offset 0x20000 * (b + 1)
//
// Bank 7 aliases bank 6 — MAME fills the entries past max_bank with the last
// block, because the ROM is 1 MB and only seven banked windows fit above the
// fixed one.
// MAX_BANK follows from the oki1 region length and is a per-game fact — see
// the note in kaneko_oki_bank.sv. Explosive Breaker carries 1 MB of samples,
// so (0x100000 - 0x20000) / 0x20000 = 7. It moves to the game table with
// everything else that differs across the driver.
wire [23:0] oki_region_addr;
kaneko_oki_bank #(.MAX_BANK(7)) u_okibank
(
	.chip_addr(oki_rom_addr),
	.bank(ym0_iob_out[2:0]),
	.region_addr(oki_region_addr)
);

// One byte port from SDRAM, the same feeder the tile layers use. The OKI reads
// a nibble per sample at 15 kHz across four channels — a few tens of kB a
// second, against the tile path's tens of megabytes.
kaneko_tilerom #(.NREQ(1), .SDR_AW(SDR_AW)) u_okirom
(
	.clk(clk_sys), .rst(rst_sys),
	.req_addr(oki_region_addr),
	.base_addr(OKI_BASE),
	.req_data(oki_rom_data),
	.port_ready(oki_rom_ok),
	.sdr_req(p5_req), .sdr_addr(p5_addr),
	.sdr_ack(p5_ack), .sdr_dout(p5_dout)
);

jt6295 u_oki
(
	.rst(rst_sys), .clk(clk_sys), .cen(ym_cen),
	.ss(1'b1),                       // PIN7_HIGH: divide by 132
	.wrn(~oki_we), .din(oki_din), .dout(oki_dout),
	.rom_addr(oki_rom_addr), .rom_data(oki_rom_data), .rom_ok(oki_rom_ok[0]),
	.sound(oki_snd), .sample()
);

// VIEW2 and VU-002 register banks. These decoded but stored nothing until now:
// kaneko_bus raised a write strobe that went nowhere and read back a hardwired
// zero. Harmless while nothing consumed them — every register access explbrkr
// makes in its first 300,000 bus cycles is a write — and necessary the moment
// the pixel path needs the scroll values.
kaneko_regs16 u_v2r0
(
	.clk(clk_sys), .we(v2r0_we), .addr(reg_addr), .din(reg_din),
	.uds(~UDSn), .lds(~LDSn),
	.rd_addr(reg_addr), .rd_q(q_v2r0), .regs_flat(v2r0_flat)
);

kaneko_regs16 u_v2r1
(
	.clk(clk_sys), .we(v2r1_we), .addr(reg_addr), .din(reg_din),
	.uds(~UDSn), .lds(~LDSn),
	.rd_addr(reg_addr), .rd_q(q_v2r1), .regs_flat(v2r1_flat)
);

kaneko_regs16 u_sprreg
(
	.clk(clk_sys), .we(sprreg_we), .addr(reg_addr), .din(reg_din),
	.uds(~UDSn), .lds(~LDSn),
	.rd_addr(reg_addr), .rd_q(q_sprreg), .regs_flat(sprreg_flat)
);

// Scanline interrupts. vcnt comes from the video timing below; the reference
// is kaneko16_state::interrupt and the numbers are its raw vpos values.
kaneko_irq u_irq
(
	.clk(clk_sys), .rst(cpu_rst),
	.vcnt(vcnt),
	.fc(cpu_fc), .as(~ASn), .a_level(eab[3:1]),
	.ipl_n(cpu_ipl_n), .vpa_n(cpu_vpa_n), .iack(cpu_iack)
);

// Interrupts acknowledged per frame. Zero while the game masks — explbrkr does
// so for its first few seconds of self-test — then three every frame: IRQ5 at
// scanline 224, IRQ3 at 144, IRQ4 at 64.
//
// This is on screen because simulation cannot cheaply reach the point where the
// game unmasks, and `make boot` can only force level 7 to prove the
// acknowledge wiring. Whether the game actually gets there, with our stubbed
// inputs and no EEPROM, is a question only the board answers.
reg [15:0] irq_cnt, irq_cnt_lat;
reg        iack_d;
always @(posedge clk_sys) begin
	iack_d <= cpu_iack;
	if (vbl_rise) begin irq_cnt_lat <= irq_cnt; irq_cnt <= 16'd0; end
	else if (cpu_iack && !iack_d) irq_cnt <= irq_cnt + 16'd1;
end

// OKI TELEMETRY: where does the sound path stop?
//
// The YM2149s are correctly silent (the game zeroes their volumes) and the OKI
// makes no sound either, so the question is which link is broken. Four
// counters, one per link, beat another round of reading the datasheet.
//
// sim/sound/tb_kaneko_oki.cpp drives jt6295 with the exact bytes the CPU is
// seen to write (08, 88, 13 — stop channel 0, select phrase 8, play it) and
// the chip starts a channel and produces samples. So every link below is
// known good against an ideal sample ROM, and whichever row goes dark on
// hardware is the one the model does not capture.
reg [15:0] oki_wr_cnt, oki_wr_lat;
reg [15:0] oki_ok_cnt, oki_ok_lat;
reg [15:0] oki_busy_cnt, oki_busy_lat;
reg [15:0] oki_snd_cnt, oki_snd_lat;
reg        oki_ok_d;
always @(posedge clk_sys) begin
	oki_ok_d <= oki_rom_ok[0];
	if (rst_sys) begin
		oki_wr_cnt <= 0; oki_ok_cnt <= 0; oki_busy_cnt <= 0; oki_snd_cnt <= 0;
	end else if (vbl_rise) begin
		oki_wr_lat   <= oki_wr_cnt;   oki_wr_cnt   <= 0;
		oki_ok_lat   <= oki_ok_cnt;   oki_ok_cnt   <= 0;
		oki_busy_lat <= oki_busy_cnt; oki_busy_cnt <= 0;
		oki_snd_lat  <= oki_snd_cnt;  oki_snd_cnt  <= 0;
	end else begin
		if (oki_we)                        oki_wr_cnt   <= oki_wr_cnt   + 1'd1;
		if (oki_rom_ok[0] && !oki_ok_d)    oki_ok_cnt   <= oki_ok_cnt   + 1'd1;
		// dout's low nibble is the per-channel busy flag — the same byte the
		// game polls at 400401 and keeps reading back as zero.
		if (oki_dout[3:0] != 4'd0)         oki_busy_cnt <= oki_busy_cnt + 1'd1;
		if (oki_snd != 14'sd0)             oki_snd_cnt  <= oki_snd_cnt  + 1'd1;
	end
end

// The subsystem counts overruns continuously; the overlay wants a per-frame
// value like every other row, so latch and clear it at the frame boundary.
reg [15:0] spr_overrun_lat, spr_overrun_prev;
always @(posedge clk_sys) begin
	if (rst_sys) begin
		spr_overrun_lat <= 16'd0; spr_overrun_prev <= 16'd0;
	end else if (vbl_rise) begin
		spr_overrun_lat  <= spr_overrun - spr_overrun_prev;
		spr_overrun_prev <= spr_overrun;
	end
end

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

// Which view the OSD is showing. Declared here because the tilewall's SDRAM
// requests are gated on it — see the note at its instantiation.
wire show_game = ~status[9];

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

// The tile contact sheet is gone. It found the SDRAM byte order, the burst
// addressing and the loader during bring-up, and then caused two problems of
// its own: it kept fetching behind the game view and took half the bus, and its
// SDRAM port is worth more to the tile feeder than its picture is to anyone. A
// debug aid that outlives its usefulness becomes a liability.

// ------------------------------------------------------------- game video
//
// Four tile layers, fetched a line ahead and mixed. In MAME's draw order:
// chip0 layer 0, chip0 layer 1, chip1 layer 0, chip1 layer 1.
//
// THE NUMBERING RUNS OPPOSITE TO THE BYTE ORDER, EVERYWHERE
//
// Layer 0 takes registers 2/3, VRAM at 0x1000, scroll at 0x3000 and control
// bits 12/11. Layer 1 takes registers 0/1, VRAM at 0x0000, scroll at 0x2000
// and bits 4/3. So the FIRST register pair, the FIRST VRAM block and the FIRST
// scroll block all belong to layer 1, while the HIGHER control bits belong to
// layer 0. Four independent chances to wire a layer to the wrong memory and
// get a picture that looks plausible — see docs/findings.md.
//
// Scroll Y is shifted down by six inside the address engine; scroll X is not,
// because line scroll is added before the shift.

// PER-GAME, and this belongs in a configuration table before a second game
// runs (rule 9). explbrkr: set_offset(0x5b, -0x8, 256, 240), m_view2_2_pri set,
// sprite priorities {8,8,8,8}, tile colour base 0x400.
localparam signed [10:0] V2_DX = 11'sd91;      // 0x5b
localparam signed [10:0] V2_DY = -11'sd8;
localparam [10:0] TILE_COLBASE = 11'h400;


// Sprites, per game (hard rule 9). These are explbrkr's, read from
// bakubrkr(machine_config) and the frame gate's table, which is pixel-exact on
// three games:
//
//   KANEKO_VU002_SPRITE, set_priorities(8,8,8,8), set_color_base(0)
//   no set_offsets() call, so both offsets are 0
//   fliptype 0 (the VU-002 default; bakubrkr does not override it)
//   set_size(256,256), set_visarea(0, 255, 16, 239)
//
// Blaze On's board parses 512 records and carries a large X offset; Wing Force
// is 320 wide. Both move here when the game table lands.
localparam [10:0] SPR_COUNT     = 11'd1024;
localparam [15:0] SPR_XOFFS     = 16'd0;
localparam [15:0] SPR_YOFFS     = 16'd0;
localparam [8:0]  SPR_VIS_MIN_Y = 9'd16;
localparam        SPR_WIDE      = 1'b0;      // screen width is 0x100, not > 0x100
localparam        SPR_FLIPTYPE  = 1'b0;
localparam [10:0] SPR_COLBASE   = 11'd0;
// kan_spr @ byte 0x280000 on both, so word 0x140000.
wire [SDR_AW:1] SPR_BASE  = SDR_AW'(25'h140000);

// Tile ROM regions, as word addresses in SDRAM (D6, SDRAM_MAP):
//   view2_0 at byte 0x080000, view2_1 at byte 0x180000.
// REGION BASES ARE PER GAME, AND EXPLOSIVE BREAKER'S ARE FROZEN.
//
// One shared layout meant making room for an unimplemented game moved every
// region, which changed a working game's MRA and broke it. Each game has its
// own MRA and its own row here, so they do not share offsets and a new game
// cannot disturb an existing one.
//
// The explbrkr column is a FIXED CONTRACT: it is what its shipped MRA already
// uses. It does not change to tidy it, align it, or make room. Word addresses,
// so half the byte offset in tools/build_rom_regions.py.
//
//                     explbrkr    mgcrystl
//   view2_0           0x080000    0x080000
//   view2_1           0x180000    0x180000
//   kan_spr           0x280000    0x280000
//   oki1              0x4c0000    0x500000
wire [SDR_AW:1] TROM0_BASE = SDR_AW'(25'h040000);
wire [SDR_AW:1] TROM1_BASE = SDR_AW'(25'h0c0000);

wire [15:0] c0r0 = v2r0_flat[ 0*16 +: 16];
wire [15:0] c0r1 = v2r0_flat[ 1*16 +: 16];
wire [15:0] c0r2 = v2r0_flat[ 2*16 +: 16];
wire [15:0] c0r3 = v2r0_flat[ 3*16 +: 16];
wire [15:0] c0r4 = v2r0_flat[ 4*16 +: 16];
wire [15:0] c1r0 = v2r1_flat[ 0*16 +: 16];
wire [15:0] c1r1 = v2r1_flat[ 1*16 +: 16];
wire [15:0] c1r2 = v2r1_flat[ 2*16 +: 16];
wire [15:0] c1r3 = v2r1_flat[ 3*16 +: 16];
wire [15:0] c1r4 = v2r1_flat[ 4*16 +: 16];

// Enables are ACTIVE LOW in the register.
wire [3:0] lay_en_live = { ~c1r4[4], ~c1r4[12], ~c0r4[4], ~c0r4[12] };
wire [3:0] lay_ls_live = {  c1r4[3],  c1r4[11],  c0r4[3],  c0r4[11] };

wire [63:0] lay_sx_live = { c1r0, c1r2, c0r0, c0r2 };  // L1 reg0, L0 reg2
wire [63:0] lay_sy_live = { c1r1, c1r3, c0r1, c0r3 };

// LATCHED ONCE PER FRAME, AS MAME DOES
//
// kaneko_tmap.cpp reads these in prepare_common(), which runs once before the
// frame is rendered. Reading them live instead lets a scroll register the IRQ
// handler updates mid-frame apply to only part of the screen — and because the
// line fetch spans about 1800 clocks, not even a whole line is guaranteed to
// use one value. That is horizontal tearing, and it is exactly what the board
// does not do.
//
// Latched at the start of the visible area rather than at vblank so the frame
// being drawn uses the values the game set for it.
reg vb_d;
always @(posedge clk_sys) vb_d <= vb;
wire frame_start = vb_d && !vb;

reg [3:0]  lay_en, lay_ls;
reg [63:0] lay_sx, lay_sy;
always @(posedge clk_sys) begin
	if (rst_sys) begin
		lay_en <= 4'd0; lay_ls <= 4'd0; lay_sx <= 64'd0; lay_sy <= 64'd0;
	end else if (frame_start) begin
		lay_en <= lay_en_live;
		lay_ls <= lay_ls_live;
		lay_sx <= lay_sx_live;
		lay_sy <= lay_sy_live;
	end
end

// Layer 1's dx is two further along than layer 0's: MAME sets scrolldx to
// -(m_dx + 2) for tmap[1].
wire [43:0] lay_dx = { 11'(V2_DX + 11'sd2), 11'(V2_DX),
                       11'(V2_DX + 11'sd2), 11'(V2_DX) };
wire [43:0] lay_dy = { 11'(V2_DY), 11'(V2_DY), 11'(V2_DY), 11'(V2_DY) };

// ------------------------------------------------------- tile ROM feeder
wire [95:0] trom_addr_f;
wire [31:0] trom_data_f;
wire [3:0]  trom_ready;
wire [SDR_AW*4-1:0] trom_base_f = { TROM1_BASE, TROM1_BASE,
                                    TROM0_BASE, TROM0_BASE };

kaneko_tilerom #(.NREQ(4), .SDR_AW(SDR_AW)) u_trom
(
	.clk(clk_sys), .rst(rst_sys),
	.req_addr(trom_addr_f),
	.base_addr(trom_base_f),
	.req_data(trom_data_f),
	.port_ready(trom_ready),
	// One port per layer. p1 is the 68000; the rest are the tile feeder's.
	.sdr_req({p4_req, p3_req, p2_req, p0_req}),
	.sdr_addr({p4_addr, p3_addr, p2_addr, p0_addr}),
	.sdr_ack({p4_ack, p3_ack, p2_ack, p0_ack}),
	.sdr_dout({p4_dout, p3_dout, p2_dout, p0_dout})
);

// ---------------------------------------------------------- line fetch
// Started at the top of every line for the NEXT one, so the display always
// reads a finished bank.
wire line_start = ce_pix && (hcnt == 10'd0);

wire [35:0]  ln_scr_addr;
wire [63:0]  ln_scr_data;
wire [39:0]  ln_vram_addr;
wire [127:0] ln_vram_data;

// LINE OVERRUN: did the fetch finish before the line was needed?
//
// Two wrong guesses at the tearing — the scroll registers, then the tilewall
// stealing the bus — both plausible and neither settled by looking. This is
// the measurement that separates "the feeder cannot keep up" from everything
// else: if the line fetch is still running when the next line starts, the
// buffer being displayed is stale or half-written, and no amount of reasoning
// about scroll values matters.
//
// Zero means look elsewhere. Non-zero means bandwidth, and the count says how
// far short.
wire line_busy;
reg [15:0] overrun_cnt, overrun_lat;
always @(posedge clk_sys) begin
	if (rst_sys) begin
		overrun_cnt <= 16'd0; overrun_lat <= 16'd0;
	end else if (vbl_rise) begin
		overrun_lat <= overrun_cnt;
		overrun_cnt <= 16'd0;
	end else if (line_start && line_busy) begin
		overrun_cnt <= overrun_cnt + 16'd1;
	end
end

wire [3:0]  mix_solid;
wire [11:0] mix_cat;
wire [23:0] mix_colour;
wire [15:0] mix_pix;

kaneko_tmap_line #(.H_VIS(256)) u_line
(
	.clk(clk_sys), .rst(rst_sys),
	.start(line_start), .line_y(screen_y + 9'd1), .busy(line_busy),

	.layer_en(lay_en), .dx_f(lay_dx), .dy_f(lay_dy),
	.scroll_x_f(lay_sx), .scroll_y_f(lay_sy), .linescroll_en(lay_ls),

	.scr_addr_f(ln_scr_addr),   .scr_data_f(ln_scr_data),
	.vram_addr_f(ln_vram_addr), .vram_data_f(ln_vram_data),
	.rom_addr_f(trom_addr_f),   .rom_data_f(trom_data_f),
	.rom_ready(trom_ready),

	.rd_x(screen_x),
	.out_solid(mix_solid), .out_cat_f(mix_cat),
	.out_colour_f(mix_colour), .out_pix_f(mix_pix)
);

// Video-side memory ports. Layer order is c0L0, c0L1, c1L0, c1L1.
assign c0_t0_addr = ln_vram_addr[ 0 +: 10];
assign c0_t1_addr = ln_vram_addr[10 +: 10];
assign c1_t0_addr = ln_vram_addr[20 +: 10];
assign c1_t1_addr = ln_vram_addr[30 +: 10];
assign ln_vram_data = { c1_t1_q, c1_t0_q, c0_t1_q, c0_t0_q };

assign c0_s0_addr = {2'b00, ln_scr_addr[ 0 +: 9]};
assign c0_s1_addr = {2'b00, ln_scr_addr[ 9 +: 9]};
assign c1_s0_addr = {2'b00, ln_scr_addr[18 +: 9]};
assign c1_s1_addr = {2'b00, ln_scr_addr[27 +: 9]};
assign ln_scr_data = { c1_s1_q, c1_s0_q, c0_s1_q, c0_s0_q };

// VU-002 "keep sprites on screen". MAME:
//
//     case 0:
//         if (ACCESSING_BITS_0_7) {
//             m_sprite_flipx = BIT(new_data, 1);
//             m_sprite_flipy = BIT(new_data, 0);
//             if (get_sprite_type() == 0)
//                 m_keep_sprites = BIT(~new_data, 2);
//         }
//
// Held in its own register rather than read out of the register file, because
// MAME only updates it on a write to register 0's LOW byte and starts it
// false. Deriving it from the stored register instead would make it true at
// power-up, when the file reads zero and the inversion turns that into "keep".
reg keep_sprites;
always @(posedge clk_sys) begin
	if (rst_sys)
		keep_sprites <= 1'b0;
	else if (sprreg_we && (reg_addr == 4'd0) && ~LDSn)
		keep_sprites <= ~reg_din[2];
end

// ------------------------------------------------------------- sprites
// The sprite surface is indexed in MAME's screen coordinates, where the
// visible area starts at visarea().min_y — the parser folds that offset into
// every record, and the frame gate composites with `sy = VIS_MIN_Y + row`. Our
// screen_y counts visible lines from 0, so the surface is read 16 lines down.
//
// Presented with the same screen_x that kaneko_tmap_line's line buffer is
// read at: both are registered reads, so both pixels arrive together and the
// mixer sees a consistent set.
wire [13:0] spr_pix;
wire [1:0]  spr_prio;
wire        spr_busy;
wire [15:0] spr_overrun;
wire [11:0] spr_ram_addr;
wire [15:0] spr_ram_q;
// screen_y is ALREADY in MAME's coordinate space — kaneko_video_timing
// documents it as "V_START .. V_START+V_VIS-1, the RAW scanline", so it runs
// 16..239 and not 0..223. The sprite surface is indexed the same way, because
// the parser folds visarea().min_y into every record. Adding the offset again
// here shifted every sprite 16 lines, which is a sixteenth of the screen.

// The surface is 320 wide because the Blaze On board is, and one bitstream
// serves every game — Explosive Breaker simply uses 256 columns of it. 320 is
// not a power of two, so the address is y*320 + x; rounding up to 512 would
// not fit in 553 M10K beside everything else.
// SPRITES OFF, AS A DIAGNOSTIC.
//
// Explosive Breaker went black and simulation clears every change made since
// it last worked — including a boot on all eight ports with the real sprite
// subsystem competing for the bus. What simulation does NOT have is the four
// tile layers fetching at the same time, so the one thing it cannot rule out
// is total SDRAM load.
//
// Held in reset, the subsystem makes no requests at all and its two ports go
// quiet, which takes the design back to six active requesters. Combined with
// forcing the sprite pixel transparent, this answers in one build whether the
// fault is anywhere in the sprite path — bus load or pixel path — instead of
// bisecting six commits at twenty minutes each.
wire spr_off = status[16];

kaneko_spr_sys #(
	.BMP_W(320), .BMP_H(256), .SPRITES(1024), .SDR_AW(SDR_AW)
) u_spr
(
	.clk(clk_sys), .rst(rst_sys | spr_off),
	.frame_start(vbl_rise),
	.keep_sprites(keep_sprites),
	.skip_en(~status[15]),

	.sprite_count(SPR_COUNT),
	.sprite_xoffs(SPR_XOFFS), .sprite_yoffs(SPR_YOFFS),
	.visarea_min_y(SPR_VIS_MIN_Y),
	.wide_screen(SPR_WIDE), .fliptype(SPR_FLIPTYPE),
	// MAME clips sprite drawing to the visible area.
	.clip_x0(10'd0), .clip_x1(10'd255),
	.clip_y0(10'd16), .clip_y1(10'd239),

	.ram_addr(spr_ram_addr), .ram_data(spr_ram_q),
	.regs_flat(sprreg_flat),

	.rom_base(SPR_BASE),
	.sdr_req(p67_req), .sdr_addr(p67_addr),
	.sdr_ack(p67_ack), .sdr_dout(p67_dout),

	.rd_x(10'(screen_x)), .rd_y(10'(screen_y)),
	.spr_pix(spr_pix), .spr_prio(spr_prio),

	.busy(spr_busy), .overrun(spr_overrun)
);

// --------------------------------------------------------------- mixer
wire [10:0] mix_pen;

kaneko_mixer u_mix
(
	.layer_solid(mix_solid),
	.layer_cat_f(mix_cat),
	.layer_colour_f(mix_colour),
	.layer_pix_f(mix_pix),

	.spr_pix(spr_off ? 14'd0 : spr_pix),
	.spr_prio(spr_off ? 2'd0  : spr_prio),

	.view2_2_pri(VIEW2_2_PRI),
	.spr_pri_f(SPR_PRI_SEL),
	.tile_colbase(TILE_COLBASE),
	.spr_colbase(SPR_COLBASE),

	.pen(mix_pen), .prio_out(), .sprite_won()
);

// --------------------------------------------------------------- inputs
// Everything on this board is ACTIVE LOW, and the ports are read as words at
// e00000-e00007. Read from INPUT_PORTS_START(bakubrkr), not guessed:
//
//   e00000 P1      bit 0    flip screen DIP        bit 8   P1 up
//                  bit 1    service DIP            bit 9   P1 down
//                  bits 2-7 unused DIPs            bit 10  P1 left
//                                                  bit 11  P1 right
//                                                  bit 12  P1 button 1
//                                                  bit 13  P1 button 2
//   e00002 P2      bits 8-13, the same for player 2; low byte unused
//   e00004 SYSTEM  bit 8  start 1     bit 12  service (no toggle)
//                  bit 9  start 2     bit 13  tilt (the game's pause)
//                  bit 10 coin 1      bit 14  service 1
//                  bit 11 coin 2      bit 15  unknown
//   e00006 UNK     unused on this board; MAME reads all ones
//
// The DIPs in P1's low byte are the only two this game has — everything else
// is configured in its test mode, which is why there is no DIP menu here.
//
// MiSTer joystick bit order is from the main firmware's own table
// (menu.cpp: joy_button_map): RIGHT, LEFT, DOWN, UP, A, B, X, Y, L, R,
// SELECT, START. The CONF_STR J1 names attach to bit 4 upwards, so Shot is A
// and Bomb is B; Start and Coin are named too AND accept the dedicated
// START/SELECT buttons, because players expect both to work.
//
// No "jn" line: this framework's firmware matches an UPPERCASE 'J' with 'D',
// 'A' or 'N' in the second position (user_io.cpp), so a lowercase "jn,..."
// is silently ignored rather than doing nothing visible but useful.
wire [15:0] joy = joystick_0 | joystick_1;   // either pad may work the menus

wire p1_right = joystick_0[0], p1_left = joystick_0[1];
wire p1_down  = joystick_0[2], p1_up   = joystick_0[3];
wire p1_b1    = joystick_0[4], p1_b2   = joystick_0[5];

wire p2_right = joystick_1[0], p2_left = joystick_1[1];
wire p2_down  = joystick_1[2], p2_up   = joystick_1[3];
wire p2_b1    = joystick_1[4], p2_b2   = joystick_1[5];

wire start1 = joystick_0[6] | joystick_0[11];
wire start2 = joystick_1[6] | joystick_1[11];
wire coin1  = joystick_0[7] | joystick_0[10];
wire coin2  = joystick_1[7] | joystick_1[10];
wire pause  = joy[8];
// SERVICE COIN, not the service switch. This board has three separate service
// inputs and conflating them is easy:
//
//   P1 bit 1     PORT_SERVICE_DIPLOC   a DIP SWITCH  -> OSD toggle below
//   SYSTEM b12   PORT_SERVICE_NO_TOGGLE  momentary test button, left unpressed
//   SYSTEM b14   IPT_SERVICE1          service COIN, momentary -> this button
//
// The switch is the one that gets you into the test menu and it belongs in the
// OSD, where it is. This is the credit-without-a-coin button, which is
// momentary by nature and cannot be a toggle.
wire svc_coin = joy[9];

// Flip screen and service are DIPs, not buttons: held, and off by default.
// Active low, so 1 is "not set".
wire dip_flip    = ~status[13];
wire dip_service = ~status[14];

wire [15:0] in_p1 = { 2'b11, ~p1_b2, ~p1_b1, ~p1_right, ~p1_left, ~p1_down, ~p1_up,
                      6'b111111, dip_service, dip_flip };
wire [15:0] in_p2 = { 2'b11, ~p2_b2, ~p2_b1, ~p2_right, ~p2_left, ~p2_down, ~p2_up,
                      8'hff };
wire [15:0] in_system = { 1'b1, ~svc_coin, ~pause, 1'b1,
                          ~coin2, ~coin1, ~start2, ~start1, 8'hff };

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

// One palette read port, two customers: the game path asks for the pen the
// mixer chose, the swatch view walks the whole table.
assign pal_rd_addr = show_game ? mix_pen : {sw_row, sw_col};

wire [7:0] pal_r = {pal_rd_q[9:5],   pal_rd_q[9:7]};
wire [7:0] pal_g = {pal_rd_q[14:10], pal_rd_q[14:12]};
wire [7:0] pal_b = {pal_rd_q[4:0],   pal_rd_q[4:2]};

// Bus cycles per frame, across the top, as twenty binary blocks — MSB left,
// green for a set bit, dark red for a clear one so the field itself is visible
// and "no readout at all" cannot be confused with "the count is zero".
//
// It was a bar of length `bus_cycles_lat >> 8`, which needs 256 cycles in a
// frame to light one pixel. The 68000 was managing four, so the bar rendered
// empty and looked exactly like a CPU held in reset. Two failures that want
// opposite fixes cannot share one indicator — rule 6: check the instrument
// could have seen it.
localparam int unsigned ALV_BIT_W = 8;
localparam int unsigned ALV_BITS  = 20;
localparam int unsigned IRQ_BITS  = 8;

// Row 0, green: bus cycles per frame, 20 bits.
wire in_alive_row = (screen_y >= 9'd16) && (screen_y < 9'(16 + 6))
                 && (screen_x < 9'(ALV_BITS * ALV_BIT_W));
wire [4:0] alive_bit = 5'(ALV_BITS - 1) - 5'(screen_x[8:3]);
wire       alive_set = bus_cycles_lat[alive_bit];

// Row 1, amber: interrupts acknowledged per frame, 8 bits. A different colour
// so the two readouts cannot be mistaken for one wide number.
wire in_irq_row = (screen_y >= 9'd24) && (screen_y < 9'(24 + 6))
               && (screen_x < 9'(IRQ_BITS * ALV_BIT_W));
wire [2:0] irq_bit = 3'(IRQ_BITS - 1) - 3'(screen_x[5:3]);
wire       irq_set = irq_cnt_lat[irq_bit];

// Rows 4-7, yellow: the OKI sound path, per frame, one row per link in the
// chain. Top to bottom:
//
//   4  CPU writes reaching the chip at 400401
//   5  sample-ROM fetches the feeder answered
//   6  clocks with a channel flagged busy — the chip accepted a play command
//   7  clocks where the chip produced a non-zero sample
//
// The first dark row is where the path breaks, and each one rules out
// everything above it. Yellow because magenta read too close to the cyan
// overrun row above it to tell apart on a photograph.
wire in_oki_row = (screen_y >= 9'd40) && (screen_y < 9'(40 + 24))
               && (screen_x < 9'(16 * ALV_BIT_W));
wire [3:0] oki_bit = 4'd15 - 4'(screen_x[6:3]);
wire [15:0] oki_row_val = (screen_y < 9'd46) ? oki_wr_lat
                        : (screen_y < 9'd52) ? oki_ok_lat
                        : (screen_y < 9'd58) ? oki_busy_lat
                                             : oki_snd_lat;
wire       oki_set = oki_row_val[oki_bit];

// Row 9, magenta: the RAW joystick word for pad 1, live — not a per-frame
// count like every other row. Set apart from the sprite row above it, which is
// in turn set apart from the four yellow sound rows: rows 4-7 are deliberately
// contiguous because they are one chain and read as a block, and anything that
// is NOT part of that chain has to be visibly separate or it looks like a
// fifth sound row. Bit 0 is at the RIGHT, so pressing the button
// mapped to A lights the fifth block from the right.
//
//   0 right  1 left  2 down  3 up  4 A  5 B  6 X  7 Y
//   8 L      9 R    10 select  11 start
//
// This exists because "there is no fire button" is not answerable from the
// RTL: the wiring matches MAME's INPUT_PORTS exactly, so the question is which
// bits the pad actually produces, and that is only visible here.
wire in_joy_row = (screen_y >= 9'd82) && (screen_y < 9'(82 + 6))
               && (screen_x < 9'(16 * ALV_BIT_W));
wire [3:0] joy_bit = 4'd15 - 4'(screen_x[6:3]);
wire       joy_set = joystick_0[joy_bit];

// Row 8, white: sprite passes that did not finish before the next frame
// started. Zero is correct. Non-zero means the renderer ran out of frame —
// 1024 sprites at one pixel per clock, each pixel able to miss a 2.25 MB
// sample of ROM, is the one part of the video path with no fixed upper bound.
wire in_spr_row = (screen_y >= 9'd72) && (screen_y < 9'(72 + 6))
               && (screen_x < 9'(16 * ALV_BIT_W));
wire [3:0] spr_bit = 4'd15 - 4'(screen_x[6:3]);
wire       spr_set = spr_overrun_lat[spr_bit];

// Row 2, cyan: line fetches that overran, per frame, 16 bits. All dark means
// the feeder is keeping up and the tearing is somewhere else entirely.
wire in_ovr_row = (screen_y >= 9'd32) && (screen_y < 9'(32 + 6))
               && (screen_x < 9'(16 * ALV_BIT_W));
wire [3:0] ovr_bit = 4'd15 - 4'(screen_x[6:3]);
wire       ovr_set = overrun_lat[ovr_bit];

// One column of every block left dark, so adjacent set bits stay countable.
//
// Off by default. The readouts are how the CPU and the interrupts were
// diagnosed and they stay in the build for the next time something stops, but
// they sit on top of the picture, so the picture wins unless asked otherwise.
wire dbg_on   = status[11];
wire in_dbg   = dbg_on && (in_alive_row || in_irq_row || in_ovr_row || in_oki_row
                           || in_spr_row || in_joy_row)
              && (screen_x[2:0] != 3'd7);
wire dbg_set  = in_alive_row ? alive_set : in_irq_row ? irq_set
              : in_ovr_row ? ovr_set : in_spr_row ? spr_set
              : in_joy_row ? joy_set : oki_set;

wire [7:0] dbg_r = dbg_set ? ((in_irq_row || in_oki_row || in_spr_row
                                || in_joy_row) ? 8'hff : 8'h00) : 8'h40;
wire [7:0] dbg_g = dbg_set ? (in_irq_row ? 8'hc0 : in_joy_row ? 8'h00 : 8'hff)
                           : 8'h00;
wire [7:0] dbg_b = dbg_set && (in_ovr_row || in_spr_row || in_joy_row)
                     ? 8'hff : 8'h00;

// The game picture and the palette swatches both come out of the palette RAM,
// so they share the same decode.
// Both remaining views come out of the palette RAM, so they share the decode
// and differ only in which address was asked for.
wire [7:0] src_r = pal_r;
wire [7:0] src_g = pal_g;
wire [7:0] src_b = pal_b;

wire [7:0] out_r = in_dbg ? dbg_r : src_r;
wire [7:0] out_g = in_dbg ? dbg_g : src_g;
wire [7:0] out_b = in_dbg ? 8'h00 : src_b;

// TWO CLOCKS OF READ LATENCY, AND THE SYNCS MOVE WITH IT
//
// The line buffer is a registered read and so is the palette, so a pixel's
// colour arrives two clocks after its x is presented. Delaying only the colour
// would shift the picture against the syncs by a quarter of a pixel and, worse,
// hand the framework the previous pixel on the CE_PIXEL it samples.
//
// Everything the framework looks at is delayed by the same two clocks instead,
// so the relationship between colour, blanking, syncs and the pixel strobe is
// exactly what the timing generator produced.
// The COLOUR IS NOT DELAYED. It already carries the two clocks — the line
// buffer read and the palette read are both registered — so delaying it again
// put it two clocks behind the syncs and the framework sampled the previous
// pixel. Only the syncs and the pixel strobe move.
reg [1:0] hs_d, vs_d, de_d, cep_d;
always @(posedge clk_sys) begin
	hs_d  <= {hs_d[0],  hs};
	vs_d  <= {vs_d[0],  vs};
	de_d  <= {de_d[0],  de};
	cep_d <= {cep_d[0], ce_pix};
end

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = cep_d[1];
assign VGA_DE    = de_d[1];
assign VGA_HS    = hs_d[1];
assign VGA_VS    = vs_d[1];
assign VGA_R     = out_r;
assign VGA_G     = out_g;
assign VGA_B     = out_b;

endmodule

`default_nettype wire
