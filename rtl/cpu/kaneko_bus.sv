// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// 68000 bus: address decode, work RAM, and DTACK generation.
//
// Decode is transcribed from bakubrkr_map (kaneko16.cpp:314), which explbrkr
// and Explosive Breaker's siblings use. It is NOT shared with mgcrystl — that
// game puts the palette at 0x500000 and the VIEW2 windows at 0x600000/0x680000,
// where this map has VIEW2 at 0x500000/0x580000 and the palette at 0x700000.
// Hard rule 9: the map is per game and lives in a table, never assumed.
//
//   000000-07ffff  ROM            in SDRAM
//   100000-10ffff  work RAM       64 KB on chip
//   400000-40001f  YM2149 #0
//   400200-40021f  YM2149 #1
//   400401         OKI M6295
//   500000-503fff  VIEW2[0] window (VRAM + line scroll)
//   580000-583fff  VIEW2[1] window
//   600000-601fff  sprite RAM
//   700000-700fff  palette
//   800000-80001f  VIEW2[0] registers
//   900000-90001f  sprite registers
//   a80000         watchdog (read)
//   b00000-b0001f  VIEW2[1] registers
//   d00000/d00001  coin lockout / EEPROM
//   e00000-e00007  inputs
//
// DTACK. The 68000 stretches a bus cycle until DTACKn asserts, so every decoded
// region must answer and every UNdecoded address must answer too — a 68000 that
// addresses nothing simply hangs, with no error and nothing to see. So the
// default case acknowledges rather than ignoring, and asserts a flag the
// harness can watch instead.
//
// ROM reads come from SDRAM and take longer than the real board's ROM did, so
// the CPU runs with more wait states here than on hardware. That is a timing
// difference, not a behavioural one — the 68000 cannot tell — but it means
// cycle counts from this core are not the PCB's. A ROM cache is the fix when
// that starts to matter.

`timescale 1ns/1ps
`default_nettype none

