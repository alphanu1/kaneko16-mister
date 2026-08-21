// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The memories the CPU writes and the video path reads.
//
// All four are simple dual-port: the CPU side writes (and reads back), the
// video side reads. That is what an M10K gives natively, and it is why these
// live together rather than being scattered through the video modules — the
// CPU must reach every one of them through a single bus, and the video side
// must read them without contending for that bus.
//
//   VIEW2 window   0x4000 bytes each: vram_1 at 0x0000, vram_0 at 0x1000,
//                  scroll_1 at 0x2000, scroll_0 at 0x3000 (kaneko_tmap.cpp
//                  vram_map). Note the reversal — the FIRST block is layer 1.
//
//                  Split into six arrays per chip rather than one 8K x 16
//                  block, because of what the video side has to read at once.
//                  A tile entry is two adjacent words, attr then code
//                  (kaneko_tmap.cpp:126), and kaneko_tmap_fetch wants both in
//                  a single 32-bit read; and each layer needs its own scroll
//                  word in the same cycle. Six independent arrays give four
//                  simultaneous reads per chip. The storage is identical —
//                  8192 words either way — because the split is by address,
//                  not by duplication.
//   sprite RAM     0x2000 bytes, 4K x 16
//   palette        0x1000 bytes, 2K x 16, xGRB_555

`timescale 1ns/1ps
`default_nettype none

