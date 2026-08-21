// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// VU-002 sprite subsystem: sprite RAM in, one sprite pixel per screen position
// out. Wraps the parser and the bitmap renderer, and owns the memory between
// and after them.
//
//   sprite RAM --> kaneko_vuspr --> resolved table --> kaneko_vuspr_draw
//                                                          |
//                                            bitmap + coverage mask (x2)
//                                                          |
//                                                     mixer read
//
// WHY A BITMAP AND NOT A LINE BUFFER (decision D5)
//
// The hardware has a bitmap and the games depend on what that implies: sprites
// are composited into it in table order with first-writer-wins, so a higher
// table index is frontmost, and the VU-002 keep-sprites mode leaves the
// previous frame's contents in place. A per-line renderer reproduces the first
// of those and not the second.
//
// WHY DOUBLE-BUFFERED
//
// A pass over 1024 sprites is tens of thousands of clocks and every pixel may
// miss the sample-ROM cache, so rendering spans a frame rather than fitting in
// vblank. The mixer must therefore read a surface nobody is drawing on.
//
// THE MASK IS NEVER CLEARED
//
// Clearing 65,536 mask bits every frame is a pass the frame does not have to
// spare. Instead each buffer carries a parity bit that flips when it becomes
// the back buffer, and a pixel counts as marked when its stored bit EQUALS
// that parity. Two frames of staleness therefore read as clear for free. The
// bitmap needs no clearing either, because the mixer gates on the mask.
//
// The mask is a two-port memory and stays one: while a buffer is the back
// buffer the renderer reads and writes it, and while it is the front buffer
// only the mixer reads it. A buffer is never both, so the read port is muxed
// rather than duplicated.
`timescale 1ns/1ps
`default_nettype none

