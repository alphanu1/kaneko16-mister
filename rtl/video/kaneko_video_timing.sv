// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Video timing generator.
//
// THE TOTALS HERE ARE A DERIVATION, NOT A MEASUREMENT. Read this before
// trusting them.
//
// MAME never calls set_raw() for any Kaneko16 game, so the pixel clock and
// blanking are unrecorded — the design study lists this as an open gap and
// docs/findings.md carries it. What MAME does give is one precise refresh
// rate, for Wing Force: set_refresh_hz(59.1854). Everything else in the driver
// is a round set_refresh_hz(59) or (60).
//
// A 6 MHz pixel clock with 384 x 264 total gives
//
//     6e6 / (384 * 264) = 59.1856 Hz
//
// against MAME's 59.1854 — four decimal places. And 6 MHz is exactly the
// PCB-verified 68000 crystal halved: explbrkr and mgcrystl are annotated
// XTAL(12'000'000) "verified on pcb", and 12/2 = 6.
//
// WHAT THIS IS NOT. It is two unknowns (H and V totals) fitted to one number,
// so it is a plausible reconstruction consistent with standard arcade geometry,
// not proof. Other pairs could land on the same refresh. It also does not
// explain Wing Force itself, whose 68000 is XTAL(16'000'000) — so if the fit is
// right, the video clock is a separate crystal shared across the board family
// rather than derived from the CPU clock.
//
// It is adopted because it is defensible, exact against the one precise figure
// in the driver, and produces sane blanking (128 of 384 horizontal, 40 of 264
// vertical). It is the single number to revisit if a PCB capture ever
// contradicts it, and everything downstream is parameterised so that revisit is
// one edit.

`timescale 1ns/1ps
`default_nettype none

module kaneko_video_timing #(
    // Totals. See the header: derived, not measured.
    parameter int unsigned H_TOTAL = 384,
    parameter int unsigned V_TOTAL = 264,

    // Visible window, from MAME's visarea. explbrkr and mgcrystl are
    // set_visarea(0, 255, 16, 239): 256 x 224, starting at line 16.
    parameter int unsigned H_VIS   = 256,
    parameter int unsigned V_VIS   = 224,
    parameter int unsigned V_START = 16,

    // Sync position and width, within the blanking. Not measured either;
    // chosen to sit centrally in the blanking so a display locks.
    parameter int unsigned H_SYNC_START = 296,
    parameter int unsigned H_SYNC_WIDTH = 32,
    parameter int unsigned V_SYNC_START = 248,
    parameter int unsigned V_SYNC_WIDTH = 8
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,       // one tick per pixel

    output logic [9:0] hcnt,         // 0 .. H_TOTAL-1
    output logic [9:0] vcnt,         // 0 .. V_TOTAL-1

    // Position within the visible window, valid when de is high.
    output logic [8:0] screen_x,     // 0 .. H_VIS-1
    output logic [8:0] screen_y,     // V_START .. V_START+V_VIS-1, i.e. the
                                     // coordinate the tilemap maths expects
    output logic       hsync,
    output logic       vsync,
    output logic       hblank,
    output logic       vblank,
    output logic       de,           // display enable
    output logic       vblank_rise   // one tick at the start of vblank
);
    wire h_last = (hcnt == 10'(H_TOTAL - 1));
    wire v_last = (vcnt == 10'(V_TOTAL - 1));

    always_ff @(posedge clk) begin
        vblank_rise <= 1'b0;
        if (rst) begin
            hcnt <= '0;
            vcnt <= '0;
        end else if (ce_pix) begin
            if (h_last) begin
                hcnt <= '0;
                vcnt <= v_last ? 10'd0 : vcnt + 10'd1;
                // The line on which the visible window ends. The driver's own
                // sprite buffering and interrupts are keyed to scanlines, so
                // this edge is what the rest of the core hangs off.
                if (vcnt == 10'(V_START + V_VIS - 1)) vblank_rise <= 1'b1;
            end else begin
                hcnt <= hcnt + 10'd1;
            end
        end
    end

    assign hblank = (hcnt >= 10'(H_VIS));
    assign vblank = (vcnt <  10'(V_START)) || (vcnt >= 10'(V_START + V_VIS));
    assign de     = ~hblank & ~vblank;

    assign hsync  = (hcnt >= 10'(H_SYNC_START)) &&
                    (hcnt <  10'(H_SYNC_START + H_SYNC_WIDTH));
    assign vsync  = (vcnt >= 10'(V_SYNC_START)) &&
                    (vcnt <  10'(V_SYNC_START + V_SYNC_WIDTH));

    assign screen_x = hcnt[8:0];
    // screen_y is the RAW scanline, not an offset from the top of the visible
    // window. The tilemap maths adds the per-game dy and expects the same
    // coordinate MAME uses, where visarea starts at 16 rather than 0.
    assign screen_y = vcnt[8:0];
endmodule

`default_nettype wire
