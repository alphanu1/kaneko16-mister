// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// VU-002 sprite list parser with multisprite latching.
//
// Behaviour transcribed from MAME's kaneko16_sprite_device /
// kaneko_vu002_sprite_device (src/mame/kaneko/kaneko_spr.cpp, BSD-3-Clause,
// Luca Elia and David Haywood). Retain that attribution on anything lifted.
//
// Walks the 1024-entry sprite list in RAM order, resolving each record into a
// drawable sprite. Order matters and cannot be parallelised: MAME's own
// comment is explicit that sprites "*must* be parsed from the first in RAM to
// the last, because of the multisprite feature", and separately that they must
// be *drawn* last-to-first for priority. This module does the parsing half;
// the draw order is the consumer's problem.
//
// Multisprite is not an edge case. In the very first frame captured from
// Explosive Breaker (tools/mame_view2_census.lua, frame 600), records 1-3 all
// read attr=0xe300 — latched code, latched colour and latched X/Y offsets, all
// three bits at once, immediately after a record that set them.
//
// Record format, 4 words (VU-002 / "type 0"):
//
//   word 0  attribute
//             f--- ---- ---- ----   Multisprite: use latched code + 1
//             -e-- ---- ---- ----   Multisprite: use latched colour
//             --d- ---- ---- ----   Multisprite: use latched X,Y as offsets
//             ---c b--- ---- ----   Index of XY offset table entry
//             ---- --9- ---- ----   High priority vs FG tiles
//             ---- ---8 ---- ----   High priority vs BG tiles
//             ---- ---- 7654 32--   Colour
//             ---- ---- ---- --1-   X flip
//             ---- ---- ---- ---0   Y flip
//   word 1  code
//   word 2  X position << 6
//   word 3  Y position << 6
//
// Arithmetic note: every position term is added or subtracted, and the final
// transform reads only bits 15:6. Addition is congruent mod 2^16, so 16-bit
// wrapping arithmetic throughout is exact — MAME's use of `int` for the
// intermediates makes no difference to the result.
//
// The code latch is 17 bits, which is provably enough: it is loaded with at
// most 0xffff from RAM and incremented at most 1023 times in a pass.

