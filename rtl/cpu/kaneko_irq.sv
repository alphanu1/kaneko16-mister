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
module kaneko_irq #(
    parameter int unsigned LINE_IRQ5 = 224,
    parameter int unsigned LINE_IRQ4 = 64,
    parameter int unsigned LINE_IRQ3 = 144
) (
    input  wire       clk,
    input  wire       rst,

    input  wire [9:0] vcnt,        // raw scanline, kaneko_video_timing

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

    logic pend5, pend4, pend3;

    always_ff @(posedge clk) begin
        if (rst) begin
            pend5 <= 1'b0; pend4 <= 1'b0; pend3 <= 1'b0;
        end else begin
            // Raise first, clear second: a level re-raised on the very edge
            // that acknowledges it must survive, or the interrupt is lost
            // exactly when the machine is busiest.
            if (line_start) begin
                if (vcnt == 10'(LINE_IRQ5)) pend5 <= 1'b1;
                if (vcnt == 10'(LINE_IRQ4)) pend4 <= 1'b1;
                if (vcnt == 10'(LINE_IRQ3)) pend3 <= 1'b1;
            end
            if (iack_edge) begin
                case (a_level)
                    3'd5:    pend5 <= 1'b0;
                    3'd4:    pend4 <= 1'b0;
                    3'd3:    pend3 <= 1'b0;
                    default: ;   // no other level is ever raised here
                endcase
            end
        end
    end

    // Highest pending level wins, encoded active-low for the 68000.
    wire [2:0] level = pend5 ? 3'd5 : pend4 ? 3'd4 : pend3 ? 3'd3 : 3'd0;
    assign ipl_n = ~level;

    // Autovector. The board has no vector generator, so every acknowledge is
    // answered with VPA and the 68000 uses the autovectors at 0x64..0x7c.
    // Asserted ONLY during the acknowledge: VPAn low in a normal cycle turns it
    // into a synchronous 6800-style cycle and the bus stops making sense.
    assign vpa_n = ~iack;

endmodule
