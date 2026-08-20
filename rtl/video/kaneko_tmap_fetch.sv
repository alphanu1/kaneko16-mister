// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// VIEW2 per-layer pixel fetch pipeline.
//
// Wraps the (MAME-verified) combinational address engine in kaneko_tmap.sv
// with the memory accesses it implies, at one pixel per clock. This is the
// shape the real core needs: the frame gate drives the combinational parts
// directly and does the fetching in C++, which proves the arithmetic but not
// that it can be pipelined against real memories.
//
// Four stages, each registered, so throughput is 1 pixel/clock and latency is
// 4 clocks:
//
//   S0  screen_x/y in       -> map_y            -> scroll RAM address
//   S1  scroll word back    -> map_x, tile idx  -> VRAM address
//   S2  VRAM word back      -> attr/code decode -> tile ROM address
//   S3  ROM byte back       -> nibble select    -> pixel out
//
// Memory shapes are an implementation choice, not hardware:
//
//   scroll RAM  512 x 16   one word per tilemap row
//   VRAM       1024 x 32   {code, attr} in ONE word, so a tile entry is a
//                          single read. The chip's own VRAM is 16-bit with
//                          attr and code in adjacent words; packing them here
//                          halves the fetch cost and changes nothing visible.
//   tile ROM    byte port  the 4bpp nibble is selected from the byte
//
// The scroll RAM read is unconditional even when line scroll is disabled —
// the result is simply masked. Gating the read would save nothing (the port
// is there either way) and would add a path from the control bit into the
// address.

`timescale 1ns/1ps
`default_nettype none

module kaneko_tmap_fetch (
    input  wire         clk,
    input  wire         rst,
    input  wire         ce,             // clock enable: one pixel per tick

    // Request
    input  wire         req_valid,
    input  wire [8:0]   screen_x,
    input  wire [8:0]   screen_y,

    // Layer configuration. Stable for at least the pipeline depth; in the core
    // these come from the VIEW2 register bank and change between frames.
    input  wire signed [10:0] dx,
    input  wire signed [10:0] dy,
    input  wire [15:0]  scroll_x,
    input  wire [15:0]  scroll_y,
    input  wire         linescroll_en,
    input  wire         layer_enable,   // layerctl disable bit, inverted

    // Scroll RAM: address out, data one clock later
    output wire [8:0]   scr_addr,
    input  wire [15:0]  scr_data,

    // VRAM: {code, attr}
    output wire [9:0]   vram_addr,
    input  wire [31:0]  vram_data,

    // Tile ROM
    output wire [23:0]  rom_addr,
    input  wire [7:0]   rom_data,

    // Result, 4 clocks after the request
    output logic        pix_valid,
    output logic [3:0]  pix,
    output logic [5:0]  colour,
    output logic [2:0]  cat,
    output logic        solid
);
    // ------------------------------------------------------------- stage 0
    wire [8:0] s0_map_y;
    kaneko_tmap_vscroll u_v (
        .screen_y(screen_y), .dy(dy), .scroll_y(scroll_y), .map_y(s0_map_y));

    assign scr_addr = s0_map_y;   // line scroll is indexed by MAP row

    logic        s1_valid;
    logic [8:0]  s1_screen_x, s1_map_y;
    always_ff @(posedge clk) begin
        if (rst) s1_valid <= 1'b0;
        else if (ce) begin
            s1_valid    <= req_valid;
            s1_screen_x <= screen_x;
            s1_map_y    <= s0_map_y;
        end
    end

    // ------------------------------------------------------------- stage 1
    wire [8:0] s1_map_x;
    kaneko_tmap_hscroll u_h (
        .screen_x(s1_screen_x), .dx(dx), .scroll_x(scroll_x),
        .linescroll(scr_data), .linescroll_en(linescroll_en), .map_x(s1_map_x));

    // 32 x 32 tiles, row-major; one 32-bit word per tile entry.
    assign vram_addr = {s1_map_y[8:4], s1_map_x[8:4]};

    logic       s2_valid;
    logic [3:0] s2_fine_x, s2_fine_y;
    always_ff @(posedge clk) begin
        if (rst) s2_valid <= 1'b0;
        else if (ce) begin
            s2_valid  <= s1_valid;
            s2_fine_x <= s1_map_x[3:0];
            s2_fine_y <= s1_map_y[3:0];
        end
    end

    // ------------------------------------------------------------- stage 2
    wire [15:0] s2_attr = vram_data[15:0];
    wire [15:0] s2_code = vram_data[31:16];

    wire [5:0] s2_colour;
    wire [2:0] s2_cat;
    wire       s2_flip_x, s2_flip_y;
    kaneko_tmap_attr u_a (
        .attr(s2_attr), .colour(s2_colour), .prio(s2_cat),
        .flip_x(s2_flip_x), .flip_y(s2_flip_y));

    wire s2_nibble_hi;
    kaneko_tmap_pixaddr u_p (
        .code(s2_code), .fine_x(s2_fine_x), .fine_y(s2_fine_y),
        .flip_x(s2_flip_x), .flip_y(s2_flip_y),
        .rom_addr(rom_addr), .nibble_hi(s2_nibble_hi));

    logic       s3_valid, s3_nibble_hi;
    logic [5:0] s3_colour;
    logic [2:0] s3_cat;
    always_ff @(posedge clk) begin
        if (rst) s3_valid <= 1'b0;
        else if (ce) begin
            s3_valid     <= s2_valid;
            s3_nibble_hi <= s2_nibble_hi;
            s3_colour    <= s2_colour;
            s3_cat       <= s2_cat;
        end
    end

    // ------------------------------------------------------------- stage 3
    // LSB variant: an even X takes the LOW nibble. Sprites use the MSB variant
    // and are the other way round — see kaneko_vuspr_pixaddr.
    wire [3:0] s3_pix = s3_nibble_hi ? rom_data[7:4] : rom_data[3:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            pix_valid <= 1'b0;
            solid     <= 1'b0;
        end else if (ce) begin
            pix_valid <= s3_valid;
            pix       <= s3_pix;
            colour    <= s3_colour;
            cat       <= s3_cat;
            // Pen 0 is transparent (set_transparent_pen(0)); a disabled layer
            // contributes nothing at all.
            solid     <= s3_valid && layer_enable && (s3_pix != 4'd0);
        end
    end
endmodule

`default_nettype wire
