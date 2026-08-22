// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Z80 sound subsystem for the Blaze On board: work RAM, address decode, the
// sound latch and its NMI, and the YM2151.
//
// NEITHER THE CPU NOR THE YM2151 IS IN HERE, ON PURPOSE
//
// T80 is VHDL, so Verilator cannot build it and nothing around it could be
// unit-tested if it were instantiated here. The Z80 bus is brought out
// instead and the top level joins the two, which leaves this module — the part
// that is ours — drivable from a testbench. It is the same split that lets the
// OKI integration be tested without simulating jt6295's internals, and the
// same reason: a verified third-party core is not what needs the harness.
//
// jt51 is outside for a second reason: `make lint` covers rtl/ alone, so a
// module in there that instantiates a third-party core cannot resolve it and
// the whole sweep fails. Every other third-party core in this design — fx68k,
// jt49, jt6295 — is instantiated in the top level for exactly that reason, and
// this one is no different.
//
// READ FROM MAME, NOT ASSUMED
//
//   blazeon_soundmem   0x0000-0x7fff  ROM
//                      0x8000-0xbfff  ROM   ("supposed to be banked?")
//                      0xc000-0xdfff  RAM
//   blazeon_soundport  global_mask(0xff)
//                      0x02-0x03      YM2151
//                      0x06           sound latch, read
//   68000 side         map(0xe00000, 0xe00000).w(soundlatch)  -- EVEN address,
//                      so the upper byte of the word, UDS not LDS
//   latch              data_pending_callback -> INPUT_LINE_NMI
//
// The trigger is NMI and not IRQ, and it is edge-triggered by the latch being
// written rather than level-held: the Z80 has no way to acknowledge it, so a
// level would re-enter for ever. The flag is cleared when the Z80 READS the
// latch, which is what `data_pending` means.
`timescale 1ns/1ps
`default_nettype none

module kaneko_z80snd (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,           // 4 MHz enable

    // ---- 68000 side
    input  wire        latch_we,     // one clk pulse
    input  wire [7:0]  latch_din,

    // ---- Z80 bus, joined to T80 in the top level
    input  wire [15:0] cpu_addr,
    input  wire [7:0]  cpu_dout,     // from the CPU
    output logic [7:0] cpu_din,      // to the CPU
    input  wire        mreq_n,
    input  wire        iorq_n,
    input  wire        rd_n,
    input  wire        wr_n,
    output logic       nmi_n,

    // ---- sound ROM, one byte, data one clock after the address
    output wire [15:0] rom_addr,
    input  wire [7:0]  rom_data,

    // ---- OKI M6295, on WING FORCE ONLY.
    //
    // Blaze On has no OKI at all; Wing Force puts one on the Z80's I/O ports
    // rather than the 68000's bus, which is the one sound difference between
    // two games that share a PCB:
    //
    //   wingforc_soundport   map(0x0a, 0x0a) OKI data, read and write
    //                        map(0x0c, 0x0c) OKI bank, write
    //
    // `has_oki` gates the decode so Blaze On does not answer at those ports —
    // a decoded address that returns a value where the board returns nothing
    // is the shape of fault that has cost this core three sessions.
    input  wire        has_oki,
    output wire        oki_we,
    output wire  [7:0] oki_din,
    input  wire  [7:0] oki_dout,
    output logic [2:0] oki_bank,

    // ---- YM2151, instantiated by the top level
    output wire        ym_cen,
    output wire        ym_cen_p1,
    output wire        ym_cs_n,
    output wire        ym_wr_n,
    output wire        ym_a0,
    output wire [7:0]  ym_din,
    input  wire [7:0]  ym_dout
);
    // ------------------------------------------------------------- decode
    wire sel_rom = ~mreq_n && (cpu_addr < 16'hc000);
    wire sel_ram = ~mreq_n && (cpu_addr >= 16'hc000) && (cpu_addr < 16'he000);
    // The port map masks to 8 bits, so only the low byte of the address
    // decodes — a Z80 OUT puts the accumulator on the high half and it must
    // not take part.
    wire [7:0] port   = cpu_addr[7:0];
    wire sel_ym       = ~iorq_n && (port[7:1] == 7'h01);   // 0x02, 0x03
    wire sel_latch    = ~iorq_n && (port == 8'h06);
    wire sel_oki      = ~iorq_n && has_oki && (port == 8'h0a);
    wire sel_okibank  = ~iorq_n && has_oki && (port == 8'h0c);

    assign rom_addr = cpu_addr;

    // -------------------------------------------------------------- RAM
    // 8 KB at 0xc000. Declared as a plain 1-D array with a plain address, the
    // shape that infers block RAM — see the inference notes in findings.
    logic [7:0] ram [0:8191];
    logic [7:0] ram_q;

    always_ff @(posedge clk) begin
        if (sel_ram && ~wr_n) ram[cpu_addr[12:0]] <= cpu_dout;
        ram_q <= ram[cpu_addr[12:0]];
    end

    // ------------------------------------------------- latch and its NMI
    // Set when the 68000 writes, cleared when the Z80 reads. NMI follows the
    // flag, so a second write while one is pending does not queue a second
    // interrupt — which matches a data-pending line rather than a counter.
    logic [7:0] latch_q;
    logic       pending;
    wire        latch_rd = sel_latch && ~rd_n;

    always_ff @(posedge clk) begin
        if (rst) begin
            latch_q <= 8'd0;
            pending <= 1'b0;
        end else begin
            // A write and a read in the same cycle leaves it pending: the byte
            // just written has not been collected.
            if (latch_we) begin
                latch_q <= latch_din;
                pending <= 1'b1;
            end else if (latch_rd) begin
                pending <= 1'b0;
            end
        end
    end

    assign nmi_n = ~pending;

    // ------------------------------------------------------- OKI on the Z80
    // The bank register is three bits, as kaneko_oki_bank takes it. MAME's
    // oki_bank0_w<0x3> masks the write to the low two bits plus the enable, so
    // the same three bits reach the banker either way.
    assign oki_we  = sel_oki && ~wr_n;
    assign oki_din = cpu_dout;

    always_ff @(posedge clk) begin
        if (rst) oki_bank <= 3'd0;
        else if (sel_okibank && ~wr_n) oki_bank <= cpu_dout[2:0];
    end

    // -------------------------------------------------- YM2151 interface
    // cen_p1 is documented as half of cen.
    logic ce_d;
    always_ff @(posedge clk) if (ce) ce_d <= ~ce_d;
    assign ym_cen    = ce;
    assign ym_cen_p1 = ce && ce_d;
    assign ym_cs_n   = ~sel_ym;
    assign ym_wr_n   = wr_n;
    assign ym_a0     = cpu_addr[0];
    assign ym_din    = cpu_dout;

    // ---------------------------------------------------- read multiplexer
    // A decoded address that returns nothing is worse than one not decoded at
    // all — that has cost this core three separate debugging sessions, on the
    // watchdog, the YM2149 ports and the OKI. Every select here has a value.
    always_comb begin
        cpu_din = 8'hff;
        if      (sel_rom)   cpu_din = rom_data;
        else if (sel_ram)   cpu_din = ram_q;
        else if (sel_latch) cpu_din = latch_q;
        else if (sel_ym)    cpu_din = ym_dout;
        else if (sel_oki)   cpu_din = oki_dout;
    end
endmodule

`default_nettype wire
