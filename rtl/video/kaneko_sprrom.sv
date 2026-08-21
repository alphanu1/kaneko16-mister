// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Sprite ROM feeder: two blocks in flight at once, on two SDRAM ports.
//
// THE ACCESS PATTERN, DERIVED RATHER THAN ASSUMED
//
// The renderer walks x inside y, and a sprite pixel's ROM address is
// {py[3], px[3], py[2:0], px[2:1]}, so the eight-byte block index is
// {py3, px3, py2, py1}. Enumerating all 256 pixels of a sprite in the order
// they are drawn gives the block sequence
//
//     0 4 0 4  1 5 1 5  2 6 2 6  3 7 3 7  8 12 8 12  9 13 9 13  ...
//
// Sixteen distinct blocks, thirty-two visits. Two facts fall out of it:
//
//   1. Bit 2 of the block index — which is address bit 5, "is x past 8" —
//      splits the sixteen into two halves that NEVER mix. So an entry per half
//      needs no replacement policy at all: an address selects its entry.
//
//   2. Each row pair uses one block from each half, alternating. Held in two
//      entries, the alternation is free; the cost is the two fetches at the
//      start of each pair.
//
// A single port makes those two fetches serial, so a sprite pays sixteen round
// trips. A port per half makes them concurrent and it pays eight. Each entry
// simply keeps its own half loaded for whatever address is current, which means
// the second block of a pair is already being fetched while the renderer is
// still drawing from the first — a prefetch that needs no prediction, because
// the address is already known.
`timescale 1ns/1ps
`default_nettype none

module kaneko_sprrom #(
    parameter int unsigned SDR_AW = 25
) (
    input  wire clk,
    input  wire rst,

    input  wire [23:0]     req_addr,
    input  wire [SDR_AW:1] base_addr,
    output wire [7:0]      req_data,
    output wire            ready,

    // One port per half. They are separate ports and not one port used twice
    // BECAUSE the point is to have both fetches outstanding together.
    output logic [1:0]            sdr_req,
    output logic [1:0][SDR_AW:1]  sdr_addr,
    input  wire  [1:0]            sdr_ack,
    input  wire  [1:0][63:0]      sdr_dout
);
    // The block tag is req_addr[23:3], and its bit 2 is address bit 5 — the
    // half select. Each entry wants the current block with that one bit forced
    // to its own half, so the tag bit is never taken from the request: it is
    // supplied. Built from req_addr directly rather than sliced back out of a
    // tag, which would leave the forced bit visibly unused.
    wire        half  = req_addr[5];
    wire [20:0] want0 = {req_addr[23:6], 1'b0, req_addr[4:3]};
    wire [20:0] want1 = {req_addr[23:6], 1'b1, req_addr[4:3]};

    logic [20:0] tag0, tag1;
    logic        valid0, valid1;
    logic [63:0] line0, line1;

    wire hit0 = valid0 && (tag0 == want0);
    wire hit1 = valid1 && (tag1 == want1);

    // Only the half the renderer is actually reading has to be present; the
    // other one being in flight is the entire point.
    assign ready    = half ? hit1 : hit0;
    assign req_data = half ? line1[{req_addr[2:0], 3'd0} +: 8]
                           : line0[{req_addr[2:0], 3'd0} +: 8];

    typedef enum logic { S_IDLE, S_WAIT } state_t;
    state_t st0, st1;

    // The controller bursts from exactly the address given, so ask for the
    // aligned one — that is what makes a block a block.
    wire [SDR_AW:1] fetch0 = SDR_AW'(base_addr + SDR_AW'({want0, 2'b00}));
    wire [SDR_AW:1] fetch1 = SDR_AW'(base_addr + SDR_AW'({want1, 2'b00}));

    always_ff @(posedge clk) begin
        if (rst) begin
            st0 <= S_IDLE; st1 <= S_IDLE;
            sdr_req <= 2'b00; valid0 <= 1'b0; valid1 <= 1'b0;
        end else begin
            case (st0)
                S_IDLE: if (!hit0) begin
                    sdr_addr[0] <= fetch0; sdr_req[0] <= 1'b1; st0 <= S_WAIT;
                end
                S_WAIT: if (sdr_ack[0]) begin
                    line0 <= sdr_dout[0]; tag0 <= want0; valid0 <= 1'b1;
                    sdr_req[0] <= 1'b0;   st0 <= S_IDLE;
                end
                default: st0 <= S_IDLE;
            endcase

            case (st1)
                S_IDLE: if (!hit1) begin
                    sdr_addr[1] <= fetch1; sdr_req[1] <= 1'b1; st1 <= S_WAIT;
                end
                S_WAIT: if (sdr_ack[1]) begin
                    line1 <= sdr_dout[1]; tag1 <= want1; valid1 <= 1'b1;
                    sdr_req[1] <= 1'b0;   st1 <= S_IDLE;
                end
                default: st1 <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
