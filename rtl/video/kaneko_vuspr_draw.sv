// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// VU-002 sprite bitmap renderer.
//
// Walks a table of resolved sprites (produced by kaneko_vuspr) and draws each
// 16x16 tile into the sprite bitmap. Decision D5: a bitmap, as the hardware
// has, not a per-line renderer.
//
// Two ordering rules from MAME, and they interact:
//
//   - kaneko_vuspr must PARSE first-to-last, because the multisprite latches
//     carry forward.
//   - draw_sprites DRAWS last-to-first, and draw_sprites_custom is
//     first-writer-wins per pixel:
//         if (pri[x] == 0) dest[x] = ...;
//         pri[x] = 0xff;          // marked even when nothing was written
//
// Together those mean **a higher table index is frontmost**. This module
// therefore walks the table DOWNWARDS and keeps the first pixel written.
//
// Note the mask is set for every non-transparent source pixel, whether or not
// that pixel won. Setting it only on a win would let a later (further back)
// sprite show through a pixel an earlier one already claimed.
//
// Pixel format matches MAME's sprite bitmap: {priority[1:0], pen[13:0]}, with
// pen = colour*16 + c. Pen 0 means nothing here.

`timescale 1ns/1ps
`default_nettype none

// WIDTH AND HEIGHT ARE SEPARATE, AND THE BITMAP IS NOT SQUARE
//
// One BMP_W_LOG2 used for both axes meant a 512x512 bitmap: 4.19 Mbit for the
// pixels alone, against 5.66 Mbit of block RAM on the whole part, and it has to
// be double-buffered because sprite rendering spans a frame rather than fitting
// in vblank. This board's screen is 256x256 (MAME's set_size for bakubrkr and
// mgcrystl); the Blaze On board is 320x240. Neither is square and neither needs
// 512 of anything.
module kaneko_vuspr_draw #(
    parameter int unsigned BMP_W_LOG2 = 8,   // bitmap stride, 256
    parameter int unsigned BMP_H_LOG2 = 8    // bitmap height, 256
    // No `localparam` in the parameter list: Quartus 17.0's parser rejects it
    // (SystemVerilog-2012), and 17.0 is the only toolchain this core is built
    // with. The address width is written out in the ports instead.
)(
    input  wire         clk,
    input  wire         rst,

    // FREEZE, FOR SDRAM.
    //
    // The sprite ROM is 2.25 MB and lives in SDRAM, not in a block RAM that
    // answers every cycle. `ce` low freezes the whole pipeline — no state
    // change, no write strobes — so a fetch that misses costs cycles rather
    // than pixels. Drive it from the ROM feeder's hit signal: when it is high
    // the byte on `rom_data` is the byte for the address issued last cycle.
    //
    // Same shape as kaneko_tmap_fetch's `ce`, which is verified to freeze
    // without losing or duplicating a pixel. This module had no stall input at
    // all and assumed a ROM that always answers.
    input  wire         ce,

    input  wire         start,
    input  wire [10:0]  sprite_count,        // 1024, or 512 on the Blaze On board
    output logic        busy,
    output logic        done,

    // Resolved sprite table, walked downwards. Packed as
    //   [16:0] code  [22:17] colour  [24:23] prio  [25] flipx  [26] flipy
    //   [36:27] x    [46:37] y       (x and y are signed 10-bit)
    output logic [9:0]  tbl_addr,
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire  [63:0] tbl_data,   // [63:47] spare, kept so the record is a
                                    // round 64 bits in memory
    /* verilator lint_on UNUSEDSIGNAL */

    // Tile ROM, one byte per read, data one clock after the address.
    output logic [23:0] rom_addr,
    input  wire  [7:0]  rom_data,

    // Clip rectangle — the visible area. MAME clips sprite drawing to it.
    input  wire [9:0]   clip_x0, clip_x1, clip_y0, clip_y1,

    // Sprite bitmap and its coverage mask. Both are read-then-write with one
    // clock of read latency.
    output logic                    bmp_we,
    output logic [BMP_W_LOG2+BMP_H_LOG2-1:0] bmp_addr,
    output logic [15:0]             bmp_data,
    // The mask needs a read and a write in the same cycle at DIFFERENT
    // addresses — stage A reads the pixel it is about to test while stage B
    // marks the previous one. A single shared address cannot express that, so
    // the port is split; an M10K simple-dual-port does this natively.
    output logic [BMP_W_LOG2+BMP_H_LOG2-1:0] mask_raddr,
    input  wire                     mask_q,
    output logic [BMP_W_LOG2+BMP_H_LOG2-1:0] mask_waddr,
    output logic                    mask_we
);

    localparam int unsigned AW = BMP_W_LOG2 + BMP_H_LOG2;

    typedef enum logic [2:0] { S_IDLE, S_FETCH, S_LATCH, S_DRAW, S_FLUSH } state_t;
    state_t state;

    logic [10:0] index;          // current sprite, counted down
    logic [3:0]  xx, yy;         // pixel within the 16x16 tile

    // Latched sprite record
    logic [16:0]       s_code;
    logic [5:0]        s_colour;
    logic [1:0]        s_prio;
    logic              s_flipx, s_flipy;
    logic signed [9:0] s_x, s_y;

    // --------------------------------------------------- pixel address maths
    wire [3:0] px = s_flipx ? ~xx : xx;
    wire [3:0] py = s_flipy ? ~yy : yy;

    // MSB nibble order for sprites — the tilemap uses LSB. Getting this
    // backwards swaps every pixel pair in every sprite.
    wire [6:0]  in_tile   = {py[3], px[3], py[2:0], px[2:1]};
    wire        nibble_hi = ~px[0];

    wire signed [10:0] dst_x = s_x + $signed({7'd0, xx});
    wire signed [10:0] dst_y = s_y + $signed({7'd0, yy});

    wire in_clip = (dst_x >= $signed({1'b0, clip_x0})) && (dst_x <= $signed({1'b0, clip_x1}))
                && (dst_y >= $signed({1'b0, clip_y0})) && (dst_y <= $signed({1'b0, clip_y1}));

    // ------------------------------------------------------------- pipeline
    // Stage A issues the ROM and mask addresses; stage B sees the data and
    // decides. Consecutive pixels in a row have distinct addresses, so no
    // read-then-write hazard arises within a sprite.
    logic        b_valid;
    logic [5:0]  b_colour;
    logic [1:0]  b_prio;
    logic        b_nibble_hi;
    logic [AW-1:0] b_addr;

    wire [AW-1:0] cur_addr = {dst_y[BMP_H_LOG2-1:0], dst_x[BMP_W_LOG2-1:0]};

    always_comb begin
        rom_addr   = {s_code, 7'd0} | {17'd0, in_tile};
        mask_raddr = cur_addr;      // stage A, combinational with the counters
    end
    // mask_waddr is REGISTERED, alongside mask_we and bmp_we/bmp_addr.
    // It was combinational (= b_addr) at first, which made the mask write land
    // one pixel AHEAD of the bitmap write: bmp_we wrote pixel N while the mask
    // was marked at pixel N+1. Every following pixel then found its mask
    // already set and drew nothing — 8 sprites produced 113 bitmap writes out
    // of an expected ~1900. A write strobe and its address must be registered
    // together or they describe different cycles.

    wire [3:0] b_pix = b_nibble_hi ? rom_data[7:4] : rom_data[3:0];

    always_ff @(posedge clk) begin
        bmp_we  <= 1'b0;
        mask_we <= 1'b0;
        done    <= 1'b0;

        if (rst) begin
            state   <= S_IDLE;
            busy    <= 1'b0;
            b_valid <= 1'b0;
        end else if (ce) begin
            // ---- stage B: resolve the pixel issued last cycle
            if (b_valid && (b_pix != 4'd0)) begin
                // First writer wins. The mask is marked whether or not this
                // pixel won, so a further-back sprite cannot show through a
                // pixel an earlier one already claimed.
                if (!mask_q) begin
                    bmp_we   <= 1'b1;
                    bmp_addr <= b_addr;
                    // {priority[1:0], pen[13:0]}, pen = colour*16 + c. The
                    // multiply leaves the low nibble clear, so the pen is just
                    // the two fields concatenated.
                    bmp_data <= {b_prio, 4'd0, b_colour, b_pix};
                end
                mask_we    <= 1'b1;
                mask_waddr <= b_addr;
            end
            b_valid <= 1'b0;

            case (state)
                // A count of zero would underflow to 2047 and draw the whole
                // table, which is not a hypothetical: the subsystem uses an
                // empty list to mean "draw nothing this frame", and without
                // this the surface fills with stale table entries instead.
                S_IDLE: if (start) begin
                    if (sprite_count == 11'd0) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        busy     <= 1'b1;
                        index    <= sprite_count - 11'd1;
                        tbl_addr <= 10'(sprite_count - 11'd1);
                        state    <= S_FETCH;
                    end
                end

                S_FETCH: state <= S_LATCH;   // table read latency

                S_LATCH: begin
                    s_code   <= tbl_data[16:0];
                    s_colour <= tbl_data[22:17];
                    s_prio   <= tbl_data[24:23];
                    s_flipx  <= tbl_data[25];
                    s_flipy  <= tbl_data[26];
                    s_x      <= tbl_data[36:27];
                    s_y      <= tbl_data[46:37];
                    xx       <= 4'd0;
                    yy       <= 4'd0;
                    state    <= S_DRAW;
                end

                S_DRAW: begin
                    // ---- stage A: issue this pixel's ROM and mask reads
                    b_valid     <= in_clip;
                    b_colour    <= s_colour;
                    b_prio      <= s_prio;
                    b_nibble_hi <= nibble_hi;
                    b_addr      <= cur_addr;

                    if (xx == 4'd15) begin
                        xx <= 4'd0;
                        if (yy == 4'd15) begin
                            if (index == 11'd0) begin
                                state <= S_FLUSH;
                            end else begin
                                index    <= index - 11'd1;
                                tbl_addr <= 10'(index - 11'd1);
                                state    <= S_FETCH;
                            end
                        end else begin
                            yy <= yy + 4'd1;
                        end
                    end else begin
                        xx <= xx + 4'd1;
                    end
                end

                S_FLUSH: begin   // one cycle for the last pixel to drain
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
