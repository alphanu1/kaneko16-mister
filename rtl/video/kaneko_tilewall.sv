// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// BRING-UP ONLY. Renders a wall of tiles straight out of the tile ROM in
// SDRAM, with no CPU and no VRAM. Nothing in the finished core instantiates
// this; it exists to make the memory path and the video path visible on
// hardware at the same time.
//
// The tile index is simply the screen position, so the screen becomes a
// contact sheet of the ROM: tile (x/16, y/16) of the current page. That makes a
// wrong picture diagnosable rather than merely wrong —
//
//   nothing at all        loader or SDRAM never delivered
//   uniform noise         reading the wrong region, or the address is wrong
//   right shapes, wrong   nibble order or the sub-tile layout is wrong
//     pixel pairs
//   right tiles, sheared  the fetch is not keeping up with the pixel clock
//   correct              the whole path works
//
// Fetch strategy. A 16-pixel tile row needs two 4-byte runs, 32 bytes apart:
// the tile layout is four 8x8 sub-tiles at byte 0/32/64/96 with 4-byte rows. So
// each 16-pixel span issues two SDRAM bursts, well inside the 128 core clocks a
// span lasts at ce_pix = clk/8.
//
// The palette is fabricated. Real palette data lives in RAM the CPU writes, and
// there is no CPU here, so the 4-bit pixel is expanded to a ramp. The point is
// to see tile SHAPE, not colour.

`timescale 1ns/1ps
`default_nettype none

module kaneko_tilewall #(
    parameter int unsigned SDR_AW = 25,
    // Region bases in SDRAM, from decision D6.
    parameter logic [24:0] BASE_VIEW2_0 = 25'h0080000 >> 1,
    parameter logic [24:0] BASE_VIEW2_1 = 25'h0180000 >> 1,
    parameter logic [24:0] BASE_KAN_SPR = 25'h0280000 >> 1
)(
    input  wire        clk,
    input  wire        rst,
    // The fetch is driven by the run address changing rather than by the pixel
    // strobe, so ce_pix is not needed here. Kept on the port so the module
    // reads the same as the real fetch path it stands in for.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire        ce_pix,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire        rom_loaded,
    input  wire [1:0]  mode,          // 0 tiles chip0, 1 tiles chip1, 2 sprites, 3 pattern

    // [8] is unused: the visible width is 256, so a page is 16 tiles across.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [8:0]  screen_x,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [8:0]  screen_y,
    input  wire        de,

    output logic           sdr_req,
    output logic [SDR_AW:1] sdr_addr,
    input  wire            sdr_ack,
    input  wire [63:0]     sdr_dout,

    output logic [7:0] r, g, b
);
    // Which ROM region this page comes from. Only the burst-aligned part is
    // used; the low bits are zero by construction (D6 puts every region on a
    // 512 KB boundary).
    /* verilator lint_off UNUSEDSIGNAL */
    logic [24:0] base;
    /* verilator lint_on UNUSEDSIGNAL */
    always_comb begin
        case (mode)
            2'd0:    base = BASE_VIEW2_0;
            2'd1:    base = BASE_VIEW2_1;
            default: base = BASE_KAN_SPR;
        endcase
    end

    // Contact-sheet index: 16 tiles across, advancing down the screen.
    wire [3:0]  tile_x = screen_x[7:4];
    wire [7:0]  tile_y = {3'd0, screen_y[8:4]};
    // 16 tiles across, advancing down: index = row*16 + column.
    wire [15:0] tile   = {4'd0, tile_y, tile_x};

    wire [3:0] fine_x = screen_x[3:0];
    wire [3:0] fine_y = screen_y[3:0];

    // Byte address of the 4-byte run holding this pixel's row within its
    // sub-tile. Same layout as kaneko_tmap_pixaddr, minus the column.
    // [1:0] select the byte within the 4-byte run and are consumed by
    // byte_sel below rather than by the address.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [23:0] run_byte;
    /* verilator lint_on UNUSEDSIGNAL */
    assign run_byte = {tile, 7'd0}
                         + {17'd0, fine_y[3], fine_x[3], fine_y[2:0], 2'd0};

    // ---------------------------------------------------------- fetch
    // One burst per 4-byte run; the run changes every 8 pixels.
    logic [20:0] run_word_q;
    wire  [20:0] run_word = run_byte[23:3];   // 8-byte aligned burst

    logic [63:0] data;
    logic        pending;

    always_ff @(posedge clk) begin
        if (rst) begin
            sdr_req <= 1'b0; pending <= 1'b0; run_word_q <= '1; data <= '0;
        end else begin
            if (sdr_ack) begin
                data    <= sdr_dout;
                pending <= 1'b0;
                sdr_req <= 1'b0;
            end
            // Issue when the needed run changes and nothing is outstanding.
            if (rom_loaded && !pending && (run_word != run_word_q)) begin
                run_word_q <= run_word;
                sdr_addr   <= SDR_AW'({base[24:2], 2'd0} + {4'd0, run_word});
                sdr_req    <= 1'b1;
                pending    <= 1'b1;
            end
        end
    end

    // ---------------------------------------------------------- pixel
    // The burst is 8 bytes; pick the byte holding this pixel's nibble pair.
    wire [2:0] byte_sel = {run_byte[2], fine_x[2:1]};
    logic [7:0] pix_byte;
    always_comb pix_byte = data[{byte_sel, 3'd0} +: 8];

    // Sprites use the MSB nibble order, tiles the LSB — the one difference
    // between the two layouts, and the thing this build can show directly.
    wire nibble_hi = (mode == 2'd2) ? ~fine_x[0] : fine_x[0];
    wire [3:0] pix = nibble_hi ? pix_byte[7:4] : pix_byte[3:0];

    // Fabricated ramp: there is no palette without a CPU.
    wire [7:0] lum = {pix, pix};

    always_comb begin
        if (!de || !rom_loaded) begin
            {r, g, b} = 24'd0;
        end else if (mode == 2'd3) begin
            // Pattern: no memory involved at all, so a blank screen here means
            // the video path, and a picture here with nothing in the other
            // modes means the memory path.
            r = {8{screen_x[3]}};
            g = {8{screen_y[3]}};
            b = {8{screen_x[4] ^ screen_y[4]}};
        end else begin
            r = lum; g = lum; b = lum;
        end
    end
endmodule

`default_nettype wire
