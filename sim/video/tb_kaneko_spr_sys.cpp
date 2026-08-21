// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// kaneko_spr_sys: sprite RAM in, one sprite pixel per screen position out.
//
// The parser is already verified against MAME and the renderer against the
// frame gate's compositor, so this does not re-derive either. It targets what
// the subsystem ADDS:
//
//   1. the resolved table between parser and renderer
//   2. the mixer read port — the right pixel at the right coordinates
//   3. double buffering — the mixer keeps reading last frame while this one draws
//   4. the parity mask — a sprite removed from the list disappears, with no
//      clearing pass, and does not linger for two frames
//   5. overrun counting when a frame arrives before the pass finishes
//
// The reference is the draw model applied to the records the parser actually
// emitted, snooped from the harness. A fault can therefore only be in the
// parts under test.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <random>
#include <cstdlib>
#include "Vkaneko_spr_sys_harness.h"
#include "verilated.h"

namespace {

constexpr int BMP_W_LOG2 = 8, BMP_H_LOG2 = 8;
constexpr int BMP_W = 1 << BMP_W_LOG2;
constexpr int BMP_H = 1 << BMP_H_LOG2;
constexpr int SDR_LATENCY = 18;

Vkaneko_spr_sys_harness* dut;
long checks = 0, fails = 0;
long ref_writes = 0, dut_writes = 0;

struct Rec {
    uint32_t code; int colour, prio, fx, fy; int x, y;
};
std::vector<Rec> seen;      // records the parser emitted this pass

void tick(int n = 1) {
    for (int i = 0; i < n; i++) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
        // Log the tail of a sprite: the last two pixels and the two cycles
        // after, which is where the dropped write lives.
        if (getenv("SPRTAIL")) {
            static long ncyc = 0; ncyc++;
            static int  armed = 0;
            if (dut->dbg_state == 3 /* S_DRAW */ && dut->dbg_xx == 15
                && dut->dbg_yy == 15 && dut->dbg_ce) armed = 6;
            if (armed > 0) {
                static int shown = 0;
                if (shown < 24) {
                    printf("    cyc st=%d ce=%d xx=%2d yy=%2d bvalid=%d "
                           "bpix=%x maskq=%d bmp_we=%d data=%04x\n",
                           (int)dut->dbg_state, (int)dut->dbg_ce,
                           (int)dut->dbg_xx, (int)dut->dbg_yy,
                           (int)dut->dbg_bvalid, (int)dut->dbg_bpix,
                           (int)dut->dbg_maskq, (int)dut->dbg_bmp_we,
                           (unsigned)dut->dbg_bmp_data);
                    shown++;
                }
                armed--;
            }
        }
        static int trace_left = 0;
        if (dut->dbg_parstart && getenv("SPRDBG")) trace_left = 10;
        if (trace_left > 0) {
            printf("    RAM addr=%4d q=%04x%s\n", (int)dut->dbg_ramaddr,
                   (unsigned)dut->dbg_ramq,
                   dut->dbg_parstart ? "   <- par_start" : "");
            trace_left--;
        }
        if (dut->dbg_bmp_we) dut_writes++;
        if (dut->dbg_bmp_we && getenv("SPRDBG")) {
            static long nw = 0;
            if (nw < 4 || (nw >= 250 && nw < 254))
                printf("    WRITE#%ld back=%d (x=%d,y=%d) data=%04x  "
                       "s_code=%05x s_col=%d tbl_ra=%d tbl_q=%011llx\n",
                       nw, (int)dut->dbg_back,
                       (int)(dut->dbg_bmp_addr & (BMP_W - 1)),
                       (int)(dut->dbg_bmp_addr >> BMP_W_LOG2),
                       (unsigned)dut->dbg_bmp_data,
                       (unsigned)dut->dbg_scode, (int)dut->dbg_scolour,
                       (int)dut->dbg_tblra, (unsigned long long)dut->dbg_tblq);
            nw++;
        }
        if (dut->par_valid) {
            Rec r;
            r.code   = dut->par_code;
            r.colour = dut->par_colour;
            r.prio   = dut->par_prio;
            r.fx     = dut->par_flipx;
            r.fy     = dut->par_flipy;
            // 10-bit signed
            r.x = (int)dut->par_x; if (r.x & 0x200) r.x -= 0x400;
            r.y = (int)dut->par_y; if (r.y & 0x200) r.y -= 0x400;
            seen.push_back(r);
        }
    }
}

