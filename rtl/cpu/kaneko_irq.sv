// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// 68000 interrupt generation: three autovectored levels off the scanline
// counter, held until the CPU acknowledges them.
//
// kaneko16.cpp, kaneko16_state::interrupt — a scanline timer configured with
// `configure_scanline(..., "screen", 0, 1)`, so it runs once per raw scanline
// and `param` is vpos:
//
//     scanline 224 -> IRQ5    main vblank; also buffers sprite RAM
//     scanline 144 -> IRQ3    translates part of the sprite buffer
//     scanline  64 -> IRQ4    translates part of the sprite buffer
//
// THE SCANLINE NUMBERS ARE RAW vpos AND NEED NO CONVERSION
//
// The driver sets `set_size(256, 256)` with `set_visarea(0, 255, 16, 239)`, so
// MAME's vpos counts from the top of the blanked frame with the visible area
// starting at 16 — exactly what kaneko_video_timing does with V_START = 16.
// The two numberings coincide, so 224/144/64 are used as they appear in the
// driver. They are parameters anyway, because the frame is 264 lines here and
// 256 in MAME and the timing is not PCB-verified (design study §9).
//
// Note 224 is sixteen lines BEFORE the end of the visible area, not the start
// of vblank. That is what the driver does and the comment there — "2 frame
// delayed normaly; differs per PCB?" — says it is not certain either. Copied
// rather than corrected.
//
// HOLD_LINE, NOT A PULSE
//
// MAME asserts each level with HOLD_LINE, which keeps the line asserted until
// the CPU acknowledges it. A one-cycle pulse would be missed whenever the 68000
// happened to be masking interrupts, and the game would drop frames in a way
// that looks like a timing bug anywhere but here.
// THE LEVELS ARE PER GAME, and the CALC3 board uses different ones.
//
// kaneko16.cpp's shogwarr_interrupt raises 4 at scanline 224, 3 at 64 and 2 at
// 144 -- every level one BELOW the Tier 1 games, and IRQ2 is a level the older
// boards never use at all. brapboys inherits that machine, so both CALC3 games
// want it. With the Tier 1 numbering the game's main handler is never called:
// it sat with a running 68000 that never reached the code talking to its MCU,
// and the screen stayed black with no other symptom.
//
// The lines are the same three on both boards; only the levels move. They are
// INPUTS rather than parameters because the game is not known until the MRA's
// config byte arrives, long after elaboration.
module kaneko_irq #(
    parameter int unsigned LINE_IRQ5 = 224,
    parameter int unsigned LINE_IRQ4 = 64,
    parameter int unsigned LINE_IRQ3 = 144
) (
    input  wire       clk,
    input  wire       rst,

    input  wire [9:0] vcnt,        // raw scanline, kaneko_video_timing

    // The level raised at each of the three lines. Tier 1 is 5, 4, 3; the
    // CALC3 board is 4, 3, 2.
    input  wire [2:0] lvl_a,       // at LINE_IRQ5, the main one
    input  wire [2:0] lvl_b,       // at LINE_IRQ4
    input  wire [2:0] lvl_c,       // at LINE_IRQ3

    // 68000 side. fc is FC2:FC0; the 68000 drives 3'b111 for a CPU-space
    // cycle, which for this machine only ever means interrupt acknowledge.
    input  wire [2:0] fc,
    input  wire       as,          // ~ASn
    input  wire [3:1] a_level,     // eab[3:1]: the level being acknowledged

    output wire [2:0] ipl_n,       // to fx68k IPL2n:IPL0n, active low
    output wire       vpa_n,       // to fx68k VPAn, active low
    output wire       iack         // CPU space cycle in progress
);

    // A scanline has started when the counter moves. Derived here rather than
    // taken as an input so this module needs only vcnt, and cannot be wired to
    // a line strobe that belongs to a different counter.
    logic [9:0] vcnt_d;
    always_ff @(posedge clk) vcnt_d <= vcnt;
    wire line_start = (vcnt != vcnt_d);

    assign iack = as && (fc == 3'b111);

    // One acknowledge per cycle, on the edge: `as` is held for the whole
    // acknowledge and would otherwise clear the level repeatedly, which is
    // harmless now and would not be if a level were re-raised during one.
    logic iack_d;
    always_ff @(posedge clk) iack_d <= iack;
    wire iack_edge = iack && !iack_d;

    // Named after the LINE that raises them, not after a level: the level is
    // now a per-game input, and naming these pend5/pend4/pend3 is what made the
    // levels look like a fixed property of the hardware.
    logic pend_a, pend_b, pend_c;

    always_ff @(posedge clk) begin
        if (rst) begin
            pend_a <= 1'b0; pend_b <= 1'b0; pend_c <= 1'b0;
        end else begin
            // Raise first, clear second: a level re-raised on the very edge
            // that acknowledges it must survive, or the interrupt is lost
            // exactly when the machine is busiest.
            if (line_start) begin
                if (vcnt == 10'(LINE_IRQ5)) pend_a <= 1'b1;
                if (vcnt == 10'(LINE_IRQ4)) pend_b <= 1'b1;
                if (vcnt == 10'(LINE_IRQ3)) pend_c <= 1'b1;
            end
            // Clear by MATCHING THE LEVEL, since which line owns a level is
            // now per game. A fixed case on 5/4/3 would leave the CALC3
            // board's level 2 pending for ever, and the 68000 would take that
            // interrupt again the instant it returned from it.
            if (iack_edge) begin
                if (a_level == lvl_a) pend_a <= 1'b0;
                if (a_level == lvl_b) pend_b <= 1'b0;
                if (a_level == lvl_c) pend_c <= 1'b0;
            end
        end
    end

    // Highest pending LEVEL wins -- compared as numbers, because the mapping
    // from line to level is per game and the highest line is not the highest
    // level on every board.
    wire [2:0] la = pend_a ? lvl_a : 3'd0;
    wire [2:0] lb = pend_b ? lvl_b : 3'd0;
    wire [2:0] lc = pend_c ? lvl_c : 3'd0;
    wire [2:0] lab   = (la >= lb) ? la : lb;
    wire [2:0] level = (lab >= lc) ? lab : lc;
    assign ipl_n = ~level;

    // Autovector. The board has no vector generator, so every acknowledge is
    // answered with VPA and the 68000 uses the autovectors at 0x64..0x7c.
    // Asserted ONLY during the acknowledge: VPAn low in a normal cycle turns it
    // into a synchronous 6800-style cycle and the bus stops making sense.
    assign vpa_n = ~iack;

endmodule
