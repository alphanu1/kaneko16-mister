// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The real controller at 96 MHz behind kaneko_sdram_x2, with requesters on a
// 48 MHz clock derived from it — the arrangement the core will use.
//
// The testbench toggles the FAST clock and acts on the slow side only when
// `slow_phase` says a slow edge is about to happen, which is how a 48 MHz
// requester actually behaves. Anything that gets this wrong shows up as a
// missed acknowledge or a repeated read, and those are the two hazards the
// adapter exists to prevent.
`timescale 1ns/1ps
`default_nettype none

module kaneko_sdram_x2_harness #(
    parameter int unsigned COL_BITS = 9,
    parameter int unsigned NP       = 9
) (
    input  logic clk,              // FAST: the controller clock
    input  logic rst_n,
    input  logic [1:0] rd_lat_sel,   // capture depth, as the OSD exposes it
    output logic ready,
    output logic slow_phase,       // high on the fast cycle before a slow edge

    // Flattened per port, for the same reason kaneko_sdram_harness is: a
    // packed [NP-1:0][63:0] is exposed to C++ as an array of 32-BIT words, so
    // p_dout[1] is port 0's upper half and not port 1 at all. Driving and
    // reading it that way produces a testbench that reports the RTL swapping
    // data between ports, which is a convincing-looking lie.
    //
    // (A comment line must not BEGIN with the simulator's name — it is parsed
    // as a pragma. That is recorded against kaneko_mixer.sv and was walked
    // into again writing this one.)
    input  logic [NP-1:0] p_req,
    input  logic [COL_BITS+15:1] a0, a1, a2, a3, a4, a5, a6, a7, a8,
    output logic [NP-1:0] p_ack,
    output logic [63:0] d0, d1, d2, d3, d4, d5, d6, d7, d8,

    input  logic        wr_req,
    input  logic [COL_BITS+15:1] wr_addr,
    input  logic [15:0] wr_din,
    input  logic [1:0]  wr_be,
    output logic        wr_ack,

    output int unsigned violations,
    output logic [15:0] v_flags,

    // Controller-side transactions. If the adapter ever lets a request
    // through twice, this exceeds the number of requests the slow side made,
    // and the data check alone would never notice — a repeated read of the
    // same address returns the same bytes.
    output int unsigned fast_acks,
    // Cycles where an acknowledge was high but was not a fresh edge: how much
    // wider than one cycle the controller's acknowledge really is.
    output int unsigned ack_width
);
    localparam int unsigned AW = COL_BITS + 15;

    // The slow clock is the fast one divided by two, which is what a PLL at an
    // exact 2:1 ratio gives: aligned edges, no phase relationship to discover.
    logic div;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) div <= 1'b0; else div <= ~div;
    assign slow_phase = div;

    wire [NP-1:0]       f_req, f_ack;
    wire [NP-1:0][AW:1] f_addr;
    wire [NP-1:0][63:0] f_dout;
    wire                f_wr_req, f_wr_ack;
    wire [AW:1]         f_wr_addr;
    wire [15:0]         f_wr_din;
    wire [1:0]          f_wr_be;

    // RISING EDGES, not levels. The controller's acknowledge is not a single
    // cycle — it carries its own `ack_d` edge detector internally, which is
    // the tell — so counting levels counts one transaction several times.
    // The first version of this counter did exactly that and reported a clean
    // 2x, which read convincingly as "every request went through twice".
    logic [NP-1:0] f_ack_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fast_acks <= 0; f_ack_d <= '0; ack_width <= 0;
        end else begin
            f_ack_d   <= f_ack;
            fast_acks <= fast_acks + $countones(f_ack & ~f_ack_d);
            if ($countones(f_ack) > 0 && $countones(f_ack & ~f_ack_d) == 0)
                ack_width <= ack_width + 1;
        end
    end

    kaneko_sdram_x2 #(.NP(NP), .AW(AW)) u_x2 (
        .clk_fast(clk),
        .s_req(p_req), .s_addr({a8, a7, a6, a5, a4, a3, a2, a1, a0}),
        // Reads only in this harness; the adapter's write pass-through is
        // exercised by tb_kaneko_sdram, which has the writing port.
        .s_we({NP{1'b0}}), .s_din({NP{16'd0}}), .s_be({NP{2'b11}}),
        .f_we(), .f_din(), .f_be(),
        .s_ack(p_ack), .s_dout({d8, d7, d6, d5, d4, d3, d2, d1, d0}),
        .s_wr_req(wr_req), .s_wr_addr(wr_addr), .s_wr_din(wr_din),
        .s_wr_be(wr_be), .s_wr_ack(wr_ack),
        .f_req(f_req), .f_addr(f_addr), .f_ack(f_ack), .f_dout(f_dout),
        .f_wr_req(f_wr_req), .f_wr_addr(f_wr_addr), .f_wr_din(f_wr_din),
        .f_wr_be(f_wr_be), .f_wr_ack(f_wr_ack)
    );

    wire sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe;
    wire [1:0]  sd_ba, sd_dqm;
    wire [12:0] sd_a;
    wire [15:0] sd_dq_o, sd_dq_i;

    // T_REFI scales with the clock: 8192 rows in 64 ms is one refresh every
    // 7.8125 us, which is 750 cycles at 96 MHz rather than 375 at 48.
    // INIT_NOP shortened for simulation exactly as the other harnesses do.
    // Left at its 10,000-cycle default it outlasts the whole run, so the
    // controller spends the test in power-up NOPs and the device model's
    // refresh watchdog fires on a controller that has not started yet.
    kaneko_sdram #(.COL_BITS(COL_BITS), .NP(NP), .T_REFI(700), .INIT_NOP(600)) u_ctrl (
        .clk(clk), .rst_n(rst_n), .ready(ready), .rd_lat_sel(rd_lat_sel),
        .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n),
        .sd_cas_n(sd_cas_n), .sd_we_n(sd_we_n), .sd_ba(sd_ba),
        .sd_a(sd_a), .sd_dqm(sd_dqm),
        .sd_dq_o(sd_dq_o), .sd_dq_oe(sd_dq_oe), .sd_dq_i(sd_dq_i),
        .wr_req(f_wr_req), .wr_addr(f_wr_addr), .wr_din(f_wr_din),
        .wr_be(f_wr_be), .wr_ack(f_wr_ack),
        .p_req(f_req), .p_addr(f_addr), .p_din({NP{16'd0}}),
        .p_be({NP{2'b11}}), .p_we({NP{1'b0}}),
        .p_ack(f_ack), .p_dout(f_dout),
        .dbg_req(), .dbg_grant()
    );

    sdram_model #(.COL_BITS(COL_BITS), .T_REFI(750), .REFI_SLACK(9)) u_dram (
        .clk(clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n), .ba(sd_ba), .a(sd_a),
        .dqm(sd_dqm), .dq_i(sd_dq_o), .dq_oe_i(sd_dq_oe),
        .dq_o(sd_dq_i), .dq_oe_o(),
        .violations(violations), .v_flags(v_flags),
        .reads_served(), .writes_served()
    );
endmodule

`default_nettype wire
