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
//                  scroll_1 at 0x2000, scroll_0 at 0x3000. One 8K x 16 block
//                  per chip holds the whole window, so the CPU's window
//                  address IS the memory address and no decode is needed here.
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

    // ---- video side, read only
    input  wire [12:0] v0_addr,
    output wire  [15:0] v0_q,
    input  wire [12:0] v1_addr,
    output wire  [15:0] v1_q,
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

    localparam int V_N = 8192, S_N = 4096, P_N = 2048;

    logic [7:0] v0_hi [0:V_N-1], v0_lo [0:V_N-1];
    logic [7:0] v1_hi [0:V_N-1], v1_lo [0:V_N-1];
    logic [7:0] sp_hi [0:S_N-1], sp_lo [0:S_N-1];
    logic [7:0] pa_hi [0:P_N-1], pa_lo [0:P_N-1];

    logic [7:0] q0h, q0l, q1h, q1l, qsh, qsl, qph, qpl;
    logic [7:0] r0h, r0l, r1h, r1l, rsh, rsl, rph, rpl;

    wire [12:0] ca = cpu_addr;

    always_ff @(posedge clk) begin
        if (we_vram0 && uds) v0_hi[ca] <= cpu_din[15:8];
        if (we_vram0 && lds) v0_lo[ca] <= cpu_din[7:0];
        if (we_vram1 && uds) v1_hi[ca] <= cpu_din[15:8];
        if (we_vram1 && lds) v1_lo[ca] <= cpu_din[7:0];
        if (we_spr   && uds) sp_hi[ca[11:0]] <= cpu_din[15:8];
        if (we_spr   && lds) sp_lo[ca[11:0]] <= cpu_din[7:0];
        if (we_pal   && uds) pa_hi[ca[10:0]] <= cpu_din[15:8];
        if (we_pal   && lds) pa_lo[ca[10:0]] <= cpu_din[7:0];

        // CPU read-back port
        q0h <= v0_hi[ca];        q0l <= v0_lo[ca];
        q1h <= v1_hi[ca];        q1l <= v1_lo[ca];
        qsh <= sp_hi[ca[11:0]];  qsl <= sp_lo[ca[11:0]];
        qph <= pa_hi[ca[10:0]];  qpl <= pa_lo[ca[10:0]];

        // Video read port. A second read of the same array is what makes each
        // of these a duplicated M10K rather than a true-dual-port; that is the
        // cheap way round the 1W+2R shape and costs block RAM, not logic.
        r0h <= v0_hi[v0_addr];   r0l <= v0_lo[v0_addr];
        r1h <= v1_hi[v1_addr];   r1l <= v1_lo[v1_addr];
        rsh <= sp_hi[spr_addr];  rsl <= sp_lo[spr_addr];
        rph <= pa_hi[pal_addr];  rpl <= pa_lo[pal_addr];
    end

    assign q_vram0 = {q0h, q0l};
    assign q_vram1 = {q1h, q1l};
    assign q_spr   = {qsh, qsl};
    assign q_pal   = {qph, qpl};
    assign v0_q    = {r0h, r0l};
    assign v1_q    = {r1h, r1l};
    assign spr_q   = {rsh, rsl};
    assign pal_q   = {rph, rpl};

endmodule

`default_nettype wire