// The harness's SDRAM returns byte k of the aligned eight-byte block at word
// address A as (A*2 + k) & 0xff. The feeder hands the renderer byte `addr`
// of the region, so the byte at a given ROM address is just that address.
inline uint8_t rom_byte(uint32_t addr) { return (uint8_t)(addr & 0xff); }

// kaneko_vuspr_draw's model, verbatim in intent: walk the table downwards,
// first writer wins, mask marked for every non-transparent source pixel.
std::vector<int> ref_who, ref_xx, ref_yy;

void reference(const std::vector<Rec>& recs, std::vector<uint16_t>& out,
               int x0, int x1, int y0, int y1)
{
    ref_who.assign((size_t)BMP_W * BMP_H, -1);
    ref_xx.assign((size_t)BMP_W * BMP_H, -1);
    ref_yy.assign((size_t)BMP_W * BMP_H, -1);
    out.assign((size_t)BMP_W * BMP_H, 0);
    std::vector<uint8_t> m((size_t)BMP_W * BMP_H, 0);
    for (int i = (int)recs.size() - 1; i >= 0; i--) {
        const Rec& s = recs[i];
        for (int yy = 0; yy < 16; yy++) {
            for (int xx = 0; xx < 16; xx++) {
                const int px = s.fx ? (15 - xx) : xx;
                const int py = s.fy ? (15 - yy) : yy;
                const int in_tile = ((py >> 3) << 6) | ((px >> 3) << 5)
                                  | ((py & 7) << 2) | ((px >> 1) & 3);
                const uint32_t ra = (s.code << 7) | (uint32_t)in_tile;
                const uint8_t  rb = rom_byte(ra);
                const int c = (px & 1) ? (rb & 0xf) : (rb >> 4);
                if (!c) continue;
                const int dx = s.x + xx, dy = s.y + yy;
                if (dx < x0 || dx > x1 || dy < y0 || dy > y1) continue;
                const size_t o = (size_t)(dy & (BMP_H - 1)) * BMP_W
                               + (size_t)(dx & (BMP_W - 1));
                if (!m[o]) { ref_writes++; out[o] = (uint16_t)((s.prio << 14)
                                    | (s.colour << 4) | c);
                             ref_who[o] = i; ref_xx[o] = xx; ref_yy[o] = yy; }
                m[o] = 1;
            }
        }
    }
}

void wr_ram(int addr, uint16_t v) {
    dut->ram_we = 1; dut->ram_wa = addr; dut->ram_wd = v;
    tick();
    dut->ram_we = 0;
}

// Read the whole surface back through the mixer port. One clock of latency,
// so present the coordinates then sample on the following cycle.
void readback(std::vector<uint16_t>& got) {
    got.assign((size_t)BMP_W * BMP_H, 0);
    for (int y = 0; y < BMP_H; y++) {
        for (int x = 0; x < BMP_W; x++) {
            dut->rd_x = x; dut->rd_y = y;
            tick();
            got[(size_t)y * BMP_W + x] =
                (uint16_t)((dut->spr_prio << 14) | dut->spr_pix);
        }
    }
}

// Run one frame to completion and return the records the parser emitted.
void run_frame(long guard_max = 4000000) {
    seen.clear();
    dut->frame_start = 1; tick(); dut->frame_start = 0;
    long guard = 0;
    while (dut->busy && guard++ < guard_max) tick();
    if (dut->busy) { printf("  TIMEOUT waiting for the pass\n"); fails++; }
    tick(4);
}

