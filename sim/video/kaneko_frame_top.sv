// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Simulation-only wrapper. Verilator builds one top per harness, and the frame
// renderer needs all three video blocks at once, so this exposes them side by
// side. It is NOT a core integration module — it has no shared state, no
// arbitration and no memory, and nothing in rtl/ should ever instantiate it.
// The real top level is a later milestone.

`default_nettype none

module kaneko_frame_top (
    input  wire         clk,
    input  wire         rst,

    // ---- tilemap address engine (combinational) ----
    input  wire [8:0]          t_screen_x,
    input  wire [8:0]          t_screen_y,
    input  wire signed [10:0]  t_dx,
    input  wire signed [10:0]  t_dy,
    input  wire [15:0]         t_scroll_x,
    input  wire [15:0]         t_scroll_y,
    input  wire [15:0]         t_linescroll,
    input  wire                t_linescroll_en,
    input  wire [15:0]         t_attr,
    input  wire [15:0]         t_code,
    output wire [8:0]          t_map_x,
    output wire [8:0]          t_map_y,
    output wire [10:0]         t_vram_attr_addr,
    output wire [10:0]         t_vram_code_addr,
    output wire [23:0]         t_rom_addr,
    output wire                t_nibble_hi,
    output wire [5:0]          t_colour,
    output wire [2:0]          t_prio,

    // ---- sprite list parser (sequential) ----
    input  wire         s_start,
    output wire         s_busy,
    output wire         s_done,
    output wire [11:0]  s_ram_addr,
    input  wire [15:0]  s_ram_data,
    input  wire [255:0] s_regs_flat,
    input  wire [15:0]  s_sprite_xoffs,
    input  wire [15:0]  s_sprite_yoffs,
    input  wire [8:0]   s_visarea_min_y,
    input  wire         s_wide_screen,
    input  wire         s_fliptype,
    output wire         s_out_valid,
    output wire [16:0]  s_out_code,
    output wire [5:0]   s_out_colour,
    output wire [1:0]   s_out_prio,
    output wire         s_out_flipx,
    output wire         s_out_flipy,
    output wire signed [9:0] s_out_x,
    output wire signed [9:0] s_out_y,

    // ---- priority mixer (combinational) ----
    input  wire [3:0]   m_layer_solid,
    input  wire [11:0]  m_layer_cat_f,
    input  wire [23:0]  m_layer_colour_f,
    input  wire [15:0]  m_layer_pix_f,
    input  wire [13:0]  m_spr_pix,
    input  wire [1:0]   m_spr_prio,
    input  wire         m_view2_2_pri,
    input  wire [15:0]  m_spr_pri_f,
    input  wire [10:0]  m_tile_colbase,
    input  wire [10:0]  m_spr_colbase,
    output wire [10:0]  m_pen,
    output wire [2:0]   m_prio_out,
    output wire         m_sprite_won,

    // ---- sprite pixel address (combinational) ----
    input  wire [16:0]  p_code,
    input  wire [3:0]   p_fine_x,
    input  wire [3:0]   p_fine_y,
    input  wire         p_flip_x,
    input  wire         p_flip_y,
    output wire [23:0]  p_rom_addr,
    output wire         p_nibble_hi
);
    kaneko_tmap_layer u_tmap (
        .screen_x(t_screen_x), .screen_y(t_screen_y), .dx(t_dx), .dy(t_dy),
        .scroll_x(t_scroll_x), .scroll_y(t_scroll_y),
        .linescroll(t_linescroll), .linescroll_en(t_linescroll_en),
        .attr(t_attr), .code(t_code),
        .map_x(t_map_x), .map_y(t_map_y),
        .vram_attr_addr(t_vram_attr_addr), .vram_code_addr(t_vram_code_addr),
        .rom_addr(t_rom_addr), .nibble_hi(t_nibble_hi),
        .colour(t_colour), .prio(t_prio));

    kaneko_vuspr u_spr (
        .clk(clk), .rst(rst), .start(s_start), .busy(s_busy), .done(s_done),
        .ram_addr(s_ram_addr), .ram_data(s_ram_data), .regs_flat(s_regs_flat),
        .sprite_xoffs(s_sprite_xoffs), .sprite_yoffs(s_sprite_yoffs),
        .visarea_min_y(s_visarea_min_y), .wide_screen(s_wide_screen),
        .fliptype(s_fliptype),
        .out_valid(s_out_valid), .out_code(s_out_code), .out_colour(s_out_colour),
        .out_prio(s_out_prio), .out_flipx(s_out_flipx), .out_flipy(s_out_flipy),
        .out_x(s_out_x), .out_y(s_out_y));

    kaneko_mixer u_mix (
        .layer_solid(m_layer_solid), .layer_cat_f(m_layer_cat_f),
        .layer_colour_f(m_layer_colour_f), .layer_pix_f(m_layer_pix_f),
        .spr_pix(m_spr_pix), .spr_prio(m_spr_prio),
        .view2_2_pri(m_view2_2_pri), .spr_pri_f(m_spr_pri_f),
        .tile_colbase(m_tile_colbase), .spr_colbase(m_spr_colbase),
        .pen(m_pen), .prio_out(m_prio_out), .sprite_won(m_sprite_won));

    kaneko_vuspr_pixaddr u_pix (
        .code(p_code), .fine_x(p_fine_x), .fine_y(p_fine_y),
        .flip_x(p_flip_x), .flip_y(p_flip_y),
        .rom_addr(p_rom_addr), .nibble_hi(p_nibble_hi));
endmodule

`default_nettype wire
