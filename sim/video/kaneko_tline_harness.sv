// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The REAL line-buffered tilemap path, next to the address engine the frame
// gate scores, so the two can be compared pixel for pixel.
//
// WHY THIS EXISTS
//
// `make gate` reports 100.0000% for blazeonj and wingforc while the board
// draws every one-pixel vertical stroke twice. Both are true, because they are
// about different modules: sim/video/kaneko_frame_top.sv instantiates
// `kaneko_tmap_layer`, and the core has run `kaneko_tmap_line` +
// `kaneko_tmap_fetch` since the line buffer replaced it. The path that draws
// the fault has never been compared against anything.
//
// `kaneko_tmap_layer` is the right oracle for it. It is combinational, it is
// simple enough to read in one sitting, and it is the thing the frame gate
// scores at 100% against MAME -- so a disagreement here is a defect in the
// line-buffered path and not an open question about what the hardware does.
//
// WHAT IS DELIBERATELY CONTROLLABLE
//
// `rom_ready` is an input rather than a modelled cache. kaneko_tilerom's
// header claims kaneko_tmap_fetch's `ce` "is verified to freeze the pipeline
// without losing or duplicating a pixel", and a stall that duplicates a pixel
// is EXACTLY the reported symptom. So the testbench drives it: all-hit first,
// then stalling, and any difference between those two runs localises the fault
// to the stall path rather than the arithmetic.
//
// One layer is exercised at a time. The layers are independent by construction
// -- separate x counters, separate fetch pipelines, separate buffers -- and a
// single layer makes a mismatch point at a pixel rather than at a mix.
`timescale 1ns/1ps
`default_nettype none

module kaneko_tline_harness #(
    parameter int unsigned H_VIS = 320
) (
    input  wire        clk,
    input  wire        rst,

    // ---- line control
    input  wire        start,
    input  wire [9:0]  h_active,
    input  wire [8:0]  line_y,
    output wire        busy,

    // ---- layer 0 configuration. Only layer 0 runs; see the header.
    input  wire signed [10:0] dx0,
    input  wire signed [10:0] dy0,
    input  wire [15:0] scroll_x0,
    input  wire [15:0] scroll_y0,
    input  wire        linescroll_en0,

    // ---- memories for layer 0, answered by the testbench
    output wire [8:0]  scr_addr0,
    input  wire [15:0] scr_data0,
    output wire [9:0]  vram_addr0,
    input  wire [31:0] vram_data0,     // {code, attr}
    output wire [23:0] rom_addr0,
    input  wire [7:0]  rom_data0,
    input  wire        rom_ready0,     // driven, not modelled -- see the header

    // ---- display read port
    input  wire [8:0]  rd_x,
    output wire        out_solid0,
    output wire [2:0]  out_cat0,
    output wire [5:0]  out_colour0,
    output wire [3:0]  out_pix0,

    // ---- the oracle: the combinational address engine the frame gate scores.
    // Driven independently by the testbench for the same pixel.
    input  wire [8:0]  o_screen_x,
    input  wire [8:0]  o_screen_y,
    input  wire [15:0] o_attr,
    input  wire [15:0] o_code,
    output wire [10:0] o_vram_attr_addr,
    output wire [10:0] o_vram_code_addr,
    output wire [23:0] o_rom_addr,
    output wire        o_nibble_hi,
    output wire [5:0]  o_colour,
    output wire [2:0]  o_prio,

    // ---- internals, for locating a mismatch in TIME rather than guessing.
    // Hierarchical references into the generate blocks: which buffer slot is
    // being written this cycle, and whether the pipeline produced a pixel.
    output wire        dbg_valid,
    output wire [9:0]  dbg_xwr,
    output wire [3:0]  dbg_pix
);
    wire [35:0]  scr_addr_f;
    wire [39:0]  vram_addr_f;
    wire [95:0]  rom_addr_f;
    wire [3:0]   out_solid_f;
    wire [11:0]  out_cat_f;
    wire [23:0]  out_colour_f;
    wire [15:0]  out_pix_f;

    // Layers 1..3 are held disabled. kaneko_tmap_line reports a disabled layer
    // done immediately, so `running` still clears and the line finishes.
    kaneko_tmap_line #(.H_VIS(H_VIS)) u_line (
        .clk(clk), .rst(rst),
        .start(start), .h_active(h_active), .line_y(line_y), .busy(busy),

        .layer_en(4'b0001),
        .dx_f({11'd0, 11'd0, 11'd0, dx0}),
        .dy_f({11'd0, 11'd0, 11'd0, dy0}),
        .scroll_x_f({16'd0, 16'd0, 16'd0, scroll_x0}),
        .scroll_y_f({16'd0, 16'd0, 16'd0, scroll_y0}),
        .linescroll_en({3'b000, linescroll_en0}),

        .scr_addr_f(scr_addr_f), .scr_data_f({48'd0, scr_data0}),
        .vram_addr_f(vram_addr_f), .vram_data_f({96'd0, vram_data0}),
        .rom_addr_f(rom_addr_f), .rom_data_f({24'd0, rom_data0}),
        // A disabled layer must still report ready or it would never finish;
        // layer_done covers that, but hold them high so a stall test only ever
        // stalls the layer under test.
        .rom_ready({3'b111, rom_ready0}),

        .rd_x(rd_x),
        .out_solid(out_solid_f), .out_cat_f(out_cat_f),
        .out_colour_f(out_colour_f), .out_pix_f(out_pix_f)
    );

    // Outputs cannot be driven by a concatenation containing constants, so the
    // full-width buses are declared here and layer 0 is sliced out.
    assign scr_addr0   = scr_addr_f[8:0];
    assign vram_addr0  = vram_addr_f[9:0];
    assign rom_addr0   = rom_addr_f[23:0];
    assign out_solid0  = out_solid_f[0];
    assign out_cat0    = out_cat_f[2:0];
    assign out_colour0 = out_colour_f[5:0];
    assign out_pix0    = out_pix_f[3:0];

    assign dbg_valid = u_line.l_valid[0];
    assign dbg_xwr   = u_line.x_wr[0];
    assign dbg_pix   = u_line.l_pix[3:0];

    kaneko_tmap_layer u_ref (
        .screen_x(o_screen_x), .screen_y(o_screen_y),
        .dx(dx0), .dy(dy0),
        .scroll_x(scroll_x0), .scroll_y(scroll_y0),
        .linescroll(scr_data0), .linescroll_en(linescroll_en0),
        .attr(o_attr), .code(o_code),
        .map_x(), .map_y(),
        .vram_attr_addr(o_vram_attr_addr), .vram_code_addr(o_vram_code_addr),
        .rom_addr(o_rom_addr), .nibble_hi(o_nibble_hi),
        .colour(o_colour), .prio(o_prio)
    );

endmodule

`default_nettype wire