void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; printf("  FAIL: %s\n", what); }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vkaneko_spr_sys_harness;
    std::mt19937 rng(0x53595300u);   // 'SYS'

    const int x0 = 0, x1 = 255, y0 = 16, y1 = 239;

    dut->rst = 1; dut->frame_start = 0; dut->ram_we = 0; dut->keep_sprites = 0;
    dut->clip_x0 = x0; dut->clip_x1 = x1;
    dut->clip_y0 = y0; dut->clip_y1 = y1;
    dut->visarea_min_y = 16;
    dut->rd_x = 0; dut->rd_y = 0;
    for (int i = 0; i < 256; i++) dut->regs_flat[i / 32] = 0;
    dut->sprite_count = 0;
    tick(8);
    dut->rst = 0;
    tick(8);

    // ---------------------------------------------------------------- 1+2
    // A list of sprites drawn, then read back through the mixer port.
    printf("== render and read back\n");
    const int N = getenv("SPRN") ? atoi(getenv("SPRN")) : 24;
    dut->sprite_count = N;
    for (int i = 0; i < N; i++) {
        // Sprite RAM record: 4 words per sprite.
        //   0: attr/colour   1: code   2: x   3: y
        const uint16_t colour = (uint16_t)(rng() & 0x3f);
        const uint16_t code   = (uint16_t)(rng() & 0x7ff);
        // OFFSCR=<percent> puts that share of the list outside the clip
        // rectangle. The hardware parses a full 1024 records every frame
        // whether a game uses them or not, so a list that is mostly off screen
        // is the normal case, not a corner one — and it is the case that
        // decides whether a pass fits in a frame.
        static const int offpct = getenv("OFFSCR") ? atoi(getenv("OFFSCR")) : 0;
        const bool     off    = ((int)(rng() % 100) < offpct);
        const int      sx     = off ? 400 + (int)(rng() % 80)
                                    : 20 + (int)(rng() % 180);
        const int      sy     = off ? 400 + (int)(rng() % 80)
                                    : 30 + (int)(rng() % 160);
        wr_ram(i * 4 + 0, colour);
        wr_ram(i * 4 + 1, code);
        wr_ram(i * 4 + 2, (uint16_t)(sx << 6));
        wr_ram(i * 4 + 3, (uint16_t)(sy << 6));
    }

    run_frame();
    // The parser always walks its whole list; the renderer draws only the
    // first sprite_count entries of the table it filled.
    printf("  parser emitted %zu records, renderer draws the first %d\n",
           seen.size(), N);
    check(seen.size() >= (size_t)N, "parser emitted fewer records than drawn");
    if (seen.size() > (size_t)N) seen.resize(N);
    std::vector<Rec> pass1 = seen;

    // The surface just drawn is still the back buffer until the next swap, so
    // one more frame with the same list puts it in front of the mixer.
    run_frame();
    if (seen.size() > (size_t)N) seen.resize(N);
    if (getenv("SPR3")) { run_frame(); run_frame();
                          if (seen.size() > (size_t)N) seen.resize(N); }

    std::vector<uint16_t> got, want;
    readback(got);
    reference(seen, want, x0, x1, y0, y1);

    if (getenv("SPRDBG")) {
        printf("  renderer latched: code=%05x colour=%02d "
               "(tbl_ra=%d tbl_q=%011llx)\n",
               (unsigned)dut->dbg_scode, (int)dut->dbg_scolour,
               (int)dut->dbg_tblra, (unsigned long long)dut->dbg_tblq);
        for (size_t i = 0; i < seen.size() && i < 4; i++)
            printf("  rec[%zu] code=%05x col=%02d prio=%d fx=%d fy=%d x=%d y=%d\n",
                   i, seen[i].code, seen[i].colour, seen[i].prio,
                   seen[i].fx, seen[i].fy, seen[i].x, seen[i].y);
        int gx0=9999,gy0=9999,gx1=-1,gy1=-1, wx0=9999,wy0=9999,wx1=-1,wy1=-1;
        long gn=0;
        for (size_t o = 0; o < got.size(); o++) {
            int X=(int)(o%BMP_W), Y=(int)(o/BMP_W);
            if (got[o])  { gn++; if(X<gx0)gx0=X; if(X>gx1)gx1=X; if(Y<gy0)gy0=Y; if(Y>gy1)gy1=Y; }
            if (want[o]) { if(X<wx0)wx0=X; if(X>wx1)wx1=X; if(Y<wy0)wy0=Y; if(Y>wy1)wy1=Y; }
        }
        printf("  DUT  %ld px, bbox x=%d..%d y=%d..%d\n", gn, gx0,gx1,gy0,gy1);
        printf("  REF  bbox x=%d..%d y=%d..%d\n", wx0,wx1,wy0,wy1);
    }

    long diff = 0, nonzero = 0;
    for (size_t o = 0; o < want.size(); o++) {
        if (want[o]) nonzero++;
        if (got[o] != want[o]) {
            if (diff < 8)
                printf("  MISMATCH (%zu,%zu) got=%04x want=%04x  "
                       "from rec[%d] pixel(%d,%d) of sprite at (%d,%d)\n",
                       o % BMP_W, o / BMP_W, got[o], want[o],
                       ref_who[o], ref_xx[o], ref_yy[o],
                       ref_who[o] >= 0 ? seen[ref_who[o]].x : -1,
                       ref_who[o] >= 0 ? seen[ref_who[o]].y : -1);
            diff++;
        }
    }
    checks += (long)want.size();
    fails  += diff;
    printf("  %ld non-zero reference pixels, %ld differ\n", nonzero, diff);
    printf("  bitmap writes: reference %ld, DUT %ld (over 2 passes) -> %+ld per pass\n",
           ref_writes, dut_writes, dut_writes / 2 - ref_writes);
    check(nonzero > 500, "reference has too few pixels to be a real test");

    // ------------------------------------------------------------------ 3
    // Double buffering: while a pass draws, the mixer must still return the
    // PREVIOUS frame. Empty the sprite list, start a frame, and read during it.
    printf("== double buffering\n");
    dut->sprite_count = 0;
    seen.clear();
    dut->frame_start = 1; tick(); dut->frame_start = 0;
    tick(4);
    check(dut->busy, "pass ended before the mid-pass read could be taken");

    long still_there = 0;
    for (size_t o = 0; o < want.size() && dut->busy; o++) {
        if (!want[o]) continue;
        dut->rd_x = (int)(o % BMP_W); dut->rd_y = (int)(o / BMP_W);
        tick();
        uint16_t v = (uint16_t)((dut->spr_prio << 14) | dut->spr_pix);
        if (v == want[o]) still_there++;
    }
    printf("  %ld of the previous frame's pixels still readable mid-pass\n",
           still_there);
    check(still_there > 0, "the mixer lost the previous frame while drawing");

    long g = 0; while (dut->busy && g++ < 4000000) tick();
    tick(4);

    // ------------------------------------------------------------------ 4
    // The parity mask: with an empty list now in front, every pixel must read
    // as nothing — with no clearing pass having run.
    printf("== the surface clears between frames\n");
    run_frame();      // swap the empty surface to the front
    readback(got);
    long leftover = 0;
    for (size_t o = 0; o < got.size(); o++) if (got[o]) leftover++;
    printf("  %ld pixels left over from the previous frame\n", leftover);
    check(leftover == 0, "stale pixels survived the buffer swap");

    // ------------------------------------------------------------------ 5
    printf("== overrun counting\n");
    dut->sprite_count = N;
    uint16_t before = dut->overrun;
    dut->frame_start = 1; tick(); dut->frame_start = 0;
    tick(20);
    check(dut->busy, "pass finished too quickly to test overrun");
    dut->frame_start = 1; tick(); dut->frame_start = 0;   // early second frame
    tick(4);
    check(dut->overrun == (uint16_t)(before + 1), "overrun did not count");
    g = 0; while (dut->busy && g++ < 4000000) tick();

    // --------------------------------------------------------------- 5.5
    // EVERY FRAME, NOT ONE FRAME.
    //
    // The first version of this checked the surface after a single swap and
    // passed while the RTL showed stale garbage on hardware. The scheme it was
    // testing had a four-frame cycle — two good frames then two bad — and one
    // sample landed on a good one. Any test of "does it clear" has to run long
    // enough to cover the whole cycle of whatever scheme is underneath, and
    // since that cycle is not known from outside, the answer is to check every
    // frame for a good many frames.
    printf("== the surface clears on EVERY frame, not just some\n");
    {
        // A sprite list drawn once, then emptied. From then on every frame
        // must read completely blank, for as long as we care to look.
        dut->sprite_count = N;
        run_frame(); run_frame();
        dut->sprite_count = 0;
        run_frame();

        long bad_frames = 0, worst = 0;
        for (int f = 0; f < 10; f++) {
            run_frame();
            readback(got);
            long left = 0;
            for (size_t o = 0; o < got.size(); o++) if (got[o]) left++;
            if (left) { bad_frames++; if (left > worst) worst = left; }
        }
        printf("  %ld of 10 consecutive frames had leftover pixels"
               " (worst %ld)\n", bad_frames, worst);
        check(bad_frames == 0, "the surface does not clear on every frame");
        dut->sprite_count = N;
    }

    // ------------------------------------------------------------------ 5.7
    // KEEP SPRITES ON SCREEN.
    //
    // MAME clears the coverage mask every frame but only clears the bitmap
    // when the game is not asking for the picture to be kept:
    //
    //     m_sprites_maskmap[m_buffer].fill(0, clip);
    //     if (!m_keep_sprites) m_sprites_bitmap[m_buffer].fill(0, clip);
    //
    // Explosive Breaker's laser holds on screen this way. So: draw a list,
    // turn keep on, empty the list, and the picture must still be there —
    // and with keep off it must vanish.
    printf("== keep sprites on screen\n");
    {
        dut->sprite_count = N;
        dut->keep_sprites = 0;
        run_frame(); run_frame();
        if (seen.size() > (size_t)N) seen.resize(N);
        reference(seen, want, x0, x1, y0, y1);

        // With keep ON and nothing to draw, the picture must survive. Two
        // frames, because the surfaces alternate and each is reused every
        // other pass.
        dut->keep_sprites = 1;
        dut->sprite_count = 0;
        run_frame(); run_frame();
        readback(got);
        long kept = 0, lost = 0;
        for (size_t o = 0; o < want.size(); o++) {
            if (!want[o]) continue;
            if (got[o] == want[o]) kept++; else lost++;
        }
        printf("  keep on:  %ld pixels held, %ld lost\n", kept, lost);
        check(kept > 0 && lost == 0, "kept sprites did not survive the frame");

        // And with keep OFF the same empty list must wipe it.
        dut->keep_sprites = 0;
        run_frame(); run_frame();
        readback(got);
        long left = 0;
        for (size_t o = 0; o < got.size(); o++) if (got[o]) left++;
        printf("  keep off: %ld pixels left\n", left);
        check(left == 0, "clearing stopped working when keep was added");
        dut->sprite_count = N;
    }

    // ------------------------------------------------------------------ 6
    // FRAMES ARRIVE ON A CLOCK, NOT WHEN THE RENDERER IS READY.
    //
    // Every test above waits for a pass to finish before starting the next.
    // Hardware does not: vbl_rise fires every frame whether the renderer has
    // finished or not, and a pass over 1024 sprites whose every pixel can miss
    // a 2.25 MB ROM does not reliably fit in one. This drives frame_start on a
    // fixed period and checks the surface is still exactly one frame's worth of
    // sprites — not an accumulation of several.
    printf("== frames on a fixed period\n");
    dut->sprite_count = N;
    long period = 0;
    {   // Time one unobstructed pass, then run frames at 60%% of it so passes
        // genuinely overlap the next frame boundary.
        long t0 = 0;
        dut->frame_start = 1; tick(); dut->frame_start = 0;
        while (dut->busy && t0 < 4000000) { tick(); t0++; }
        period = t0 * 3 / 5;
        printf("  one pass takes %ld clocks; driving frames every %ld\n",
               t0, period);
    }

    uint16_t ov0 = dut->overrun;
    for (int f = 0; f < 12; f++) {
        seen.clear();
        dut->frame_start = 1; tick(); dut->frame_start = 0;
        for (long i = 0; i < period; i++) tick();
    }
    // Let whatever is in flight finish, then two clean frames so the surface
    // in front of the mixer is a completed pass.
    long gg = 0; while (dut->busy && gg++ < 4000000) tick();
    printf("  overruns counted: %d\n", (int)(uint16_t)(dut->overrun - ov0));
    run_frame(); run_frame();
    if (seen.size() > (size_t)N) seen.resize(N);

    readback(got);
    reference(seen, want, x0, x1, y0, y1);
    long acc = 0, missing = 0;
    for (size_t o = 0; o < want.size(); o++) {
        if (got[o] && !want[o]) acc++;         // a pixel no sprite put there
        if (!got[o] && want[o]) missing++;
    }
    printf("  %ld pixels present that no current sprite drew, %ld missing\n",
           acc, missing);
    check(acc == 0, "sprites accumulate across frames");
    check(missing == 0, "sprites missing after overlapping frames");

    printf("\ntb_kaneko_spr_sys: %ld checks, %ld fails\n", checks, fails);
    delete dut;
    return fails ? 1 : 0;
}
