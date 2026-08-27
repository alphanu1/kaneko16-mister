// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// 68000 against the REAL memory system: loader, arbiter, SDRAM device model.
//
// WHY THIS EXISTS
//
// sim/cpu/kaneko_cpu_harness.sv acks every ROM fetch combinationally
// (`rom_ack_now = 1'b1`) and hands back the word in the same cycle. That
// harness proved the decode and the instruction stream, and it passed, and
// then the same RTL sat on hardware with the 68000 issuing no bus cycles at
// all. Everything an immediate-ack ROM cannot fail — arbitration, ack edge
// timing, burst latency, the loader and the CPU agreeing on where the ROM
// went — was untested, and the failure had to be in there somewhere.
//
// So this instantiates what the core instantiates, wired the way the core
// wires it: same clock divider, same reset, same ROM_BASE, same COL_BITS.
// The video port is included and driven as hard as it will go, because a
// starved CPU port and a dead CPU port look identical from the outside.
module kaneko_cpumem_harness #(
    parameter int unsigned SDR_AW  = 25,
    parameter int unsigned SDR_COL = 10,
    parameter int unsigned NPORTS  = 11
) (
    input  wire        clk,
    input  wire        rst,

    // ioctl, driven by the testbench exactly as hps_io would
    input  wire        ioctl_download,
    input  wire [15:0] ioctl_index,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire [15:0] ioctl_dout,
    output wire        ioctl_wait,

    // Set to stop the video port requesting, to test the CPU uncontended.
    input  wire        video_idle,
    // The boot RAM self-test, so a run can have it on or off.
    input  wire        selftest_en,
    output wire        selftest_done,
    output wire        selftest_pass,
    output wire [3:0]  selftest_stage,
    output wire [15:0] selftest_got,
    output wire [15:0] selftest_want,
    output wire [3:0]  dbg_com_w,
    // The MCU's own state, so a run can say whether it was ever commanded.
    output wire [3:0]  dbg_c3_status,
    output wire        dbg_c3_busy,
    output wire        dbg_c3_crc_ready,
    // The device only leaves idle on a frame tick. A run where this stays 0
    // has a commanded MCU that can never start, which reads exactly like a
    // device that ignores its command.
    output wire [31:0] dbg_tick_cnt,
    // What the device DID. busy is momentary, so reading it at the end of a
    // run says nothing; these are cumulative.
    output wire [31:0] dbg_c3_wr_cnt,
    output wire [31:0] dbg_c3_rd_cnt,
    output wire [31:0] dbg_c3_busy_cnt,
    output wire [31:0] dbg_c3_ack_cnt,
    // The first four shared-RAM writes the device issues, so they can be put
    // beside MAME's -- which starts at 20019e, the EEPROM address shogwarr
    // passes to the init command.
    output wire [15:0] dbg_c3_wa0, dbg_c3_wa1, dbg_c3_wa2, dbg_c3_wa3,
    output wire [15:0] dbg_c3_wd0, dbg_c3_wd1, dbg_c3_wd2, dbg_c3_wd3,
    // How many commands the device processed and what the last one was: a
    // device that ran once and a device that runs every frame look the same
    // from a write count.
    output wire [7:0]  dbg_c3_cmds,
    output wire [15:0] dbg_c3_cmd,
    // The LAST write it made, and the frame it made it on. The first four say
    // what it started doing; these say whether it ever stopped.
    output wire [15:0] dbg_c3_wlast_a, dbg_c3_wlast_d,
    output wire [31:0] dbg_c3_wfirst_tick, dbg_c3_wlast_tick,
    // One-cycle strobe with the address and data, so the device's own accesses
    // can be logged and put beside MAME's -- which contains them, while the
    // 68000's bus trace does not.
    output wire        dbg_c3_wr_stb,
    output wire        dbg_c3_rd_stb,
    output wire [15:0] dbg_c3_acc_addr,
    output wire [15:0] dbg_c3_acc_data,
    output wire        dbg_c3_rv_stb,
    output wire [15:0] dbg_c3_rdata,
    // What the MCU RAM port actually receives, at the controller's door: the
    // CPU trace shows what the 68000 ASKED for, and the two have to be
    // compared to find a write that is issued and never lands.
    output wire        dbg_p10_req,
    output wire        dbg_p10_we,
    output wire        dbg_p10_ack,
    output wire [1:0]  dbg_p10_be,
    output wire [15:0] dbg_p10_din,
    output wire [SDR_AW:1] dbg_p10_addr,

    // OKI sound telemetry, the four links the hardware overlay counts.
    output logic [31:0] oki_wr_cnt,
    output logic [31:0] oki_ok_cnt,
    output logic [31:0] oki_busy_cnt,
    output logic [31:0] oki_snd_cnt,

    // TEST ONLY: force an interrupt level onto the CPU, bypassing kaneko_irq.
    //
    // explbrkr masks interrupts at level 7 for its first ~240 frames of
    // self-test and this harness cannot reach that point in a reasonable run,
    // so the acknowledge path — fx68k's VPAn autovectoring, the FC=7 decode,
    // and kaneko_bus's cpu_space gating — would otherwise never be exercised
    // by anything. Level 7 is non-maskable, so forcing it tests exactly that
    // path against a CPU that is still masking everything else.
    //
    // kaneko_irq itself is unit-tested in sim/cpu/tb_kaneko_irq.cpp; this
    // covers the wiring around it, which no unit test can.
    input  wire [2:0]  ipl_force,

    // The VIEW2 chip-0 register bank, so a test can ask what the 68000
    // actually wrote. Blaze On sets layer 1's scroll exactly 2 below layer 0's
    // to cancel the hardware's dx+2, and if that write never lands the two
    // layers ghost 2 pixels apart — which is what hardware shows.
    output wire [255:0] dbg_v2r0_flat,
    // Pulses of v2r0_we, and how many of those had a byte enable asserted.
    // If they differ, the write strobe is arriving after the 68000 has already
    // dropped UDS/LDS and the register file sees an enable-less write.
    output logic [31:0] dbg_v2r0_we_cnt,
    output logic [31:0] dbg_v2r0_be_cnt,

    // A window into VIEW2 chip 0's TILE MEMORY, so a test can compare what the
    // 68000 actually wrote against what MAME holds at the same point. Neither
    // harness has ever looked: the frame gate loads VRAM from C++ arrays and
    // this one tied the video read ports to zero, so the CPU write path into
    // kaneko_vmem is the last link in the tilemap chain with no coverage.
    input  wire [9:0]   dbg_vram_addr,
    output wire [31:0]  dbg_c0_t0_q,
    output wire [31:0]  dbg_c0_t1_q,

    // Read capture depth. The board wants 0 (CL+1) on hardware evidence; the
    // device model wants 3 (CL+3), which is what the controller resets to. A
    // harness that hard-wired either one would be testing the other machine,
    // so the testbench sweeps it.
    input  wire [1:0]  rd_lat_sel,

    // observability
    output wire        rom_loaded,
    output wire        mem_ready,
    output wire        cpu_as,          // ~ASn
    output wire        cpu_dtack,       // ~DTACKn
    output wire [23:1] cpu_addr,
    output wire        cpu_rw,
    output wire [15:0] cpu_din,
    output wire [15:0] cpu_dout,
    output wire        cpu_uds,
    output wire        cpu_lds,
    output wire        rom_req,
    output wire        rom_ack,
    output wire [SDR_AW:1] rom_addr,
    output wire        unmapped_hit,
    output wire [23:1] unmapped_addr,
    output wire        vid_req,
    output wire        vid_ack,
    output wire [9:0]  vcnt,
    output wire [2:0]  cpu_ipl_n,
    output wire        cpu_iack,
    output int unsigned dram_violations,
    output wire [15:0]  dram_vflags
);

    // ------------------------------------------------------------ SDRAM bus
    wire [15:0] sd_dq_o, sd_dq_i;
    wire        sd_dq_oe;
    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [1:0]  sd_ba, sd_dqm;
    wire [12:0] sd_a;

    wire        ldr_wr_req, ldr_wr_ack;
    wire [SDR_AW:1] ldr_wr_addr;
    wire [15:0] ldr_wr_din;
    wire [1:0]  ldr_wr_be;

    wire [NPORTS-1:0]       p_ack_bus;
    wire [NPORTS-1:0][63:0] p_dout_bus;

    // Video port: request again the instant the last one is acked, walking
    // addresses so it cannot sit on one open row. This is the arbiter's worst
    // case and the CPU has to get through it.
    logic            p0_req;
    logic [SDR_AW:1] p0_addr;
    always_ff @(posedge clk) begin
        if (rst) begin
            p0_req  <= 1'b0;
            p0_addr <= SDR_AW'(25'h040000);
        end else if (video_idle) begin
            p0_req  <= 1'b0;
        end else if (p0_req && p_ack_bus[0]) begin
            p0_req  <= 1'b0;
            p0_addr <= p0_addr + SDR_AW'(4);
        end else if (!p0_req) begin
            p0_req  <= 1'b1;
        end
    end
    assign vid_req = p0_req;
    assign vid_ack = p_ack_bus[0];

    wire        p1_req;
    wire [SDR_AW:1] p1_addr;

    // Port 5, the OKI's sample fetch. Present here so the sound path is tested
    // against the REAL controller and the REAL ROM image rather than the ideal
    // memory in sim/sound — an arbiter that starves the sixth port, or samples
    // that are not at 0x4c0000, both look exactly like a chip that does not
    // work, and neither is visible in an isolated harness.
    wire            p5_req;
    wire [SDR_AW:1] p5_addr;

    kaneko_sdram #(.COL_BITS(SDR_COL), .NP(NPORTS), .T_REFI(300)) u_sdram
    (
        .clk(clk), .rst_n(~rst), .ready(mem_ready),
        .rd_lat_sel(rd_lat_sel),

        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_ba(sd_ba),
        .sd_a(sd_a), .dqm_swap(1'b0), .sd_dqm(sd_dqm),
        .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(sd_dq_i),

        .wr_req(ldr_wr_req), .wr_addr(ldr_wr_addr), .wr_din(ldr_wr_din),
        .wr_be(ldr_wr_be), .wr_ack(ldr_wr_ack),

        // Port 8 is the Z80's program fetch. This harness has no Z80, so it is
        // tied off -- but it must still BE here: kaneko_sdram takes NP ports and
        // a short bundle would silently shift every port down by one.
        // BUILT PER PORT, not as a bundle. These were nine- and eight-entry
        // concatenations against an eleven-port controller: they zero-extended
        // in silence, which is the same shape as the five-bit p_we that once
        // drove a nine-bit signal here. Port 10 in particular was tied off, so
        // the MCU's RAM could never have been reached from this harness even
        // once it was connected.
        .p_req  (h_req),
        .p_addr (h_addr),
        .p_din  (h_din),
        .p_be   (h_be),
        .p_we   (h_we),
        .p_ack  (p_ack_bus),
        .p_dout (p_dout_bus),
        .dbg_req(), .dbg_grant()
    );

    // The controller runs at 48 MHz here, not the model's default ~100 MHz, so
    // the refresh interval is scaled to match — otherwise the model fails a
    // controller that is refreshing correctly for the clock it is on.
    sdram_model #(
        .COL_BITS(SDR_COL), .T_REFI(375), .REFI_SLACK(9)
    ) u_dram (
        .clk(clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n), .ba(sd_ba), .a(sd_a),
        .dqm(sd_dqm), .dq_i(sd_dq_o), .dq_oe_i(sd_dq_oe),
        .dq_o(sd_dq_i), .dq_oe_o(),
        .violations(dram_violations), .v_flags(dram_vflags),
        .reads_served(), .writes_served()
    );

    kaneko_rom_loader #(.SDR_AW(SDR_AW)) u_loader
    (
        .clk(clk), .rst(rst), .mem_ready(mem_ready),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
        .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
        .ioctl_wait(ioctl_wait),
        .sdr_wr_req(ldr_wr_req), .sdr_wr_addr(ldr_wr_addr),
        .sdr_wr_din(ldr_wr_din), .sdr_wr_be(ldr_wr_be), .sdr_wr_ack(ldr_wr_ack),
        .rom_loaded(rom_loaded), .overflow()
    );

    // ---------------------------------------------------------------- CPU
    // Copied from KanekoCALC3.sv, not paraphrased. A harness that divides the
    // clock differently to the core is testing a CPU the core does not have.
    reg [1:0] cpu_phase;
    always @(posedge clk) cpu_phase <= cpu_phase + 2'd1;
    wire enPhi1 = (cpu_phase == 2'd0);
    wire enPhi2 = (cpu_phase == 2'd2);

    // NOT FRAME-ALIGNED, AND DELIBERATELY SO
    //
    // Releasing the CPU at vcnt == 0 would make its interrupts land at a
    // repeatable point in boot, which looks like it would let the trace be
    // compared against MAME across interrupts. It would not. MAME runs this
    // board at 59 Hz over 256 lines; kaneko_video_timing runs 264 lines at
    // 59.1856 Hz. Different line rate, different frame length — so the two
    // machines reach scanline 224 a different number of instructions apart no
    // matter where the CPU is released, and an alignment here would only make
    // the mismatch look deliberate.
    //
    // Screen timing is not PCB-verified (design study §9). Until it is, the
    // bus-trace comparison covers boot up to the first interrupt and the
    // interrupt logic is verified by sim/cpu/tb_kaneko_irq.cpp instead.
    wire cpu_rst = rst | ~rom_loaded;

    wire        ASn, LDSn, UDSn, eRWn, DTACKn;
    wire [15:0] oEdb, iEdb;
    wire [23:1] eab;

    fx68k u_cpu
    (
        .clk(clk), .HALTn(1'b1),
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

    // Video timing exists here only to drive the scanline interrupts. The
    // pixel path is not part of this harness.
    wire ce_pix_h;
    kaneko_video_timing u_timing
    (
        .clk(clk), .rst(rst), .ce_pix(ce_pix_h),
        .h_vis(CFG_H_VIS), .v_vis(CFG_V_VIS),
        .v_start(CFG_V_START), .h_sync_start(CFG_HSYNC), .h_start(CFG_H_START),
        .hcnt(), .vcnt(vcnt), .screen_x(), .screen_y(),
        .hsync(), .vsync(), .hblank(), .vblank(), .de(), .vblank_rise(vbl_rise)
    );

    // 6 MHz pixel clock from 48 MHz, as the core does.
    logic [2:0] ce_div;
    always_ff @(posedge clk) ce_div <= ce_div + 3'd1;
    assign ce_pix_h = (ce_div == 3'd0);

    wire [2:0] cpu_fc;
    wire       cpu_vpa_n;

    kaneko_irq u_irq
    (
        .clk(clk), .rst(cpu_rst),
        .vcnt(vcnt),
        .fc(cpu_fc), .as(~ASn), .a_level(eab[3:1]),
        .ipl_n(irq_ipl_n), .vpa_n(cpu_vpa_n), .iack(cpu_iack)
    );

    wire [2:0] irq_ipl_n;
    assign cpu_ipl_n = (ipl_force != 3'd0) ? ~ipl_force : irq_ipl_n;

    // Two YM2149s and the EEPROM, wired as the core wires them. The EEPROM is
    // not optional here: explbrkr will not finish its self-test without one,
    // and the chip select comes from YM2149 #1 port B rather than from any
    // address the memory map decodes.
    reg [4:0] ym_div;
    always @(posedge clk) ym_div <= (ym_div == 5'd23) ? 5'd0 : ym_div + 5'd1;
    wire ym_cen = (ym_div == 5'd0);        // 48 MHz / 24 = 2 MHz

    wire        ym0_we, ym1_we, eeprom_we;
    wire [3:0]  ym_addr;
    wire [7:0]  ym_din, eeprom_din;
    wire [7:0]  ym0_q, ym1_q, ym1_iob_out;
    wire [7:0]  ym0_iob_out;   // OKI bank register, MAME's oki_bank0_w<7>
    wire        eeprom_do;

    jt49 u_ym0 (
        .rst_n(~cpu_rst), .clk(clk), .clk_en(ym_cen),
        .addr(ym_addr), .cs_n(~ym0_we), .wr_n(~ym0_we), .din(ym_din),
        .sel(1'b1), .dout(ym0_q),
        .sound(), .A(), .B(), .C(), .sample(),
        .IOA_in(8'hff), .IOA_out(), .IOA_oe(),
        .IOB_in(8'hff), .IOB_out(ym0_iob_out), .IOB_oe()
    );

    jt49 u_ym1 (
        .rst_n(~cpu_rst), .clk(clk), .clk_en(ym_cen),
        .addr(ym_addr), .cs_n(~ym1_we), .wr_n(~ym1_we), .din(ym_din),
        .sel(1'b1), .dout(ym1_q),
        .sound(), .A(), .B(), .C(), .sample(),
        .IOA_in({7'h7f, eeprom_do}), .IOA_out(), .IOA_oe(),
        .IOB_in(8'hff), .IOB_out(ym1_iob_out), .IOB_oe()
    );

    reg [7:0] eeprom_ctl;
    always @(posedge clk) begin
        if (cpu_rst)        eeprom_ctl <= 8'd0;
        else if (eeprom_we) eeprom_ctl <= eeprom_din;
    end

    kaneko_eeprom93c46 u_eeprom (
        .clk(clk), .rst(cpu_rst),
        .cs(|ym1_iob_out), .sk(eeprom_ctl[0]), .di(eeprom_ctl[1]),
        .do_out(eeprom_do),
        .bk_addr(eepdef_we ? eepdef_addr : c3_eep_addr),
        .bk_din(eepdef_din), .bk_we(eepdef_we), .bk_q(bk_q),
        .dirty(), .dirty_clr(1'b0),
        .dbg_state(), .dbg_busy(), .dbg_wen(), .dbg_cmd(), .dbg_cmd_valid()
    );

    wire [15:0] q_vram0, q_vram1, q_spr, q_pal;
    wire        vram0_we, vram1_we, spr_we, pal_we;
    wire [12:0] vmem_addr;
    wire [15:0] vmem_din;

    // The game table, fed from the same ioctl stream as the real core: the
    // MRA's <rom index="1"> config byte selects the memory map. Booting a
    // title is not just its ROM — kaneko_bus decodes a DIFFERENT map per game.
    wire [7:0] PG_WRAM, PG_V2W0, PG_V2W1, PG_SPR, PG_PAL, PG_WDOG, PG_IN, PG_SND;
    wire       ROM_1MB, BLAZEON_IO, INPUTS_BLAZEON;
    // Geometry too. Left unconnected these tie to 0, which gives a visible
    // area of zero height and a vblank_rise that never fires — the harness
    // then disagrees with hardware about the one thing being debugged.
    wire [9:0] CFG_H_VIS, CFG_V_VIS, CFG_V_START, CFG_HSYNC;
    wire [SDR_AW:1] CFG_BASE_MCURAM;
    wire [SDR_AW:1] CFG_BASE_CALC3ROM;

    // THE EEPROM DEFAULTS, exactly as KanekoCALC3.sv loads them. The init
    // command copies 64 words out of the EEPROM into shared RAM, so without
    // this the device copies a blank part -- ffff where MAME writes 0000 --
    // and the game reads back nonsense from the one place it is waiting on.
    // Started on rom_loaded rather than reset, because game_id arrives from
    // the MRA long after reset and at reset no game looks like one with
    // defaults.
    logic [15:0] eep_def [0:127];
    initial $readmemh("rtl/io/eeprom_defaults.hex", eep_def);
    wire       eepdef_has  = (CFG_GAME_ID == 8'd4) || (CFG_GAME_ID == 8'd5);
    wire       eepdef_slot = (CFG_GAME_ID == 8'd5);
    reg  [6:0] eepdef_i;
    reg        eepdef_run, eepdef_done, rom_loaded_d;
    always_ff @(posedge clk) begin
        rom_loaded_d <= rom_loaded;
        if (rst) begin
            eepdef_i <= 7'd0; eepdef_run <= 1'b0;
            eepdef_done <= 1'b0; rom_loaded_d <= 1'b0;
        end else if (rom_loaded && !rom_loaded_d && eepdef_has && !eepdef_done) begin
            eepdef_i <= 7'd0; eepdef_run <= 1'b1; eepdef_done <= 1'b1;
        end else if (eepdef_run) begin
            eepdef_i <= eepdef_i + 7'd1;
            if (eepdef_i == 7'd63) eepdef_run <= 1'b0;
        end
    end
    wire        eepdef_we   = eepdef_run;
    wire [5:0]  eepdef_addr = eepdef_i[5:0];
    wire [15:0] eepdef_din  = eep_def[{eepdef_slot, eepdef_i[5:0]}];
    wire            vbl_rise;
    wire [15:0]     bk_q;
    wire [8:0] CFG_H_START;

    // THIS INSTANTIATION HAD DRIFTED, and nothing caught it: `make boot` is
    // not part of `make test`, so it went on referring to ports the game table
    // no longer has -- hit_we, mcu_we, oki2_we and friends, which belong to
    // kaneko_bus -- and to calc3_io twice. It has been unbuildable since the
    // MCU's RAM moved to SDRAM, and the only reason that was not noticed is
    // that nothing runs it. Same shape as the x2 harness that sat orphaned.
    assign dbg_p10_req  = p10_req;
    assign dbg_p10_we   = p10_we;
    assign dbg_p10_ack  = p_ack_bus[10];
    assign dbg_p10_be   = p10_be;
    assign dbg_p10_din  = p10_din;
    assign dbg_p10_addr = p10_addr;

    assign selftest_done  = rt_done;
    assign selftest_pass   = rt_pass;
    assign selftest_stage  = rt_fail_stage;
    assign selftest_got    = rt_fail_got;
    assign selftest_want   = rt_fail_want;
    assign dbg_com_w       = cpu_com_w;

    kaneko_gamecfg #(.SDR_AW(SDR_AW)) u_gamecfg (
        .clk(clk), .rst(rst),
        .ioctl_wr(ioctl_wr),
        .ioctl_index(ioctl_index[7:0]), .ioctl_dout(ioctl_dout[7:0]),
        .pg_wram(PG_WRAM), .pg_v2w0(PG_V2W0), .pg_v2w1(PG_V2W1),
        .pg_spr(PG_SPR), .pg_pal(PG_PAL), .pg_wdog(PG_WDOG),
        .pg_snd(PG_SND), .pg_in(PG_IN),
        .rom_1mb(ROM_1MB), .blazeon_io(BLAZEON_IO),
        .calc3_io(CFG_CALC3_IO),
        .base_trom0(), .base_trom1(), .base_spr(),
        .base_oki(CFG_OKI_BASE), .oki_max_bank(CFG_OKI_MAX_BANK),
        .base_oki2(), .oki2_max_bank(),
        .base_z80(), .has_z80(), .oki_on_z80(), .oki_cen_half(),
        // The MCU's RAM and its data ROM: real bases, because this harness now
        // runs that RAM through the arbiter and the SDRAM, which is the whole
        // reason it exists again.
        .base_mcuram(CFG_BASE_MCURAM), .base_calc3rom(CFG_BASE_CALC3ROM),
        .hit_type2(),
        .irq_lvl_a(), .irq_lvl_b(), .irq_lvl_c(),
        .game_id(CFG_GAME_ID),
        .v2_dx(), .v2_dy(), .view2_2_pri(), .spr_pri_f(),
        .two_chips(), .spr_count(), .spr_xoffs(), .visarea_min_y(),
        .wide_screen(), .spr_elements(), .tile_colbase(),
        .rot_en(), .rot_ccw(), .fliptype(),
        .inputs_blazeon(), .in_unk_val(),
        .id_force(2'd0), .id_force_en(1'b0),
        .h_vis(CFG_H_VIS), .v_vis(CFG_V_VIS),
        .v_start(CFG_V_START), .h_sync_start(CFG_HSYNC), .h_start(CFG_H_START)
    );

    // THE REGISTER BANKS, WHICH THIS HARNESS DID NOT HAVE.
    //
    // v2r0_q/v2r1_q/sprreg_q were tied to zero, so every register read-back
    // returned 0 and the harness disagreed with the real core on the one thing
    // the bus-trace diff exists to check. The oracle caught it immediately once
    // the e40000 divergence was out of the way:
    //
    //     ours   900006 R 0000        mame   900006 R 0150
    //
    // The game writes 0x0150 to the sprite register at 0x900006 and reads it
    // straight back. MAME returns it. This harness returned zero — not because
    // the core is wrong, but because the harness had no register file at all.
    wire        h_v2r0_we, h_v2r1_we, h_sprreg_we, h_sprreg2_we;
    wire [3:0]  h_reg_addr;
    wire [15:0] h_reg_din, h_v2r0_q, h_v2r1_q, h_sprreg_q, h_sprreg2_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            dbg_v2r0_we_cnt <= 32'd0;
            dbg_v2r0_be_cnt <= 32'd0;
        end else if (h_v2r0_we) begin
            dbg_v2r0_we_cnt <= dbg_v2r0_we_cnt + 1'd1;
            if (~UDSn || ~LDSn) dbg_v2r0_be_cnt <= dbg_v2r0_be_cnt + 1'd1;
        end
    end

    kaneko_regs16 u_h_v2r0 (
        .clk(clk), .we(h_v2r0_we), .addr(h_reg_addr), .din(h_reg_din),
        .uds(~UDSn), .lds(~LDSn),
        .rd_addr(h_reg_addr), .rd_q(h_v2r0_q), .regs_flat(dbg_v2r0_flat)
    );
    kaneko_regs16 u_h_v2r1 (
        .clk(clk), .we(h_v2r1_we), .addr(h_reg_addr), .din(h_reg_din),
        .uds(~UDSn), .lds(~LDSn),
        .rd_addr(h_reg_addr), .rd_q(h_v2r1_q), .regs_flat()
    );
    // The Blaze On board's SECOND sprite register window at 980000, which
    // blazeon_map declares as plain RAM. Modelled with a real register file
    // rather than left unconnected: an unconnected input reads as zero, which
    // happens to be what MAME returns before anything is written, so the
    // harness would have agreed with the oracle by accident and stopped
    // agreeing the moment the game wrote a value and read it back.
    kaneko_regs16 u_h_sprreg2 (
        .clk(clk), .we(h_sprreg2_we), .addr(h_reg_addr), .din(h_reg_din),
        .uds(~UDSn), .lds(~LDSn),
        .rd_addr(h_reg_addr), .rd_q(h_sprreg2_q), .regs_flat()
    );

    kaneko_regs16 u_h_sprreg (
        .clk(clk), .we(h_sprreg_we), .addr(h_reg_addr), .din(h_reg_din),
        .uds(~UDSn), .lds(~LDSn),
        .rd_addr(h_reg_addr), .rd_q(h_sprreg_q), .regs_flat()
    );

    // ------------------------------------------------ MCU RAM, the real path
    //
    // The 68000 reaches it through the arbiter, the controller and the device
    // model, exactly as the core does. It was not connected here at all, so
    // mcuram_ack was tied to zero and the first access to that memory would
    // have hung the CPU for ever -- which is the symptom the board shows, and
    // is why this harness had to be able to run it before anything else.
    wire            cpu_mcu_req, cpu_mcu_we, cpu_mcu_ack;
    wire [SDR_AW:1] cpu_mcu_addr;
    wire [15:0]     cpu_mcu_din;
    wire [1:0]      cpu_mcu_be;
    wire [63:0]     cpu_mcu_dout;
    wire [3:0]      cpu_com_w;

    // The boot self-test, as the core wires it -- gated, so a run can have it
    // on or off and the difference is measurable here rather than on a board.
    wire            rt_req, rt_we, rt_running, rt_done, rt_pass;
    wire [SDR_AW:1] rt_addr;
    wire [15:0]     rt_din, rt_fail_got, rt_fail_want;
    wire [1:0]      rt_be;
    wire [3:0]      rt_fail_stage;

    kaneko_ramtest #(.SDR_AW(SDR_AW), .WORDS(16)) u_ramtest (
        .clk(clk), .rst(rst),
        .enable(rom_loaded && selftest_en), .base_mcuram(CFG_BASE_MCURAM),
        .req(rt_req), .addr(rt_addr), .we(rt_we), .din(rt_din), .be(rt_be),
        .ack(arb_ack[3]), .dout(arb_dout),
        .running(rt_running), .done(rt_done), .pass(rt_pass),
        .fail_stage(rt_fail_stage), .fail_got(rt_fail_got),
        .fail_want(rt_fail_want)
    );

    // ---- The CALC3 MCU, on the arbiter it has in the core ----
    //
    // Lockstep stopped being able to say anything at the point the game asks
    // the MCU for something. With no device here, nothing answers: the 68000
    // sits in its watchdog-and-poll loop forever while MAME leaves it, and
    // every access after that is a divergence that means nothing. The device
    // sits on masters 1 and 2, in the order KanekoCALC3.sv uses, so a fault
    // found here is a fault in what the board runs.
    wire [16:0] c3_rom_addr;
    wire        c3_rom_rd;
    wire [7:0]  c3_rom_byte;
    wire        c3_rom_ok;
    wire [15:0] c3_ram_addr;
    wire        c3_ram_rd, c3_ram_wr;
    wire [1:0]  c3_ram_be;
    wire [15:0] c3_ram_wdata;
    wire [5:0]  c3_eep_addr;
    wire        c3_eep_rd;
    wire        c3_busy, c3_crc_ready, c3_key_missing;

    wire        c3_romp_req;
    wire [SDR_AW:1] c3_romp_addr;

    kaneko_tilerom #(.NREQ(1), .SDR_AW(SDR_AW)) u_calc3rom (
        .clk(clk), .rst(rst),
        .req_addr({{7{1'b0}}, c3_rom_addr}),
        .base_addr(CFG_BASE_CALC3ROM),
        .req_data(c3_rom_byte),
        .port_ready(c3_rom_ok),
        .sdr_req(c3_romp_req), .sdr_addr(c3_romp_addr),
        .sdr_ack(arb_ack[2]), .sdr_dout(arb_dout)
    );

    // The feeder answers with an address-and-ready contract; the device asks
    // and waits for a valid. Also stops a ready left high by a CACHE HIT at
    // the previous address being read as an answer to this cycle's request.
    reg c3_rom_pending;
    always_ff @(posedge clk) begin
        if (rst)                c3_rom_pending <= 1'b0;
        else if (c3_rom_rd)     c3_rom_pending <= 1'b1;
        else if (c3_rom_valid)  c3_rom_pending <= 1'b0;
    end
    wire c3_rom_valid = c3_rom_pending && c3_rom_ok;

    wire c3_ram_req = c3_ram_rd | c3_ram_wr;
    // Aligned read, exact write -- the rule the whole core follows. See
    // kaneko_bus and KanekoCALC3.sv; a burst starts at the address given.
    wire [SDR_AW:1] c3_ram_sdr_addr = CFG_BASE_MCURAM +
        (c3_ram_wr ? SDR_AW'(c3_ram_addr[15:1])
                   : SDR_AW'({c3_ram_addr[15:3], 2'b00}));
    reg [1:0] c3_ram_lane;
    always_ff @(posedge clk) if (c3_ram_req) c3_ram_lane <= c3_ram_addr[2:1];
    wire [15:0] c3_ram_rdata = arb_dout[{c3_ram_lane, 4'd0} +: 16];
    wire        c3_ram_valid = arb_ack[1];

    kaneko_calc3 #(.AW(17), .ROM_BYTES(32'h20000)) u_calc3 (
        .clk(clk), .rst_n(~rst),
        .com_w(dbg_com_w),
        .tick(vbl_rise),
        .dsw(8'he7),
        .rom_addr(c3_rom_addr), .rom_rd(c3_rom_rd),
        .rom_data(c3_rom_byte), .rom_valid(c3_rom_valid),
        .ram_addr(c3_ram_addr), .ram_rd(c3_ram_rd), .ram_wr(c3_ram_wr),
        .ram_be(c3_ram_be), .ram_wdata(c3_ram_wdata),
        .ram_rdata(c3_ram_rdata), .ram_valid(c3_ram_valid),
        .eep_addr(c3_eep_addr), .eep_data(bk_q), .eep_rd(c3_eep_rd),
        .busy(c3_busy), .crc_ready(c3_crc_ready),
        .key_missing(c3_key_missing),
        .dbg_cmds(dbg_c3_cmds), .dbg_cmd(dbg_c3_cmd),
        .dbg_status(dbg_c3_status), .dbg_crc()
    );

    reg [31:0] c3_wr_cnt, c3_rd_cnt, c3_busy_cnt, c3_ack_cnt;
    reg        c3_wr_d, c3_rd_d;
    // Which kind of access is outstanding, so a valid can be attributed.
    reg        c3_ram_wr_seen;
    always_ff @(posedge clk)
      if (rst)                c3_ram_wr_seen <= 1'b0;
      else if (c3_ram_wr)     c3_ram_wr_seen <= 1'b1;
      else if (c3_ram_rd)     c3_ram_wr_seen <= 1'b0;
    reg [15:0] wa [0:3];
    reg [15:0] wd [0:3];
    reg [15:0] wlast_a, wlast_d;
    reg [31:0] wfirst_tick, wlast_tick;
    assign dbg_c3_wlast_a     = wlast_a;
    assign dbg_c3_wlast_d     = wlast_d;
    assign dbg_c3_wfirst_tick = wfirst_tick;
    assign dbg_c3_wlast_tick  = wlast_tick;
    always_ff @(posedge clk) begin
      c3_wr_d <= c3_ram_wr;
      c3_rd_d <= c3_ram_rd;
      if (rst) begin
        for (int i = 0; i < 4; i++) begin wa[i] <= '0; wd[i] <= '0; end
      end else if (c3_ram_wr && !c3_wr_d) begin
        if (c3_wr_cnt < 32'd4) begin
          wa[c3_wr_cnt[1:0]] <= c3_ram_addr;
          wd[c3_wr_cnt[1:0]] <= c3_ram_wdata;
        end
        if (c3_wr_cnt == 32'd0) wfirst_tick <= tick_cnt;
        wlast_a    <= c3_ram_addr;
        wlast_d    <= c3_ram_wdata;
        wlast_tick <= tick_cnt;
      end
    end
    assign dbg_c3_wa0 = wa[0]; assign dbg_c3_wa1 = wa[1];
    assign dbg_c3_wa2 = wa[2]; assign dbg_c3_wa3 = wa[3];
    assign dbg_c3_wd0 = wd[0]; assign dbg_c3_wd1 = wd[1];
    assign dbg_c3_wd2 = wd[2]; assign dbg_c3_wd3 = wd[3];
    assign dbg_c3_ack_cnt = c3_ack_cnt;
    assign dbg_c3_wr_stb   = c3_ram_wr && !c3_wr_d;
    assign dbg_c3_rd_stb   = c3_ram_rd && !c3_rd_d;
    assign dbg_c3_acc_addr = c3_ram_addr;
    assign dbg_c3_acc_data = c3_ram_wdata;
    // A read logged at REQUEST time has no data yet, so the capture said
    // "----" and hid the parameters the device is deciding on. This is the
    // answer arriving.
    assign dbg_c3_rv_stb   = c3_ram_valid && !c3_ram_wr_seen;
    assign dbg_c3_rdata    = c3_ram_rdata;
    always_ff @(posedge clk) begin
      if (rst) begin
        c3_wr_cnt <= '0; c3_rd_cnt <= '0; c3_busy_cnt <= '0; c3_ack_cnt <= '0;
      end else begin
        // COUNT THE REQUEST, NOT ITS COINCIDENCE WITH AN ACKNOWLEDGE. The
        // device pulses ram_rd/ram_wr for one cycle and clears them -- which
        // is the whole reason the arbiter latches pulses -- so the request is
        // long gone by the time the acknowledge arrives. Gating one on the
        // other counts zero and reads exactly like a device that never asks.
        if (c3_ram_wr && !c3_wr_d) c3_wr_cnt   <= c3_wr_cnt + 1'b1;
        if (c3_ram_rd && !c3_rd_d) c3_rd_cnt   <= c3_rd_cnt + 1'b1;
        if (arb_ack[1])            c3_ack_cnt  <= c3_ack_cnt + 1'b1;
        if (c3_busy)               c3_busy_cnt <= c3_busy_cnt + 1'b1;
      end
    end
    assign dbg_c3_wr_cnt   = c3_wr_cnt;
    assign dbg_c3_rd_cnt   = c3_rd_cnt;
    assign dbg_c3_busy_cnt = c3_busy_cnt;

    reg [31:0] tick_cnt;
    always_ff @(posedge clk) if (rst) tick_cnt <= '0;
                             else if (vbl_rise) tick_cnt <= tick_cnt + 1'b1;
    assign dbg_tick_cnt = tick_cnt;

    assign dbg_c3_busy      = c3_busy;
    assign dbg_c3_crc_ready = c3_crc_ready;

    wire [3:0]            arb_req  = {rt_req, c3_romp_req, c3_ram_req, cpu_mcu_req};
    wire [3:0][SDR_AW:1]  arb_addr = {rt_addr, c3_romp_addr, c3_ram_sdr_addr, cpu_mcu_addr};
    wire [3:0]            arb_we   = {rt_we, 1'b0, c3_ram_wr, cpu_mcu_we};
    wire [3:0][15:0]      arb_din  = {rt_din, 16'd0, c3_ram_wdata, cpu_mcu_din};
    wire [3:0][1:0]       arb_be   = {rt_be, 2'b11, c3_ram_be, cpu_mcu_be};
    wire [3:0]            arb_ack;
    wire [63:0]           arb_dout;

    assign cpu_mcu_ack  = arb_ack[0];
    assign cpu_mcu_dout = arb_dout;

    wire            p10_req, p10_we;
    wire [SDR_AW:1] p10_addr;
    wire [15:0]     p10_din;
    wire [1:0]      p10_be;

    kaneko_mcuram_arb #(.SDR_AW(SDR_AW), .NM(4)) u_mcu_arb (
        .clk(clk), .rst_n(~rst),
        .m_req(arb_req), .m_addr(arb_addr), .m_we(arb_we),
        .m_din(arb_din), .m_be(arb_be),
        .m_ack(arb_ack), .m_dout(arb_dout),
        .s_req(p10_req), .s_addr(p10_addr), .s_we(p10_we),
        .s_din(p10_din), .s_be(p10_be),
        .s_ack(p_ack_bus[10]), .s_dout(p_dout_bus[10])
    );

    // One entry per port, so a short bundle cannot shift them.
    wire [NPORTS-1:0]           h_req, h_we;
    wire [NPORTS-1:0][SDR_AW:1] h_addr;
    wire [NPORTS-1:0][15:0]     h_din;
    wire [NPORTS-1:0][1:0]      h_be;
    genvar hp;
    generate
      for (hp = 0; hp < NPORTS; hp = hp + 1) begin : g_hp
        assign h_req[hp]  = (hp == 0)  ? p0_req
                          : (hp == 1)  ? p1_req
                          : (hp == 5)  ? p5_req
                          : (hp == 6)  ? p67_req[0]
                          : (hp == 7)  ? p67_req[1]
                          : (hp == 10) ? p10_req : 1'b0;
        assign h_addr[hp] = (hp == 0)  ? p0_addr
                          : (hp == 1)  ? p1_addr
                          : (hp == 5)  ? p5_addr
                          : (hp == 6)  ? p67_addr[0]
                          : (hp == 7)  ? p67_addr[1]
                          : (hp == 10) ? p10_addr : {SDR_AW{1'b0}};
        assign h_we[hp]   = (hp == 10) ? p10_we  : 1'b0;
        assign h_din[hp]  = (hp == 10) ? p10_din : 16'd0;
        assign h_be[hp]   = (hp == 10) ? p10_be  : 2'b11;
      end
    endgenerate

    kaneko_bus #(.SDR_AW(SDR_AW), .ROM_BASE(25'd0)) u_bus
    (
        .clk(clk), .rst(cpu_rst),
        .eab(eab), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .eRWn(eRWn),
        .oEdb(oEdb), .iEdb(iEdb), .DTACKn(DTACKn), .cpu_space(cpu_iack),

        .rom_req(p1_req), .rom_addr(p1_addr),
        .rom_ack(p_ack_bus[1]), .rom_dout(p_dout_bus[1]),
        // WITHOUT THIS the CALC3 decode is off and sel_mcu never matches, so
        // every MCU RAM read returns the bus's 0xffff default and every write
        // is dropped. It reproduced the board's symptom exactly -- the game's
        // RAM test reading back ffff and branching into its failure path -- and
        // was an unconnected input reading as zero in the HARNESS, not a fault
        // in the core, which wires it. An omitted input is the same silent
        // failure check_ports exists to catch on the core, and harnesses have
        // no such check.
        .calc3_io(CFG_CALC3_IO),
        .mcuram_req(cpu_mcu_req), .mcuram_addr(cpu_mcu_addr),
        .mcuram_we(cpu_mcu_we), .mcuram_din(cpu_mcu_din),
        .mcuram_be(cpu_mcu_be), .mcuram_ack(cpu_mcu_ack),
        .mcuram_dout(cpu_mcu_dout), .base_mcuram(CFG_BASE_MCURAM),
        .com_w(cpu_com_w),

        .vram0_we(vram0_we), .vram1_we(vram1_we),
        .spr_we(spr_we), .pal_we(pal_we),
        .vmem_addr(vmem_addr), .vmem_din(vmem_din),
        .vram0_q(q_vram0), .vram1_q(q_vram1), .spr_q(q_spr), .pal_q(q_pal),

        .ym0_we(ym0_we), .ym1_we(ym1_we), .ym_addr(ym_addr), .ym_din(ym_din),
        .ym0_q(ym0_q), .ym1_q(ym1_q),
        .eeprom_we(eeprom_we), .eeprom_din(eeprom_din),
        .oki_we(oki_we), .oki_din(oki_din), .oki_dout(oki_dout),

        .v2r0_we(h_v2r0_we), .v2r1_we(h_v2r1_we), .sprreg_we(h_sprreg_we),
        .sprreg2_we(h_sprreg2_we), .sprreg2_q(h_sprreg2_q),
        .reg_addr(h_reg_addr), .reg_din(h_reg_din),
        .v2r0_q(h_v2r0_q), .v2r1_q(h_v2r1_q), .sprreg_q(h_sprreg_q),

        // PER GAME, BIT BY BIT, THE SAME WAY THE TOP LEVEL BUILDS THEM.
        //
        // These were a blanket 0xffff, and that blanket is what hid the
        // Magical Crystals fault for a whole session: the core drove DSW bits
        // 7..2 LOW while this harness drove them HIGH, so the game passed its
        // check here, unmasked, took interrupts and ran -- and failed on the
        // board, where the same six bits read zero. Simulation and hardware
        // disagreed because the harness was feeding an idealised word.
        //
        // Both games declare bits 7..2 as PORT_DIPUNUSED_DIPLOC with default
        // equal to mask, i.e. pulled high; the SYSTEM low byte is defined on
        // mgcrystl (0xff) and absent on bakubrkr (0x00).
        // P2's LOW BYTE IS PER BOARD, NOT PER GAME.
        //
        // On the Blaze On board c00002 is DSW1_P2 and its low byte is DIP
        // switches, all defaulting high, so it reads 0xffff. On bakubrkr the
        // low byte is not declared at all and reads 0x00; on mgcrystl it is
        // IPT_UNKNOWN and reads 0xff.
        //
        // This drove {8'hff, CFG_SYS_LO} for every game, which gave Wing Force
        // 0xff00 where the board gives 0xffff. The bus trace caught it as the
        // first divergence from the oracle once a real fault ahead of it was
        // fixed -- a wrong value in the instrument, masking whatever came next.
        .in_p1(16'hffff),
        .in_p2(INPUTS_BLAZEON ? 16'hffff : {8'hff, CFG_SYS_LO}),
        // EVERY window page comes from the game table, exactly as the top
        // level wires them. They used to be left unconnected, which ties them
        // to 0 — so every window decoded at page 0x00, where the ROM lives,
        // and the CPU in this harness had no working WRAM at all. It ran
        // anyway, which is precisely why it went unnoticed: a harness that
        // agrees with whatever it is handed reports success either way.
        .pg_wram(PG_WRAM), .pg_v2w0(PG_V2W0), .pg_v2w1(PG_V2W1),
        .pg_spr(PG_SPR),  .pg_pal(PG_PAL),
        .pg_wdog(PG_WDOG), .pg_in(PG_IN), .pg_snd(PG_SND),
        .rom_1mb(ROM_1MB), .blazeon_io(BLAZEON_IO),
        // NOT a blanket 0xffff. The Blaze On board's SYSTEM word reads 0xFF00
        // idle, because MAME's port defines only the high byte and undefined
        // bits read zero. Tying it to all-ones here is what let the core ship
        // the same mistake — a harness that feeds an idealised value cannot
        // catch a wrong one.
        .in_system(INPUTS_BLAZEON ? 16'hff00 : {8'hff, CFG_SYS_LO}),
        .in_unk(16'hffff),

        .unmapped_hit(unmapped_hit), .unmapped_addr(unmapped_addr)
    );

    // ----------------------------------------------------------- sprites
    // THE REAL SPRITE SUBSYSTEM, ON ITS REAL PORTS.
    //
    // This harness ran six ports while the core ran eight, and the two it was
    // missing are the sprite ROM's — the heaviest requesters in the design,
    // sixteen round trips per sprite across a thousand sprites a frame. So a
    // boot "verified" here was verified against a memory system under a
    // fraction of the real contention, and the CPU is the port that starves
    // when contention rises.
    //
    // frame_start is synthesised rather than taken from video timing: this
    // harness has no video, and what matters is that the subsystem runs at a
    // realistic rate and competes for the bus.
    wire [1:0]            p67_req;
    wire [1:0][SDR_AW:1]  p67_addr;
    wire [11:0]           spr_ram_addr;
    wire [15:0]           spr_ram_q;
    wire [13:0]           spr_pix_unused;
    wire [1:0]            spr_prio_unused;

    localparam int unsigned FRAME_CLKS = 384 * 264 * 8;   // one frame at 48 MHz
    logic [19:0] frame_ctr;
    logic        spr_frame;
    always_ff @(posedge clk) begin
        if (rst) begin
            frame_ctr <= '0; spr_frame <= 1'b0;
        end else begin
            spr_frame <= (frame_ctr == 20'(FRAME_CLKS - 1));
            frame_ctr <= (frame_ctr == 20'(FRAME_CLKS - 1)) ? '0 : frame_ctr + 1'b1;
        end
    end

    kaneko_spr_sys #(
        .BMP_W(320), .BMP_H(256), .SPRITES(1024), .SDR_AW(SDR_AW)
    ) u_spr (
        .clk(clk), .rst(rst),
        .frame_start(spr_frame), .keep_sprites(1'b0), .skip_en(1'b1),
        .sprite_count(11'd1024),
        .sprite_xoffs(16'd0), .sprite_yoffs(16'd0),
        .visarea_min_y(9'd16), .wide_screen(1'b0), .fliptype(1'b0),
        .clip_x0(10'd0), .clip_x1(10'd255),
        .clip_y0(10'd16), .clip_y1(10'd239),
        .ram_addr(spr_ram_addr), .ram_data(spr_ram_q),
        .regs_flat(256'd0),
        .rom_base(SDR_AW'(25'h140000)),
        .sdr_req(p67_req), .sdr_addr(p67_addr),
        .sdr_ack({p_ack_bus[7], p_ack_bus[6]}),
        .sdr_dout({p_dout_bus[7], p_dout_bus[6]}),
        .rd_x(10'd0), .rd_y(10'd0),
        .spr_pix(spr_pix_unused), .spr_prio(spr_prio_unused),
        .busy(), .overrun()
    );

    // ------------------------------------------------------------- OKI
    // Identical wiring to KanekoCALC3.sv. ym0_iob_out is the bank register; the
    // YM2149s are not instantiated here, so it is held at the reset value the
    // chip would present until the game writes one.
    wire       oki_we;
    wire [7:0] oki_din;
    wire [7:0] oki_dout;

    // NOT a hardcoded 0x260000. That is Explosive Breaker's oki1 base, and
    // this harness takes SET: Magical Crystals' region starts at byte
    // 0x500000 and Wing Force's elsewhere again, so pinning one game's value
    // silently pointed every other game's sample fetch into another region.
    // Same fault the core had and hard rule 9 exists for.
    wire [SDR_AW:1] CFG_OKI_BASE;
    wire [2:0]      CFG_OKI_MAX_BANK;
    wire [7:0]      CFG_GAME_ID;
    wire            CFG_CALC3_IO;
    // mgcrystl declares the SYSTEM/P2 low byte as IPT_UNKNOWN, so it reads
    // 0xff; bakubrkr does not declare it at all, so it reads 0x00. Undefined
    // bits in a MAME port read ZERO -- that is the whole rule, and it has now
    // caught three separate bugs in this project.
    wire [7:0]      CFG_SYS_LO = (CFG_GAME_ID == 8'd1) ? 8'hff : 8'h00;

    wire [17:0] oki_rom_addr;
    wire [7:0]  oki_rom_data;
    wire [0:0]  oki_rom_ok;
    wire [23:0] oki_region_addr;
    wire signed [13:0] oki_snd;

    kaneko_oki_bank u_okibank (
        .chip_addr(oki_rom_addr),
        .max_bank(CFG_OKI_MAX_BANK),
        .bank(ym0_iob_out[2:0]),
        .region_addr(oki_region_addr)
    );

    kaneko_tilerom #(.NREQ(1), .SDR_AW(SDR_AW)) u_okirom (
        .clk(clk), .rst(rst),
        .req_addr(oki_region_addr),
        .base_addr(CFG_OKI_BASE),
        .req_data(oki_rom_data),
        .port_ready(oki_rom_ok),
        .sdr_req(p5_req), .sdr_addr(p5_addr),
        .sdr_ack(p_ack_bus[5]), .sdr_dout(p_dout_bus[5])
    );

    jt6295 u_oki (
        .rst(rst), .clk(clk), .cen(ym_cen),
        .ss(1'b1),
        .wrn(~oki_we), .din(oki_din), .dout(oki_dout),
        .rom_addr(oki_rom_addr), .rom_data(oki_rom_data),
        .rom_ok(oki_rom_ok[0]),
        .sound(oki_snd), .sample()
    );

    // The same four counts the hardware overlay shows, so a hardware
    // photograph and a simulation run are directly comparable.
    reg oki_ok_d;
    always_ff @(posedge clk) begin
        oki_ok_d <= oki_rom_ok[0];
        if (rst) begin
            oki_wr_cnt <= 0; oki_ok_cnt <= 0; oki_busy_cnt <= 0; oki_snd_cnt <= 0;
        end else begin
            if (oki_we)                     oki_wr_cnt   <= oki_wr_cnt   + 1;
            if (oki_rom_ok[0] && !oki_ok_d) oki_ok_cnt   <= oki_ok_cnt   + 1;
            if (oki_dout[3:0] != 4'd0)      oki_busy_cnt <= oki_busy_cnt + 1;
            if (oki_snd != 14'sd0)          oki_snd_cnt  <= oki_snd_cnt  + 1;
        end
    end

    kaneko_vmem u_vmem
    (
        .clk(clk),
        .cpu_addr(vmem_addr), .cpu_din(vmem_din),
        .we_vram0(vram0_we), .we_vram1(vram1_we),
        .we_spr(spr_we), .we_pal(pal_we),
        .uds(~UDSn), .lds(~LDSn),
        .q_vram0(q_vram0), .q_vram1(q_vram1), .q_spr(q_spr), .q_pal(q_pal),
        .c0_t0_addr(dbg_vram_addr), .c0_t0_q(dbg_c0_t0_q),
        .c0_t1_addr(dbg_vram_addr), .c0_t1_q(dbg_c0_t1_q),
        .c0_s0_addr(11'd0), .c0_s0_q(),
        .c0_s1_addr(11'd0), .c0_s1_q(),
        .c1_t0_addr(10'd0), .c1_t0_q(),
        .c1_t1_addr(10'd0), .c1_t1_q(),
        .c1_s0_addr(11'd0), .c1_s0_q(),
        .c1_s1_addr(11'd0), .c1_s1_q(),
        .spr_addr(spr_ram_addr), .spr_q(spr_ram_q),
        .pal_addr(11'd0), .pal_q()
    );

    assign cpu_as    = ~ASn;
    assign cpu_dtack = ~DTACKn;
    assign cpu_addr  = eab;
    assign cpu_rw    = eRWn;
    assign cpu_din   = iEdb;
    assign cpu_dout  = oEdb;
    assign cpu_uds   = ~UDSn;
    assign cpu_lds   = ~LDSn;
    assign rom_req   = p1_req;
    assign rom_ack   = p_ack_bus[1];
    assign rom_addr  = p1_addr;

endmodule
