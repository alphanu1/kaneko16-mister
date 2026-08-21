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
// ONE EIGHT-BYTE BLOCK PER LAYER, AND WHY NOT SIXTEEN
//
// Tiles are 16x16 at 4bpp, so one row of one tile is 16 pixels x 4 bits =
// exactly eight bytes: one block, one miss per tile, about seventeen per layer
// across a 256-pixel line allowing for a straddle.
//
// A sixteen-byte line was tried, on the reasoning that it covers two tile rows
// so the next scanline would hit. It made things materially worse, and the
// reason is worth keeping: the cache holds ONE entry per layer, and a scanline
// walks seventeen different tiles, so the entry is replaced long before the
// next line revisits that tile. Misses per line were unchanged while each one
// now cost two bursts — about twice the traffic. On hardware the line fetch
// ran out of time and the right-hand eighth of the screen stopped being
// written at all.
//
// The vertical reuse is real but only pays with enough entries to hold a whole
// line of tiles, which is a different change: ~17 entries per layer, or 32 for
// a power of two, at 128 bits each. Worth doing if the bandwidth is still
// short — not worth doing halfway.
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

    logic [NREQ-1:0][20:0] tag;     // req_addr[23:3]
    logic [NREQ-1:0]       valid;
    logic [NREQ-1:0][63:0] line;

    wire [NREQ-1:0] hit;
    genvar g;
    generate
        for (g = 0; g < NREQ; g = g + 1) begin : g_port
            assign hit[g] = valid[g] && (tag[g] == req_addr[g][23:3]);
            // Byte within the eight-byte block.
            assign req_data[g] = line[g][{req_addr[g][2:0], 3'd0} +: 8];
        end
    endgenerate

    assign ready = &hit;

    // Per-port fill, entirely independent: one burst, one block.
    typedef enum logic { S_IDLE, S_WAIT } state_t;

    generate
        for (g = 0; g < NREQ; g = g + 1) begin : g_fill
            state_t st;

            always_ff @(posedge clk) begin
                if (rst) begin
                    st <= S_IDLE; sdr_req[g] <= 1'b0; valid[g] <= 1'b0;
                end else begin
                    case (st)
                        S_IDLE: if (!hit[g]) begin
                            // The controller starts a burst at exactly the
                            // address given, so ask for the aligned one — that
                            // is what makes the block a block.
                            sdr_addr[g] <= SDR_AW'(base_addr[g]
                                   + SDR_AW'({req_addr[g][23:3], 2'b00}));
                            sdr_req[g]  <= 1'b1;
                            st          <= S_WAIT;
                        end

                        S_WAIT: if (sdr_ack[g]) begin
                            line[g]    <= sdr_dout[g];
                            tag[g]     <= req_addr[g][23:3];
                            valid[g]   <= 1'b1;
                            sdr_req[g] <= 1'b0;
                            st         <= S_IDLE;
                        end

                        default: st <= S_IDLE;
                    endcase
                end
            end
        end
    endgenerate

endmodule