module kaneko_spr_sys #(
    parameter  int unsigned BMP_W_LOG2 = 8,
    parameter  int unsigned BMP_H_LOG2 = 8,
    parameter  int unsigned SPRITES    = 1024,
    parameter  int unsigned SDR_AW     = 25,
    localparam int unsigned AW         = BMP_W_LOG2 + BMP_H_LOG2,
    localparam int unsigned NPIX       = 1 << AW
) (
    input  wire clk,
    input  wire rst,

    // One pulse per frame, in vblank. Ignored while a pass is still running —
    // see `overrun`.
    input  wire         frame_start,

    // Per-game configuration, all of it from the machine config.
    input  wire [10:0]  sprite_count,
    input  wire [15:0]  sprite_xoffs,
    input  wire [15:0]  sprite_yoffs,
    input  wire [8:0]   visarea_min_y,
    input  wire         wide_screen,
    input  wire         fliptype,
    input  wire [9:0]   clip_x0, clip_x1, clip_y0, clip_y1,

    // Sprite RAM, video-side read port on kaneko_vmem.
    output wire [11:0]  ram_addr,
    input  wire [15:0]  ram_data,

    // Sprite register file.
    input  wire [255:0] regs_flat,

    // Sprite ROM, through the same feeder the tile layers use.
    input  wire [SDR_AW:1]  rom_base,
    output wire             sdr_req,
    output wire [SDR_AW:1]  sdr_addr,
    input  wire             sdr_ack,
    input  wire [63:0]      sdr_dout,

    // Mixer read port. The pixel arrives ONE clock after the coordinates, in
    // step with kaneko_tmap_line's own registered line-buffer read.
    input  wire [BMP_W_LOG2-1:0] rd_x,
    input  wire [BMP_H_LOG2-1:0] rd_y,
    output wire [13:0]      spr_pix,     // 0 = nothing here
    output wire [1:0]       spr_prio,

    // Telemetry, for the debug overlay.
    output wire         busy,
    output logic [15:0] overrun
);

    // ------------------------------------------------------ resolved table
    // 47 bits of payload; kaneko_vuspr_draw reads it as a 64-bit record with
    // the top bits spare, so the record stays a round size in memory.
    logic [46:0] tbl [0:SPRITES-1];
    logic [46:0] tbl_q;

    logic [9:0]  tbl_wa;
    logic        tbl_we;
    logic [46:0] tbl_wd;
    wire  [9:0]  tbl_ra;

    always_ff @(posedge clk) begin
        if (tbl_we) tbl[tbl_wa] <= tbl_wd;
        tbl_q <= tbl[tbl_ra];
    end

    // ------------------------------------------------------------- parser
    logic par_start;
    wire  par_busy, par_done;
    wire  par_valid;
    wire [16:0] par_code;
    wire [5:0]  par_colour;
    wire [1:0]  par_prio;
    wire        par_flipx, par_flipy;
    wire signed [9:0] par_x, par_y;

    kaneko_vuspr #(.SPRITES(SPRITES)) u_parse (
        .clk(clk), .rst(rst),
        .start(par_start), .busy(par_busy), .done(par_done),
        .ram_addr(ram_addr), .ram_data(ram_data),
        .regs_flat(regs_flat),
        .sprite_xoffs(sprite_xoffs), .sprite_yoffs(sprite_yoffs),
        .visarea_min_y(visarea_min_y),
        .wide_screen(wide_screen), .fliptype(fliptype),
        .out_valid(par_valid),
        .out_code(par_code), .out_colour(par_colour), .out_prio(par_prio),
        .out_flipx(par_flipx), .out_flipy(par_flipy),
        .out_x(par_x), .out_y(par_y)
    );

    // The parser streams one record per sprite in RAM order, so the write
    // index is just a count of them.
    //
    // The counter is separate from the write address on purpose. Deriving the
    // address from the strobe — `if (tbl_we) tbl_wa <= tbl_wa + 1` — works
    // only while `par_valid` is continuous: the strobe is registered, so on an
    // isolated pulse it is still low when the increment is tested and the next
    // record overwrites the previous one. The address, the data and the strobe
    // are all registered from the same cycle instead, which is the rule the
    // renderer's mask write already had to learn.
    logic [9:0] wr_idx;

    always_ff @(posedge clk) begin
        tbl_we <= 1'b0;
        if (rst || par_start) begin
            wr_idx <= 10'd0;
        end else if (par_valid) begin
            tbl_we <= 1'b1;
            tbl_wa <= wr_idx;
            tbl_wd <= {par_y, par_x, par_flipy, par_flipx,
                       par_prio, par_colour, par_code};
            wr_idx <= wr_idx + 10'd1;
        end
    end

    // ------------------------------------------------------- sprite ROM
    wire [23:0] dr_rom_addr;
    wire [7:0]  feed_data;
    wire [0:0]  feed_ok;
    logic [7:0] dr_rom_data;

    kaneko_tilerom #(.NREQ(1), .SDR_AW(SDR_AW)) u_sprrom (
        .clk(clk), .rst(rst),
        .req_addr(dr_rom_addr),
        .base_addr(rom_base),
        .req_data(feed_data),
        .port_ready(feed_ok),
        .sdr_req(sdr_req), .sdr_addr(sdr_addr),
        .sdr_ack(sdr_ack), .sdr_dout(sdr_dout)
    );

    // The renderer wants the byte one clock after the address; the feeder
    // presents it in the same clock, and only when it hits. Registering it on
    // the hit gives both: valid data, one clock late.
    wire dr_ce = feed_ok[0];
    always_ff @(posedge clk) if (dr_ce) dr_rom_data <= feed_data;

    // ----------------------------------------------------------- renderer
    logic dr_start;
    wire  dr_busy, dr_done;
    wire  dr_bmp_we;
    wire [AW-1:0] dr_bmp_addr;
    wire [15:0]   dr_bmp_data;
    wire [AW-1:0] dr_mask_raddr, dr_mask_waddr;
    wire          dr_mask_we;
    wire          dr_mask_q;

    kaneko_vuspr_draw #(.BMP_W_LOG2(BMP_W_LOG2), .BMP_H_LOG2(BMP_H_LOG2))
    u_draw (
        .clk(clk), .rst(rst), .ce(dr_ce),
        .start(dr_start), .sprite_count(sprite_count),
        .busy(dr_busy), .done(dr_done),
        .tbl_addr(tbl_ra), .tbl_data({17'd0, tbl_q}),
        .rom_addr(dr_rom_addr), .rom_data(dr_rom_data),
        .clip_x0(clip_x0), .clip_x1(clip_x1),
        .clip_y0(clip_y0), .clip_y1(clip_y1),
        .bmp_we(dr_bmp_we), .bmp_addr(dr_bmp_addr), .bmp_data(dr_bmp_data),
        .mask_raddr(dr_mask_raddr), .mask_q(dr_mask_q),
        .mask_waddr(dr_mask_waddr), .mask_we(dr_mask_we)
    );

    // ------------------------------------------------- surfaces (double)
    // Two separate arrays rather than one indexed by buffer: an array of
    // arrays, or a concatenated index, is one of the shapes that stops Quartus
    // inferring block RAM, and it does so without a warning.
    logic [15:0] bmp0 [0:NPIX-1];
    logic [15:0] bmp1 [0:NPIX-1];
    logic        msk0 [0:NPIX-1];
    logic        msk1 [0:NPIX-1];

    logic [15:0] q_bmp0, q_bmp1;
    logic        q_msk0, q_msk1;

    logic back;              // which surface the renderer is drawing on
    logic par0, par1;        // "marked" parity, per surface

    wire [AW-1:0] mix_addr = {rd_y, rd_x};

    // Only the back surface is written, and only the front is read by the
    // mixer, so each surface needs one read address and one write port.
    wire [AW-1:0] m0_ra = back ? mix_addr : dr_mask_raddr;
    wire [AW-1:0] m1_ra = back ? dr_mask_raddr : mix_addr;

    always_ff @(posedge clk) begin
        if (dr_bmp_we  && !back) bmp0[dr_bmp_addr]  <= dr_bmp_data;
        if (dr_bmp_we  &&  back) bmp1[dr_bmp_addr]  <= dr_bmp_data;
        if (dr_mask_we && !back) msk0[dr_mask_waddr] <= par0;
        if (dr_mask_we &&  back) msk1[dr_mask_waddr] <= par1;

        q_bmp0 <= bmp0[mix_addr];
        q_bmp1 <= bmp1[mix_addr];
        // THE BACK SURFACE'S MASK READ IS FROZEN WITH THE RENDERER.
        //
        // The renderer's mask address is combinational from its pixel
        // counters, and those counters advance on the LAST cycle of a sprite —
        // so by the time a stall begins, the address has already moved to the
        // next sprite's first pixel while stage B still owes a decision on the
        // last one. Reading every cycle then replaces the correct answer with
        // one for the wrong address, and when `ce` returns the final pixel of
        // the sprite is judged already-marked and dropped. One missing pixel
        // per sprite, which is invisible on a still and wrong everywhere.
        //
        // Gating the read with `ce` holds the answer that was correct when it
        // was asked for. The front surface is not gated: the mixer reads it
        // every pixel and has nothing to do with the renderer's stalls.
        if (back || dr_ce)  q_msk0 <= msk0[m0_ra];
        if (!back || dr_ce) q_msk1 <= msk1[m1_ra];
    end

    // The renderer tests the surface it is drawing on; the mixer reads the
    // other one. `back` is registered and changes only between passes, so
    // using it directly on the one-clock-late read results is correct.
    assign dr_mask_q = back ? (q_msk1 == par1) : (q_msk0 == par0);

    wire         mix_marked = back ? (q_msk0 == par0) : (q_msk1 == par1);
    wire [15:0]  mix_word   = back ? q_bmp0 : q_bmp1;

    assign spr_pix  = mix_marked ? mix_word[13:0] : 14'd0;
    assign spr_prio = mix_word[15:14];

    // ------------------------------------------------------------- sequence
    typedef enum logic [1:0] { S_IDLE, S_PARSE, S_DRAW } state_t;
    state_t st;

    assign busy = (st != S_IDLE);

    always_ff @(posedge clk) begin
        par_start <= 1'b0;
        dr_start  <= 1'b0;

        if (rst) begin
            st      <= S_IDLE;
            back    <= 1'b0;
            par0    <= 1'b0;
            par1    <= 1'b0;
            overrun <= 16'd0;
        end else begin
            case (st)
                S_IDLE: if (frame_start) begin
                    // Swap, then flip the new back surface's parity so every
                    // mark left from two frames ago reads as clear.
                    back      <= ~back;
                    if (back) par0 <= ~par0;
                    else      par1 <= ~par1;
                    par_start <= 1'b1;
                    st        <= S_PARSE;
                end

                S_PARSE: begin
                    if (frame_start) overrun <= overrun + 16'd1;
                    if (par_done) begin
                        dr_start <= 1'b1;
                        st       <= S_DRAW;
                    end
                end

                S_DRAW: begin
                    if (frame_start) overrun <= overrun + 16'd1;
                    if (dr_done) st <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, par_busy, dr_busy};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule

`default_nettype wire
