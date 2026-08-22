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
    // The BUFFER is sized for the widest screen in the driver; how much of it
    // a line actually uses is a runtime width, because fetching 320 pixels for
    // a 256-wide game would cost 25% more tile ROM traffic for nothing — and
    // the tile feeder is the part with the least headroom.
    parameter int unsigned H_VIS = 320
) (
    input  wire        clk,
    input  wire        rst,

    // Pulse at the start of a line to fetch `line_y` into the spare bank.
    input  wire        start,
    input  wire [9:0]  h_active,     // visible width of the CURRENT game
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
    input  wire [3:0]  rom_ready,      // kaneko_tilerom: per-port hit

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
    logic running;

    assign busy = running;

    // EACH LAYER ADVANCES ON ITS OWN
    //
    // A single `ce = &hit` made every layer wait for the slowest, so their
    // stalls SUMMED: about seventeen misses per layer became sixty-eight
    // serialised waits per line, and the fetch ran out of time whenever the
    // screen got busy. The four layers are independent — different scroll, so
    // they cross tile boundaries at different x — and nothing about the line
    // buffer requires them to be in step, because each writes its own slice.
    //
    // Per-layer enables make the misses overlap instead, so a line costs the
    // WORST layer rather than the sum of all four.
    logic [9:0] x_req [0:3];
    logic [9:0] x_wr  [0:3];
    wire  [3:0] ce = rom_ready;
    wire  [3:0] req_valid;
    wire  [3:0] layer_done;

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_seq
            assign req_valid[gi]  = running && (x_req[gi] < h_active);
            assign layer_done[gi] = (x_wr[gi] >= h_active);

            always_ff @(posedge clk) begin
                if (rst || start) begin
                    x_req[gi] <= '0;
                    x_wr[gi]  <= '0;
                end else if (ce[gi]) begin
                    if (x_req[gi] < (h_active + 10'(LAT))) x_req[gi] <= x_req[gi] + 10'd1;
                    if (l_valid[gi] && !layer_done[gi]) x_wr[gi] <= x_wr[gi] + 10'd1;
                end
            end
        end
    endgenerate

    // The line is finished when every layer has written its 256 pixels.
    always_ff @(posedge clk) begin
        if (rst)          begin bank <= 1'b0; running <= 1'b0; end
        else if (start)   begin bank <= ~bank; running <= 1'b1; end
        else if (&layer_done) running <= 1'b0;
    end

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
                .clk(clk), .rst(rst),
                .ce(ce[g]),
                .req_valid(req_valid[g]),
                .screen_x(x_req[g][8:0]),
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

    // ------------------------------------------------------- line buffer
    // One buffer PER LAYER, 14 bits each: 4-bit pixel, 6-bit colour, 3-bit
    // category, solid. Split per layer rather than one 56-bit word because the
    // layers no longer advance together — each writes its own slice at its own
    // x, and a shared word would need all four before it could be stored.
    localparam int unsigned W  = 14;
    localparam int unsigned XW = $clog2(H_VIS);

    // Out of range reads entry 0 rather than aliasing back into the line: the
    // display should never ask, and if it does the fault should look like a
    // stuck column rather than a plausible repeat of the left edge.
    wire [XW-1:0] rd_i = (rd_x >= 9'(H_VIS)) ? '0 : rd_x[XW-1:0];

    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_buf
            // TWO PLAIN ARRAYS, ONE PER BANK, PLAIN ADDRESSES
            //
            // This memory has been through three shapes before inferring:
            //
            //   lbuf [0:1][0:H_VIS-1]        "cannot regroup multidimensional
            //                                array into its bus" — flip-flops
            //   lbuf [0:2*H_VIS-1] with
            //     lbuf[{bank, x_wr}]         no warning at all, still
            //                                flip-flops: 14,014 ALMs in this
            //                                module alone
            //   lb0/lb1, plain addresses     inferred
            //
            // The rule that comes out of it is narrower than the one already
            // recorded for kaneko_vmem: not merely "one-dimensional", but a
            // plain array with a plain address signal. A concatenation in the
            // index is enough to lose it, and Quartus says nothing — the only
            // symptom is the ALM count and a block-memory total that falls by
            // exactly the size of the memory that vanished.
            logic [W-1:0] lb0 [0:H_VIS-1];
            logic [W-1:0] lb1 [0:H_VIS-1];
            logic [W-1:0] q0, q1;

            wire [XW-1:0] wa = x_wr[gi][XW-1:0];
            wire          we = ce[gi] && l_valid[gi] && running && !layer_done[gi];

            wire [W-1:0] wr_data = {l_solid[gi], l_cat[gi*3 +: 3],
                                    l_colour[gi*6 +: 6], l_pix[gi*4 +: 4]};

            always_ff @(posedge clk) begin
                if (we && !bank) lb0[wa] <= wr_data;
                if (we &&  bank) lb1[wa] <= wr_data;
                q0 <= lb0[rd_i];
                q1 <= lb1[rd_i];
            end

            // The display reads the bank the fetch is NOT writing.
            wire [W-1:0] rq = bank ? q0 : q1;

            assign out_pix_f[gi*4 +: 4]    = rq[3:0];
            assign out_colour_f[gi*6 +: 6] = rq[9:4];
            assign out_cat_f[gi*3 +: 3]    = rq[12:10];
            assign out_solid[gi]           = rq[13];
        end
    endgenerate

endmodule

`default_nettype wire