module kaneko_bus #(
    parameter int unsigned SDR_AW   = 25,
    parameter logic [24:0] ROM_BASE = 25'd0,  // word address of ROM in SDRAM

    // Four-word lines of ROM cache, direct-mapped. Power of two, at least 2.
    // Sized by measurement — see the hit-rate table in docs/findings.md.
    parameter int unsigned ROM_LINES = 16
)(
    input  wire        clk,
    input  wire        rst,

    // ---- 68000 side (fx68k)
    input  wire [23:1] eab,
    input  wire        ASn,
    input  wire        LDSn,
    input  wire        UDSn,
    input  wire        eRWn,          // 1 = read
    input  wire [15:0] oEdb,          // CPU -> bus
    output logic [15:0] iEdb,         // bus -> CPU
    output logic       DTACKn,

    // FC = 7. The 68000 drives it for an interrupt acknowledge, and this bus
    // must stay out of that cycle entirely: kaneko_irq answers it with VPA so
    // the CPU autovectors. Decoding it here instead would find nothing mapped
    // at fffffx, assert DTACK anyway (see the note in S_IDLE), and the CPU
    // would take a VECTORED interrupt through whatever the read mux happened to
    // be driving — a jump to a garbage address, one frame after the game
    // finally enables interrupts.
    input  wire        cpu_space,

    // ---- SDRAM read port for ROM
    output logic            rom_req,
    output logic [SDR_AW:1] rom_addr,
    input  wire             rom_ack,
    // [63:16] are the other three words of the burst. Discarded for now; see
    // the note in S_ROM about caching them.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire  [63:0]     rom_dout,
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- video-side memories, written by the CPU
    output logic        vram0_we, vram1_we, spr_we, pal_we,
    // A VIEW2 READ, which now claims a shared port. kaneko_vmem's tile and
    // scroll arrays have one read port between the CPU and the tile fetch, so
    // the CPU has to ask for the cycle. Raised for the access cycle of a read
    // from either VIEW2 window and low otherwise -- the games read these about
    // 1.4 times a frame, so the fetch is almost never stalled.
    output logic        vram_rd,
    output logic [12:0] vmem_addr,     // word address within the selected window
    output logic [15:0] vmem_din,
    input  wire  [15:0] vram0_q, vram1_q, spr_q, pal_q,

    // ---- register banks
    // YM2149s. Each register sits at its own address (kaneko16.cpp ym2149_r:
    // address_w(offset) then data_r()), so ym_addr is just a[4:1]. A register
    // reads back as a byte.
    output logic        ym0_we, ym1_we,
    output wire  [3:0]  ym_addr,
    output wire  [7:0]  ym_din,
    input  wire  [7:0]  ym0_q,
    input  wire  [7:0]  ym1_q,

    // d00001, the byte eeprom_w writes: bit 0 clk, bit 1 di. The chip select is
    // not here — it is YM2149 #1 port B. See kaneko_eeprom93c46.sv.
    output logic        eeprom_we,
    output wire  [7:0]  eeprom_din,

    // OKI M6295 at 400401 — an 8-bit device on the ODD byte of a 16-bit word,
    // so the write is qualified by LDS and never by UDS.
    output logic        oki_we,
    // Second OKI and the shared sample-bank write, CALC3 board only.
    output logic        oki2_we,
    output logic        okibk_we,
    // Hit calculator and MCU RAM, CALC3 board only.
    output logic        hit_we,
    output wire  [5:0]  hit_addr,
    output logic        mcu_we,
    output wire  [15:0] mcu_addr,
    output wire  [7:0]  oki_din,
    input  wire  [7:0]  oki_dout,

    // Sound latch to the Z80, on the Blaze On board only. MAME maps it as
    // map(0xe00000, 0xe00000).w(soundlatch) — the EVEN byte of the word, so it
    // is qualified by UDS and never by LDS. The odd byte at 0xe00001 is not the
    // latch, and taking a word write as two bytes would send the low half as a
    // second, spurious command.
    output logic        snd_we,
    output wire  [7:0]  snd_din,

    output logic        v2r0_we, v2r1_we, sprreg_we, sprreg2_we,
    output logic [3:0]  reg_addr,
    output logic [15:0] reg_din,
    input  wire  [15:0] v2r0_q, v2r1_q, sprreg_q, sprreg2_q,
    input  wire  [7:0]  oki2_dout,
    input  wire  [15:0] hit_dout, mcu_dout,

    // ---- inputs, active low as the hardware presents them
    input  wire [15:0]  in_p1, in_p2, in_system, in_unk,

    // Per-game window pages, from the game table in the top level.
    input  wire [7:0]   pg_wram, pg_v2w0, pg_v2w1, pg_spr, pg_pal,
    input  wire [7:0]   pg_wdog, pg_in, pg_snd,
    input  wire         rom_1mb,
    // Gates the Blaze On board's extra IRQ-ack windows. Per-game, because
    // 0xe40000 is not an acknowledge on the other boards and decoding it there
    // would answer an address their code may use for something else.
    input  wire         blazeon_io,
    // The CALC3 board's decode: two OKIs at 400001/480001, a sample bank at
    // e00001, and the hit calculator at a00000. Gated so no Tier 1 board
    // answers at those addresses.
    input  wire         calc3_io,

    // Observability. An unmapped access is acknowledged so the CPU cannot hang
    // on it, but it must not pass silently.
    output logic        unmapped_hit,
    output logic [23:1] unmapped_addr
);
    // ---------------------------------------------------------- decode
    wire [23:1] a = eab;
    wire        as = ~ASn && !cpu_space;
    wire        ds = ~LDSn | ~UDSn;
    wire        wr = ~eRWn;   // reads need no strobe of their own: the read mux
                              // is combinational and the CPU latches on DTACK

    // WINDOWS THAT MOVE BETWEEN GAMES ARE PAGES, NOT CONSTANTS.
    //
    // Comparing the whole address against a literal only works for one game.
    // Every window that moves between bakubrkr_map and mgcrystl_map moves on a
    // 64 KB boundary and keeps its size, so the movable part is exactly
    // a[23:16] and the size stays a fixed mask on the bits below:
    //
    //             explbrkr   mgcrystl        size
    //   work RAM    0x10       0x30          64 KB
    //   VIEW2 0     0x50       0x60          16 KB
    //   VIEW2 1     0x58       0x68          16 KB
    //   sprite RAM  0x60       0x70           8 KB
    //   palette     0x70       0x50           4 KB
    //   watchdog    0xa8       0xa0
    //   inputs      0xe0       0xc0
    //
    // Everything else — ROM, both YM2149s, the OKI, all three register blocks,
    // the coin lockout and the EEPROM — is at the same address in both, so it
    // stays a literal. A page that is wired to a constant is a per-game fact
    // hiding in shared code, which is what hard rule 9 is about.
    // The program ROM window is a PER-GAME size, and it was the Blaze On black
    // screen. From MAME:
    //
    //   bakubrkr_map  map(0x000000, 0x07ffff).rom()    512 KB
    //   mgcrystl_map  map(0x000000, 0x07ffff).rom()    512 KB
    //   blazeon_map   map(0x000000, 0x0fffff).rom()      1 MB   (Wing Force too)
    //
    // It was 512 KB for everything. Blaze On carries a full megabyte of 68000
    // code, so every fetch above 0x07ffff fell through to the unmapped path,
    // was acknowledged, and returned nothing.
    //
    // Widening it for ALL games was tried once and produced a black screen on
    // Explosive Breaker, because that game's SDRAM layout puts view2_0 at byte
    // 0x080000 — a read there returns tile graphics, not the zero-fill the
    // reasoning assumed. Per-game is the only correct answer; see hard rule 9.
    wire sel_rom   = rom_1mb ? (a[23:20] == 4'b0000)            // 000000-0fffff
                             : (a[23:19] == 5'b00000);          // 000000-07ffff
    wire sel_wram  = (a[23:16] == pg_wram);
    wire sel_ym0   = (a[23:8]  == 16'h4000) && (a[7:5] == 3'd0);
    wire sel_ym1   = (a[23:8]  == 16'h4002) && (a[7:5] == 3'd0);
    wire sel_oki   = (a[23:1]  == 23'h200200);                  // 400401 byte
    // THE CALC3 BOARD HAS TWO OKIs. shogwarr_map puts the first at 400001 and
    // the second at 480001 -- note 400001, not 400401 as every Tier 1 board
    // uses. Both are byte ports on the odd lane.
    wire sel_oki_a = calc3_io && (a[23:1] == 23'h200000);       // 400001 byte
    wire sel_oki_b = calc3_io && (a[23:1] == 23'h240000);       // 480001 byte
    // Sample bank, written at e00001 on this board.
    wire sel_okibk = calc3_io && (a[23:1] == 23'h700000);       // e00001 byte
    // The hit calculator, a00000-a0007f. 64 words, so a[23:7] selects it and
    // a[6:1] picks the register.
    wire sel_hit   = calc3_io && (a[23:7] == 17'h14000);
    // 64 KB of MCU RAM at 200000-20ffff, shared with the CALC3 simulation.
    wire sel_mcu   = calc3_io && (a[23:16] == 8'h20);
    wire sel_v2w0  = (a[23:16] == pg_v2w0) && (a[15:14] == 2'd0);
    wire sel_v2w1  = (a[23:16] == pg_v2w1) && (a[15:14] == 2'd0);
    wire sel_spr   = (a[23:16] == pg_spr)  && (a[15:13] == 3'd0);
    wire sel_pal   = (a[23:16] == pg_pal)  && (a[15:12] == 4'd0);
    wire sel_v2r0  = (a[23:5]  == 19'h40000);                   // 800000-80001f
    wire sel_sprr  = (a[23:5]  == 19'h48000);                   // 900000-90001f
    // THE SECOND SPRITE REGISTER BLOCK, 980000-98001f.
    //
    // blazeon_map has `map(0x980000, 0x98001f).ram()` -- plain RAM, no device
    // behind it. The board carries two VU-002 chips and this is the second
    // one's register window; MAME does not model the chip but it does honour
    // the RAM, so a read returns what was written.
    //
    // We returned 0xffff, and the bus trace caught it as the FIRST divergence
    // from the oracle on Wing Force, at compared access 19:
    //
    //     ours  980004 R ffff        mame  980004 R 0000
    //
    // The game writes 980000 and 980002, then reads 980004 through 98000a
    // expecting zeros. Everything it does after that is running on values the
    // hardware never produced.
    //
    // Blaze On board only. bakubrkr and mgcrystl have nothing at this address
    // and a read there must stay unmapped, which is how it is caught.
    wire sel_sprr2 = blazeon_io && (a[23:5] == 19'h4c000);      // 980000-98001f
    wire sel_wdog  = (a[23:16] == pg_wdog) && (a[15:1] == 15'd0);
    wire sel_v2r1  = (a[23:5]  == 19'h58000);                   // b00000-b0001f
    wire sel_ctrl  = (a[23:1]  == 23'h680000);                  // d00000/1
    wire sel_in    = (a[23:16] == pg_in)   && (a[15:3] == 13'd0);
    wire sel_snd   = (a[23:16] == pg_snd)  && (a[15:1] == 15'd0);

    // The Blaze On board's other three interrupt-acknowledge reads. From
    // blazeon_map:
    //
    //   map(0xe00000, 0xe00001).nopr();   // "Read = IRQ Ack ?"   -- sel_snd
    //   map(0xe40000, 0xe40001).nopr();   // "IRQ Ack ?"
    //   map(0xec0000, 0xec0001).nopr();   // "Lev 4 IRQ Ack ?"
    //
    // A MAME nopr() returns ZERO. This core left them undecoded, and its
    // unmapped default is 0xffff — which the bus-trace diff against MAME
    // caught as the first and only value divergence in 100,000 accesses:
    //
    //   ours   e40000 R ffff        mame   e40000 R 0000
    //
    // It changed no branch in that window, so it is not known to be a bug the
    // game notices. Corrected because the oracle says so, and because guessing
    // which wrong value a game tolerates is how the OKI stayed silent.
    // 0xe80000 is commented out in the driver and only ever written here, so
    // it is deliberately NOT decoded — decoding an address MAME does not is
    // the opposite mistake.
    wire sel_iack2 = blazeon_io && (a[23:16] == 8'he4) && (a[15:1] == 15'd0);
    wire sel_iack3 = blazeon_io && (a[23:16] == 8'hec) && (a[15:1] == 15'd0);

    wire decoded = sel_rom | sel_wram | sel_ym0 | sel_ym1 | sel_oki | sel_v2w0
                 | sel_v2w1 | sel_spr | sel_pal | sel_v2r0 | sel_sprr | sel_wdog
                 | sel_v2r1 | sel_ctrl | sel_in  | sel_snd
                 | sel_iack2 | sel_iack3 | sel_sprr2
                 | sel_oki_a | sel_oki_b | sel_okibk | sel_hit | sel_mcu;

    // ---------------------------------------------------------- work RAM
    // 64 KB as 32k x 16, held as TWO BYTE-WIDE ARRAYS rather than one 16-bit
    // array with bit-slice writes.
    //
    // That is not a style choice. Writing a slice of an array element —
    // `wram[addr][15:8] <= ...` — is a pattern Quartus does not recognise as a
    // byte-enabled memory, so it infers none: 512 Kbit becomes flip-flops plus
    // address muxes. The design then reported
    //
    //   Error (170011): Design contains 438004 blocks of type combinational
    //   node. However, the device contains only 83820 blocks.
    //
    // a 5x overflow that looks like the design being far too big when it is
    // one inference failing. Two byte-wide arrays, each written whole, infer as
    // M10K every time.
    logic [7:0] wram_hi [0:32767];
    logic [7:0] wram_lo [0:32767];
    logic [7:0] wram_qh, wram_ql;
    wire [14:0] wram_a = a[15:1];

    always_ff @(posedge clk) begin
        if (as && ds && sel_wram && wr && ~UDSn) wram_hi[wram_a] <= oEdb[15:8];
        if (as && ds && sel_wram && wr && ~LDSn) wram_lo[wram_a] <= oEdb[7:0];
        wram_qh <= wram_hi[wram_a];
        wram_ql <= wram_lo[wram_a];
    end
    wire [15:0] wram_q = {wram_qh, wram_ql};

    // ------------------------------------------------- video memory strobes
    // All four windows are addressed by the low word address; the select picks
    // which memory the write lands in.
    assign vmem_addr = a[13:1];
    assign vmem_din  = oEdb;
    assign reg_addr  = a[4:1];
    assign reg_din   = oEdb;
    assign ym_addr   = a[4:1];
    // A byte write to an odd address carries the low half, to an even address
    // the high half — "the registers are mapped to odd addresses, except one!"
    // (kaneko16.cpp ym2149_w).
    assign ym_din    = ~LDSn ? oEdb[7:0] : oEdb[15:8];
    assign eeprom_din = oEdb[7:0];
    assign oki_din    = oEdb[7:0];
    assign hit_addr   = a[6:1];
    assign mcu_addr   = a[16:1];
    // The EVEN byte of the word, which on a big-endian 68000 is the UPPER half.
    assign snd_din    = oEdb[15:8];

    // ---------------------------------------------------------- sequencing
    typedef enum logic [2:0] { S_IDLE, S_ROM, S_DONE, S_VRAM } state_t;
    // Edges still to wait before a VIEW2 read-back is valid. See S_VRAM.
    logic [1:0] vwait;
    state_t state;

    logic [15:0] rom_word;

    // ---------------------------------------------------- ROM line cache
    //
    // Direct-mapped, ROM_LINES lines of four words — one SDRAM burst each.
    //
    // Without any cache every instruction fetch cost a whole burst — request,
    // arbitration, activate, CAS, four words back, three of them thrown away —
    // and the next fetch was almost always the very next word, so it paid the
    // whole cost again. Measured at 35.7 clk ticks per bus cycle against the 16
    // a 12 MHz 68000 needs: the CPU ran at about 45% speed, which is not a
    // performance problem but a correctness one. A core that runs the game at
    // half speed is wrong, and wrong in a way that looks like bad timing in
    // every other block.
    //
    // ONE LINE IS NOT ENOUGH, AND THE REASON IS MEASURABLE
    //
    // A single line only helps straight-line code. explbrkr's boot self-test
    // sits in a loop at 00ca14..00ca24 which spans three four-word blocks, so a
    // one-line cache misses on every fetch of it — requests halved rather than
    // quartered, and the whole gain came from elsewhere. Direct-mapped over
    // several lines holds a loop of that size entirely.
    //
    // THE REQUEST IS ALIGNED DOWN, WHICH IT WAS NOT BEFORE
    //
    // The controller starts a burst at the EXACT word address given and
    // increments from there (kaneko_sdram.sv S_RD: `xfer_addr[COL_BITS:1] + 1`)
    // — it does not align. Asking for an unaligned address therefore returned a
    // window straddling two lines, which cannot be tagged at all. Asking for
    // `{wa[SDR_AW:3], 2'b00}` makes the burst a natural four-word block, so the
    // tag is the address above the index and the lane is wa[2:1].
    //
    // It also removes a hazard that was there before: the controller wraps a
    // burst inside the column bits, and an unaligned four-word burst can cross
    // a row boundary. An aligned one never can, because 1024 words per row
    // divides evenly into four-word blocks.
    //
    // No invalidation. The region is ROM, written once by the loader before
    // cpu_rst is released and never again. `rst` covers the one case that
    // matters — a fresh download holds the CPU in reset anyway.
    localparam int unsigned IDXW  = $clog2(ROM_LINES);
    localparam int unsigned TAGLO = 3 + IDXW;

    logic [63:0]          cdata  [0:ROM_LINES-1];
    logic [SDR_AW:TAGLO]  ctag   [0:ROM_LINES-1];
    logic [ROM_LINES-1:0] cvalid;

    wire [SDR_AW:1]   rom_wa = SDR_AW'(ROM_BASE + {8'd0, a[23:1]});
    wire [IDXW-1:0]   cidx   = rom_wa[TAGLO-1:3];
    wire              line_hit = cvalid[cidx] && (ctag[cidx] == rom_wa[SDR_AW:TAGLO]);
    wire [1:0]        lane     = rom_wa[2:1];
    wire [15:0]       line_word = cdata[cidx][{lane, 4'd0} +: 16];

    wire [15:0]     burst_word = rom_dout[{lane, 4'd0} +: 16];

    always_ff @(posedge clk) begin
        vram0_we <= 1'b0; vram1_we <= 1'b0; spr_we <= 1'b0; pal_we <= 1'b0;
        vram_rd  <= 1'b0;
        v2r0_we  <= 1'b0; v2r1_we  <= 1'b0; sprreg_we <= 1'b0; sprreg2_we <= 1'b0;
        ym0_we   <= 1'b0; ym1_we   <= 1'b0; eeprom_we <= 1'b0;
        oki_we   <= 1'b0; snd_we <= 1'b0;
        oki2_we  <= 1'b0; okibk_we <= 1'b0;
        hit_we   <= 1'b0; mcu_we   <= 1'b0;
        unmapped_hit <= 1'b0;

        if (rst) begin
            state      <= S_IDLE;
            vwait      <= 2'd0;
            DTACKn     <= 1'b1;
            rom_req    <= 1'b0;
            cvalid     <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    DTACKn <= 1'b1;
                    if (as && ds) begin
                        if (sel_rom) begin
                            if (line_hit) begin
                                // Served without touching SDRAM at all, and
                                // DTACK goes out on THIS edge rather than on
                                // the next one in S_DONE. That one clk is the
                                // difference between landing inside the 68000's
                                // sampling window for the current cycle and
                                // missing it, which costs a whole CPU clock —
                                // four ticks here, and about 20% of the CPU's
                                // speed once the cache is doing its job.
                                rom_word <= {line_word[7:0], line_word[15:8]};
                                DTACKn   <= 1'b0;
                                state    <= S_DONE;
                            end else begin
                                // ROM lives at SDRAM word 0 (D6). Aligned down
                                // so the burst is a natural line — see above.
                                rom_addr <= {rom_wa[SDR_AW:3], 2'b00};
                                rom_req  <= 1'b1;
                                state    <= S_ROM;
                            end
                        end else begin
                            // The read half of the same access cycle. Raised
                            // for a READ of either VIEW2 window; `wr` below
                            // handles the write half.
                            vram_rd <= ~wr && (sel_v2w0 || sel_v2w1);
                            if (wr) begin
                                vram0_we  <= sel_v2w0;
                                vram1_we  <= sel_v2w1;
                                spr_we    <= sel_spr;
                                pal_we    <= sel_pal;
                                v2r0_we   <= sel_v2r0;
                                v2r1_we   <= sel_v2r1;
                                sprreg_we <= sel_sprr;
                                sprreg2_we <= sel_sprr2;
                                ym0_we    <= sel_ym0;
                                ym1_we    <= sel_ym1;
                                // Only the low byte of d00000/d00001 is the
                                // EEPROM; the high byte is coin lockout.
                                eeprom_we <= sel_ctrl && ~LDSn;
                                // On the CALC3 board the first OKI answers at
                                // 400001, not 400401, so both selects feed the
                                // same strobe.
                                oki_we    <= (sel_oki || sel_oki_a) && ~LDSn;
                                oki2_we   <= sel_oki_b && ~LDSn;
                                okibk_we  <= sel_okibk && ~LDSn;
                                hit_we    <= sel_hit;
                                mcu_we    <= sel_mcu;
                                snd_we    <= sel_snd  && ~UDSn;
                            end
                            // Everything else answers in one cycle, INCLUDING
                            // addresses nothing decodes — a 68000 waiting on a
                            // DTACK that never comes just stops, silently.
                            if (!decoded) begin
                                unmapped_hit  <= 1'b1;
                                unmapped_addr <= a;
                            end
                            // Same one-clk saving as the cache hit above: work
                            // RAM, video memory and the registers all answer
                            // immediately, so there is no reason to spend an
                            // edge getting to S_DONE before saying so.
                            //
                            // The YM2149s are the exception. jt49 registers its
                            // dout off the address, so the value is one clock
                            // behind; answering on this edge would hand the CPU
                            // whatever register the previous access happened to
                            // land on. They spend the extra edge.
                            //
                            // AND SO IS VIEW2, SINCE ITS READ PORT WAS SHARED.
                            // kaneko_vmem no longer has a read port per
                            // reader: the array is read once into the video
                            // register, the CPU's copy is taken from that
                            // register a cycle later, and the read-back mux
                            // registers it again. So vram0_q/vram1_q are valid
                            // THREE edges after vram_rd, not on this one.
                            //
                            // Answering here hands the 68000 whatever the
                            // previous VIEW2 read left behind. Explosive
                            // Breaker reads VIEW2 1.4 times a frame and never
                            // showed it; Magical Crystals reads it 724 times a
                            // frame and read-modify-writes its tilemap, so it
                            // wrote the stale value back and the picture came
                            // apart in bands.
                            if (!wr && (sel_v2w0 || sel_v2w1)) begin
                                vwait <= 2'd2;
                                state <= S_VRAM;      // DTACK deliberately not
                            end else begin            // asserted yet
                                if (!(sel_ym0 || sel_ym1)) DTACKn <= 1'b0;
                                state <= S_DONE;
                            end
                        end
                    end
                end

                S_ROM: if (rom_ack) begin
                    rom_req    <= 1'b0;
                    cdata[cidx]  <= rom_dout;
                    ctag[cidx]   <= rom_wa[SDR_AW:TAGLO];
                    cvalid[cidx] <= 1'b1;

                    // BYTE ORDER: the swap is not cosmetic.
                    //
                    // hps_io runs WIDE=1, and in WIDE mode file byte n lands in
                    // ioctl_dout[7:0] and byte n+1 in [15:8]. The loader stores
                    // that word verbatim, so SDRAM word n is little-endian with
                    // respect to the file. The graphics path is built around
                    // exactly that order and is pixel-exact against MAME, so the
                    // stream is right and must not be changed.
                    //
                    // The 68000 is big-endian: byte n is the HIGH half of its
                    // word. So the conversion belongs here, at the endian
                    // boundary, and nowhere else.
                    //
                    // Without it the reset vectors read 1000 FCF7 / 0000 1409
                    // instead of 0010 F7FC / 0000 0914, and the CPU executed
                    // four bus cycles and stopped — on hardware that was a black
                    // screen with no liveness bar, indistinguishable from a CPU
                    // that never left reset. sim/cpu/tb_kaneko_cpu.cpp could not
                    // see it: it fed the CPU big-endian words straight from the
                    // file and never went through the loader at all. sim/top
                    // does, and fails without this line.
                    //
                    // Taken from rom_dout rather than from line_data: the
                    // register has not been written yet on this edge.
                    rom_word <= {burst_word[7:0], burst_word[15:8]};
                    state    <= S_DONE;
                end

                // The shared VIEW2 read port's latency, spent as edges. The
                // count is the number of extra cycles kaneko_vmem needs before
                // its CPU-side output is the value just asked for.
                S_VRAM: begin
                    if (vwait != 2'd0) begin
                        vwait <= vwait - 2'd1;
                    end else begin
                        DTACKn <= 1'b0;
                        state  <= S_DONE;
                    end
                end

                S_DONE: begin
                    DTACKn <= 1'b0;
                    if (!as) begin          // cycle over
                        DTACKn <= 1'b1;
                        state  <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------- read mux
    always_comb begin
        if      (sel_rom)  iEdb = rom_word;
        else if (sel_wram) iEdb = wram_q;
        else if (sel_v2w0) iEdb = vram0_q;
        else if (sel_v2w1) iEdb = vram1_q;
        else if (sel_spr)  iEdb = spr_q;
        else if (sel_pal)  iEdb = pal_q;
        else if (sel_v2r0) iEdb = v2r0_q;
        else if (sel_v2r1) iEdb = v2r1_q;
        else if (sel_sprr) iEdb = sprreg_q;
        else if (sel_sprr2) iEdb = sprreg2_q;
        // Both OKIs are readable: the game polls their status the same way
        // the Blaze On board's Z80 does.
        // High byte 0x00, matching the sel_oki read below: the OKI is a byte
        // port on the odd lane and nothing drives the even half.
        else if (sel_oki_a) iEdb = {8'h00, oki_dout};
        else if (sel_oki_b) iEdb = {8'h00, oki2_dout};
        else if (sel_hit)   iEdb = hit_dout;
        else if (sel_mcu)   iEdb = mcu_dout;
        // A YM2149 register reads back as a byte. MAME promotes data_r() to
        // u16, so the high half is zero; the game only reads the low half, but
        // matching it keeps the bus traces comparable.
        else if (sel_ym0)  iEdb = {8'h00, ym0_q};
        else if (sel_ym1)  iEdb = {8'h00, ym1_q};
        // The OKI's status byte, on the low half like its writes.
        else if (sel_oki)  iEdb = {8'h00, oki_dout};
        // The watchdog reads back as zero. MAME's watchdog_timer_device
        // reset16_r returns 0, and this was the first place the core's bus
        // trace differed from MAME's during boot — 55,400 data accesses in,
        // everything before it identical. It fell through to the 0xffff
        // default below because sel_wdog was decoded but never given a value.
        //
        // The reset itself is deliberately not implemented: a watchdog that
        // never fires is the safe direction during bring-up, where a core that
        // silently restarted would be far harder to attribute than one that
        // hangs. Revisit when the game runs.
        else if (sel_wdog) iEdb = 16'h0000;
        // A read of e00000 is an IRQ acknowledge on this board, not the latch:
        // MAME has it as nopr(). It needs a VALUE, though — a decoded address
        // that returns nothing has cost this core three sessions already.
        else if (sel_snd)  iEdb = 16'h0000;
        else if (sel_iack2 || sel_iack3) iEdb = 16'h0000;
        // THE THIRD AND FOURTH INPUT WORDS ARE SWAPPED BETWEEN THE BOARDS.
        //
        //   bakubrkr_map   e00000 P1   e00002 P2   e00004 SYSTEM  e00006 UNK
        //   blazeon_map    c00000 P1   c00002 P2   c00004 UNK     c00006 SYSTEM
        //
        // Blaze On has an extra unused word at offset 4 which pushes SYSTEM to
        // offset 6. This mux was written for bakubrkr_map, so on the Blaze On
        // board a read of SYSTEM returned the UNUSED word instead — 0xffff,
        // where the board reads 0xff00. The game tests it, fails, and jumps to
        // the park loop at 0x000100.
        //
        // Found by the bus-trace diff against MAME, not by reading the map:
        //
        //     ours   c00006 R ffff        mame   c00006 R ff00
        //
        // A per-game fact sitting in shared code, which is hard rule 9.
        else if (sel_in)   iEdb = (a[2:1] == 2'd0) ? in_p1
                                : (a[2:1] == 2'd1) ? in_p2
                                : blazeon_io ? ((a[2:1] == 2'd2) ? in_unk : in_system)
                                             : ((a[2:1] == 2'd2) ? in_system : in_unk);
        // Undriven reads float high on this board's bus, and 0xffff is also
        // what an unpressed input reads, so it is the honest default.
        else               iEdb = 16'hffff;
    end
endmodule

`default_nettype wire
