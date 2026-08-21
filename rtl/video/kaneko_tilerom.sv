// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Tile ROM feeder: N byte-wide read ports served from one SDRAM port.
//
// kaneko_tmap_fetch wants a byte of tile ROM per pixel per layer, with the
// data one clock after the address — a ROM-like port. There are four layers
// and one SDRAM port, and SDRAM answers in eight-byte bursts after an
// arbitrated round trip, so something has to sit in between.
//
// SIXTEEN-BYTE LINES, BECAUSE THE REUSE IS VERTICAL
//
// The tiles are 16x16 at 4bpp, so one row of one tile is 16 pixels x 4 bits =
// exactly eight bytes. Within a scanline that means one miss per tile — about
// seventeen per layer across 256 pixels, allowing for a straddle — and it also
// means the NEXT scanline of the same tile is a different eight bytes. A cache
// of one block per layer therefore gets no reuse between lines at all.
//
// Holding sixteen bytes covers two tile rows, so every second scanline hits:
// roughly 68 misses per line across four layers becomes 34. The second burst
// is nearly free, being the same open row.
//
// This was measured, not assumed. An earlier version held one block and the
// core could not finish a line in time; the line-overrun counter in the top
// level lit up in step with the tearing, which is what identified bandwidth
// after two plausible guesses at scroll timing had each fixed something real
// without fixing the symptom.
//
// A miss stalls every layer, not just the one that missed. They advance in
// lockstep on the same screen_x, so stalling one and not the others would
// shear the picture; kaneko_tmap_fetch's `ce` is verified to freeze the
// pipeline without losing or duplicating a pixel, which is exactly what is
// wanted here.
//
// BYTE ORDER
//
// SDRAM word n holds file byte 2n in its low half — hps_io packs it that way
// and the graphics path is built around it (D7). So byte k of an aligned
// eight-byte block is simply dout[8*k +: 8], with no swap. The 68000's ROM
// reads are the exception, not this.
`timescale 1ns/1ps
`default_nettype none

module kaneko_tilerom #(
    parameter int unsigned NREQ   = 4,
    parameter int unsigned SDR_AW = 25
) (
    input  wire clk,
    input  wire rst,

    // One byte port per layer. Addresses are byte offsets within that layer's
    // region; base_addr moves them to where the loader put it.
    input  wire [NREQ-1:0][23:0]     req_addr,
    input  wire [NREQ-1:0][SDR_AW:1] base_addr,   // region base, word address
    output wire [NREQ-1:0][7:0]      req_data,

    // Low while any port is missing. Drives kaneko_tmap_fetch's ce.
    output wire ready,

    // ONE SDRAM PORT PER LAYER, not one shared between them.
    //
    // Sharing serialised the misses: `ready` needs every port to hit, the four
    // layers cross tile boundaries at different x because their scroll differs,
    // and a pixel where two of them miss cost two full round trips back to
    // back. With a port each the controller's round-robin overlaps them, and
    // the two regions sit in different banks so the row activations overlap
    // too.
    //
    // This was the difference between a line fetch finishing inside its 3072
    // clocks and not: the line-overrun counter lit in step with the tearing,
    // and got worse as more distinct tiles appeared on screen.
    output logic [NREQ-1:0]            sdr_req,
    output logic [NREQ-1:0][SDR_AW:1]  sdr_addr,
    input  wire  [NREQ-1:0]            sdr_ack,
    input  wire  [NREQ-1:0][63:0]      sdr_dout
);

    logic [NREQ-1:0][19:0]  tag;     // req_addr[23:4]
    logic [NREQ-1:0]        valid;
    logic [NREQ-1:0][127:0] line;

    wire [NREQ-1:0] hit;
    genvar g;
    generate
        for (g = 0; g < NREQ; g = g + 1) begin : g_port
            assign hit[g] = valid[g] && (tag[g] == req_addr[g][23:4]);
            // Byte within the sixteen-byte line.
            assign req_data[g] = line[g][{req_addr[g][3:0], 3'd0} +: 8];
        end
    endgenerate

    assign ready = &hit;

    // Per-port fill, entirely independent. Two bursts make the sixteen-byte
    // line; the second lands in the row the first just opened.
    typedef enum logic [1:0] { S_IDLE, S_LO, S_GAP, S_HI } state_t;

    generate
        for (g = 0; g < NREQ; g = g + 1) begin : g_fill
            state_t st;
            logic [SDR_AW:1] blk;

            always_ff @(posedge clk) begin
                if (rst) begin
                    st <= S_IDLE; sdr_req[g] <= 1'b0; valid[g] <= 1'b0;
                end else begin
                    case (st)
                        S_IDLE: if (!hit[g]) begin
                            // The controller starts a burst at exactly the
                            // address given, so ask for the aligned one — that
                            // is what makes the line a line.
                            blk <= SDR_AW'(base_addr[g]
                                   + SDR_AW'({req_addr[g][23:4], 3'b000}));
                            sdr_addr[g] <= SDR_AW'(base_addr[g]
                                   + SDR_AW'({req_addr[g][23:4], 3'b000}));
                            sdr_req[g]  <= 1'b1;
                            st          <= S_LO;
                        end

                        S_LO: if (sdr_ack[g]) begin
                            line[g][63:0] <= sdr_dout[g];
                            sdr_req[g]    <= 1'b0;
                            sdr_addr[g]   <= blk + SDR_AW'(4);
                            st            <= S_GAP;
                        end

                        // One cycle with req low, so the controller sees a
                        // fresh rising edge for the second transfer.
                        S_GAP: begin
                            sdr_req[g] <= 1'b1;
                            st         <= S_HI;
                        end

                        S_HI: if (sdr_ack[g]) begin
                            line[g][127:64] <= sdr_dout[g];
                            tag[g]          <= req_addr[g][23:4];
                            valid[g]        <= 1'b1;
                            sdr_req[g]      <= 1'b0;
                            st              <= S_IDLE;
                        end

                        default: st <= S_IDLE;
                    endcase
                end
            end
        end
    endgenerate

endmodule
