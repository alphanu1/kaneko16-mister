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
// DDRAM is driven by screen_rotate at the bottom of this file. It was tied off
// while nothing used it; rotation writes each frame into DDR3 and lets the
// scaler read it back turned, which is how every vertical MiSTer arcade core
// does it. Note it is DDR3, NOT the core's SDRAM: the two are separate, so
// rotation costs nothing from the 37 spare M10K blocks or from the memory the
// sprite bitmap is destined for.

// Audio. Both YM2149s are mono into the cabinet's single speaker, so the two
// outputs are summed and sent to both channels. AUDIO_S = 0: jt49's `sound` is
// an unsigned 10-bit level, not a signed sample.
//
// The OKI M6295 is not connected yet; when it is, it mixes in here.
assign AUDIO_S   = 1;
// The Blaze On board's mix is a SEPARATE path, not a term added to the other
// one. Explosive Breaker's sound works on hardware and its mix stays bit for
// bit what it was; a board with no YM2149s must also not inherit the -1024 DC
// offset those chips contribute when present but silent.
assign AUDIO_L   = HAS_Z80 ? z80_mix_l : ym_mix;
assign AUDIO_R   = HAS_Z80 ? z80_mix_r : ym_mix;
assign AUDIO_MIX = 0;

assign LED_USER  = ioctl_download;
assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

assign VGA_SL      = 0;
assign VGA_F1      = 0;
// THE ANALOG OUTPUT HAS TO BE ASKED FOR THE SCALER, OR ROTATION NEVER REACHES
// IT.
//
// Rotation lives entirely in the DDR3 framebuffer that screen_rotate fills;
// the scaler reads that and drives HDMI. With VGA_SCALER tied low the analog
// output carries the core's RAW video instead, which is never rotated -- so a
// turned game showed on HDMI and upright on VGA. This was 0 from the first
// bring-up commit and nothing since has changed it, so rotation on analog has
// most likely never worked rather than having regressed; the 180 change
// touched only the select width, the flip line and the no-rotate term, and
// none of those alters CW or CCW.
//
// Raised only while the framebuffer is actually in use, so a game running
// unrotated keeps the direct path and the frame of latency the framebuffer
// costs. And never while DIRECT VIDEO is on: that mode exists to put the
// core's own timing on the VGA pins for a CRT, the scaler is bypassed by
// definition, and rotation cannot reach it at all -- turn Direct Video off to
// rotate on a CRT.
assign VGA_SCALER  = FB_EN & ~direct_video;
assign VGA_DISABLE = 0;

// Aspect: the visible area is 256x224 and the game is ROT90, but this build
// deliberately shows the NATIVE orientation. Rotation is decision D3 and an
// output-stage concern; putting it in before the picture is trusted would mean
// debugging two things at once.
// SWAPPED WHEN ROTATED, or a turned game is drawn in the wrong shape. The
// framework needs the aspect of what it is actually scaling, not of the
// unrotated source.
wire [11:0] arx_base = status[8] ? 12'd16 : 12'd4;
wire [11:0] ary_base = status[8] ? 12'd9  : 12'd3;
assign VIDEO_ARX = video_rotated ? ary_base : arx_base;
assign VIDEO_ARY = video_rotated ? arx_base : ary_base;

`include "build_id.v"
localparam CONF_STR = {
	"Kaneko16;;",
	"-;",
	"O[8],Aspect ratio,4:3,16:9;",
	"O[5:4],SDRAM capture,CL+4,CL+5,CL+3,CL+2;",
	"O[9],Show,Game,Palette+CPU;",
	"O[11],Debug overlay,Off,On;",
	"-;",
	"O[14],Service switch,Off,On;",
	"O[15],Sprite offscreen skip,Off,On;",
	"O[16],Sprites,On,Off;",
	"O[17],Tilemaps,On,Off;",
	// THE TWO DEBUG OPTIONS MOVED UP so the volumes can sit in one piece.
	// hps_io delivers status in 16-BIT CHUNKS, so a field straddling bit 31/32
	// is written in two halves -- which is what made the SFX control behave
	// differently from the Music one when it sat at O[32:30]. Both volumes are
	// now inside a single chunk. These two are development aids, so they take
	// the high bits where a straddle would matter least.
	"O[34:33],Game override,Off(MRA),1 Magical Crystals,2 Blaze On,3 Wing Force;",
	"O[37:35],Layer1 dx,+2 (MAME),0,-2,+4;",
	"O[26:24],Rotation,Off,Auto (per game),CW 90,CCW 90,180;",
	// POSITION 0 IS 100% ON BOTH, because status defaults to zero and a fresh
	// boot must not be silent or quiet. The same reason the rotation option and
	// the SDRAM capture option put their working value first.
	//
	// WHICH CHIP EACH ONE MOVES IS PER BOARD, and on one game the split is not
	// real at all. Blaze On and Wing Force put music on the YM2151 and effects
	// on the OKI, so the two controls are independent there. Explosive Breaker
	// and Magical Crystals have two YM2149s and an OKI -- and Explosive Breaker
	// keeps BOTH YM2149 volumes at zero and plays its whole soundtrack through
	// the OKI, so on that game SFX moves everything and Music moves nothing
	// audible. That is the hardware, not a shortcut; see docs/findings.md.
	// 20% to 200% in tens. NINETEEN levels, so five bits each.
	//
	// The list starts at 100% and climbs to 200% before wrapping to the quiet
	// end, because `status` defaults to zero and position 0 is what a fresh
	// boot gets -- an ascending list from 20% would boot nearly silent. The
	// rotation and SDRAM capture options put their working value first for the
	// same reason.
	"O[31:27],Music volume,100%,110%,120%,130%,140%,150%,160%,170%,180%,190%,200%,20%,30%,40%,50%,60%,70%,80%,90%;",
	"O[23:19],SFX volume,100%,110%,120%,130%,140%,150%,160%,170%,180%,190%,200%,20%,30%,40%,50%,60%,70%,80%,90%;",
	"-;",
	"R[12],Reset;",
	"-;",
	"J1,Shot,Bomb,Start,Coin,Pause,Service Coin;",
	"V,v",`BUILD_DATE
};

// ------------------------------------------------------------------ clocks
// One clock for the core AND the SDRAM: no clock-domain crossing in this
// build. See rtl/pll/pll.v.
wire clk_sys, clk_sdram_ps, pll_locked;
wire clk_sdram;

