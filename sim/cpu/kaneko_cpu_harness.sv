// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// fx68k + kaneko_bus, with ROM answered directly rather than through SDRAM.
//
// The SDRAM path is already verified on its own and on hardware, and putting it
// under the CPU here would make every bus trace depend on arbitration timing
// that has nothing to do with whether the 68000 is executing correctly. So ROM
// answers in one cycle and the trace shows the instruction stream, not the
// memory system. The full stack is exercised in the core itself.

`timescale 1ns/1ps
`default_nettype none

module kaneko_cpu_harness (
    input  wire        clk,
    input  wire        rst,

    // ROM, answered by the testbench.
    //
    // A FOUR-WORD BURST AT THE ADDRESS THE BUS ASKS FOR
    //
    // This was `rom_a = eab` with a single 16-bit `rom_q` in the low lane,
    // which was fine while kaneko_bus took one word per burst and threw the
    // rest away. It stopped being fine the moment the ROM line cache landed:
    // the bus aligns its request down and stores all four returned words, so a
    // harness that supplies one real word and three zeros fills the cache with
    // rubbish and the CPU executes it. The test still "passed" — it just
    // stopped reaching the unmapped writes it had been counting, which is the
    // only reason the change was noticed at all.
    //
    // rom_a is now the bus's own request, and the testbench must answer with
    // the four words starting there.
    output wire [24:1] rom_a,
    input  wire [63:0] rom_q,

    // Bus observability
    output wire [23:1] bus_addr,
    output wire        bus_as,
    output wire        bus_rw,        // 1 = read
    output wire [15:0] bus_dout,      // CPU -> bus
    output wire [15:0] bus_din,       // bus -> CPU
    output wire        bus_uds, bus_lds,
    output wire        bus_dtack,
    output wire        unmapped_hit,
    output wire [23:1] unmapped_addr,

    input  wire [15:0] in_p1, in_p2, in_system, in_unk,
    output wire [2:0]  fc
);
    // 12 MHz from 48 MHz: the CPU clock is clk/4, and enPhi1/enPhi2 are its two
    // halves, two cycles apart.
    logic [1:0] phase;
    always_ff @(posedge clk) phase <= rst ? 2'd0 : phase + 2'd1;
    wire enPhi1 = (phase == 2'd0);
    wire enPhi2 = (phase == 2'd2);

    wire        ASn, LDSn, UDSn, eRWn, DTACKn;
    wire [15:0] oEdb, iEdb;
    wire [23:1] eab;
    wire        FC0, FC1, FC2;

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(rst), .pwrUp(rst),
        .enPhi1(enPhi1), .enPhi2(enPhi2),
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(), .VMAn(),
        .FC0(FC0), .FC1(FC1), .FC2(FC2),
        .BGn(), .oRESETn(), .oHALTEDn(),
        .DTACKn(DTACKn), .VPAn(1'b1), .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        .IPL0n(1'b1), .IPL1n(1'b1), .IPL2n(1'b1),
        .iEdb(iEdb), .oEdb(oEdb), .eab(eab)
    );

    // ROM answered in one cycle: request out, data back, ack immediately.
    wire [24:1] rom_addr_w;
    assign rom_a = rom_addr_w;
    wire rom_ack_now = 1'b1;

    kaneko_bus #(.SDR_AW(24)) u_bus (
        .clk(clk), .rst(rst),
        .eab(eab), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn), .eRWn(eRWn),
        .oEdb(oEdb), .iEdb(iEdb), .DTACKn(DTACKn), .cpu_space(1'b0),

        .rom_req(), .rom_addr(rom_addr_w), .rom_ack(rom_ack_now),
        .rom_dout(rom_q),

        .vram0_we(), .vram1_we(), .spr_we(), .pal_we(),
        .vmem_addr(), .vmem_din(),
        .vram0_q(16'h0000), .vram1_q(16'h0000),
        .spr_q(16'h0000), .pal_q(16'h0000),

        .v2r0_we(), .v2r1_we(), .sprreg_we(),
        .reg_addr(), .reg_din(),
        .v2r0_q(16'h0000), .v2r1_q(16'h0000), .sprreg_q(16'h0000),

        .in_p1(in_p1), .in_p2(in_p2), .in_system(in_system), .in_unk(in_unk),
        .unmapped_hit(unmapped_hit), .unmapped_addr(unmapped_addr)
    );

    assign bus_addr  = eab;
    assign bus_as    = ~ASn;
    assign bus_rw    = eRWn;
    assign bus_dout  = oEdb;
    assign bus_din   = iEdb;
    assign bus_uds   = ~UDSn;
    assign bus_lds   = ~LDSn;
    assign bus_dtack = ~DTACKn;
    assign fc        = {FC2, FC1, FC0};
endmodule

`default_nettype wire
