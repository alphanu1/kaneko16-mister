// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// One scanline of all four tile layers, fetched ahead into a line buffer.
//
// WHY A LINE BUFFER AND NOT A PIXEL-RATE PIPELINE
//
// kaneko_tmap_fetch produces one pixel per enabled clock and stalls whenever
// the tile ROM misses. The display wants one pixel every eight clocks, exactly
// on time. Those two cannot be the same clock enable: a burst of misses inside
// one pixel slot would push the picture sideways.
//
// So the fetch runs flat out for the NEXT line while the current one is being
// displayed, and the display reads a buffer. The budget, at 384 pixel times of
// 8 clocks each:
//
//     clocks per line          3072
//     pipeline, 1 px/clk        256
//     misses, 4 layers          128 x ~12 clk = 1536
//     total                    1792   (58% of the line)
//
// which leaves room for the CPU and, later, the sprite fetches.
//
// Double-buffered: the fetch writes one bank while the display reads the other,
// and they swap at the start of each line. A single buffer would tear.
`timescale 1ns/1ps
`default_nettype none

module kaneko_tmap_line #(
    parameter int unsigned H_VIS = 256
) (
    input  wire        clk,
    input  wire        rst,

    // Pulse at the start of a line to fetch `line_y` into the spare bank.
    input  wire        start,
    input  wire [8:0]  line_y,
    output wire        busy,

    // Per-layer configuration, in mixer order: chip0 L0, chip0 L1, chip1 L0,
    // chip1 L1. Flattened because a packed array of signed values does not
    // survive a Verilator top-level boundary cleanly.
    input  wire [3:0]  layer_en,
    input  wire [43:0] dx_f,           // 4 x signed 11
    input  wire [43:0] dy_f,
    input  wire [63:0] scroll_x_f,     // 4 x 16
    input  wire [63:0] scroll_y_f,
    input  wire [3:0]  linescroll_en,

    // Memories, one port per layer.
    output wire [35:0] scr_addr_f,     // 4 x 9
    input  wire [63:0] scr_data_f,     // 4 x 16
    output wire [39:0] vram_addr_f,    // 4 x 10
    input  wire [127:0] vram_data_f,   // 4 x 32
    output wire [95:0] rom_addr_f,     // 4 x 24
    input  wire [31:0] rom_data_f,     // 4 x 8
    input  wire        rom_ready,      // kaneko_tilerom: all ports hit

    // Display read port. Combinational address, data one clock later.
    input  wire [8:0]  rd_x,
    output wire [3:0]  out_solid,
    output wire [11:0] out_cat_f,      // 4 x 3
    output wire [23:0] out_colour_f,   // 4 x 6
    output wire [15:0] out_pix_f       // 4 x 4
);

    localparam int unsigned LAT = 4;   // kaneko_tmap_fetch pipeline depth

    // Which bank the fetch writes. The display reads the other one.
    logic bank;

    logic [9:0] x_req;                 // pixel being requested
    logic [9:0] x_wr;                  // pixel being written back
    logic       running;

    assign busy = running;

    wire ce = rom_ready;               // a miss stalls every layer together

    always_ff @(posedge clk) begin
        if (rst) begin
            bank <= 1'b0; x_req <= '0; x_wr <= '0; running <= 1'b0;
        end else if (start) begin
            bank    <= ~bank;
            x_req   <= '0;
            x_wr    <= '0;
            running <= 1'b1;
        end else if (running && ce) begin
            if (x_req < 10'(H_VIS + LAT)) x_req <= x_req + 10'd1;
            else                          running <= 1'b0;
            if (wr_en) x_wr <= x_wr + 10'd1;
        end
    end

    wire req_valid = running && (x_req < 10'(H_VIS));

    // ------------------------------------------------------------ layers
    wire [3:0]  l_valid;
    wire [3:0]  l_solid;
    wire [15:0] l_pix;                 // 4 x 4
    wire [23:0] l_colour;              // 4 x 6
    wire [11:0] l_cat;                 // 4 x 3

    genvar g;
    generate
        for (g = 0; g < 4; g = g + 1) begin : g_layer
            kaneko_tmap_fetch u_fetch (
                .clk(clk), .rst(rst), .ce(ce),
                .req_valid(req_valid),
                .screen_x(x_req[8:0]),
                .screen_y(line_y),

                .dx($signed(dx_f[g*11 +: 11])),
                .dy($signed(dy_f[g*11 +: 11])),
                .scroll_x(scroll_x_f[g*16 +: 16]),
                .scroll_y(scroll_y_f[g*16 +: 16]),
                .linescroll_en(linescroll_en[g]),
                .layer_enable(layer_en[g]),

                .scr_addr(scr_addr_f[g*9 +: 9]),
                .scr_data(scr_data_f[g*16 +: 16]),
                .vram_addr(vram_addr_f[g*10 +: 10]),
                .vram_data(vram_data_f[g*32 +: 32]),
                .rom_addr(rom_addr_f[g*24 +: 24]),
                .rom_data(rom_data_f[g*8 +: 8]),

                .pix_valid(l_valid[g]),
                .pix(l_pix[g*4 +: 4]),
                .colour(l_colour[g*6 +: 6]),
                .cat(l_cat[g*3 +: 3]),
                .solid(l_solid[g])
            );
        end
    endgenerate

    // All four run in lockstep on the same ce and req_valid, so their valids
    // should always agree. ANDing rather than taking layer 0's stalls instead
    // of writing three good pixels and one stale one if they ever do not.
    wire wr_en = &l_valid;

    // ------------------------------------------------------- line buffer
    // 4 layers x (4-bit pixel + 6-bit colour + 3-bit category + solid) = 56
    // bits per pixel, two banks.
    localparam int unsigned W = 56;
    logic [W-1:0] lbuf [0:1][0:H_VIS-1];

    wire [W-1:0] wr_data = {l_solid, l_cat, l_colour, l_pix};

    // Out of range reads entry 0 rather than aliasing back into the line: the
    // display should never ask, and if it does the fault should look like a
    // stuck column rather than a plausible repeat of the left edge.
    localparam int unsigned XW = $clog2(H_VIS);
    wire [XW-1:0] rd_i = (rd_x >= 9'(H_VIS)) ? '0 : rd_x[XW-1:0];

    logic [W-1:0] rd_q;
    always_ff @(posedge clk) begin
        // Gated by ce as well as pix_valid, so the write and the x_wr
        // increment are driven by the same condition. kaneko_tmap_fetch holds
        // its outputs while ce is low and pix_valid stays asserted through a
        // stall, so writing on pix_valid alone would rewrite a slot repeatedly
        // — harmless while x_wr is also held, and a trap the moment either
        // gate changes.
        if (ce && wr_en && running && x_wr < 10'(H_VIS))
            lbuf[bank][x_wr[XW-1:0]] <= wr_data;
        rd_q <= lbuf[~bank][rd_i];
    end

    assign out_pix_f    = rd_q[15:0];
    assign out_colour_f = rd_q[39:16];
    assign out_cat_f    = rd_q[51:40];
    assign out_solid    = rd_q[55:52];

endmodule

`default_nettype wire