pll pll
(
	.refclk   (CLK_50M),
	.rst      (0),
	.outclk_0 (clk_sdram),
	.outclk_1 (clk_sys),
	.outclk_2 (clk_sdram_ps),
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
// ------------------------------------------------------- the game table
// Every per-game fact lives in kaneko_gamecfg, which has a testbench: 113
// checks covering the ioctl path that delivers the id, the fallback for an
// unknown id, and the whole configuration each id selects. That path decides
// the MEMORY MAP, and when it lived here — untestable — a wrong byte would
// have been a black screen with no way to tell why.
//
// Explosive Breaker is id 0 and id 0 is the reset value, so a game whose MRA
// carries no config byte gets its configuration, unchanged.
wire [7:0]  game_id;
wire [7:0]  PG_WRAM, PG_V2W0, PG_V2W1, PG_SPR, PG_PAL, PG_WDOG, PG_IN;
wire [SDR_AW:1] TROM0_BASE, TROM1_BASE, SPR_BASE, OKI_BASE;
wire signed [10:0] V2_DX_CFG, V2_DY_CFG;
wire        VIEW2_2_PRI, TWO_CHIPS, SPR_WIDE, SPR_FLIPTYPE;
wire [15:0] SPR_PRI_SEL, SPR_XOFFS_CFG, SPR_YOFFS_CFG;
wire [10:0] TILE_COLBASE_CFG, SPR_COLBASE_CFG, SPR_COUNT_CFG;
// Sprite tiles in the ROM region -- the modulus the sprite code is reduced
// by before it is fetched. Two of the six are not powers of two.
wire [17:0] SPR_ELEMENTS_CFG;
wire [8:0]  SPR_MIN_Y;
wire [9:0]  CFG_H_VIS, CFG_V_VIS, CFG_V_START, CFG_HSYNC;
wire [8:0] CFG_H_START;   // visible window's x origin; 40 on the CALC3 board
wire        INPUTS_BLAZEON;
wire [7:0]  PG_SND;
wire        ROM_1MB;
wire        BLAZEON_IO;
wire [SDR_AW-1:0] BASE_Z80;
wire        HAS_Z80;
wire [2:0]  OKI_MAX_BANK;
wire        OKI_ON_Z80;
wire [15:0] IN_UNK_VAL;
wire        OKI_CEN_HALF;

// THE MRA's GAME-ID BYTE DOES NOT ARRIVE, AND THIS IS BOTH THE PROBE AND THE
// WAY ROUND IT.
//
// Proven twice on hardware: Blaze On reports 256x224 in the OSD, which is
// Explosive Breaker's geometry, and Explosive Breaker's own ROMs relabelled as
// game 01 still boot Explosive Breaker. game_id is stuck at its reset value.
// Every wire has been checked — hps_io and this module share clk_sys, rst_por
// is only PLL lock, WIDE=1, index 1 is emitted with md5="none" after index 0 —
// and the byte still never lands.
//
// cfg_writes counts ioctl writes seen at index 1, which separates "the
// transfer never happens" from "it happens and the value is wrong". Those are
// different faults and nothing so far distinguishes them.
//
// The override exists so the rest of the core is testable meanwhile: the game
// table, the per-game map, the geometry and the inputs are all verified
// against MAME and none of them has ever been exercised on hardware, because
// the selector that reaches them never arrives. Off means use the MRA.
reg [15:0] cfg_writes;
always @(posedge clk_sys) begin
	if (rst_por) cfg_writes <= 16'd0;
	else if (ioctl_wr && (ioctl_index[7:0] == 8'd1) && ~&cfg_writes)
		cfg_writes <= cfg_writes + 1'd1;
end

wire [1:0] game_ovr = status[34:33];

// Volume in SIXTY-FOURTHS of unity, 20% to 200% in tens. Menu order is
// 100..200 then 20..90, so position 0 -- what a fresh boot gets -- is 100%.
//
// Each value is round(level * 64 / 100). Eighths could not express 10% steps
// and had no 20% at all, which is why the scale changed with the range.
function automatic [7:0] vol64(input [4:0] sel);
	case (sel)
		5'd0:  vol64 = 8'd64;    // 100%
		5'd1:  vol64 = 8'd70;    // 110%
		5'd2:  vol64 = 8'd77;    // 120%
		5'd3:  vol64 = 8'd83;    // 130%
		5'd4:  vol64 = 8'd90;    // 140%
		5'd5:  vol64 = 8'd96;    // 150%
		5'd6:  vol64 = 8'd102;   // 160%
		5'd7:  vol64 = 8'd109;   // 170%
		5'd8:  vol64 = 8'd115;   // 180%
		5'd9:  vol64 = 8'd122;   // 190%
		5'd10: vol64 = 8'd128;   // 200%
		5'd11: vol64 = 8'd13;    // 20%
		5'd12: vol64 = 8'd19;    // 30%
		5'd13: vol64 = 8'd26;    // 40%
		5'd14: vol64 = 8'd32;    // 50%
		5'd15: vol64 = 8'd38;    // 60%
		5'd16: vol64 = 8'd45;    // 70%
		5'd17: vol64 = 8'd51;    // 80%
		5'd18: vol64 = 8'd58;    // 90%
		// 19 to 31 are not in the menu. They resolve to 100%, not to silence:
		// a spare code that lands on "off" is the shape of bug this file has
		// paid for before.
		default: vol64 = 8'd64;
	endcase
endfunction
wire [7:0] g_music = vol64(status[31:27]);
wire [7:0] g_sfx   = vol64(status[23:19]);

kaneko_gamecfg #(.SDR_AW(SDR_AW)) u_gamecfg
(
	.clk(clk_sys), .rst(rst_por),
	.ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index[7:0]),
	.ioctl_dout(ioctl_dout[7:0]),
	// Applied INSIDE the table, so every consumer — pages, geometry, inputs,
	// ROM bases — sees one consistent id. Muxing the output would leave the
	// table's internals on the MRA's value.
	.id_force_en(game_ovr != 2'd0), .id_force({6'd0, game_ovr}),
	.game_id(game_id),

	.pg_wram(PG_WRAM), .pg_v2w0(PG_V2W0), .pg_v2w1(PG_V2W1),
	.pg_spr(PG_SPR), .pg_pal(PG_PAL), .pg_wdog(PG_WDOG), .pg_in(PG_IN),
	.pg_snd(PG_SND), .rom_1mb(ROM_1MB), .blazeon_io(BLAZEON_IO),

	.base_trom0(TROM0_BASE), .base_trom1(TROM1_BASE),
	.base_spr(SPR_BASE), .base_oki(OKI_BASE),

	.v2_dx(V2_DX_CFG), .v2_dy(V2_DY_CFG),
	.view2_2_pri(VIEW2_2_PRI), .spr_pri_f(SPR_PRI_SEL),
	.tile_colbase(TILE_COLBASE_CFG), .spr_colbase(SPR_COLBASE_CFG),
	.two_chips(TWO_CHIPS),

	.spr_count(SPR_COUNT_CFG), .spr_elements(SPR_ELEMENTS_CFG),
	.spr_xoffs(SPR_XOFFS_CFG), .spr_yoffs(SPR_YOFFS_CFG),
	.visarea_min_y(SPR_MIN_Y), .wide_screen(SPR_WIDE),
	.fliptype(SPR_FLIPTYPE),

	.h_vis(CFG_H_VIS), .v_vis(CFG_V_VIS),
	.v_start(CFG_V_START), .h_sync_start(CFG_HSYNC), .h_start(CFG_H_START),
	.inputs_blazeon(INPUTS_BLAZEON),
	.base_z80(BASE_Z80), .has_z80(HAS_Z80),
	.oki_max_bank(OKI_MAX_BANK), .oki_on_z80(OKI_ON_Z80),
	.in_unk_val(IN_UNK_VAL),
	.oki_cen_half(OKI_CEN_HALF),
	.rot_en(ROT_EN), .rot_ccw(ROT_CCW)
);

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
// TEN. The tenth is the CALC3 board's second OKI, which fetches its own
// samples from its own region. It was going to be the sprite bitmap; that move
// is blocked on SDRAM bandwidth (D5), and this is a better use of the port
// meanwhile.
localparam int unsigned NPORTS  = 9;

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
// The Z80's program fetch. It used to be 48 KB of block RAM filled by snooping
// the loader, which cost 48 of the device's 553 M10K blocks and did not fit --
// see the header of kaneko_z80rom.sv for why those 48 were a cliff rather than
// a slope. It reads through a 256-byte cache now, like the 68000 does.
wire              p8_req;
wire [SDR_AW:1]   p8_addr;
// Second OKI sample fetch, CALC3 board only. Idle on every other game.
// Two ports for the sprite ROM, not one: a sprite row needs a block from each
// half of its address space and they are fetched CONCURRENTLY. See the header
// of kaneko_sprrom for the derivation of that pattern.
wire [1:0]            p67_req;
wire [1:0][SDR_AW:1]  p67_addr;
wire [1:0]            p67_ack;
wire [1:0][63:0]      p67_dout;
// SDRAM OCCUPANCY, MEASURED ON THE BOARD.
//
// The sprite bitmap has to leave block RAM before Tier 3 is reachable -- see
// D5 -- and whether SDRAM has room for it is the open question. The estimates
// say no by a margin small enough to be inside their own error: bus efficiency
// was measured on wandering cursors rather than row-local runs, and the tile
// and write demands are both derived rather than observed.
//
// This counts what the arbiter actually grants, per scanline, in the 96 MHz
// domain. A line is 768 fast clocks, so the counters fit 16 bits with room and
// the number reads directly as occupancy.
wire [NPORTS-1:0]       sdr_dbg_req, sdr_dbg_grant;
wire [NPORTS-1:0]       f_we;
wire [NPORTS-1:0][15:0] f_din;
wire [NPORTS-1:0][1:0]  f_be;
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
// From the PLL's own phase-shifted output, not an inverter. `~clk_sdram` put a
// fabric inverter in the path to the pin; this takes the dedicated clock route,
// which is the whole reason for spending a PLL output on it.
assign SDRAM_CLK = clk_sdram_ps;

// Declared above the controller because its port gating uses rom_loaded.
wire rom_loaded, ldr_overflow;

// WHICH PORTS HAVE A DEADLINE, by index:
//
//   p0, p2, p3, p4   tile feeder, one per layer — must finish a LINE
//   p1               68000 ROM fetch — the CPU stalls on DTACK waiting
//   p5               OKI samples — REAL TIME. The chip consumes a sample
//                    every 66us and there is no buffer behind it; starve it
//                    and the audio breaks, which is exactly what putting it in
//                    the slack tier did to Explosive Breaker.
//   p6, p7           sprite ROM — a whole frame of slack, and the only ports
//                    here that genuinely have any
//
// Round-robin gave all eight an equal share, so the sprite ports took their
// slots on schedule while the tile feeder missed its line. On hardware that
// showed as tilemap overruns on the Blaze On board and a smeared layer, and
// turning sprites off took those overruns to zero — the measurement that
// identified this.
//
// 8'b0011_1111: tiles, the CPU and the OKI first; only the sprite engine, which
// has a whole frame to fill its bitmap, waits.
// T_REFI is in clk cycles and clk is 96 MHz now, so the 48 MHz value of 300
// would refresh twice as often as needed and spend the bandwidth this change
// exists to recover. 8192 rows per 64 ms is one per 750 cycles at 96 MHz; 700
// keeps margin for a transfer in flight when the timer fires.
// ------------------------------------------------ 48 MHz side -> 96 MHz side
//
// The controller runs at twice the core clock now, so every requester -- four
// tile layers, the 68000, the OKI, two sprite ports and the Z80 -- is a slow
// master talking to a fast servant. kaneko_sdram was written for exactly this
// (its ACK_HOLD is documented as "2 for a clk/2 requester") but two hazards sit
// in the gap, and this adapter is the tested answer to both: a request held
// across its own acknowledge must not be taken twice, and an acknowledge must
// span exactly one slow cycle. sim/mem/tb_kaneko_sdram_x2.cpp exercises the
// pair at 96/48 and passes with rd_lat_sel=3.
wire [NPORTS-1:0]        f_req;
wire [NPORTS-1:0][SDR_AW:1] f_addr;
wire [NPORTS-1:0]        f_ack;
wire [NPORTS-1:0][63:0]  f_dout;
wire                     f_wr_req, f_wr_ack;
wire [SDR_AW:1]          f_wr_addr;
wire [15:0]              f_wr_din;
wire [1:0]               f_wr_be;

kaneko_sdram_x2 #(.NP(NPORTS), .AW(SDR_AW)) u_sdr_x2
(
	.clk_fast(clk_sdram),

	.s_req  (rom_loaded ? {p8_req, p67_req, p5_req, p4_req, p3_req, p2_req, p1_req, p0_req}
	                    : {NPORTS{1'b0}}),
	.s_addr ({p8_addr, p67_addr, p5_addr, p4_addr, p3_addr, p2_addr, p1_addr, p0_addr}),
	// No port writes yet: the sprite bitmap will be the first, and until it
	// exists every master is a reader. Driven explicitly rather than left off
	// the instance -- an omitted input is tied to GND without an error, which
	// is how the per-game memory map shipped broken for eleven commits.
	.s_we   ({NPORTS{1'b0}}),
	.s_din  ({NPORTS{16'd0}}),
	.s_be   ({NPORTS{2'b11}}),
	.s_ack  (p_ack_bus),
	.s_dout (p_dout_bus),

	.s_wr_req(ldr_wr_req), .s_wr_addr(ldr_wr_addr), .s_wr_din(ldr_wr_din),
	.s_wr_be(ldr_wr_be),   .s_wr_ack(ldr_wr_ack),

	.f_req(f_req), .f_addr(f_addr), .f_ack(f_ack), .f_dout(f_dout),
	.f_we(f_we), .f_din(f_din), .f_be(f_be),
	.f_wr_req(f_wr_req), .f_wr_addr(f_wr_addr), .f_wr_din(f_wr_din),
	.f_wr_be(f_wr_be),   .f_wr_ack(f_wr_ack)
);

kaneko_sdram #(.COL_BITS(SDR_COL), .NP(NPORTS), .T_REFI(700),
               // Bit 8 is the Z80's program fetch. Urgent, despite being a
               // tiny share of the bandwidth -- one eight-byte line per eight
               // opcode bytes at 4 MHz -- because everything behind it is the
               // sound CPU stalled with its clock enable held low.
               // Bit 9 is the second OKI, urgent for the same reason bit 5
               // is: a starved sample fetch is audible.
               .URGENT(10'b11_0011_1111)) u_sdram
(
	.clk(clk_sdram), .rst_n(pll_locked), .ready(mem_ready),
	// THE FIRST OSD POSITION IS THE DEFAULT AND MUST WORK ON THE BOARD.
	//
	// kaneko_sdram's own mapping is 0->CL+3, 1->CL+2, 2->CL+4, 3->CL+5, and
	// status defaults to zero, so position 0 is whatever a fresh boot gets.
	//
	// SIMULATION AND SILICON DISAGREE HERE, AND SILICON WINS.
	// tb_kaneko_sdram_x2 measures that at 96 MHz only 3 (CL+5) reads correct
	// data against sdram_model -- 0, 1 and 2 fail all 6402 of its checks. The
	// board wants 2 (CL+4): CL+5 gave a black screen and a 68000 running
	// garbage with zero interrupts acknowledged. The same disagreement is
	// already on record at 48 MHz, where kaneko_sdram's own header notes
	// "1 -> CL+2 (the board: its device is clocked on the inverse of
	// clk_sys)" while the model wanted 0. The real device has never matched
	// the model, which is the entire reason this is an OSD option.
	//
	// Changing it at runtime leaves artefacts that do not always clear, and
	// that is expected rather than a fault: reads already in flight are
	// captured at the old depth and everything buffered from them is wrong
	// until it is overwritten. It is a diagnostic, not a setting to tune while
	// playing.
	//
	// The menu text was wrong as well; it read CL+1,CL+0,CL+2,CL+3, which
	// matched none of the four values it was selecting.
	.rd_lat_sel(status[5:4] == 2'd0 ? 2'd2 :
	            status[5:4] == 2'd1 ? 2'd3 :
	            status[5:4] == 2'd2 ? 2'd0 : 2'd1),

	.sd_cke(SDRAM_CKE), .sd_cs_n(SDRAM_nCS), .sd_ras_n(SDRAM_nRAS),
	.sd_cas_n(SDRAM_nCAS), .sd_we_n(SDRAM_nWE), .sd_ba(SDRAM_BA),
	.sd_a(SDRAM_A), .sd_dqm({SDRAM_DQMH, SDRAM_DQML}),
	.sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(SDRAM_DQ),

	.wr_req(f_wr_req), .wr_addr(f_wr_addr), .wr_din(f_wr_din),
	.wr_be(f_wr_be), .wr_ack(f_wr_ack),

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
	.p_req  (f_req),
	.p_addr (f_addr),
	.dbg_req(sdr_dbg_req), .dbg_grant(sdr_dbg_grant),
	.p_din  (f_din),
	.p_be   (f_be),
	.p_we   (f_we),
	.p_ack  (f_ack),
	.p_dout (f_dout)
);


// ON clk_sys, NOT clk_sdram, AND THIS MATTERS NOW.
//
// Every input here comes from hps_io, which runs on clk_sys: ioctl_download,
// ioctl_wr, ioctl_addr, ioctl_dout. While the two clocks were the same signal
// that was invisible. Splitting the memory to 96 MHz made it a real crossing
// AND put the loader on the wrong side of kaneko_sdram_x2 -- it drives the
// adapter's SLOW port while being clocked fast, so ACK_HOLD's two-cycle
// acknowledge, which is exactly one edge for a 48 MHz requester, became two
// edges for it. Every write would be counted twice and the ROM image would
// load corrupt, which is every game broken at once and no clue as to why.
kaneko_rom_loader #(.SDR_AW(SDR_AW)) u_loader
(
	.clk(clk_sys), .rst(~pll_locked), .mem_ready(mem_ready),
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
wire        v2r0_we, v2r1_we, sprreg_we, sprreg2_we;
wire [15:0] q_sprreg2;
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
wire [23:1] unmapped_addr;

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
	.sprreg2_we(sprreg2_we), .sprreg2_q(q_sprreg2),
	.reg_addr(reg_addr), .reg_din(reg_din),
	.v2r0_q(q_v2r0), .v2r1_q(q_v2r1), .sprreg_q(q_sprreg),

	// EVERY window page, from the game table. These were declared on the bus
	// and connected by nothing for eleven commits: Quartus said so in the
	// build report every time —
	//
	//   pg_wram  Input  Warning  Declared by entity but not connected by
	//                            instance ... the port will be connected to GND
	//
	// — and nobody read it. The game table computed all seven pages and drove
	// a set of wires that went nowhere.
	.pg_wram(PG_WRAM), .pg_v2w0(PG_V2W0), .pg_v2w1(PG_V2W1),
	.pg_spr(PG_SPR), .pg_pal(PG_PAL), .pg_wdog(PG_WDOG), .pg_in(PG_IN),
	.pg_snd(PG_SND), .rom_1mb(ROM_1MB), .blazeon_io(BLAZEON_IO),
	.snd_we(z80_latch_we), .snd_din(z80_latch_din),

	// Nothing pressed. The EEPROM is not implemented yet, so anything the game
	// reads from it comes back as an unwritten device.
	.in_p1(in_p1), .in_p2(in_p2),
	// The fourth word: Explosive Breaker has a port at e00006 that MAME
	// declares and leaves entirely empty, so it reads 0x0000, not 0xffff.
	// Magical Crystals has no such port at all.
	.in_system(in_system), .in_unk(IN_UNK_VAL),

	.unmapped_hit(unmapped_hit), .unmapped_addr(unmapped_addr)
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

// The OKI gets its own enable rather than sharing the YM2149s'. Its clock is a
// per-game fact — 2 MHz on Explosive Breaker and Magical Crystals, 1 MHz on
// Wing Force — and getting it wrong plays every sample an octave out, which
// sounds like a bad ROM rather than a bug in the core. Counting to 48 keeps
// both taps evenly spaced; a mask on a 24-counter would not.
reg [5:0] oki_div;
always @(posedge clk_sys) oki_div <= (oki_div == 6'd47) ? 6'd0 : oki_div + 6'd1;
wire oki_cen = (oki_div == 6'd0) || (!OKI_CEN_HALF && oki_div == 6'd24);

// oki1: byte 0x4c0000 on explbrkr, 0x500000 on mgcrystl (its kan_spr is
// larger). Word addresses.

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
// Two YM2149s and one OKI on every board this core runs. Summing both
// unconditionally is right: a part that does not exist is held silent by its
// own reset. The CALC3 board's second OKI left with the rest of Tier 2.
// The two parts are scaled SEPARATELY now, so Music and SFX are independent
// where the board makes them so. At 100% each this is bit-for-bit the sum it
// was: gain8 of 8 is a multiply by 8 and a shift by 3.
wire signed [16:0] ym_part_dc   = {{3{ym_ctr[11]}}, ym_ctr, 2'd0};

// AC-COUPLED BEFORE THE VOLUME TOUCHES IT, and this is not a refinement.
//
// jt49's sound is unsigned with silence at ZERO, not at mid-scale, so
// centring it by a fixed midpoint puts a constant -1024 into the mix whenever
// the chips are quiet. Explosive Breaker keeps both YM2149 volumes at zero for
// its whole soundtrack, so that offset is permanent: -4096 here, -24576 by the
// time the mix is scaled, three quarters of the negative rail.
//
// It cost twice. The offset ate the headroom the OKI needed, which is why that
// game stayed quiet however much the gain went up; and once the music control
// could scale it, anything above 140% pushed it past the rail and every sound
// stopped, effects included -- reported from hardware on both 68000 games,
// while the YM2151 boards, which never take this path, were fine.
//
// A real board never has this: its output is AC-coupled and a DC level from a
// silent DAC never reaches the speaker.
wire signed [16:0] ym_part_raw;
kaneko_dcblock #(.W(17)) u_ym_dc
(
	.clk(clk_sys), .rst(rst_sys),
	.din(ym_part_dc), .dout(ym_part_raw)
);
wire signed [16:0] oki_part_raw = {{3{oki_snd[13]}}, oki_snd};
wire signed [16:0] ym_part, oki_part;

kaneko_volume #(.W(17)) u_vol_music_a (.gain64(g_music), .din(ym_part_raw),  .dout(ym_part));
kaneko_volume #(.W(17)) u_vol_sfx_a   (.gain64(g_sfx),   .din(oki_part_raw), .dout(oki_part));

wire signed [16:0] snd_mix = ym_part + oki_part;

// SCALED UP, BECAUSE THE HEADROOM IS FOR A SUM THAT NEVER HAPPENS.
//
// This was snd_mix[16:1] -- a straight halving -- which reserves room for both
// chips at full tilt. Explosive Breaker keeps BOTH YM2149 volumes at zero and
// plays its entire soundtrack through the OKI, so in practice the sum is just
// the OKI at +/-8192, halved to +/-4096: 18 dB below full scale, and 12 dB
// below the Blaze On board's +/-16384. That went unnoticed until Blaze On had
// any sound at all to compare against.
//
// The real bound is tighter than the widths suggest. jt49's two 10-bit
// unsigned levels sum to 0..2046, so ym_ctr is about +/-1024 and its shift by
// two is +/-4096; jt6295's sample is +/-8192. The worst case is +/-12288, so
// doubling cannot reach +/-32767 -- but it is saturated rather than trusted,
// because a silent overflow inverts the waveform and sounds like a broken
// chip rather than a loud one.
// TWO MORE DOUBLINGS THAN THE ARITHMETIC CALLS SAFE, DELIBERATELY.
//
// Equalising the two boards' theoretical full scale was the wrong target.
// jt6295's sample is 14-bit and jt51's is 16-bit, so the YM2151 board is 4x
// louder before any gain, and MAME widens that further: Blaze On routes its
// YM2151 at 1.0 while Explosive Breaker routes everything at 0.5. Some of the
// difference is therefore authentic.
//
// The rest is that the OKI's full scale is theoretical. ADPCM samples carry
// their own volume attenuation and rarely approach +/-8192, while the YM2151
// really does use its range -- so matching the peaks left EB obviously quieter
// by ear. This scales past the point where the sum can be proven not to clip
// and relies on the saturation below, which is a judgement rather than a
// derivation: a rare clipped peak is a better trade than a soundtrack nobody
// can hear.
//
// If loud effects distort, back this off to <<< 1 -- that is the largest shift
// that cannot clip.
// x4, WHICH IS UNITY FOR THIS BOARD, and the DC fix is what made it enough.
//
// This was x4, then x6 chasing a soundtrack nobody could hear. The cause was
// never the gain: a silent YM2149 reads 0 rather than mid-scale, so centring
// it put a permanent -24576 into the mix, and the OKI rode on that into the
// rail. Removing the DC gave the headroom back, and x6 was then too loud --
// reported from hardware, exactly as raising it had been.
//
// x4 is where the arithmetic says unity is: jt6295's sample is 14 bits, so
// four times it fills a 16-bit output. ADPCM rarely reaches full scale, so
// peaks that do are caught by the saturation below rather than being designed
// around, and anyone wanting more has the SFX control.
//
// THE PRODUCT IS FORMED AT 21 BITS, NOT AT THE TARGET'S. A narrower target
// truncates in silence, which is how Wing Force's music turned to noise.
wire signed [20:0] snd_gain = $signed({{4{snd_mix[16]}}, snd_mix}) * 21'sd4;
wire [15:0] ym_mix = (snd_gain >  21'sd32767) ? 16'h7fff
                   : (snd_gain < -21'sd32768) ? 16'h8000
                                              : snd_gain[15:0];

// Blaze On board: the YM2151 in stereo, plus the OKI on Wing Force, which puts
// it on the Z80's I/O ports rather than the 68000's bus.
//
// THE TWO ARE NOT ROUTED AT THE SAME LEVEL, AND THAT IS WHY WING FORCE HAD NO
// SOUND EFFECTS.
//
// kaneko16.cpp, wingforc():
//
//     m_ymsnd->add_route(ALL_OUTPUTS, "mono", 0.2);
//     m_oki[0]->add_route(ALL_OUTPUTS, "mono", 0.5);
//
// The OKI is routed two and a half times LOUDER than the music. Every other
// board in this driver routes its YM2149s at 0.5, the same as its OKI, so the
// balance used there is wrong here and was applied here anyway.
//
// This summed them at equal weight, and jt6295's sample is 14-bit where jt51's
// is 16 -- so the OKI arrived a further four times down, about ten times
// quieter than the oracle relative to the music, roughly 20 dB. The chip was
// producing samples the whole time: the overlay's OKI chain showed writes,
// rom_ok, busy and a non-zero output all running while nothing was audible.
//
// MAME's weights, applied directly. 13/64 is 0.203, within 2% of 0.2.
//
// WIDTH FIRST, ARITHMETIC SECOND. The first version of this wrote
//
//     wire signed [17:0] z80_ym_l = (18'sd13 * $signed({...})) >>> 6;
//
// and the multiply is evaluated at the EIGHTEEN bits of its target, not at the
// width the product needs: 13 * 32768 is 425,984, which wants 20. It wrapped
// before the shift ever happened. On hardware that was a second of correct
// music and then hissing and popping -- quiet passages stayed under the wrap
// and loud ones inverted. The OKI term had the same fault from the other
// direction, a 20-bit vector assigned to an 18-bit wire.
//
// So the product is formed at 24 bits and the shift is a bit-select of the
// top 18, which cannot overflow and needs no multiplier inference to be
// correct.
wire signed [23:0] z80_ym_l24 = 24'sd5 * $signed({{8{ym2151_l[15]}}, ym2151_l});
wire signed [23:0] z80_ym_r24 = 24'sd5 * $signed({{8{ym2151_r[15]}}, ym2151_r});
wire signed [17:0] z80_ym_l  = z80_ym_l24[23:6];      // x5/64 = x0.078
wire signed [17:0] z80_ym_r  = z80_ym_r24[23:6];
// x2, NOT x0.5, AND THE DIFFERENCE IS THE NATIVE RANGES.
//
// MAME's weights are OKI 0.5 against YM2151 0.2 -- the effects two and a half
// times LOUDER than the music -- and applying those numbers literally was
// wrong, because the two chips do not start from the same scale. jt51's sample
// is 16-bit and jt6295's is 14, a factor of four, so `oki * 0.5` landed at
// 4096 against the YM's 6656: the OKI came out QUIETER than the music instead
// of 2.5x louder, still four times short.
//
// Scaling by 2 puts the PEAKS at 16,384 against 6,656, MAME's 2.5 to 1 within
// 2% -- and on hardware that was still barely audible, exactly as Explosive
// Breaker was before its mix was boosted.
//
// MATCHING THE PEAKS IS THE WRONG MODEL, and the 68000 board's mix already
// says why a few lines above: the OKI's full scale is theoretical. ADPCM
// samples carry their own volume attenuation and rarely approach +/-8192,
// while jt51 really does use its range. So a ratio computed from peaks gives
// the OKI far less than 2.5 to 1 of what is actually heard.
//
// THE BALANCE IS SET BY EAR AGAINST MAME; THE LEVEL IS SET BY THE HEADROOM.
//
// Two separate questions, and conflating them cost three builds. The balance
// that sounds right against the oracle is about 9.6 to 1 by peak -- far more
// than MAME's nominal 2.5, because the OKI's full scale is theoretical while
// jt51 genuinely uses its range, the same reason the 68000 board's mix is
// boosted past what its arithmetic can prove safe.
//
// Reaching that balance by raising the OKI alone put the peak sum at 72,192
// against a 16-bit range, and on hardware that was popping and crackling --
// saturation, not distortion in the chips. The fix is to scale the PAIR, not
// one side: x3/8 on both holds the balance at 9.6 to 1 and brings the peak sum
// to 27,136, which leaves 5,631 of headroom and cannot saturate at all.
//
// So: ym x5/64 and oki x3. If it is too quiet overall, scale both again --
// x1/4 on the pair keeps the same balance with 14,719 of headroom. Changing
// only one of them changes the balance, which is the mistake this comment
// exists to stop.
wire signed [17:0] z80_oki_x1 = $signed({{4{oki_snd[13]}}, oki_snd});
wire signed [17:0] z80_oki_w  = (z80_oki_x1 <<< 1) + z80_oki_x1;   // x3

// Scaled separately, so Music moves the YM2151 and SFX moves the OKI. At 100%
// each this is the same sum it was.
wire signed [17:0] z80_ym_lv, z80_ym_rv, z80_oki_v;
kaneko_volume #(.W(18)) u_vol_music_l (.gain64(g_music), .din(z80_ym_l),  .dout(z80_ym_lv));
kaneko_volume #(.W(18)) u_vol_music_r (.gain64(g_music), .din(z80_ym_r),  .dout(z80_ym_rv));
kaneko_volume #(.W(18)) u_vol_sfx_z   (.gain64(g_sfx),   .din(z80_oki_w), .dout(z80_oki_v));

wire signed [17:0] z80_sum_l = z80_ym_lv + z80_oki_v;
wire signed [17:0] z80_sum_r = z80_ym_rv + z80_oki_v;

// Saturated rather than trusted, for the same reason the 68000 board's mix is:
// a silent overflow inverts the waveform and sounds like a broken chip.
wire [15:0] z80_mix_l = (z80_sum_l >  18'sd32767) ? 16'h7fff
                      : (z80_sum_l < -18'sd32768) ? 16'h8000
                                                  : z80_sum_l[15:0];
wire [15:0] z80_mix_r = (z80_sum_r >  18'sd32767) ? 16'h7fff
                      : (z80_sum_r < -18'sd32768) ? 16'h8000
                                                  : z80_sum_r[15:0];
// ZERO IN THE UPPER BITS, NOT ONES. MAME's read handler is
//
//     u8 kaneko16_state::eeprom_r() { return m_eeprom->do_read(); }
//
// and do_read() returns 0 or 1, so the byte the game sees is 0x00 or 0x01 --
// the other seven bits are not "unused and pulled high", they are zero. Both
// boards read the EEPROM this way: bakubrkr and mgcrystl each wire
// m_ym2149[1]->port_a_read_callback() to it, with MAME's own comment reading
// "inputs A: 0,EEPROM bit read".
//
// This is the third time today the same mistake has surfaced -- the P1/P2/
// SYSTEM words, the fourth input word, and now here. A bit that is not there
// reads ZERO, and driving it high is invisible on a game that tests only the
// bit it wants and fatal on one that compares the byte.
wire [7:0] ym1_ioa_in = {7'h00, eeprom_do};
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
// the note in kaneko_oki_bank.sv. It is a per-game fact and now comes from the
// game table with everything else that differs across the driver: 7 for
// Explosive Breaker's 1 MB, 3 for Wing Force's 512 KB, 1 for Magical Crystals'
// 256 KB. It was a parameter fixed at 7, which would have played the wrong
// sample on two of the three rather than failing.
// WHO ACTUALLY DRIVES THE CHIP. Named once and used by both the chip and the
// debug overlay, because they disagreed: the overlay counted kaneko_bus's
// `oki_we` while Wing Force drives the OKI from the Z80, so its row read zero
// no matter what the Z80 did. A census of the wrong signal returns zero and
// looks exactly like an answer -- the failure CLAUDE.md's rule 6 is about.
wire       oki_we_eff  = OKI_ON_Z80 ? z80_oki_we  : oki_we;
wire [7:0] oki_din_eff = OKI_ON_Z80 ? z80_oki_din : oki_din;

wire [23:0] oki_region_addr;
kaneko_oki_bank u_okibank
(
	.chip_addr(oki_rom_addr),
	.max_bank(OKI_MAX_BANK),
	// Same split: Wing Force banks from Z80 port 0x0c, the rest from YM2149
	// chip 0's port B.
	.bank(OKI_ON_Z80 ? z80_oki_bank : ym0_iob_out[2:0]),
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

// ------------------------------------------- Tier 2 hardware: REMOVED
// The CALC3 board's hit calculator, its MCU RAM and its second OKI lived here
// and have moved to their own core -- see docs/HANDOFF.md.
//
// They were removed because they do not fit alongside Tier 1. Measured, in
// order: 64 KB of MCU RAM asked the fitter for 6,773 LABs against the
// device's 4,191; cutting it to 8 KB still missed setup by 0.773 ns; and the
// VIEW2 read-port sharing done to recover the blocks broke Magical Crystals,
// which reads VIEW2 724 times a frame against Explosive Breaker's 1.4.
//
// Tier 1 keeps its block memory and its nine SDRAM ports. The CALC3 board
// gets a core sized for what it actually needs.

// -------------------------------------------------------- Z80 sound CPU
// The Blaze On board only: Z80 + YM2151, with the 68000 handing it one byte at
// a time through a latch. Held in reset on every other board, where the sound
// hardware is the two YM2149s and the OKI on the 68000's own bus.
//
// T80 is VHDL. That is why kaneko_z80snd brings the Z80 bus out instead of
// instantiating it — Verilator cannot build VHDL, and a module that hid the
// CPU inside itself could not be unit-tested at all. The join happens here,
// which is also where fx68k, jt49 and jt6295 are joined for the same reason.
wire        z80_latch_we;
// THE 68000 SIDE OF THE SOUND LATCH, which nothing counted.
//
// zlat_cnt already counts the Z80 READING the latch at port 06. What was
// missing is the 68000 WRITING it -- and that is the interesting half, because
// the fault now looks like missed commands rather than broken chips.
//
// Measured in MAME with tools/mame_wf_sound.lua, Wing Force writes this latch
// only a handful of times a minute and not once during the attract demo: the
// Z80 runs that sequence itself. So a command missed at a TRANSITION is enough
// to leave a whole mode silent, which is exactly the reported shape -- the
// high-score screen plays in game and not in attract.
//
// Saturating rather than wrapping: a stuck write would otherwise read as a
// healthy small number.
reg [15:0] lw_cnt, lw_lat, lw_tot;
// lw_tot counts OUTSIDE the vbl branch for the same reason zlat_tot does: a
// command arriving on the frame boundary would otherwise be dropped by the
// very counter meant to catch it.
always @(posedge clk_sys) begin
	if (rst_sys)                        lw_tot <= 16'd0;
	else if (z80_latch_we && !(&lw_tot)) lw_tot <= lw_tot + 16'd1;
end
reg  [7:0] lw_last;
always @(posedge clk_sys) begin
	if (rst_sys) begin
		lw_cnt <= 16'd0; lw_lat <= 16'd0; lw_last <= 8'd0; lw_hist <= 16'd0; lw_hist2 <= 16'd0;
		lw_gap <= 16'd0; lw_gapl <= 16'd0; lw_arm <= 1'b0;
	end else if (vbl_rise) begin
		lw_lat <= lw_cnt; lw_cnt <= 16'd0;
		if (lw_arm && !(&lw_gap)) lw_gap <= lw_gap + 16'd1;
	end else if (z80_latch_we) begin
		if (!(&lw_cnt)) lw_cnt <= lw_cnt + 16'd1;
		lw_last <= z80_latch_din;      // the command byte itself
		lw_hist <= {lw_hist[7:0], z80_latch_din};   // and the two before it
		lw_hist2 <= {lw_hist2[7:0], lw_hist[15:8]};  // and the two before THOSE
		// HOW LONG THE MUSIC IS ALLOWED TO PLAY.
		//
		// The commands, their order and their sender all match MAME exactly --
		// 01,01,17,01 with 0x17 starting the attract audio. What cannot match
		// is the INTERVAL: the oracle leaves about eighteen seconds between
		// the 17 and the 01 that follows it, roughly 1080 frames, and this
		// core is silent through a demo that is still drawing normally.
		//
		// So count frames from the start command to the stop. A small number
		// here is the fault, stated as a number rather than inferred.
		if (z80_latch_din == 8'h17) begin
			lw_gap  <= 16'd0;
			lw_arm  <= 1'b1;
		end else if (z80_latch_din == 8'h01 && lw_arm) begin
			lw_gapl <= lw_gap;        // frames the music was allowed
			lw_arm  <= 1'b0;
		end
	end
end

// THE LAST TWO COMMANDS, NOT JUST THE LAST ONE.
//
// MAME sends this pair at the transition into the attract demo:
//
//     5s:01   5s:17
//
// and 0x17 is what starts the audio -- OKI traffic begins the second after it.
// Measured on hardware, this core holds 0x17 on the title screen, which plays,
// and 0x01 in the demo, which is silent. So we end up holding the STOP where
// the oracle ends up holding the START.
//
// Two writes in quick succession is exactly where a latch can drop one, and a
// single last-value register cannot tell "the 17 never arrived" from "the 17
// arrived and something sent 01 after it". This holds both, newest in the low
// byte: 0x1701 means 01 then 17 -- the oracle's order, correct -- and 0x0117
// means 17 then 01, which would be something stopping the music after it
// started.
reg [15:0] lw_hist;
// Four deep in total, across two rows. MAME's sequence into the attract demo
// is 01, 05, 01, 01, 17 -- five commands in six seconds -- and two is not
// enough to line ours up against it.
reg [15:0] lw_hist2;
reg [15:0] lw_gap, lw_gapl;   // frames between the 0x17 and the next 0x01
reg        lw_arm;
wire [7:0]  z80_latch_din;

wire [15:0] z80_a;
wire [7:0]  z80_do, z80_di;
wire        z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_nmi_n;
wire [15:0] z80_rom_addr;
wire [7:0]  z80_rom_data;
wire        z80_oki_we;
wire [7:0]  z80_oki_din;
wire [2:0]  z80_oki_bank;
wire        z80_ym_cen, z80_ym_cen_p1, z80_ym_cs_n, z80_ym_wr_n, z80_ym_a0;
wire [7:0]  z80_ym_din, z80_ym_dout;

// 4 MHz, from MAME: Z80(config, m_audiocpu, 4000000) on Blaze On and
// XTAL(16'000'000)/4 on Wing Force, which is the same number. 48/12 is exact,
// so no fractional divider and no phase error.
reg [3:0] z80_cediv;
always @(posedge clk_sys) z80_cediv <= (z80_cediv == 4'd11) ? 4'd0 : z80_cediv + 4'd1;

// STALLED BY WITHHOLDING THE CLOCK ENABLE, NOT BY WAIT_n.
//
// The program ROM is a cache over SDRAM now, so a fetch can miss. Holding CEN
// low is the unambiguous way to say "not yet" to T80s: the CPU does not
// advance, its address and control lines hold, the line arrives, and it
// resumes. Driving WAIT_n correctly alongside CEN and IOWait would be a second
// timing contract to get right for no benefit.
//
// The divider keeps counting through a stall, so the cost of a miss is rounded
// up to the next 4 MHz tick. That is the right way round: it can only ever
// make the Z80 slower than 4 MHz, never faster.
wire        z80_rom_ready;
wire        z80_rom_rd = ~z80_mreq_n && ~z80_rd_n && (z80_a < 16'hc000);
wire        z80_stall  = z80_rom_rd && !z80_rom_ready;
// The CPU's enable stalls; the sound chip's does not. z80_ce_free is the
// unconditional 4 MHz tick and is what jt51 runs on.
wire z80_ce_free = (z80_cediv == 4'd0);
wire z80_ce      = z80_ce_free && !z80_stall;

// Held in reset when the board has no Z80. Not merely idle: a Z80 free-running
// over whatever the block RAM powered up with would drive the YM2151 with
// noise, and the OKI board would gain a sound source it does not have.
wire z80_rst_n = ~(cpu_rst | ~HAS_Z80);

T80s #(.Mode(0), .T2Write(1), .IOWait(1)) u_z80
(
	.RESET_n(z80_rst_n), .CLK(clk_sys), .CEN(z80_ce),
	.WAIT_n(1'b1),
	// The YM2151's IRQ is not wired on this board — MAME sets no irq_handler,
	// so the program polls the status register for its timers. NMI is the only
	// interrupt, and it comes from the latch.
	.INT_n(1'b1), .NMI_n(z80_nmi_n), .BUSRQ_n(1'b1),
	.M1_n(), .MREQ_n(z80_mreq_n), .IORQ_n(z80_iorq_n),
	.RD_n(z80_rd_n), .WR_n(z80_wr_n),
	.RFSH_n(), .HALT_n(), .BUSAK_n(),
	.OUT0(1'b0),
	.A(z80_a), .DI(z80_di), .DO(z80_do)
);

kaneko_z80rom #(.SDR_AW(SDR_AW)) u_z80rom
(
	.clk(clk_sys), .rst(~z80_rst_n), .base(BASE_Z80),
	.rom_addr(z80_rom_addr), .rom_rd(z80_rom_rd),
	.rom_data(z80_rom_data), .rom_ready(z80_rom_ready),
	.p_req(p8_req), .p_addr(p8_addr),
	.p_ack(p_ack_bus[8]), .p_dout(p_dout_bus[8])
);

kaneko_z80snd u_z80snd
(
	.clk(clk_sys), .rst(~z80_rst_n), .ym_ce(z80_ce_free),
	.latch_we(z80_latch_we), .latch_din(z80_latch_din),
	.cpu_addr(z80_a), .cpu_dout(z80_do), .cpu_din(z80_di),
	.mreq_n(z80_mreq_n), .iorq_n(z80_iorq_n),
	.rd_n(z80_rd_n), .wr_n(z80_wr_n), .nmi_n(z80_nmi_n),
	.rom_addr(z80_rom_addr), .rom_data(z80_rom_data),
	.has_oki(OKI_ON_Z80),
	.dbg_oki_wr(z80_dbg_oki_wr), .dbg_ym_wr(z80_dbg_ym_wr),
	.dbg_latch_rd(z80_dbg_latch_rd), .dbg_bank_wr(z80_dbg_bank_wr),
	.oki_we(z80_oki_we), .oki_din(z80_oki_din), .oki_dout(oki_dout),
	.oki_bank(z80_oki_bank),
	.ym_cen(z80_ym_cen), .ym_cen_p1(z80_ym_cen_p1),
	.ym_cs_n(z80_ym_cs_n), .ym_wr_n(z80_ym_wr_n), .ym_a0(z80_ym_a0),
	.ym_din(z80_ym_din), .ym_dout(z80_ym_dout)
);

// The YM2151 is stereo on this board — MAME routes channel 0 left and 1 right,
// unlike every other Kaneko sound chip, which is mono to one speaker.
wire signed [15:0] ym2151_l, ym2151_r;

jt51 u_ym2151
(
	.rst(~z80_rst_n), .clk(clk_sys),
	.cen(z80_ym_cen), .cen_p1(z80_ym_cen_p1),
	.cs_n(z80_ym_cs_n), .wr_n(z80_ym_wr_n), .a0(z80_ym_a0),
	.din(z80_ym_din), .dout(z80_ym_dout),
	.ct1(), .ct2(), .irq_n(),
	.sample(), .left(), .right(),
	.xleft(ym2151_l), .xright(ym2151_r)
);

jt6295 u_oki
(
	.rst(rst_sys), .clk(clk_sys), .cen(oki_cen),
	// PIN7 selects the sample-rate divider: HIGH is 132, LOW is 165. Every game
	// this core runs is HIGH, and two of the three are marked "verified on pcb"
	// in kaneko16.cpp -- bakubrkr and mgcrystl at 12 MHz/6, wingforc at
	// 16 MHz/16. A constant here is therefore right, but it is right by
	// coincidence rather than by nature: berlwall is PIN7_LOW, so this becomes a
	// game-table entry the moment that board is attempted.
	.ss(1'b1),                       // PIN7_HIGH: divide by 132
	.wrn(~oki_we_eff), .din(oki_din_eff), .dout(oki_dout),
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

// THE SECOND SPRITE REGISTER BLOCK AT 980000, ON THE BLAZE ON BOARD.
//
// blazeon_map declares it as plain RAM -- `map(0x980000, 0x98001f).ram()` --
// because the board has two VU-002 chips and this is the second one's window.
// MAME does not model that chip, but it does honour the RAM, so a read gives
// back what was written.
//
// This core answered 0xffff, and the Wing Force bus trace caught it as the
// FIRST divergence from the oracle, nineteen compared accesses in:
//
//     ours  980004 R ffff       mame  980004 R 0000
//
// The game writes 980000 and 980002 and then reads 980004 to 98001f expecting
// what it wrote. Every decision it took afterwards was made on values the
// hardware never produced, which is why nothing downstream of this was worth
// trusting.
//
// A register file, not a device: driving a second sprite bitmap from it is the
// open item in the design study, and storing the writes is the part that has
// to be right first either way.
kaneko_regs16 u_sprreg2
(
	.clk(clk_sys), .we(sprreg2_we), .addr(reg_addr), .din(reg_din),
	.uds(~UDSn), .lds(~LDSn),
	.rd_addr(reg_addr), .rd_q(q_sprreg2), .regs_flat()
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

// SDRAM OCCUPANCY PER SCANLINE, counted in the 96 MHz domain.
//
// Four numbers, all in fast clocks out of the 768 a scanline lasts:
//
//   any        clocks with SOME port granted -- total occupancy
//   tiles      the four tile feeders, ports 0, 2, 3, 4
//   sprrom     the two sprite ROM ports, 6 and 7
//   peak       the largest `any` seen in the last frame
//
// The line boundary is derived here rather than crossed from the video timing:
// hcnt is a slow-domain counter and sampling it in the fast domain would need
// care for no benefit, when a free-running divide-by-768 is exact. Both clocks
// come from one PLL at 2:1, so 768 fast clocks IS a scanline.
reg [15:0] occ_any, occ_tile, occ_spr, occ_peak;
reg [15:0] occ_any_l, occ_tile_l, occ_spr_l, occ_peak_l;
reg [9:0]  occ_div;
wire       occ_g_any  = |sdr_dbg_grant;
wire       occ_g_tile = |(sdr_dbg_grant & 9'b0_0001_1101);   // 0,2,3,4
wire       occ_g_spr  = |(sdr_dbg_grant & 9'b0_1100_0000);   // 6,7

// ONE CLOCK, ONE BLOCK. The first version updated occ_peak here and cleared it
// from a clk_sys block on vbl_rise, which is two drivers on one register and
// two different clocks driving it. Quartus refused it outright -- "Can't
// resolve multiple constant drivers" -- and Verilator's lint did not, because
// the top level is not verilated: it instantiates VHDL and vendor IP.
//
// vbl_rise is one slow clock wide, so it spans exactly two fast clocks at the
// 2:1 ratio and an edge detector in this domain sees it once.
reg vbl_f_d;
always @(posedge clk_sdram) begin
	vbl_f_d <= vbl_rise;

	if (occ_div == 10'd767) begin
		occ_div    <= 10'd0;
		occ_any_l  <= occ_any;
		occ_tile_l <= occ_tile;
		occ_spr_l  <= occ_spr;
		occ_peak   <= (occ_any > occ_peak) ? occ_any : occ_peak;
		occ_any    <= 16'd0;
		occ_tile   <= 16'd0;
		occ_spr    <= 16'd0;
	end else begin
		occ_div  <= occ_div + 10'd1;
		if (occ_g_any)  occ_any  <= occ_any  + 16'd1;
		if (occ_g_tile) occ_tile <= occ_tile + 16'd1;
		if (occ_g_spr)  occ_spr  <= occ_spr  + 16'd1;
	end

	// Peak resets on the FRAME, not the line, so one busy scanline cannot hide
	// behind an average. Last in the block, so it wins over the line update
	// when both land together.
	if (vbl_rise && !vbl_f_d) begin
		occ_peak_l <= occ_peak;
		occ_peak   <= 16'd0;
	end
end

// Z80 SOUND-PORT CENSUS, to diff against tools/mame_z80_ports.lua.
//
// Wing Force plays its in-game music and nothing else -- no OKI effects and no
// attract music -- and two plausible causes were checked and were both wrong:
// the fourth input word (real bug, fixed, changed nothing here) and jt6295
// missing the write because its clock enable is slower than the Z80's strobe
// (jt6295_ctrl samples wrn on the bare clock, so it cannot).
//
// MAME's census on wingforc, per second, is the thing to compare against:
//
//   w02/w03  232-564   YM2151, continuously, in attract AND in game
//   r03      6300-7200 YM2151 status polled
//   w0a      up to 54  OKI, ONLY during the attract demo
//   r06      1-2       the latch, read only inside the NMI handler
//
// Divide by 60 for the per-frame numbers these rows show.
wire z80_dbg_oki_wr, z80_dbg_ym_wr, z80_dbg_latch_rd, z80_dbg_bank_wr;
reg [15:0] zoki_cnt, zoki_lat, zym_cnt, zym_lat;
reg [15:0] zlat_cnt, zlat_lat, zbank_cnt, zbank_lat;
// Cumulative, never reset: a once-per-transition event cannot be seen in a
// per-frame count, which reads zero on every frame but the one.
reg [15:0] zlat_tot;
always @(posedge clk_sys) begin
	// Outside the vbl branch, so a command landing on the frame boundary is
	// still counted. The per-frame counters below cannot do this -- they are
	// cleared there -- and a once-per-transition event is precisely the sort
	// that hides in the one cycle a counter is being reset.
	if (rst_sys)                 zlat_tot <= 16'd0;
	else if (z80_dbg_latch_rd && !(&zlat_tot)) zlat_tot <= zlat_tot + 16'd1;

	if (vbl_rise) begin
		zoki_lat  <= zoki_cnt;  zoki_cnt  <= 16'd0;
		zym_lat   <= zym_cnt;   zym_cnt   <= 16'd0;
		zlat_lat  <= zlat_cnt;  zlat_cnt  <= 16'd0;
		zbank_lat <= zbank_cnt; zbank_cnt <= 16'd0;
	end else begin
		if (z80_dbg_oki_wr   && !(&zoki_cnt))  zoki_cnt  <= zoki_cnt  + 16'd1;
		if (z80_dbg_ym_wr    && !(&zym_cnt))   zym_cnt   <= zym_cnt   + 16'd1;
		if (z80_dbg_latch_rd && !(&zlat_cnt))  zlat_cnt  <= zlat_cnt  + 16'd1;
		if (z80_dbg_bank_wr  && !(&zbank_cnt)) zbank_cnt <= zbank_cnt + 16'd1;
	end
end

// IPL ASSERTIONS, WHICH ARE NOT THE SAME THING AS ACKNOWLEDGEMENTS.
//
// irq_cnt above counts what the CPU ACCEPTED. Magical Crystals reads zero
// there on hardware while its 68000 runs at a healthy ~46,800 bus cycles a
// frame, and zero is ambiguous in exactly the way that matters:
//
//   kaneko_irq never asserts        -> the fault is in the interrupt path
//   it asserts and the CPU ignores  -> the 68000 is masked at level 7, so it
//                                      never got through its self-test and the
//                                      fault is upstream, nowhere near the IRQ
//
// Those want opposite work, and no counter in the build could tell them apart.
// MAME says the game spins in an idle loop at 01f820 -- 2.7 million fetches in
// 600 frames -- and does all of its work in the handlers, so "no interrupts"
// is a complete explanation of the black screen either way.
//
// COUNTED AS A LEVEL, NOT AN EDGE, and the first version got this wrong.
//
// Counting rising edges of "some IPL line is low" cannot answer the question.
// kaneko_irq HOLDS a request until it is acknowledged, the way MAME's
// HOLD_LINE does, so a request the CPU never answers asserts ONCE and then
// stays asserted -- no further edges, a per-frame count of zero, and a reading
// identical to never asserting at all. The two cases it was built to separate
// both read dark.
//
// Clocks with IPL asserted, saturating, is unambiguous:
//
//   0        never asserted            -> the fault is the interrupt path
//   0xffff   asserted and HELD all frame -> the 68000 is masked at level 7 and
//                                          never finished its self-test
//   small    asserted and promptly acknowledged -> working normally
//
// All sixteen blocks lit versus all dark is also the easiest thing to read off
// a photograph, which is how this gets looked at.
reg [15:0] ipl_cnt, ipl_cnt_lat;
wire       ipl_any = (cpu_ipl_n != 3'b111);
always @(posedge clk_sys) begin
	if (vbl_rise) begin ipl_cnt_lat <= ipl_cnt; ipl_cnt <= 16'd0; end
	else if (ipl_any && !(&ipl_cnt)) ipl_cnt <= ipl_cnt + 16'd1;
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
// Z80 SOUND-PORT CENSUS, to diff against MAME's on the same title.
//
// tools/mame_z80_ports.lua counts the same four things in the oracle. For
// Wing Force it reports, per second: the YM2151 written 232-540 times and its
// status polled about 7,000, continuously, in menu AND demo; the OKI written
// only during the demo. Per frame that is roughly:
//
//            YM writes   YM status reads   OKI writes
//   menu         8            120               0
//   demo        18            107               0-1
//
// Numbers far below those mean the Z80 is not getting through its driver
// loop; near zero means it is not running at all. The fourth row is how many
// 4 MHz ticks were LOST to a ROM-cache stall, saturating, which says whether
// the cause is the cache this session introduced.
wire        z80_io_wr = ~z80_iorq_n && ~z80_wr_n;
wire        z80_io_rd = ~z80_iorq_n && ~z80_rd_n;
reg         z80_io_wr_d, z80_io_rd_d;
always @(posedge clk_sys) begin
	z80_io_wr_d <= z80_io_wr;
	z80_io_rd_d <= z80_io_rd;
end
// Edges, because the Z80 holds its strobes for a whole 4 MHz bus cycle -- a
// dozen clk_sys ticks -- and a level would count each access twelve times and
// be incomparable with MAME's per-access figures.
wire        z80_io_wr_e = z80_io_wr && !z80_io_wr_d;
wire        z80_io_rd_e = z80_io_rd && !z80_io_rd_d;
wire [7:0]  z80_port    = z80_a[7:0];

reg [15:0] z80_ymw_cnt,  z80_ymw_lat;
reg [15:0] z80_ymr_cnt,  z80_ymr_lat;
reg [15:0] z80_okiw_cnt, z80_okiw_lat;
reg [15:0] z80_stl_cnt,  z80_stl_lat;
// THE ADDRESS HALF, LATCHED, so a write can be attributed to a register.
// The YM2151 is written as a pair: register number to port 02, value to port
// 03. Watching the delivered strobe rather than the Z80's bus, because the
// delivery is one-shot and held for cen_p1 -- counting the CPU side would
// count requests, not what the chip actually saw.
reg  [7:0] ym_reg_addr;

// THE STATUS BYTE THE Z80 READS BACK, which is what the sequencer runs on.
//
// MAME's Wing Force polls this about 120 times a frame and sees 0x02 -- Timer
// B set, Timer A clear -- for 87% of them. It ticks only when bit 0 (Timer A)
// appears, roughly 4 to 6 times a frame, and answers each tick with one write
// to register 0x14 to reset the flag.
//
// This core polls at the same rate and writes 120 times a frame: one per poll.
// That is what a Timer A flag STUCK SET looks like -- the driver ticks every
// time it looks, so the sequence runs about thirty times too fast and collapses.
//
// So the reading that settles it is the status byte itself. Latched on the
// read, and counted two ways: how often bit 0 is set, and how often the byte
// is anything other than MAME's dominant 0x02.
reg  [7:0] ym_status_lat;
reg [15:0] ym_ta_cnt, ym_ta_lat;      // polls with bit 0 (Timer A) set
always @(posedge clk_sys) begin
	if (rst_sys) begin
		ym_status_lat <= 8'd0; ym_ta_cnt <= 16'd0; ym_ta_lat <= 16'd0;
	end else if (vbl_rise) begin
		ym_ta_lat <= ym_ta_cnt; ym_ta_cnt <= 16'd0;
	end else if (z80_io_rd_e && (z80_port[7:1] == 7'h01)) begin
		ym_status_lat <= z80_ym_dout;
		if (z80_ym_dout[0] && !(&ym_ta_cnt)) ym_ta_cnt <= ym_ta_cnt + 16'd1;
	end
end
// The top-level wires, not a hierarchical reference into the instance. These
// are kaneko_z80snd's OUTPUTS and are already brought out here, so reaching
// inside was never necessary. Quartus does not resolve a hierarchical
// reference the way the simulator does -- it said "can't resolve reference to
// object ym_cs_n" and failed synthesis in seven seconds, which is at least a
// loud failure rather than a misleading one.
//
// (A comment must not put the simulator's name at the start of a line: it is
// parsed as a pragma. Recorded against kaneko_mixer.sv and walked into again
// writing this one.)
wire       ym_deliv  = ~z80_ym_cs_n && ~z80_ym_wr_n && z80_ym_cen_p1;
wire       ym_reg_wr = ym_deliv && z80_ym_a0;           // the data half
always @(posedge clk_sys) begin
	if (rst_sys)                     ym_reg_addr <= 8'd0;
	else if (ym_deliv && !z80_ym_a0) ym_reg_addr <= z80_ym_din;
end

// WHERE THE 68000 IS, for a game that runs and never enables interrupts.
// Magical Crystals shows a healthy bus-cycle count and zero interrupts
// acknowledged, which means it is executing and looping somewhere before it
// ever sets its interrupt mask. The address it keeps touching says where.
reg [15:0] bus_a_hi_lat, bus_a_lo_lat;
// THE SAME ADDRESS, HELD STILL FOR A WHOLE FRAME.
//
// bus_a_*_lat update on every acknowledged access, so what the overlay draws
// changes thousands of times while the screen is being scanned. On a phone
// camera the rolling shutter then smears several different values down the
// block and it reads as noise -- which is what the first two Magical Crystals
// photographs showed, and it cost a round trip each time.
//
// These sample the same value once per frame at vblank, so the block is
// constant while it is drawn and a photograph of it is a number.
reg [15:0] bus_a_hi_run, bus_a_lo_run;
reg [15:0] bus_a_hi_frm, bus_a_lo_frm;
reg [15:0] unmap_a_lat;
reg [15:0] unmap_cnt, unmap_cnt_lat;
always @(posedge clk_sys) begin
	if (rst_sys) begin
		bus_a_hi_lat <= 0; bus_a_lo_lat <= 0;
		bus_a_hi_run <= 0; bus_a_lo_run <= 0;
		bus_a_hi_frm <= 0; bus_a_lo_frm <= 0;
		unmap_a_lat  <= 0; unmap_cnt <= 0; unmap_cnt_lat <= 0;
	end else begin
		// Sampled on every acknowledged cycle, so what is displayed is
		// wherever it last was -- which for a tight loop is the loop.
		// The same edge the bus-cycle counter uses: an acknowledged cycle.
		if (~DTACKn && !dtack_d) begin
			bus_a_hi_lat <= {8'd0, eab[23:16]};
			bus_a_lo_lat <= {eab[15:1], 1'b0};
			bus_a_hi_run <= {8'd0, eab[23:16]};
			bus_a_lo_run <= {eab[15:1], 1'b0};
		end
		if (unmapped_hit) begin
			unmap_a_lat <= {unmapped_addr[15:1], 1'b0};
			if (!(&unmap_cnt)) unmap_cnt <= unmap_cnt + 1'd1;
		end
		if (vbl_rise) begin
			unmap_cnt_lat <= unmap_cnt; unmap_cnt <= 0;
			// One sample per frame, so the overlay draws a still number
			// rather than a smear the camera cannot resolve.
			bus_a_hi_frm <= bus_a_hi_run;
			bus_a_lo_frm <= bus_a_lo_run;
		end
	end
end

reg [15:0] ym_key_cnt,   ym_key_lat;     // writes to 0x08, KEY ON/OFF
reg [15:0] ym_tmr_cnt,   ym_tmr_lat;     // writes to 0x14, timer control
reg [15:0] ym_nz_cnt,    ym_nz_lat;      // clocks where jt51's output is non-zero
reg [15:0] mix_nz_cnt,   mix_nz_lat;     // clocks where the mixed output is non-zero
always @(posedge clk_sys) begin
	if (rst_sys) begin
		z80_ymw_cnt <= 0; z80_ymr_cnt <= 0; z80_okiw_cnt <= 0; z80_stl_cnt <= 0;
		ym_nz_cnt <= 0; mix_nz_cnt <= 0; ym_nz_lat <= 0; mix_nz_lat <= 0;
		ym_key_cnt <= 0; ym_tmr_cnt <= 0; ym_key_lat <= 0; ym_tmr_lat <= 0;
		// ym_reg_addr is NOT reset here: it has its own always block below,
		// and driving one register from two of them is two constant drivers
		// as far as Quartus is concerned -- eight errors, one per bit.
		z80_ymw_lat <= 0; z80_ymr_lat <= 0; z80_okiw_lat <= 0; z80_stl_lat <= 0;
	end else if (vbl_rise) begin
		z80_ymw_lat  <= z80_ymw_cnt;  z80_ymw_cnt  <= 0;
		z80_ymr_lat  <= z80_ymr_cnt;  z80_ymr_cnt  <= 0;
		z80_okiw_lat <= z80_okiw_cnt; z80_okiw_cnt <= 0;
		ym_nz_lat    <= ym_nz_cnt;    ym_nz_cnt    <= 0;
		ym_key_lat   <= ym_key_cnt;   ym_key_cnt   <= 0;
		ym_tmr_lat   <= ym_tmr_cnt;   ym_tmr_cnt   <= 0;
		mix_nz_lat   <= mix_nz_cnt;   mix_nz_cnt   <= 0;
		z80_stl_lat  <= z80_stl_cnt;  z80_stl_cnt  <= 0;
	end else begin
		if (z80_io_wr_e && (z80_port[7:1] == 7'h01)) z80_ymw_cnt  <= z80_ymw_cnt  + 1'd1;
		if (z80_io_rd_e && (z80_port[7:1] == 7'h01)) z80_ymr_cnt  <= z80_ymr_cnt  + 1'd1;
		if (z80_io_wr_e && (z80_port      == 8'h0a)) z80_okiw_cnt <= z80_okiw_cnt + 1'd1;
		// PAST THE YM INTERFACE. The two rows above proved the Z80 writes the
		// chip at MAME's rate while the board is silent, so the question moved
		// downstream: is jt51 producing anything, and does it survive the mix?
		if (ym2151_l != 16'sd0 && !(&ym_nz_cnt)) ym_nz_cnt <= ym_nz_cnt + 1'd1;
		// WHICH YM REGISTER, not how many writes. The counts already match
		// MAME; the content is the open question, and two registers decide
		// whether anything is audible at all.
		if (ym_reg_wr && (ym_reg_addr == 8'h08) && !(&ym_key_cnt))
			ym_key_cnt <= ym_key_cnt + 1'd1;
		if (ym_reg_wr && (ym_reg_addr == 8'h14) && !(&ym_tmr_cnt))
			ym_tmr_cnt <= ym_tmr_cnt + 1'd1;
		if (z80_mix_l != 16'd0 && !(&mix_nz_cnt)) mix_nz_cnt <= mix_nz_cnt + 1'd1;
		// Saturating: a fully starved Z80 loses far more than 65535 ticks a
		// frame, and a wrapped counter would read as a healthy small number.
		if ((z80_cediv == 4'd0) && z80_stall && !(&z80_stl_cnt))
			z80_stl_cnt <= z80_stl_cnt + 1'd1;
	end
end

reg        oki_we_eff_d;
always @(posedge clk_sys) oki_we_eff_d <= oki_we_eff;
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
		// Counted on the EDGE, not the level. kaneko_bus pulses for one cycle
		// but the Z80's decode is a level held for a whole 4 MHz bus cycle --
		// about twelve of these -- so counting the level would read twelve
		// times higher on Wing Force and be incomparable with every other
		// game. jt6295 latches on the same falling edge.
		if (oki_we_eff && !oki_we_eff_d)   oki_wr_cnt   <= oki_wr_cnt   + 1'd1;
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

// WHAT THE CPU ASKED FOR THAT WE DID NOT ANSWER.
//
// Added for the Blaze On black screen: the overlay showed bus cycles running
// and interrupts at zero, which says the 68000 is executing but has them
// masked — stuck in early init. Simulation runs the same ROM and reaches its
// main loop, so the difference is something the harness does not model, and
// static reading of the memory map had already been wrong twice.
//
// An unmapped access is acknowledged, so it never hangs the bus; it just
// returns a value the game did not expect. That makes it invisible unless the
// address is reported, and it is the one thing that distinguishes "the map is
// wrong" from "the map is right and something else is". blazeon_map has at
// least one window this core does not decode — 0x980000, the second VU-002's
// registers, which MAME backs with plain RAM because the game touches it.
//
// The address is LATCHED AND HELD, not sampled per frame: a stuck CPU asks
// for the same thing every time, and a value that survives to the next frame
// is one a photograph can read.
// One sample per frame of wherever the CPU happens to be. A stuck 68000 is
// looping over a handful of addresses, so a photograph lands somewhere inside
// the loop — which names the routine even though it does not name the
// instruction. Sampled at vblank_rise rather than continuously, because a
// value that changes every bus cycle is not photographable.
reg [23:1] bus_addr_lat;
always @(posedge clk_sys) if (vbl_rise) bus_addr_lat <= eab;

// WHICH EXCEPTION THE 68000 TOOK.
//
// Blaze On parks in a three-instruction loop at 0x000100:
//
//     4e71  NOP     4e71  NOP     60fa  BRA.S -6
//
// and FIFTY-EIGHT of its exception vectors point at it. That was proved from
// the ROM image, and it matches every reading on screen: full-speed execution
// (a six-byte loop runs entirely out of the ROM cache), a[23:9] always zero,
// no unmapped accesses, no interrupts. The game has not stalled in init — it
// has crashed.
//
// The loop address cannot say WHICH exception, because they all land there.
// The vector FETCH can: the 68000 reads the vector from 0x000008-0x0000ff
// immediately before jumping, and once it is in the loop it never reads there
// again, so the last such read stays latched. vector = byte address / 4, and
// eab is bits 23:1 of the byte address, so the number is eab[7:2].
//
//   2 bus error (impossible here, BERR is never asserted)   3 address error
//   4 illegal instruction   5 divide by zero   6 CHK   7 TRAPV
//   8 privilege violation   9 trace   10 line-A   11 line-F
reg [5:0] vec_lat;
always @(posedge clk_sys) begin
	if (cpu_rst) vec_lat <= 6'd0;
	// On the DTACK edge, so one completed access latches once. eab[23:8]==0
	// is a byte address below 0x100, which is the vector table and nothing
	// else — the loop itself sits at 0x100 and is excluded deliberately.
	// eab[23:7], NOT eab[23:8]. eab is bits 23:1 of the byte address, so
	// eab[23:8]==0 admits byte addresses up to 0x1ff — which includes the park
	// loop at 0x100-0x105, and the loop then overwrote the latch with its own
	// fetches every pass. The instrument was measuring itself. CLAUDE.md:
	// check the instrument could have seen it.
	else if (~DTACKn && !dtack_d && eRWn && (eab[23:7] == 17'd0))
		vec_lat <= eab[7:2];
end

reg [23:1] unmapped_addr_lat;
reg [15:0] unmapped_cnt, unmapped_cnt_lat;
always @(posedge clk_sys) begin
	if (cpu_rst) begin
		unmapped_addr_lat <= 23'd0;
		unmapped_cnt <= 16'd0; unmapped_cnt_lat <= 16'd0;
	end else begin
		if (unmapped_hit) begin
			unmapped_addr_lat <= unmapped_addr;
			if (~&unmapped_cnt) unmapped_cnt <= unmapped_cnt + 1'd1;
		end
		if (vbl_rise) begin
			unmapped_cnt_lat <= unmapped_cnt;
			unmapped_cnt     <= unmapped_hit ? 16'd1 : 16'd0;
		end
	end
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
	// The visible window is per game — 256x224 from line 16 on this board,
	// 320x232 from line 0 on the Blaze On board. The totals are shared.
	.h_vis(CFG_H_VIS), .v_vis(CFG_V_VIS),
	.v_start(CFG_V_START), .h_sync_start(CFG_HSYNC), .h_start(CFG_H_START),
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
// kan_spr @ byte 0x280000 on both, so word 0x140000.

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
// ONE VIEW2 CHIP OR TWO.
//
// Layers 2 and 3 are the second chip. The Blaze On board has only one, and
// there is no second chip to read a disable bit from — its register window is
// not even decoded there — so the layers are masked off rather than left to
// whatever the undriven register file happens to hold. An enabled layer
// fetching from an unloaded tile region draws garbage over the picture, which
// is the "renders a plausible wrong picture rather than failing" case hard
// rule 9 is about.
wire [3:0] lay_en_live = { ~c1r4[4]  & TWO_CHIPS, ~c1r4[12] & TWO_CHIPS,
                           ~c0r4[4], ~c0r4[12] };
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
// Layer 1 sits two pixels further along than layer 0. That is REAL VIEW2
// behaviour, straight from MAME:
//
//   m_tmap[0]->set_scrolldx(-m_dx,     ...)
//   m_tmap[1]->set_scrolldx(-(m_dx+2), ...)
//
// and the game cancels it by writing layer 1's scroll two LOWER — 0x72c0
// against 0x7340, 459 against 461. Both halves are verified on the board, and
// the arithmetic makes the two layers coincide exactly.
//
// The board nevertheless draws them two pixels apart, and this offset is the
// only +2 anywhere in the path. `O[21]` removes it at run time so that can be
// tested by looking rather than argued about: if the picture comes good with
// it off, the game's compensation is NOT reaching the engine despite the
// overlay reading correct, and the fault is between the latch and the address
// engine. If nothing changes, this is not the cause.
//
// A switch, not an edit: the offset is correct per MAME and Explosive Breaker
// depends on it, so it must not be quietly removed to make one game look
// right — hard rule 9.
// FOUR POSITIONS, so the answer can be found by looking instead of by me
// getting the sign right in prose — which I have not managed twice running.
//
//   +2   what MAME does, and what the code has always done
//    0   no offset at all
//   -2   the opposite offset
//   +4   twice MAME's
//
// Larger dx makes the layer sample further right in the tilemap, so the IMAGE
// moves LEFT. Whichever position makes Blaze On's copyright screen and Atlas
// logo line up is the measurement; the difference from +2 is the bug.
wire signed [10:0] l1_dx =
      (status[37:35] == 3'd1) ? V2_DX_CFG
    : (status[37:35] == 3'd2) ? 11'(V2_DX_CFG - 11'sd2)
    : (status[37:35] == 3'd3) ? 11'(V2_DX_CFG + 11'sd4)
                              : 11'(V2_DX_CFG + 11'sd2);
wire [43:0] lay_dx = { 11'(l1_dx), 11'(V2_DX_CFG),
                       11'(l1_dx), 11'(V2_DX_CFG) };
wire [43:0] lay_dy = { 11'(V2_DY_CFG), 11'(V2_DY_CFG), 11'(V2_DY_CFG), 11'(V2_DY_CFG) };

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
// TILEMAPS OFF: no line fetch is started, so the tile ROM feeder issues no
// SDRAM requests at all. Paired with the existing sprite switch — which holds
// kaneko_spr_sys in reset and therefore genuinely stops its fetching, not just
// its output — this leaves the 68000 as the ONLY consumer of SDRAM on a board
// whose OKI is idle.
//
// It exists to settle one question that nothing else can: both Blaze On board
// titles park their CPU on hardware while running 491 frames in simulation,
// and the one thing the boot harness does not model is the video path
// competing for memory. With both switches off the contention is gone. If the
// CPU still parks, contention is not the cause and the whole line of enquiry
// is closed; if it boots, it is.
wire tile_off = status[17];
wire line_start = ce_pix && (hcnt == 10'd0) && ~tile_off;

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

kaneko_tmap_line #(.H_VIS(320)) u_line
(
	.clk(clk_sys), .rst(rst_sys),
	.start(line_start), .h_active(CFG_H_VIS),
	.line_y(screen_y + 9'd1), .busy(line_busy),

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
	// cpu_rst, NOT rst_sys: cpu_rst adds ~rom_loaded. Released on rst_sys
	// alone the sprite system starts parsing and fetching before the ROM is in
	// SDRAM, latches state from whatever it read, and never recovers. The
	// symptom was Blaze On showing no sprites at all until the OSD sprite
	// switch was toggled off and on, which re-reset it after the load had
	// finished. A toggle that fixes something is a reset that came too early.
	.clk(clk_sys), .rst(cpu_rst | spr_off),
	.frame_start(vbl_rise),
	.keep_sprites(keep_sprites),
	// OFF IS THE DEFAULT. status resets to zero, so the menu is ordered with
	// Off first and the sense is straight rather than inverted -- reversing one
	// without the other silently swaps every position.
	.skip_en(status[15]),

	.sprite_count(SPR_COUNT_CFG), .spr_elements(SPR_ELEMENTS_CFG),
	.sprite_xoffs(SPR_XOFFS_CFG), .sprite_yoffs(SPR_YOFFS_CFG),
	.visarea_min_y(SPR_MIN_Y),
	.wide_screen(SPR_WIDE), .fliptype(SPR_FLIPTYPE),
	// MAME clips sprite drawing to the visible area — and the visible area is
	// PER GAME. This was hardcoded to Explosive Breaker's 0..255 / 16..239, so
	// on the Blaze On board, which is 320 wide and starts at line 0, sprites
	// lost their last 64 columns and their top 16 rows. On hardware that read
	// as sprites sitting about a sixteenth of the screen too low (16 of 232)
	// and appearing an eighth too early, drawn half-complete at the boundary —
	// in Blaze On and Wing Force identically, which is what said it was shared
	// code and not per-game data.
	//
	// Derived from the geometry the game table already publishes, so it cannot
	// drift from the screen it is clipping to.
	.clip_x0(10'd0), .clip_x1(CFG_H_VIS - 10'd1),
	.clip_y0(CFG_V_START), .clip_y1(CFG_V_START + CFG_V_VIS - 10'd1),

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
	.tile_colbase(TILE_COLBASE_CFG),
	.spr_colbase(SPR_COLBASE_CFG),

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

// Service is a DIP, not a button: held, and off by default. Flip screen is a
// DIP too but is no longer offered -- see dip_flip below.
// Active low, so 1 is "not set".
// HELD AT THE FACTORY POSITION, and no longer an OSD option.
//
// This is the board's Flip_Screen DIP -- bit 0 of the word at c00000/e00000,
// active low, so 1 is Off, which is what MAME defaults it to.
//
// It was exposed in the OSD and did nothing a player could see. The game reads
// the DIP and flips its OWN rendering, which means writing mirrored scroll and
// tile attributes, and this core does not implement that path: fliptype is
// hardwired off in kaneko_gamecfg. Offering the switch let a user select a
// state the renderer cannot draw.
//
// Orientation is handled by the Rotation option, which turns the finished
// picture through MiSTer's framebuffer and is a different mechanism entirely.
//
// Bit 13 is now unused. The OSD names its bits explicitly, so nothing
// renumbered when the line went.
wire dip_flip    = 1'b1;
wire dip_service = ~status[14];

// THE INPUT WORDS ARE ASSEMBLED DIFFERENTLY PER BOARD, NOT JUST MOVED.
//
// This is the one per-game difference that is not a number. On this board the
// start and coin bits are in SYSTEM; on the Blaze On board they are in the P1
// and P2 words alongside that board's DIP switches, and SYSTEM carries only
// service, tilt and the service coin:
//
//   explbrkr / mgcrystl        blazeon / wingforc
//   P1     b0  flip DIP        DSW2_P1  b0-7  difficulty, lives, demo, service
//          b1  service DIP              b8-13 P1 up/down/left/right/B1/B2
//          b8-13 P1 controls            b14   START1     b15  COIN1
//   P2     b8-13 P2 controls    DSW1_P2 b0-7  Coin_A, Coin_B
//   SYSTEM b8  START1                   b8-13 P2 controls
//          b9  START2                   b14   START2     b15  COIN2
//          b10 COIN1            UNK     unused
//          b11 COIN2            SYSTEM  b13 service  b14 tilt  b15 service coin
//          b12 service
//          b13 tilt
//          b14 service coin
//
// Everything is active low on both. Blaze On also has REAL DIP switches where
// Explosive Breaker configures everything through its test mode, so those bits
// come from the OSD rather than reading as "not set".
wire [5:0] p1_bits = { ~p1_b2, ~p1_b1, ~p1_right, ~p1_left, ~p1_down, ~p1_up };
wire [5:0] p2_bits = { ~p2_b2, ~p2_b1, ~p2_right, ~p2_left, ~p2_down, ~p2_up };

// ---- Explosive Breaker / Magical Crystals
//
// THESE TWO ARE NOT THE SAME WORDS, and every difference is in the bits that
// are NOT there. A bit MAME never mentions in INPUT_PORTS_START reads ZERO; a
// bit declared IPT_UNKNOWN with IP_ACTIVE_LOW reads ONE. The two look
// identical in a listing and are opposite on the bus. This is the fault that
// parked Blaze On for a session -- its SYSTEM word is 0xFF00 idle, not
// 0xFFFF -- and the same reading was never applied to these two games.
//
//                       Explosive Breaker            Magical Crystals
//   c00000/e00000  bits 2-7 DIPUNUSED   -> 1    bits 2-7 DIPUNUSED   -> 1
//   c00002/e00002  low byte  absent     -> 0    low byte IPT_UNKNOWN -> ff
//   c00004/e00004  low byte  absent     -> 0    low byte IPT_UNKNOWN -> ff
//   c00006         port exists, empty   -> 0    NO SUCH PORT
//
// Explosive Breaker plainly never tests the ones that differ, since it has run
// correctly all along. Magical Crystals reaches its test screen and stops with
// the 68000 masked at level 7, which is what sent this table back to
// INPUT_PORTS_START to be read bit by bit a second time.
wire [7:0]  eb_lo   = (game_id == 8'd1) ? 8'hff : 8'h00;   // 1 = mgcrystl

// BITS 7..2 ARE ONES, NOT ZEROS. They were zeros, and the comment above said
// they were "absent". They are not absent in either game:
//
//   PORT_DIPUNUSED_DIPLOC( 0x0004, 0x0004, "SW1:3" )  /* Listed as "Unused" */
//   ... 0x0008, 0x0010, 0x0020, 0x0040, 0x0080, all the same shape
//
// PORT_DIPUNUSED_DIPLOC(mask, default, loc) with default EQUAL TO THE MASK is a
// DIP switch in the off position, and these are active low, so the board pulls
// every one of them HIGH. bakubrkr and mgcrystl declare them identically.
//
// Explosive Breaker never tests them, which is why it has run correctly for
// weeks with all six driven low and why this was not noticed. "Listed as
// Unused" in the manual describes the CABINET, not the program -- it says
// nothing about whether the game reads the word.
wire [15:0] in_p1_eb  = { 2'b11, p1_bits, 6'b111111, dip_service, dip_flip };
wire [15:0] in_p2_eb  = { 2'b11, p2_bits, eb_lo };
wire [15:0] in_sys_eb = { 1'b1, ~svc_coin, ~pause, 1'b1,
                          ~coin2, ~coin1, ~start2, ~start1, eb_lo };

// ---- Blaze On board. The DIPs are OSD switches; default all ones, which is
// every setting at its factory position because they are active low.
wire [7:0]  dsw2 = { dip_service, 7'h7f };
wire [15:0] in_p1_bz  = { ~coin1, ~start1, p1_bits, dsw2 };
wire [15:0] in_p2_bz  = { ~coin2, ~start2, p2_bits, 8'hff };
// SYSTEM on this board reads 0xFF00 IDLE, NOT 0xFFFF. From MAME's
// INPUT_PORTS_START(blazeon), the port defines only the high byte:
//
//   0x8000  IPT_SERVICE1            (service coin)
//   0x4000  IPT_TILT
//   0x2000  PORT_SERVICE_NO_TOGGLE  (the service-mode DIP)
//   0x1000..0x0100  IPT_UNKNOWN     (active low, so 1 when idle)
//   0x00ff  NOT DEFINED AT ALL
//
// Undefined bits in a MAME port read ZERO. This core returned all ones, and
// the bus-trace diff against MAME caught it as the first divergence past the
// self-test:
//
//     ours   c00006 R ffff        mame   c00006 R ff00
//
// The game reads SYSTEM, tests the low byte, finds it non-zero and jumps to
// the park loop at 0x000100 — which is why the 68000 was found spinning in
// three instructions there with no exception ever taken. An idle input word is
// not "all ones"; it is whatever the board actually drives, and the unwired
// half of this one drives nothing.
wire [15:0] in_sys_bz = { ~svc_coin, ~pause, dip_service, 5'h1f, 8'h00 };

wire [15:0] in_p1     = INPUTS_BLAZEON ? in_p1_bz  : in_p1_eb;
wire [15:0] in_p2     = INPUTS_BLAZEON ? in_p2_bz  : in_p2_eb;
wire [15:0] in_system = INPUTS_BLAZEON ? in_sys_bz : in_sys_eb;

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
// THE Z80 SOUND-PORT CENSUS, 2026-08-22. Was the OKI chain for one build.
//
// That build answered its question: the OKI rows lit whenever Wing Force made
// any sound and were dark when it did not, so the whole OKI path -- writes,
// sample fetch, channel busy, non-zero output -- is correct and driven. The
// fault is upstream, in the Z80 not producing sound at all at those moments,
// and Wing Force's music is the YM2151 rather than the OKI (MAME writes the YM
// 232-540 times a second continuously; the OKI only during the demo).
//
// So the rows now count what the Z80 actually does, to diff against
// tools/mame_z80_ports.lua on the same title. Expected per frame, from MAME:
//
//   row 4  YM2151 writes        menu ~8    demo ~18
//   row 5  YM2151 status reads  menu ~120  demo ~107
//   row 6  OKI writes           menu 0     demo 0-1
//   row 7  4 MHz ticks LOST to a ROM-cache stall, saturating at ffff
//
// Rows 4-6 near MAME's numbers with no sound means the chips are being driven
// and the fault is past them. All three near zero means the Z80 is not getting
// round its loop -- and row 7 says whether the cache this session introduced
// is why. Row 7 saturated is the smoking gun for that; row 7 small clears it.
//
// Blaze On is NOT a control for this. Its music and effects sound right, which
// is not the same as being complete, and nobody has compared it against
// anything. Run the census there too.
// ROWS MOVED DOWNSTREAM, 2026-08-22. The census answered its question: with
// Wing Force silent, the Z80 wrote the YM about 15 times a frame and polled its
// status a hundred-odd times, which is MAME's rate (8-18 and ~107-120). The
// CPU, its ROM cache -- measured at a 0.5% miss rate against a real MAME fetch
// trace -- and the command path are all healthy, and the fault is past the
// chip's write port. So:
//
//   row 4  YM2151 writes per frame          the control, should stay ~15
//   row 5  clocks with jt51's output non-zero
//   row 6  clocks with the MIXED output non-zero
//   row 7  4 MHz ticks lost to a ROM-cache stall
//
// Row 5 dark with row 4 healthy means jt51 is being written and producing
// nothing -- its state or its enables. Row 5 lit and row 6 dark means the
// mix is eating it, which is where the OKI is summed in at full weight next
// to the YM before the halving.
// WHICH REGISTERS, against MAME's own figures for the same title.
// tools/mame_ym_regs.lua counts 900 frames of a working Wing Force:
//
//   0x14  timer control  3506 writes  ~3.9 per frame   the tempo loop
//   0x08  KEY ON/OFF     1007 writes  ~1.1 per frame   the notes themselves
//
// Row 4 near 4 and row 5 near 1 means the driver is doing what the oracle's
// does and the fault is inside jt51 or past it. Row 4 healthy with row 5 at
// zero means the tempo loop runs and no note is ever keyed, which is a
// different fault from anything chased so far. Both at zero means the writes
// are not reaching the chip after all.
// WHERE THE CPU IS. The YM census answered its question on the Blaze On
// board and is no use on Magical Crystals, which has no Z80 at all -- four
// dark rows that mean nothing. It runs with a healthy bus-cycle count and
// ZERO interrupts acknowledged, so it is looping before it enables them.
//
//   row 4  last bus address, high half (a[23:16])
//   row 5  last bus address, low half  (a[15:0])
//   row 6  last UNMAPPED address, low half
//   row 7  unmapped accesses per frame -- zero means it is not lost, it is
//          waiting for something that never comes
// THE SCRATCH BLOCK, POINTED AT THE Z80 FOR WING FORCE.
//
// It carried SDRAM occupancy for the sprite-bitmap move; that question is
// answered -- the bitmap does not fit -- and Tier 2 has left the core, so the
// counters it fed are gone with it.
//
// Wing Force plays its in-game music and no OKI at all: no sound effects and
// nothing in the attract demo, which is probably one fault rather than two if
// the attract music is PCM. MAME's Z80 drives the chip perfectly well there --
// measured with tools/mame_z80_ports.lua, 2 to 54 writes a second to port 0a
// with bank writes on 0c -- so the game is not simply quiet.
//
// The OKI chain answered its question already: on the title screen all four of
// its stages run, and in the attract demo the FIRST one is zero -- the Z80
// never writes port 0a at all. So the chip, its ROM, its banking and its clock
// are right, and the commands are simply not being issued.
//
// That moves the question to the Z80 itself, and the measurement above says
// what to expect. The 68000 barely speaks: `latch_w` is zero for the whole
// attract demo, so the Z80 runs that sequence AUTONOMOUSLY, pacing itself off
// the YM2151's timer flags -- which it polls about seven thousand times a
// second, roughly 117 a frame at 60 Hz.
//
// This core has been bitten by exactly that before. When jt51 was clocked from
// `ce` rather than `ym_ce`, a Z80 stalled on a program-ROM miss took the
// YM2151's timers down with it, and the driver fell behind its own sequencer
// and wedged -- music for a split second and then silence, with the stall
// counter reading half its bits.
//
// So these four are the Z80's own chain:
//
//   ym_rd    YM status polls -- the sequencer's clock. Wants about 0075 a frame
//   ym_wr    YM register writes -- about 0008 a frame while music plays
//   oki_wr   OKI commands issued
//   stall    cycles the Z80 was held waiting on a program-ROM miss
//
// Read the fourth first. A large stall count with a low poll count is a
// starved Z80, and everything else follows from it.
wire [15:0] oki_row_val = (screen_y < 9'd46) ? z80_ymw_lat
                        : (screen_y < 9'd52) ? z80_ymr_lat
                        : (screen_y < 9'd58) ? lw_tot
                                             : z80_okiw_lat;
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
// RESTORED to the live joystick word. The unmapped-access diagnostic that
// borrowed this row did its job: the memory map is now verified from three
// directions — the MAME bus trace, the per-game page table, and the register
// readout — and nothing is unmapped that should not be.
wire       joy_set = joystick_0[joy_bit];

// Row 8, white: sprite passes that did not finish before the next frame
// started. Zero is correct. Non-zero means the renderer ran out of frame —
// 1024 sprites at one pixel per clock, each pixel able to miss a 2.25 MB
// sample of ROM, is the one part of the video path with no fixed upper bound.
wire in_spr_row = (screen_y >= 9'd72) && (screen_y < 9'(72 + 6))
               && (screen_x < 9'(16 * ALV_BIT_W));
wire [3:0] spr_bit = 4'd15 - 4'(screen_x[6:3]);
// RESTORED. This row is sprite passes that did not finish before the next
// frame started, and it is the measurement that answers a real open question:
// the Blaze On board carries TWO VU-002 sprite chips reading one shared sprite
// list, for "double sprite bitmap size". This core renders that list with ONE
// engine into a 320-wide bitmap, which covers the same area — but unlike MAME
// it has a real per-frame time budget. If this row goes non-zero in a busy
// scene, one engine is not keeping up where two chips did.
wire       spr_set = spr_overrun_lat[spr_bit];

// Rows 10 and 11: the unmapped access. Added for the Blaze On black screen,
// where every other row read zero and there was nothing left to look at.
//
//   10  orange  unmapped accesses this frame, 16 bits
//   11  blue    the address of the last one, a[23:8] — the top 16 bits of the
//               23-bit word address, so 0x980000 reads as 9800 and a page is
//               identifiable without counting to 23
//
// Below the joystick row and separated from it, because they are a different
// kind of readout: row 10 is per-frame like the counters above, row 11 is a
// latched value that HOLDS until the next unmapped access, which is what makes
// a stuck CPU photographable.
wire in_unm_row = (screen_y >= 9'd92) && (screen_y < 9'(92 + 6))
               && (screen_x < 9'(16 * ALV_BIT_W));
wire [3:0] unm_bit = 4'd15 - 4'(screen_x[6:3]);
wire       unm_set = unmapped_cnt_lat[unm_bit];

wire in_uad_row = (screen_y >= 9'd100) && (screen_y < 9'(100 + 6))
               && (screen_x < 9'(16 * ALV_BIT_W));
wire [3:0] uad_bit = 4'd15 - 4'(screen_x[6:3]);
wire       uad_set = unmapped_addr_lat[uad_bit + 4'd8];

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
// A SOLID BACKDROP, because three readings in a row were unreadable.
//
// The overlay used to paint only where a block is, so the game showed through
// the one-column gap between blocks and through every row's background. On a
// black screen that is fine and it is how Magical Crystals was diagnosed. Over
// a bright, busy picture -- Wing Force's ranking screen, a playfield full of
// sprites -- the blocks blend into the artwork and the readings are guesses.
//
// It now covers a solid rectangle over the whole readout: the panel is opaque
// black, the blocks are drawn on it, and nothing behind it is visible. The
// measurements this exists to take are taken on BUSY screens by definition,
// since that is where the bandwidth goes, so legibility over artwork is not a
// nicety.
wire in_dbg_panel = dbg_on
                 && (screen_y >= 9'd12) && (screen_y < 9'd108)
                 && (screen_x < 9'(20 * ALV_BIT_W));

wire in_dbg_blk = (in_alive_row || in_irq_row || in_ovr_row || in_oki_row
                   || in_spr_row || in_joy_row
                   || in_unm_row || in_uad_row)
                && (screen_x[2:0] != 3'd7);

wire in_dbg   = dbg_on && in_dbg_panel;
wire dbg_bit  = in_alive_row ? alive_set : in_irq_row ? irq_set
              : in_ovr_row ? ovr_set : in_spr_row ? spr_set
              : in_joy_row ? joy_set
              : in_unm_row ? unm_set : in_uad_row ? uad_set : oki_set;
// Outside a block the panel is black; inside, the bit decides lit or dark red.
wire dbg_set  = in_dbg_blk && dbg_bit;
wire dbg_dark = in_dbg_blk && !dbg_bit;

// NIBBLE SEPARATORS, so a sixteen-bit row reads as four hex digits instead of
// sixteen blocks to be counted. Every fourth gap column is dim grey rather
// than black. Counting to sixteen off a photograph is where the misreadings
// have come from, and hex is what every number in the notes is written in.
wire dbg_tick = dbg_on && in_dbg_panel && !in_dbg_blk
              && (screen_x[2:0] == 3'd7) && (screen_x[4:3] == 2'd3);

wire [7:0] dbg_r = dbg_set ? ((in_irq_row || in_oki_row || in_spr_row
                                || in_joy_row || in_unm_row) ? 8'hff : 8'h00)
                 : dbg_dark ? 8'h40 : dbg_tick ? 8'h30 : 8'h00;
wire [7:0] dbg_g = dbg_set ? (in_irq_row ? 8'hc0 : in_unm_row ? 8'h80
                              : (in_joy_row || in_uad_row) ? 8'h00 : 8'hff)
                 : dbg_tick ? 8'h30 : 8'h00;
wire [7:0] dbg_b = (dbg_set && (in_ovr_row || in_spr_row || in_joy_row
                                || in_uad_row)) ? 8'hff
                 : dbg_tick ? 8'h30 : 8'h00;

// The game picture and the palette swatches both come out of the palette RAM,
// so they share the same decode.
// Both remaining views come out of the palette RAM, so they share the decode
// and differ only in which address was asked for.
wire [7:0] src_r = pal_r;
wire [7:0] src_g = pal_g;
wire [7:0] src_b = pal_b;

wire [7:0] out_r = in_dbg ? dbg_r : src_r;
wire [7:0] out_g = in_dbg ? dbg_g : src_g;
// dbg_b, not 8'h00. The blue channel was hardcoded off whenever the overlay
// was on, so the cyan overrun row rendered green, the white sprite row
// rendered yellow and the magenta joystick row rendered red — three rows
// documented by colour and none of them that colour. It never mattered while
// every one of them read zero, because a clear bit is dark red regardless.
wire [7:0] out_b = in_dbg ? dbg_b : src_b;

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

// ------------------------------------------------------------- rotation
//
// Explosive Breaker is ROT90 and Wing Force ROT270 -- two of the four games,
// turned in OPPOSITE directions -- so the game table supplies both whether and
// which way, and the OSD can override for a monitor that is already turned.
//
// screen_rotate lives in sys/arcade_video.v and is already in sys.qip, so this
// is an instantiation rather than a new dependency. It takes the video the
// core would have displayed, writes each frame into DDR3 with the axes
// swapped, and raises FB_EN so the scaler reads that instead.
wire       ROT_EN, ROT_CCW;
// OFF IS THE DEFAULT, DELIBERATELY. status defaults to zero, so position 0 is
// what a fresh boot gets, and rotation is not the right thing to hand somebody
// unasked: on an ordinary landscape monitor a turned game is a tall strip down
// the middle, and the framebuffer path costs a frame of latency that the
// direct video path does not. It is opt-in.
//
//   0 Off              1 Auto, from the game table
//   2 CW 90            3 CCW 90            4 180
//
// 180 IS NOT A ROTATION HERE, and that is why it was missing. screen_rotate
// gates its flip on `do_flip <= no_rotate && flip`, so a half turn is asked
// for by NOT rotating and raising flip; it keeps the framebuffer because
// `fb_en <= ~no_rotate | flip`. With flip tied to zero the option could never
// be reached, which left a physically portrait monitor with three settings
// that are each a quarter turn out and none that is right -- reported from
// hardware, and the reason this exists.
// AN OLD SETTING MUST SURVIVE THE FIELD GETTING WIDER.
//
// This was status[25:24] until 180 was added, and widening it to [26:24] gave
// bit 26 a meaning it had never had. A config saved by the older core can have
// that bit set to anything, so "CW 90" -- 10 in two bits -- comes back as 110,
// which is code 6, which the unused-code term below sends to NO ROTATION. The
// option still reads CW in the menu and the picture is upright, and nothing
// says why.
//
// That is the shape of the CRT report: rotation that worked on the previous
// release and not on the one after it, with no change to any rotation signal
// between them. Re-picking the option writes all three bits and clears it,
// which is why a setting touched since the upgrade behaves and one left alone
// does not.
//
// So codes 5, 6 and 7 fall back to what their LOW TWO BITS meant before: 101
// is Auto, 110 is CW, 111 is CCW. Only code 4 is new, and only code 4 is 180.
wire [2:0] rot_raw = status[26:24];
wire [2:0] rot_sel = (rot_raw >= 3'd5) ? {1'b0, rot_raw[1:0]} : rot_raw;
wire       rot_ccw = (rot_sel == 3'd1) ? ROT_CCW      // per game
                   : (rot_sel == 3'd3);               // 2 = CW, 3 = CCW
wire       rot_180 = (rot_sel == 3'd4);
// Positions 5..7 do not exist in the menu. They resolve to Off rather than to
// a rotation, because a spare code that lands on a real setting is the shape
// of bug this file has paid for repeatedly.
// Only code 4 reaches here as "at or above 4" now: 5 to 7 were folded onto
// their old two-bit meaning above.
wire       no_rot  = (rot_sel == 3'd0)                // explicitly off
                  || (rot_sel == 3'd4)                // 180 is a flip, not a turn
                  || ((rot_sel == 3'd1) && !ROT_EN);  // auto, game is ROT0
wire       video_rotated;

screen_rotate u_rotate
(
	.CLK_VIDEO(clk_sys), .CE_PIXEL(cep_d[1]),
	.VGA_R(out_r), .VGA_G(out_g), .VGA_B(out_b),
	.VGA_HS(hs_d[1]), .VGA_VS(vs_d[1]), .VGA_DE(de_d[1]),

	.rotate_ccw(rot_ccw), .no_rotate(no_rot), .flip(rot_180),
	.video_rotated(video_rotated),

	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL), .FB_LL(FB_LL),

	.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE), .DDRAM_RD(DDRAM_RD)
);

// screen_rotate has no FB_FORCE_BLANK port, so the core owns it. Low: the
// framebuffer's contents are what we want shown. It exists for cores that
// must blank the surface while reconfiguring it, which this one never does --
// the geometry only changes when a different game is loaded, and that is a
// reset.
assign FB_FORCE_BLANK = 1'b0;

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