module kaneko_vmem (
    input  wire        clk,

    // ---- CPU side
    input  wire [12:0] cpu_addr,       // word address within the selected space
    input  wire [15:0] cpu_din,
    input  wire        we_vram0, we_vram1, we_spr, we_pal,
    input  wire        uds, lds,       // byte enables, active high
    output wire  [15:0] q_vram0, q_vram1, q_spr, q_pal,

    // ---- video side, read only.
    // Per chip: a tile entry per layer as {code, attr}, and a scroll word per
    // layer. Chip 0 is the 0x500000 window, chip 1 the 0x580000 one.
    input  wire [9:0]  c0_t0_addr,
    output wire [31:0] c0_t0_q,
    input  wire [9:0]  c0_t1_addr,
    output wire [31:0] c0_t1_q,
    input  wire [10:0] c0_s0_addr,
    output wire [15:0] c0_s0_q,
    input  wire [10:0] c0_s1_addr,
    output wire [15:0] c0_s1_q,

    input  wire [9:0]  c1_t0_addr,
    output wire [31:0] c1_t0_q,
    input  wire [9:0]  c1_t1_addr,
    output wire [31:0] c1_t1_q,
    input  wire [10:0] c1_s0_addr,
    output wire [15:0] c1_s0_q,
    input  wire [10:0] c1_s1_addr,
    output wire [15:0] c1_s1_q,
    input  wire [11:0] spr_addr,
    output wire  [15:0] spr_q,
    input  wire [10:0] pal_addr,
    output wire  [15:0] pal_q
);
    // Each memory is TWO BYTE-WIDE ARRAYS, not one 16-bit array written by
    // bit-slice. Quartus does not infer a byte-enabled memory from
    // `mem[addr][15:8] <= ...`; it infers no memory at all and builds registers
    // instead. See the note in kaneko_bus.sv — that mistake produced 438,004
    // combinational nodes against a device holding 83,820.
    //
    // Byte enables are needed because the 68000 writes single bytes, and the
    // very first store the boot code makes is `move.b #$00, $900009`.

    localparam int S_N = 4096, P_N = 2048;

    // ------------------------------------------------------- VIEW2 windows
    //
    // Per chip and per layer: 1024 tile entries, held as separate attr and
    // code arrays so both come back in one cycle. Plus 2048 scroll words per
    // layer — only the first 512 are used for scrolling
    // (set_scroll_rows(0x200)), but the rest is real RAM the game may use, so
    // all of it is stored.
    //
    // Each array is still TWO BYTE-WIDE halves, not one 16-bit array written
    // by bit-slice. Quartus does not infer a byte-enabled memory from
    // `mem[addr][15:8] <= ...`; it infers no memory at all and builds
    // registers instead — 438,004 combinational nodes against a device holding
    // 83,820. See kaneko_bus.sv.
    //
    // The 68000 writes single bytes, so the byte enables are not optional
    // either: `move.b #$00, $900009` is the first store the boot code makes.

    // Window decode. ca[12:11] selects the quarter, and within a tile block
    // ca[0] picks attr (the even word) or code (the odd one).
    wire [12:0] ca      = cpu_addr;
    wire        is_v1   = (ca[12:11] == 2'b00);   // vram_1   at 0x0000
    wire        is_v0   = (ca[12:11] == 2'b01);   // vram_0   at 0x1000
    wire        is_s1   = (ca[12:11] == 2'b10);   // scroll_1 at 0x2000
    wire        is_s0   = (ca[12:11] == 2'b11);   // scroll_0 at 0x3000
    wire [9:0]  t_idx   = ca[10:1];
    wire [10:0] s_idx   = ca[10:0];
    wire        is_code = ca[0];

    // INFERENCE IS FUSSIER THAN IT LOOKS
    //
    // The first attempt at this split declared the arrays as
    // `logic [7:0] ta_hi [0:1][0:1][0:1023]` and read them inside the mux that
    // picks the CPU's quarter:
    //
    //     qch <= is_v1 ? tc_hi[gc][1][t_idx] : is_v0 ? ... ;
    //
    // Quartus inferred no memory at all from that and built 137,160
    // combinational nodes against a device holding 83,820 — the same failure
    // the bit-slice writes produced, with the same misleading shape, a design
    // that looks far too big when it is one inference that did not happen.
    //
    // Two rules, both of which that version broke:
    //   * one array per memory, declared inside the generate so it is plain
    //     and one-dimensional, not an array of arrays indexed three deep;
    //   * the read is UNCONDITIONAL, straight into its own register. Muxing
    //     four arrays inside the read makes the address and enable conditional
    //     and there is no simple-dual-port left to infer. Mux the registered
    //     outputs afterwards instead, which costs a 4:1 mux of 16 bits.

    logic [15:0] cpu_rq [0:1];
    logic [1:0]  rd_quarter [0:1];      // registered decode, for the mux below

    wire [1:0] v_we = {we_vram1, we_vram0};

    genvar gc, gl;
    generate
        for (gc = 0; gc < 2; gc = gc + 1) begin : g_chip
            for (gl = 0; gl < 2; gl = gl + 1) begin : g_layer
                // 1024 tile entries per layer, attr and code held apart so a
                // whole entry comes back in one cycle.
                logic [7:0] ta_hi [0:1023], ta_lo [0:1023];
                logic [7:0] tc_hi [0:1023], tc_lo [0:1023];
                // 2048 scroll words. Only the first 512 scroll
                // (set_scroll_rows(0x200)); the rest is RAM the game may use.
                logic [7:0] sc_hi [0:2047], sc_lo [0:2047];

                // Which quarter of this chip's window belongs to this layer.
                // Layer 1 is the FIRST block — see the header.
                wire tile_sel = v_we[gc] && (gl ? is_v1 : is_v0);
                wire scr_sel  = v_we[gc] && (gl ? is_s1 : is_s0);

                wire [9:0]  vr_t = (gc == 0) ? (gl ? c0_t1_addr : c0_t0_addr)
                                             : (gl ? c1_t1_addr : c1_t0_addr);
                wire [10:0] vr_s = (gc == 0) ? (gl ? c0_s1_addr : c0_s0_addr)
                                             : (gl ? c1_s1_addr : c1_s0_addr);

                logic [7:0] ca_h, ca_l, cc_h, cc_l, cs_h, cs_l;   // CPU side
                logic [7:0] va_h, va_l, vc_h, vc_l, vs_h, vs_l;   // video side

                always_ff @(posedge clk) begin
                    if (tile_sel && !is_code && uds) ta_hi[t_idx] <= cpu_din[15:8];
                    if (tile_sel && !is_code && lds) ta_lo[t_idx] <= cpu_din[7:0];
                    if (tile_sel &&  is_code && uds) tc_hi[t_idx] <= cpu_din[15:8];
                    if (tile_sel &&  is_code && lds) tc_lo[t_idx] <= cpu_din[7:0];
                    if (scr_sel && uds) sc_hi[s_idx] <= cpu_din[15:8];
                    if (scr_sel && lds) sc_lo[s_idx] <= cpu_din[7:0];

                    // Unconditional reads, each into its own register.
                    ca_h <= ta_hi[t_idx];  ca_l <= ta_lo[t_idx];
                    cc_h <= tc_hi[t_idx];  cc_l <= tc_lo[t_idx];
                    cs_h <= sc_hi[s_idx];  cs_l <= sc_lo[s_idx];

                    va_h <= ta_hi[vr_t];   va_l <= ta_lo[vr_t];
                    vc_h <= tc_hi[vr_t];   vc_l <= tc_lo[vr_t];
                    vs_h <= sc_hi[vr_s];   vs_l <= sc_lo[vr_s];
                end

                wire [31:0] tile_q = {vc_h, vc_l, va_h, va_l};
                wire [15:0] scr_q  = {vs_h, vs_l};
            end

            // CPU read-back: mux the registered outputs, never the arrays.
            always_ff @(posedge clk)
                rd_quarter[gc] <= ca[12:11];

            always_comb begin
                case (rd_quarter[gc])
                    2'b00: cpu_rq[gc] = is_code_r ? {g_layer[1].cc_h, g_layer[1].cc_l}
                                                  : {g_layer[1].ca_h, g_layer[1].ca_l};
                    2'b01: cpu_rq[gc] = is_code_r ? {g_layer[0].cc_h, g_layer[0].cc_l}
                                                  : {g_layer[0].ca_h, g_layer[0].ca_l};
                    2'b10: cpu_rq[gc] = {g_layer[1].cs_h, g_layer[1].cs_l};
                    default: cpu_rq[gc] = {g_layer[0].cs_h, g_layer[0].cs_l};
                endcase
            end
        end
    endgenerate

    // The attr/code choice must be delayed alongside the data it selects.
    logic is_code_r;
    always_ff @(posedge clk) is_code_r <= is_code;

    // ------------------------------------------------ sprite RAM, palette
    logic [7:0] sp_hi [0:S_N-1], sp_lo [0:S_N-1];
    logic [7:0] pa_hi [0:P_N-1], pa_lo [0:P_N-1];
    logic [7:0] qsh, qsl, qph, qpl;
    logic [7:0] rsh, rsl, rph, rpl;

    always_ff @(posedge clk) begin
        if (we_spr && uds) sp_hi[ca[11:0]] <= cpu_din[15:8];
        if (we_spr && lds) sp_lo[ca[11:0]] <= cpu_din[7:0];
        if (we_pal && uds) pa_hi[ca[10:0]] <= cpu_din[15:8];
        if (we_pal && lds) pa_lo[ca[10:0]] <= cpu_din[7:0];

        qsh <= sp_hi[ca[11:0]];  qsl <= sp_lo[ca[11:0]];
        qph <= pa_hi[ca[10:0]];  qpl <= pa_lo[ca[10:0]];

        rsh <= sp_hi[spr_addr];  rsl <= sp_lo[spr_addr];
        rph <= pa_hi[pal_addr];  rpl <= pa_lo[pal_addr];
    end

    assign q_vram0 = cpu_rq[0];
    assign q_vram1 = cpu_rq[1];
    assign q_spr   = {qsh, qsl};
    assign q_pal   = {qph, qpl};
    assign spr_q   = {rsh, rsl};
    assign pal_q   = {rph, rpl};

    // {code, attr} — the order kaneko_tmap_fetch expects.
    assign c0_t0_q = g_chip[0].g_layer[0].tile_q;
    assign c0_t1_q = g_chip[0].g_layer[1].tile_q;
    assign c1_t0_q = g_chip[1].g_layer[0].tile_q;
    assign c1_t1_q = g_chip[1].g_layer[1].tile_q;

    assign c0_s0_q = g_chip[0].g_layer[0].scr_q;
    assign c0_s1_q = g_chip[0].g_layer[1].scr_q;
    assign c1_s0_q = g_chip[1].g_layer[0].scr_q;
    assign c1_s1_q = g_chip[1].g_layer[1].scr_q;

endmodule

`default_nettype wire
