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
    // Which ROM region this page comes from. D6 puts every region on a 512 KB
    // boundary, so a region base is already burst-aligned as a word address
    // and the sum below stays aligned.
    logic [24:0] base;
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
    //
    // ONE GROUP OF LOOKAHEAD, DOUBLE BUFFERED.
    //
    // The first version issued the request at the moment the group's first
    // pixel was already on screen, so the opening pixels of every 8-pixel group
    // showed the PREVIOUS group's data — horizontal smearing, drifting
    // diagonally because the error is constant per line. It also dropped
    // requests: run_word_q only advanced when a request was issued, so a run
    // that changed while one was outstanding was never fetched. And it churned
    // during blanking, because screen_x runs to H_TOTAL and the tile index
    // keeps cycling there.
    //
    // Now the fetch runs exactly one 8-pixel group ahead of the display,
    // wrapping to the next line at the end of one, and only for positions that
    // will actually be shown. A group lasts 8 pixel times = 64 core clocks at
    // ce_pix = clk/8, comfortably more than an SDRAM read, so the data is
    // always in hand before its group starts.

    localparam int unsigned H_TOTAL = 384;
    localparam int unsigned H_VIS   = 256;
    localparam int unsigned V_TOTAL = 264;

    wire [9:0] fx_raw  = {1'b0, screen_x} + 10'd8;
    wire       fx_wrap = fx_raw >= 10'(H_TOTAL);
    wire [8:0] fetch_x = fx_wrap ? 9'(fx_raw - 10'(H_TOTAL)) : fx_raw[8:0];
    wire [8:0] fetch_y = fx_wrap
                       ? ((screen_y == 9'(V_TOTAL - 1)) ? 9'd0 : screen_y + 9'd1)
                       : screen_y;

    wire [3:0]  f_tile_x = fetch_x[7:4];
    wire [7:0]  f_tile_y = {3'd0, fetch_y[8:4]};
    wire [15:0] f_tile   = {4'd0, f_tile_y, f_tile_x};
    // Only bit 3 matters here: it selects the left or right 8x8 sub-tile. The
    // low bits pick the byte within the run and are applied at display time.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [3:0]  f_fine_x = fetch_x[3:0];
    /* verilator lint_on UNUSEDSIGNAL */
    wire [3:0]  f_fine_y = fetch_y[3:0];

    /* verilator lint_off UNUSEDSIGNAL */
    wire [23:0] f_run_byte = {f_tile, 7'd0}
                           + {17'd0, f_fine_y[3], f_fine_x[3], f_fine_y[2:0], 2'd0};
    /* verilator lint_on UNUSEDSIGNAL */

    wire [20:0] want_word = f_run_byte[23:3];
    wire        want_ok   = rom_loaded && (fetch_x < 9'(H_VIS));

    logic [20:0] have_word;
    logic [63:0] data_next, data_cur;
    logic        pending;

    always_ff @(posedge clk) begin
        if (rst) begin
            sdr_req <= 1'b0; pending <= 1'b0; have_word <= '1;
            data_next <= '0; data_cur <= '0;
        end else begin
            if (sdr_ack) begin
                data_next <= sdr_dout;
                pending   <= 1'b0;
                sdr_req   <= 1'b0;
            end

            // Compared against what we HAVE, not against what we last asked
            // for, so a run that changes mid-flight is still fetched.
            if (want_ok && !pending && (want_word != have_word)) begin
                have_word <= want_word;
                // want_word counts 8-BYTE bursts; sdr_addr is a WORD address,
                // so it scales by four.
                sdr_addr  <= SDR_AW'(base + {want_word, 2'b00});
                sdr_req   <= 1'b1;
                pending   <= 1'b1;
            end

            // Hand the prefetched group over as the display crosses into it.
            if (ce_pix && (screen_x[2:0] == 3'd7)) data_cur <= data_next;
        end
    end

    // ---------------------------------------------------------- pixel
    // The burst is 8 bytes; pick the byte holding this pixel's nibble pair.
    wire [2:0] byte_sel = {run_byte[2], fine_x[2:1]};
    logic [7:0] pix_byte;
    always_comb pix_byte = data_cur[{byte_sel, 3'd0} +: 8];

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
