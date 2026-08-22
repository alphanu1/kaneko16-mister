// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Port adapter for running the SDRAM controller at twice the core clock.
//
// WHY THE CONTROLLER IS NOT SIMPLY GIVEN A FASTER CLOCK
//
// Every requester in this core — the tile feeders, the CPU's ROM fetch, the
// OKI and the sprite renderer — is in the 48 MHz core domain, and the core
// cannot follow: its critical path measures 15.74 ns, a ceiling near 63 MHz.
// So the controller runs at 96 MHz and this sits between, which halves every
// round trip as counted in CORE clocks. That is the whole point: the sprite
// renderer's cost is dominated by serial round trips, sixteen per sprite.
//
// THIS IS NOT A CLOCK-DOMAIN CROSSING, AND THE DISTINCTION MATTERS
//
// Both clocks come from one PLL at an exact 2:1 ratio, so their edges are
// aligned and every slow-domain signal is stable across two fast cycles. There
// is no metastability to synchronise away and no synchroniser here. What there
// IS, is a pulse-width problem in the other direction, and two hazards:
//
//   1. An acknowledge has to span exactly one slow cycle: any narrower and the
//      slow domain misses it, any wider and it counts it twice. MEASURED, the
//      controller already holds it for two fast cycles — it carries its own
//      `ack_d` edge detector internally, which is the tell — so it is passed
//      straight through. Widening it to three, which the first version did,
//      let the slow side acknowledge one transaction twice and read the second
//      time into the next one's data.
//
//   2. A requester drops `req` the slow cycle AFTER it sees the acknowledge,
//      so `req` is still high for up to two more fast cycles. The controller
//      would take that as a second request and read the same address again.
//      `done` masks the request from the moment it is acknowledged until the
//      slow side actually lowers it.
//
// Addresses need nothing: a requester holds the address for as long as it
// holds `req`, so it is stable across the whole fast-domain transaction.
`timescale 1ns/1ps
`default_nettype none

module kaneko_sdram_x2 #(
    parameter int unsigned NP = 7,
    parameter int unsigned AW = 25
) (
    input  wire clk_fast,          // controller clock, 2x clk_slow, same PLL

    // ---- slow side: the core's requesters
    input  wire [NP-1:0]          s_req,
    input  wire [NP-1:0][AW:1]    s_addr,
    output wire [NP-1:0]          s_ack,
    output wire [NP-1:0][63:0]    s_dout,

    input  wire                   s_wr_req,
    input  wire [AW:1]            s_wr_addr,
    input  wire [15:0]            s_wr_din,
    input  wire [1:0]             s_wr_be,
    output wire                   s_wr_ack,

    // ---- fast side: the controller
    output wire [NP-1:0]          f_req,
    output wire [NP-1:0][AW:1]    f_addr,
    input  wire [NP-1:0]          f_ack,
    input  wire [NP-1:0][63:0]    f_dout,

    output wire                   f_wr_req,
    output wire [AW:1]            f_wr_addr,
    output wire [15:0]            f_wr_din,
    output wire [1:0]             f_wr_be,
    input  wire                   f_wr_ack
);

    genvar g;
    generate
        for (g = 0; g < NP; g = g + 1) begin : g_port
            logic        done;
            logic [63:0] dout_r;

            always_ff @(posedge clk_fast) begin
                // Cleared by the slow side lowering its request, which is the
                // only event that means "this transaction is finished with".
                if (!s_req[g])      done <= 1'b0;
                else if (f_ack[g])  done <= 1'b1;

                if (f_ack[g]) dout_r <= f_dout[g];
            end

            // Masked from the acknowledge itself, not from the registered
            // `done` a cycle later: the controller takes a request on its
            // rising edge, and one more cycle of a held request is one more
            // chance for it to look like a new one.
            assign f_req[g]  = s_req[g] & ~done & ~f_ack[g];
            assign f_addr[g] = s_addr[g];
            assign s_ack[g]  = f_ack[g];      // already two fast cycles wide

            // BYPASSED ON THE ACKNOWLEDGE CYCLE, not just registered.
            //
            // `dout_r` does not load until the fast edge AFTER f_ack, but
            // f_ack is two fast cycles wide and the slow edge can land on
            // either of them. Land on the first and the slow side latches the
            // previous transaction's data -- or zero, on the first read of a
            // port. That failed almost exactly half the reads, which is what
            // "half" means here: the two alignments are equally likely and one
            // of them is wrong.
            //
            // The controller writes p_dout and raises p_ack on the SAME edge
            // and holds both until that port completes again, so f_dout is
            // already valid throughout the acknowledge. The register is kept
            // for the cycles after it.
            assign s_dout[g] = f_ack[g] ? f_dout[g] : dout_r;
        end
    endgenerate

    // The loader's write port, same two hazards and the same two answers.
    logic w_done;
    always_ff @(posedge clk_fast) begin
        if (!s_wr_req)     w_done <= 1'b0;
        else if (f_wr_ack) w_done <= 1'b1;
    end

    assign f_wr_req  = s_wr_req & ~w_done & ~f_wr_ack;
    assign f_wr_addr = s_wr_addr;
    assign f_wr_din  = s_wr_din;
    assign f_wr_be   = s_wr_be;
    assign s_wr_ack  = f_wr_ack;

endmodule

`default_nettype wire
