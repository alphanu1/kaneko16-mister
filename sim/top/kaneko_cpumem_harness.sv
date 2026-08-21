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
    parameter int unsigned NPORTS  = 8
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
        .sd_a(sd_a), .sd_dqm(sd_dqm),
        .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(sd_dq_i),

        .wr_req(ldr_wr_req), .wr_addr(ldr_wr_addr), .wr_din(ldr_wr_din),
        .wr_be(ldr_wr_be), .wr_ack(ldr_wr_ack),

        .p_req  ({p67_req, p5_req, 3'b0, p1_req, p0_req}),
        .p_addr ({p67_addr, p5_addr, {3{{SDR_AW{1'b0}}}}, p1_addr, p0_addr}),
        .p_din  ({8{16'd0}}),
        .p_be   ({8{2'b11}}),
        .p_we   (8'b0),
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
    // Copied from Kaneko16.sv, not paraphrased. A harness that divides the
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
        .hcnt(), .vcnt(vcnt), .screen_x(), .screen_y(),
        .hsync(), .vsync(), .hblank(), .vblank(), .de(), .vblank_rise()
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
        .bk_addr(6'd0), .bk_din(16'd0), .bk_we(1'b0), .bk_q(),
        .dirty(), .dirty_clr(1'b0),
        .dbg_state(), .dbg_busy(), .dbg_wen(), .dbg_cmd(), .dbg_cmd_valid()
    );

    wire [15:0] q_vram0, q_vram1, q_spr, q_pal;
    wire        vram0_we, vram1_we, spr_we, pal_we;
    wire [12:0] vmem_addr;
    wire [15:0] vmem_din;

    kaneko_bus #(.SDR_AW(SDR_AW), .ROM_BASE(25'd0)) u_bus
    (
        .clk(clk), .rst(cpu_rst),
        .eab(eab), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .eRWn(eRWn),
        .oEdb(oEdb), .iEdb(iEdb), .DTACKn(DTACKn), .cpu_space(cpu_iack),

        .rom_req(p1_req), .rom_addr(p1_addr),
        .rom_ack(p_ack_bus[1]), .rom_dout(p_dout_bus[1]),

        .vram0_we(vram0_we), .vram1_we(vram1_we),
        .spr_we(spr_we), .pal_we(pal_we),
        .vmem_addr(vmem_addr), .vmem_din(vmem_din),
        .vram0_q(q_vram0), .vram1_q(q_vram1), .spr_q(q_spr), .pal_q(q_pal),

        .ym0_we(ym0_we), .ym1_we(ym1_we), .ym_addr(ym_addr), .ym_din(ym_din),
        .ym0_q(ym0_q), .ym1_q(ym1_q),
        .eeprom_we(eeprom_we), .eeprom_din(eeprom_din),
        .oki_we(oki_we), .oki_din(oki_din), .oki_dout(oki_dout),

        .v2r0_we(), .v2r1_we(), .sprreg_we(),
        .reg_addr(), .reg_din(),
        .v2r0_q(16'h0000), .v2r1_q(16'h0000), .sprreg_q(16'h0000),

        .in_p1(16'hffff), .in_p2(16'hffff),
        .in_system(16'hffff), .in_unk(16'hffff),

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
    // Identical wiring to Kaneko16.sv. ym0_iob_out is the bank register; the
    // YM2149s are not instantiated here, so it is held at the reset value the
    // chip would present until the game writes one.
    wire       oki_we;
    wire [7:0] oki_din;
    wire [7:0] oki_dout;

    localparam [SDR_AW:1] OKI_BASE = SDR_AW'(25'h260000);

    wire [17:0] oki_rom_addr;
    wire [7:0]  oki_rom_data;
    wire [0:0]  oki_rom_ok;
    wire [23:0] oki_region_addr;
    wire signed [13:0] oki_snd;

    kaneko_oki_bank #(.MAX_BANK(7)) u_okibank (
        .chip_addr(oki_rom_addr),
        .bank(ym0_iob_out[2:0]),
        .region_addr(oki_region_addr)
    );

    kaneko_tilerom #(.NREQ(1), .SDR_AW(SDR_AW)) u_okirom (
        .clk(clk), .rst(rst),
        .req_addr(oki_region_addr),
        .base_addr(OKI_BASE),
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
        .c0_t0_addr(10'd0), .c0_t0_q(),
        .c0_t1_addr(10'd0), .c0_t1_q(),
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