`default_nettype none

module kaneko_vuspr #(
    parameter int unsigned SPRITES = 1024
)(
    input  wire         clk,
    input  wire         rst,

    input  wire         start,          // pulse to begin a parse pass
    output logic        busy,
    output logic        done,           // pulse when the pass completes

    // Sprite RAM read port. Address is a word address; data is expected one
    // clock after the address is presented (synchronous BRAM).
    output logic [11:0] ram_addr,
    input  wire  [15:0] ram_data,

    // Sprite register file, 16 words (0x00..0x1e). Flat so the port works on
    // tools that dislike unpacked array ports.
    input  wire  [255:0] regs_flat,

    // set_offsets() from the machine config
    input  wire  [15:0] sprite_xoffs,
    input  wire  [15:0] sprite_yoffs,
    // screen().visible_area().min_y — enters the Y offset, see parse_sprite
    input  wire  [8:0]  visarea_min_y,
    // (screen width > 0x100) selects max = 0x200<<6 rather than 0x100<<6
    input  wire         wide_screen,
    // m_sprite_fliptype: 0 latches flip with colour, 1 never latches it
    input  wire         fliptype,

    // Resolved sprite stream, one beat per record, in RAM order.
    output logic        out_valid,
    output logic [16:0] out_code,
    output logic [5:0]  out_colour,
    output logic [1:0]  out_prio,
    output logic        out_flipx,
    output logic        out_flipy,
    output logic signed [9:0] out_x,
    output logic signed [9:0] out_y
);

    // ------------------------------------------------------------- registers
    function automatic [15:0] reg_word(input [3:0] idx);
        reg_word = regs_flat[idx*16 +: 16];
    endfunction

    /* verilator lint_off UNUSEDSIGNAL */
    wire [15:0] reg0        = reg_word(4'd0);   // [15] sprite disable and
                                                // [2] keep-on-screen are the
                                                // consumer's business, not the
                                                // parser's
    /* verilator lint_on UNUSEDSIGNAL */
    wire [15:0] global_yoff = reg_word(4'd1);   // 0x02: Y offset << 6
    wire        glob_flipy  = reg0[0];
    wire        glob_flipx  = reg0[1];

    // max = (width > 0x100) ? (0x200 << 6) : (0x100 << 6)
    wire [15:0] max_val = wide_screen ? 16'h8000 : 16'h4000;

    // ------------------------------------------------------------------ FSM
    typedef enum logic [2:0] { S_IDLE, S_W0, S_W1, S_W2, S_W3 } state_t;
    state_t state;

    logic [$clog2(SPRITES):0] index;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [15:0] attr;      // [10] is blank in MAME's format table and unread
    /* verilator lint_on UNUSEDSIGNAL */
    logic [15:0] code_raw, x_raw, y_raw;

    // Latches carried across records. Reset at the start of every pass, the
    // same as MAME's locals in draw_sprites().
    logic [15:0] lat_x, lat_y;
    logic [16:0] lat_code;
    logic [5:0]  lat_colour;
    logic [1:0]  lat_prio;
    logic [15:0] lat_xoffs, lat_yoffs;
    logic        lat_flipx, lat_flipy;

    // ------------------------------------------------- per-record decode
    wire        use_lat_xy    = attr[13];
    wire        use_lat_col   = attr[14];
    wire        use_lat_code  = attr[15];
    wire [1:0]  off_index     = attr[12:11];

    wire        raw_flipy     = attr[0];
    wire        raw_flipx     = attr[1];
    wire [5:0]  raw_colour    = attr[7:2];
    wire [1:0]  raw_prio      = attr[9:8];

    // Offset table lives at word indices 8..15: xoffs at 8+idx*2, yoffs +1.
    wire [15:0] tbl_xoffs = reg_word({1'b1, off_index, 1'b0});
    wire [15:0] tbl_yoffs = reg_word({1'b1, off_index, 1'b1});

    // yoffs -= regs[1], then +/- (visible_area().min_y << 6) by global flip Y.
    wire [15:0] visy_shift = {1'b0, visarea_min_y, 6'd0};
    wire [15:0] adj_yoffs  = glob_flipy ? (tbl_yoffs - global_yoff - visy_shift)
                                        : (tbl_yoffs - global_yoff + visy_shift);

    // Resolved-this-record values after the latch rules.
    wire [16:0] r_code   = use_lat_code ? (lat_code + 17'd1) : {1'b0, code_raw};
    wire [5:0]  r_colour = use_lat_col  ? lat_colour : raw_colour;
    wire [1:0]  r_prio   = use_lat_col  ? lat_prio   : raw_prio;
    wire [15:0] r_xoffs  = use_lat_col  ? lat_xoffs  : tbl_xoffs;
    wire [15:0] r_yoffs  = use_lat_col  ? lat_yoffs  : adj_yoffs;

    // Flip follows colour when fliptype == 0; when fliptype == 1 it is always
    // taken from the record. B.Rap Boys is the only game wanting the latter,
    // and MAME flags it as not properly understood.
    wire r_flipx = fliptype ? raw_flipx : (use_lat_col ? lat_flipx : raw_flipx);
    wire r_flipy = fliptype ? raw_flipy : (use_lat_col ? lat_flipy : raw_flipy);

    // Position: optional add of the running latch, THEN latch the result,
    // THEN apply the offsets. The order is load-bearing — the latch
    // accumulates pre-offset coordinates.
    wire [15:0] p_x = use_lat_xy ? (x_raw + lat_x) : x_raw;
    wire [15:0] p_y = use_lat_xy ? (y_raw + lat_y) : y_raw;

    wire [15:0] o_x_pre = p_x + r_xoffs + sprite_xoffs;
    wire [15:0] o_y_pre = p_y + r_yoffs + sprite_yoffs;

    // Global flip mirrors about max and inverts the per-sprite flip.
    /* verilator lint_off UNUSEDSIGNAL */
    // [5:0] is the sub-pixel fraction, discarded by the /0x40 below.
    wire [15:0] o_x_flip = glob_flipx ? (max_val - o_x_pre - 16'd1024) : o_x_pre;
    wire [15:0] o_y_flip = glob_flipy ? (max_val - o_y_pre - 16'd1024) : o_y_pre;
    /* verilator lint_on UNUSEDSIGNAL */
    wire        f_flipx  = glob_flipx ? ~r_flipx : r_flipx;
    wire        f_flipy  = glob_flipy ? ~r_flipy : r_flipy;

    // ((v & 0x7fc0) - (v & 0x8000)) / 0x40  is exactly the signed 10-bit
    // value {v[15], v[14:6]}: the masked terms are both multiples of 0x40, so
    // the division is exact and no truncation-toward-zero question arises.
    wire signed [9:0] fin_x = $signed({o_x_flip[15], o_x_flip[14:6]});
    wire signed [9:0] fin_y = $signed({o_y_flip[15], o_y_flip[14:6]});

    // ------------------------------------------------------------- sequencer
    always_ff @(posedge clk) begin
        done      <= 1'b0;
        out_valid <= 1'b0;

        if (rst) begin
            state <= S_IDLE;
            busy  <= 1'b0;
            index <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (start) begin
                        busy       <= 1'b1;
                        index      <= '0;
                        lat_x      <= 16'd0;
                        lat_y      <= 16'd0;
                        lat_code   <= 17'd0;
                        lat_colour <= 6'd0;
                        lat_prio   <= 2'd0;
                        lat_xoffs  <= 16'd0;
                        lat_yoffs  <= 16'd0;
                        lat_flipx  <= 1'b0;
                        lat_flipy  <= 1'b0;
                        ram_addr   <= 12'd0;
                        state      <= S_W0;
                    end
                end

                // ram_addr is registered on one edge, its data is valid on the
                // next. So each state captures the word its predecessor
                // addressed and issues the following address in the same
                // cycle. S_W3 both captures word 3 (combinationally, as
                // y_raw) and emits.
                S_W0: begin attr     <= ram_data;
                            ram_addr <= ram_addr + 12'd1; state <= S_W1; end
                S_W1: begin code_raw <= ram_data;
                            ram_addr <= ram_addr + 12'd1; state <= S_W2; end
                S_W2: begin x_raw    <= ram_data;
                            ram_addr <= ram_addr + 12'd1; state <= S_W3; end

                S_W3: begin
                    // y_raw is combinational here: ram_data is the 4th word.
                    out_valid  <= 1'b1;
                    out_code   <= r_code;
                    out_colour <= r_colour;
                    out_prio   <= r_prio;
                    out_flipx  <= f_flipx;
                    out_flipy  <= f_flipy;
                    out_x      <= fin_x;
                    out_y      <= fin_y;

                    // Update the latches exactly where MAME does.
                    lat_code   <= r_code;
                    lat_colour <= r_colour;
                    lat_prio   <= r_prio;
                    lat_xoffs  <= r_xoffs;
                    lat_yoffs  <= r_yoffs;
                    if (!fliptype) begin
                        lat_flipx <= r_flipx;
                        lat_flipy <= r_flipy;
                    end
                    lat_x <= p_x;   // "Always latch the latest result"
                    lat_y <= p_y;

                    if (index == SPRITES[$clog2(SPRITES):0] - 1) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        index    <= index + 1'b1;
                        ram_addr <= ram_addr + 12'd1;
                        state    <= S_W0;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // y_raw is read straight from the bus in S_EMIT.
    always_comb y_raw = ram_data;

endmodule

// ------------------------------------------------------------- pixel address
//
// VU-002 uses gfx_8x8x4_row_2x2_group_packed_MSB, where the tilemap uses the
// LSB variant. The sub-tile structure is identical — 16x16 as four 8x8 blocks
// at bytes 0/32/64/96, rows of 4 bytes — and the ONLY difference is the nibble
// order within a byte: "hi nibble first" here, so an even X takes the HIGH
// nibble. Getting this backwards swaps every pixel pair in every sprite, which
// looks like corruption rather than an offset.
module kaneko_vuspr_pixaddr (
    input  wire [16:0]  code,
    input  wire [3:0]   fine_x,
    input  wire [3:0]   fine_y,
    input  wire         flip_x,
    input  wire         flip_y,
    output wire [23:0]  rom_addr,
    output wire         nibble_hi
);
    wire [3:0] px = flip_x ? ~fine_x : fine_x;
    wire [3:0] py = flip_y ? ~fine_y : fine_y;

    wire [23:0] tile_base = {code, 7'd0};
    wire [6:0]  in_tile   = {py[3], px[3], py[2:0], px[2:1]};

    assign rom_addr  = tile_base | {17'd0, in_tile};
    assign nibble_hi = ~px[0];      // MSB variant: even X is the high nibble
endmodule

`default_nettype wire
