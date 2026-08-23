// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The CALC hitbox calculator, type 1 — Shogun Warriors.
//
// A00000-A0007F on the CALC3 board. Eight registers describing two rectangles
// as position and size, and read-back of an overlap distance and a status
// word. Transcribed from kaneko_hit.cpp's type-1 handlers.
//
// WHAT IT IS AND IS NOT
//
// MAME's header says the plainest thing about this device: "It is thought that
// this is done by the CALC1, TOYBOX and CALC3 protection chips found on the
// various boards, however we have 3 implementations, and they don't quite pair
// up with the chips". Type 1 is what shogwarr uses; B.Rap Boys is on the same
// PCB with the same chip and needs TYPE 2, which MAME notes means at least one
// of the implementations must be wrong.
//
// So this is not a model of silicon. It reproduces what the oracle computes,
// which is the only standard available, and B.Rap Boys gets its own type when
// it is brought up rather than being assumed compatible.
//
// SIGNEDNESS IS THE WHOLE JOB
//
// The eight registers are UNSIGNED 16-bit and every comparison between them in
// the status word is unsigned. The two distances are SIGNED 16-bit, negative
// meaning no overlap, and the sign is what the status word reports. Mixing
// those up produces a device that computes plausible distances and reports
// collisions that did not happen, which looks like a game bug rather than an
// arithmetic one.
//
// The `/2` in the overlap arithmetic is C integer division on a value that is
// always non-negative here (a sum of two unsigned 16-bit halves), so a logical
// shift is right. `abs` is over a signed difference of two 17-bit sums.
`timescale 1ns/1ps
`default_nettype none

module kaneko_hit (
    input  wire        clk,
    input  wire        rst,

    // 68000 side. WORD offset within the window -- a[6:1] of the byte address,
    // since every register here is 16 bits and bit 0 selects a half rather
    // than a register.
    input  wire [5:0]  addr,
    input  wire [15:0] din,
    input  wire        we,
    input  wire        uds,
    input  wire        lds,
    output logic [15:0] dout,

    // Free-running, sampled for the random register. The game uses it for
    // effects, not for anything it checks, so any decent sequence will do --
    // but it must not be constant, which a zero here would make it.
    input  wire [15:0] rnd
);
    logic [15:0] x1p, x1s, y1p, y1s;
    logic [15:0] x2p, x2s, y2p, y2s;

    // ------------------------------------------------------ the distances
    //
    //   [one inside other] | [ normal overlap ] | [   no overlap   ]
    //    <-------------->  |  <----------->     |  <--->
    //        <----->       |     <----------->  |             <--->
    //        <---------->  |     <-------->     |       <---->
    //
    // Negative means no overlap, and the magnitude is the gap.
    function automatic signed [15:0] coll(
        input [15:0] p1, input [15:0] s1,
        input [15:0] p2, input [15:0] s2);
        logic [16:0] e1, e2;          // p + s, 17 bits so it cannot wrap
        logic [16:0] c1, c2;          // p + s/2, the centres
        logic signed [17:0] dc;
        begin
            e1 = {1'b0, p1} + {1'b0, s1};
            e2 = {1'b0, p2} + {1'b0, s2};
            c1 = {1'b0, p1} + {1'b0, s1[15:1]};
            c2 = {1'b0, p2} + {1'b0, s2[15:1]};
            if ((p2 >= p1) && ({1'b0, p2} < e1))
                coll = 16'(s1 - (p2 - p1));       // p2 inside 1
            else if ((p1 >= p2) && ({1'b0, p1} < e2))
                coll = 16'(s2 - (p1 - p2));       // p1 inside 2
            else begin
                dc   = $signed({1'b0, c1}) - $signed({1'b0, c2});
                if (dc < 0) dc = -dc;             // abs
                coll = 16'(({1'b0, s1} + {1'b0, s2}) >> 1) - 16'(dc);
            end
        end
    endfunction

    wire signed [15:0] x_coll = coll(x1p, x1s, x2p, x2s);
    wire signed [15:0] y_coll = coll(y1p, y1s, y2p, y2s);

    // ------------------------------------------------------- status word
    // Nibble by nibble, exactly as the oracle assembles it. The second nibble
    // is a constant 4 and the first can reach 0xf, which is not a typo in
    // either place: both are in kaneko_hit.cpp verbatim.
    logic [15:0] status;
    always_comb begin
        status = 16'h0000;
        // 4th nibble: Y absolute collision
        if      (y1p >  y2p) status[13]   = 1'b1;   // 0x2000
        else if (y1p == y2p) status[14]   = 1'b1;   // 0x4000
        else                 status[15]   = 1'b1;   // 0x8000
        if (y_coll < 0)      status[12]   = 1'b1;   // 0x1000
        // 3rd nibble: X absolute collision
        if      (x1p >  x2p) status[9]    = 1'b1;   // 0x0200
        else if (x1p == x2p) status[10]   = 1'b1;   // 0x0400
        else                 status[11]   = 1'b1;   // 0x0800
        if (x_coll < 0)      status[8]    = 1'b1;   // 0x0100
        // 2nd nibble: always 4
        status[6] = 1'b1;                           // 0x0040
        // 1st nibble: XY overlap
        if (x_coll >= 0)                    status[2] = 1'b1;   // 0x0004
        if (y_coll >= 0)                    status[1] = 1'b1;   // 0x0002
        if ((x_coll >= 0) && (y_coll >= 0)) status[3:0] = 4'hf;  // 0x000f
    end

    // ------------------------------------------------------------- access
    wire [5:0] off = addr;

    always_comb begin
        case (off)
            6'h00>>1: dout = x_coll;
            6'h02>>1: dout = y_coll;
            6'h04>>1: dout = status;
            6'h14>>1: dout = rnd;
            6'h20>>1: dout = x1p;
            6'h22>>1: dout = x1s;
            6'h24>>1: dout = y1p;
            6'h26>>1: dout = y1s;
            6'h2c>>1: dout = x2p;
            6'h2e>>1: dout = x2s;
            6'h30>>1: dout = y2p;
            6'h32>>1: dout = y2s;
            // Everything else logs a warning in the oracle and returns zero.
            default:  dout = 16'h0000;
        endcase
    end

    // The oracle masks the incoming data with mem_mask before storing, so a
    // byte write leaves the other half ZERO rather than preserving it. That is
    // reproduced rather than corrected: the game writes words here, and a
    // half-write that behaved differently would diverge silently.
    wire [15:0] wdata = {uds ? din[15:8] : 8'h00, lds ? din[7:0] : 8'h00};

    always_ff @(posedge clk) begin
        if (rst) begin
            x1p <= 16'd0; x1s <= 16'd0; y1p <= 16'd0; y1s <= 16'd0;
            x2p <= 16'd0; x2s <= 16'd0; y2p <= 16'd0; y2s <= 16'd0;
        end else if (we) begin
            case (off)
                6'h20>>1: x1p <= wdata;
                6'h22>>1: x1s <= wdata;
                6'h24>>1: y1p <= wdata;
                6'h26>>1: y1s <= wdata;
                6'h2c>>1: x2p <= wdata;
                6'h2e>>1: x2s <= wdata;
                6'h30>>1: y2p <= wdata;
                6'h32>>1: y2s <= wdata;
                // 0x38 is written to zero before every computation and has no
                // effect on inputs or results. Accepted and discarded, as the
                // oracle does, so it does not fall through to the default.
                6'h38>>1: ;
                default:  ;
            endcase
        end
    end

endmodule

`default_nettype wire
