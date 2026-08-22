// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The Blaze On board's Z80 program ROM, as a small direct-mapped cache over
// SDRAM.
//
// WHY THIS IS NOT A COPY IN BLOCK RAM ANY MORE
//
// It was, and it did not fit. 48 KB of block RAM is 48 of the device's 553
// M10K blocks, and the budget has no room for them:
//
//   sprites 265   vmem ~76   68000 work RAM 67   Z80 ROM 48   ascal 41
//
// Taking those 48 did not merely overflow by 48. kaneko_vmem's sprite and
// palette RAM are ONE WRITE, TWO READS -- the 68000 on one address and the
// sprite engine on another -- which an M10K cannot be, so Quartus duplicates
// them into two blocks each. It does that silently, and only while blocks are
// spare. Take the spare away and it builds registers instead: 98,304 bits fell
// into logic and the fitter asked for 6,673 LABs against the device's 4,191.
// The ALM cost of these 48 blocks was a CLIFF, not a slope, which is why the
// design looked comfortable right up until it was 157% over.
//
// WHY A CACHE IS ENOUGH HERE, WHEN IT WOULD NOT BE FOR THE TILE FETCHERS
//
// The Z80 runs at 4 MHz against a 48 MHz memory clock: twelve clk cycles per
// Z80 cycle, and roughly four Z80 cycles per opcode fetch. An SDRAM round trip
// is around twenty clk cycles, so a miss costs well under two Z80 cycles. With
// eight bytes per line, sequential code misses once every eight fetches, which
// is a few percent. The 68000 already reaches its code this way through
// kaneko_bus's line cache; this is the same bargain on a CPU with far more
// slack.
//
// The cache is deliberately TINY -- 32 lines of 8 bytes, 2,048 bits -- and
// lives in registers, not block RAM. Making it larger would buy almost
// nothing: sequential fetching misses once per line whatever the capacity, and
// the point of the exercise was to stop spending M10K.
//
// STALLING IS DONE WITH THE CLOCK ENABLE, NOT WAIT_n
//
// T80s takes a CEN, and holding it low is unambiguous: the CPU does not
// advance, its bus signals hold, the line arrives, and it resumes. Driving
// WAIT_n correctly alongside CEN and IOWait is a second timing contract to get
// right for no benefit.
//
// SIZE
//
// 0x0000-0xBFFF is ROM on this board; MAME maps 0x8000-0xBFFF straight through
// with a note wondering whether it is supposed to be banked. Nothing is known
// to bank it, so the whole 48 KB window is cacheable and the region above is
// left to the decode in kaneko_z80snd.
`timescale 1ns/1ps
`default_nettype none

module kaneko_z80rom #(
    parameter int SDR_AW = 25,
    parameter int LINES  = 32                // 8 bytes each -> 256 B
) (
    input  wire                clk,
    input  wire                rst,

    // Word address of the audiocpu region, from the game table.
    input  wire [SDR_AW-1:0]   base,

    // ---- Z80 side. `rom_rd` is asserted while the CPU is reading ROM;
    // `rom_ready` low means the answer is not here yet and the caller must
    // hold the CPU's clock enable.
    input  wire [15:0]         rom_addr,
    input  wire                rom_rd,
    output wire [7:0]          rom_data,
    output wire                rom_ready,

    // ---- SDRAM read port. Burst of four words, burst-aligned.
    output logic               p_req,
    output logic [SDR_AW:1]    p_addr,
    input  wire                p_ack,
    input  wire [63:0]         p_dout
);
    localparam int IXW = $clog2(LINES);
    localparam int TW  = 16 - 3 - IXW;       // byte addr = tag : index : 3

    wire [IXW-1:0] ix = rom_addr[3+IXW-1 -: IXW];
    wire [TW-1:0]  tg = rom_addr[15 -: TW];

    logic [63:0]      cdata [0:LINES-1];
    logic [TW-1:0]    ctag  [0:LINES-1];
    logic [LINES-1:0] cval;

    wire        hit  = cval[ix] && (ctag[ix] == tg);
    wire [63:0] line = cdata[ix];

    // Byte k of the burst is dout[8*k +: 8] with no swap -- the convention
    // kaneko_tilerom states and kaneko_bus's word unpack follows. The Z80 is
    // little-endian and the region is stored as raw bytes, so there is nothing
    // to undo here; the 68000's swap is a property of the 68000, not of SDRAM.
    assign rom_data  = line[{rom_addr[2:0], 3'd0} +: 8];
    assign rom_ready = hit;

    // Byte address of the line is {rom_addr[15:3], 3'b000}, so its WORD offset
    // is {rom_addr[15:3], 2'b00} -- already four-word aligned, which the
    // controller requires of a burst port. base is aligned by construction.
    wire [SDR_AW-1:0] line_woff = {{(SDR_AW-15){1'b0}}, rom_addr[15:3], 2'b00};

    logic [IXW-1:0] fill_ix;
    logic [TW-1:0]  fill_tag;

    always_ff @(posedge clk) begin
        if (rst) begin
            cval  <= '0;
            p_req <= 1'b0;
        end else if (!p_req) begin
            // A miss is only acted on while the CPU is actually asking. The
            // address bus is stable for the whole of a held Z80 cycle, so the
            // tag captured here cannot move underneath the fill.
            if (rom_rd && !hit) begin
                p_req    <= 1'b1;
                p_addr   <= (base + line_woff);
                fill_ix  <= ix;
                fill_tag <= tg;
            end
        end else if (p_ack) begin
            p_req          <= 1'b0;
            cdata[fill_ix] <= p_dout;
            ctag [fill_ix] <= fill_tag;
            cval [fill_ix] <= 1'b1;
        end
    end

endmodule

`default_nettype wire
