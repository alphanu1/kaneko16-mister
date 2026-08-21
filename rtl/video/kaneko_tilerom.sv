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
// WHY A CACHE AND NOT A PREFETCHER
//
// 4bpp tiles put two pixels in a byte and eight pixels in a tile row, so one
// aligned eight-byte burst covers a whole tile row and the next. Consecutive
// screen pixels walk consecutive bytes, so a single held burst per layer hits
// seven times out of eight. At a 6 MHz pixel clock that is about 3 M bursts a
// second across four layers, against 48 MHz of SDRAM — comfortable, and it
// needs no lookahead into a pipeline that does not offer any.
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

    // SDRAM read port, single outstanding.
    output logic             sdr_req,
    output logic [SDR_AW:1]  sdr_addr,
    input  wire              sdr_ack,
    input  wire [63:0]       sdr_dout
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

    // Which port to serve. Lowest missing index; the ports are equal-rate and
    // advance together, so there is nothing for a rotation to be fair about.
    logic [$clog2(NREQ)-1:0] sel;
    logic                    sel_valid;
    integer i;
    always_comb begin
        sel = '0; sel_valid = 1'b0;
        for (i = int'(NREQ) - 1; i >= 0; i = i - 1)
            if (!hit[i]) begin sel = ($clog2(NREQ))'(i); sel_valid = 1'b1; end
    end

    typedef enum logic { S_IDLE, S_WAIT } state_t;
    state_t state;
    logic [$clog2(NREQ)-1:0] pend;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; sdr_req <= 1'b0; valid <= '0;
        end else begin
            case (state)
                S_IDLE: if (sel_valid) begin
                    // Aligned four-word burst covering the eight-byte block.
                    // The controller starts a burst at exactly the address
                    // given, so asking for the aligned one is what makes the
                    // block a block (see kaneko_bus.sv on the same point).
                    sdr_addr <= SDR_AW'(base_addr[sel] + SDR_AW'({req_addr[sel][23:3], 2'b00}));
                    sdr_req  <= 1'b1;
                    pend     <= sel;
                    state    <= S_WAIT;
                end

                S_WAIT: if (sdr_ack) begin
                    sdr_req     <= 1'b0;
                    line[pend]  <= sdr_dout;
                    tag[pend]   <= req_addr[pend][23:3];
                    valid[pend] <= 1'b1;
                    state       <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
