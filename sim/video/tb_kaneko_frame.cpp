// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// M0 GATE: render a frame with the RTL and diff it against MAME's own output.
//
// This is the check the fuzz harnesses cannot make. They compare the RTL to a
// model transcribed by hand from MAME, so a misreading of the source passes
// both sides. Here the reference is a frame MAME actually rendered.
//
// Inputs, all produced by tools/ and never committed:
//   <dump>/view2_{0,1}_vram.bin   0x4000 bytes each, as the CPU sees the window
//   <dump>/view2_{0,1}_regs.bin   16 words
//   <dump>/spr_regs.bin           16 words
//   <dump>/spriteram_prev.bin     frame N-1 live RAM = frame N's buffer
//   <dump>/palette.bin            2048 words, xGRB_555
//   <dump>/frame.raw              MAME's frame, w*h u32
//   <dump>/frame.txt              width/height
//   build/roms/mgcrystl_*.bin     assembled by tools/build_rom_regions.py
//
// Every address is produced by the RTL. This file does memory fetches, the
// category/priority mixing and the comparison — it must not recompute an
// address the RTL is responsible for, or the gate tests nothing.
//
// Mixing model, from kaneko16_v.cpp screen_update / screen_update_common:
//   fill with pen 0
//   priority bitmap := 0
//   for category 0..7:
//     view2[0] layer0, view2[0] layer1   -> priority bitmap := category
//     view2[1] layer0, view2[1] layer1   -> priority bitmap := 0 (m_view2_2_pri=0)
//   sprites composited where m_priority.sprite[spr_pri] > priority bitmap
//
// mgcrystl specifics: sprite priorities {2,3,5,7}, sprite colour base 0, tile
// colour base 0x400, set_offset(0x5b, -0x8), no sprite offsets, fliptype 0.

#include <verilated.h>
#include "Vkaneko_frame_top.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

namespace {

Vkaneko_frame_top* dut;

std::vector<uint8_t> slurp(const std::string& path, size_t expect = 0)
{
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path.c_str()); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> v(n);
    if (fread(v.data(), 1, n, f) != (size_t)n) { fprintf(stderr, "short read %s\n", path.c_str()); exit(2); }
    fclose(f);
    if (expect && v.size() != expect) {
        fprintf(stderr, "%s: expected %zu bytes, got %zu\n", path.c_str(), expect, v.size());
        exit(2);
    }
    return v;
}

inline uint16_t rd16(const std::vector<uint8_t>& v, size_t word)
{
    return (uint16_t)(v[word * 2] | (v[word * 2 + 1] << 8));
}

// MAME palette_device::xGRB_555 -> 8:8:8, using pal5bit expansion.
inline uint32_t xgrb555(uint16_t v)
{
    auto e = [](uint32_t c) { return (c << 3) | (c >> 2); };
    const uint32_t g = e((v >> 10) & 0x1f);
    const uint32_t r = e((v >>  5) & 0x1f);
    const uint32_t b = e((v >>  0) & 0x1f);
    return 0xff000000u | (r << 16) | (g << 8) | b;
}

struct Layer {
    const uint16_t* vram;       // 0x800 words: 1024 tiles x 2
    const uint16_t* scroll;     // 0x800 words, 512 used
    uint16_t scroll_x, scroll_y;
    bool     enabled;
    bool     linescroll_en;
    int      dx, dy;
    const std::vector<uint8_t>* rom;
    bool     chip1;             // writes priority 0 rather than its category
};

// One pixel of one layer, with every address coming from the RTL.
struct Pix { bool solid; uint8_t c; uint8_t colour; uint8_t cat; };

int g_xadj = 0, g_yadj = 0;
bool g_ls_by_screen = false;   // LSMODE=screen -> index line scroll by scanline

Pix layer_pixel(const Layer& L, int sx, int sy)
{
    sx += g_xadj; sy += g_yadj;
    Pix p{false, 0, 0, 0};
    if (!L.enabled) return p;

    dut->t_screen_x = sx & 0x1ff;
    dut->t_screen_y = sy & 0x1ff;
    dut->t_dx = (uint32_t)(L.dx & 0x7ff);
    dut->t_dy = (uint32_t)(L.dy & 0x7ff);
    dut->t_scroll_x = L.scroll_x;
    dut->t_scroll_y = L.scroll_y;
    dut->t_linescroll = 0;
    dut->t_linescroll_en = 0;
    dut->t_attr = 0; dut->t_code = 0;
    dut->eval();

    // map_y indexes the line-scroll RAM. Not the scanline — see findings.
    const uint16_t ls = g_ls_by_screen ? L.scroll[sy & 0x1ff]
                                       : L.scroll[dut->t_map_y & 0x1ff];

    dut->t_linescroll = ls;
    dut->t_linescroll_en = L.linescroll_en;
    dut->eval();

    const uint16_t attr = L.vram[dut->t_vram_attr_addr & 0x7ff];
    const uint16_t code = L.vram[dut->t_vram_code_addr & 0x7ff];

    dut->t_attr = attr;
    dut->t_code = code;
    dut->eval();

    const size_t elements = L.rom->size() / 128;
    const uint32_t tile = (uint32_t)(code % elements);
    // rom_addr from the RTL carries the untruncated code; re-base onto the
    // wrapped tile the way MAME's code % gfx->elements() does.
    const uint32_t in_tile = dut->t_rom_addr & 0x7f;
    const uint8_t byte = (*L.rom)[tile * 128 + in_tile];
    const uint8_t c = dut->t_nibble_hi ? (byte >> 4) : (byte & 0xf);

    p.solid  = (c != 0);
    p.c      = c;
    p.colour = dut->t_colour;
    p.cat    = dut->t_prio;
    return p;
}

} // namespace

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    const std::string dump = (argc > 1) ? argv[1] : "build/m0dump";
    const std::string roms = (argc > 2) ? argv[2] : "build/roms";

    dut = new Vkaneko_frame_top;
    g_ls_by_screen = getenv("LSMODE") && !strcmp(getenv("LSMODE"), "screen");

    // ------------------------------------------------------------ inputs
    int W = 256, H = 224;
    {
        FILE* f = fopen((dump + "/frame.txt").c_str(), "r");
        if (f) {
            char line[256];
            while (fgets(line, sizeof line, f)) {
                if (!strncmp(line, "width=", 6))  W = atoi(line + 6);
                if (!strncmp(line, "height=", 7)) H = atoi(line + 7);
            }
            fclose(f);
        }
    }

    auto v0 = slurp(dump + "/view2_0_vram.bin", 0x4000);
    auto v1 = slurp(dump + "/view2_1_vram.bin", 0x4000);
    auto r0 = slurp(dump + "/view2_0_regs.bin", 32);
    auto r1 = slurp(dump + "/view2_1_regs.bin", 32);
    auto sr = slurp(dump + "/spr_regs.bin", 32);
    // SPRRAM selects which sprite RAM snapshot the frame is rendered from, so
    // the buffering lag is settled by measurement rather than assumption:
    //   buf1  live at scanline 223 of frame N-1 — the buffer, one-frame lag
    //   buf2  live at scanline 223 of frame N-2 — two-frame lag
    //   live  live at frame N — no lag
    // The old end-of-frame "prev" capture is gone: it fired ~32 lines after the
    // copy and was never the buffer.
    const char* which = getenv("SPRRAM") ? getenv("SPRRAM") : "buf1";
    std::string sfile = "/spriteram_buf1.bin";
    if (!strcmp(which, "buf2")) sfile = "/spriteram_buf2.bin";
    else if (!strcmp(which, "live")) sfile = "/spriteram.bin";
    printf("sprite RAM: %s\n", which);
    auto sram = slurp(dump + sfile, 0x2000);
    auto pal = slurp(dump + "/palette.bin", 0x1000);
    auto ref = slurp(dump + "/frame.raw", (size_t)W * H * 4);

    const std::string setname_early = (argc > 3) ? argv[3] : "mgcrystl";
    auto rom_t0 = slurp(roms + "/" + setname_early + "_view2_0.bin");
    auto rom_t1 = slurp(roms + "/" + setname_early + "_view2_1.bin");
    auto rom_sp = slurp(roms + "/" + setname_early + "_kan_spr.bin");

    // VRAM window: 0x0000 vram_1, 0x1000 vram_0, 0x2000 scroll_1, 0x3000
    // scroll_0. Layer 1 is at the LOW half — the trap called out in the RTL.
    std::vector<uint16_t> w0(0x2000), w1(0x2000);
    for (size_t i = 0; i < 0x2000; i++) { w0[i] = rd16(v0, i); w1[i] = rd16(v1, i); }

    uint16_t reg0[16], reg1[16], sreg[16];
    for (int i = 0; i < 16; i++) { reg0[i] = rd16(r0, i); reg1[i] = rd16(r1, i); sreg[i] = rd16(sr, i); }

    // Per-game video configuration, read out of the machine configs. These
    // are NOT interchangeable: explbrkr takes MACHINE_RESET_OVERRIDE(gtmr),
    // which sets m_view2_2_pri = 1, so its second VIEW2 writes its category
    // into the priority bitmap where mgcrystl's writes 0. And its sprite
    // priorities are {8,8,8,8} — above everything — against mgcrystl's
    // {2,3,5,7}. Using one game's numbers for the other renders a plausible
    // wrong picture rather than failing.
    struct GameCfg {
        const char* name;
        int dx, dy, vis_min_y;
        int spr_pri[4];
        bool view2_2_pri;
        uint32_t tile_colbase, spr_colbase;
    };
    static const GameCfg GAMES[] = {
        { "mgcrystl", 0x5b, -0x8, 16, { 2, 3, 5, 7 }, false, 0x400, 0 },
        { "explbrkr", 0x5b, -0x8, 16, { 8, 8, 8, 8 }, true,  0x400, 0 },
    };
    const char* setname = (argc > 3) ? argv[3] : "mgcrystl";
    const GameCfg* G = nullptr;
    for (const auto& g : GAMES) if (!strcmp(g.name, setname)) G = &g;
    if (!G) { fprintf(stderr, "no video config for set '%s'\n", setname); return 2; }
    printf("set: %s  view2_2_pri=%d spr_pri={%d,%d,%d,%d}\n", G->name, G->view2_2_pri,
           G->spr_pri[0], G->spr_pri[1], G->spr_pri[2], G->spr_pri[3]);

    const int DX = G->dx, DY = G->dy;
    const int VIS_MIN_Y = G->vis_min_y;

    // tmap[0] takes regs 2/3 and VRAM 0x1000; tmap[1] takes regs 0/1 and VRAM
    // 0x0000. Layer enable is bit 12 (tmap0) and bit 4 (tmap1), ACTIVE LOW.
    // Line scroll enable is bit 11 (tmap0) and bit 3 (tmap1).
    auto mklayer = [&](std::vector<uint16_t>& win, uint16_t* rg,
                       int which, bool chip1, std::vector<uint8_t>* rom) {
        Layer L{};
        const uint16_t ctl = rg[4];
        if (which == 0) {
            L.vram = &win[0x800]; L.scroll = &win[0x1800];
            L.scroll_x = rg[2]; L.scroll_y = rg[3];
            L.enabled = ((ctl >> 12) & 1) == 0;
            L.linescroll_en = (ctl >> 11) & 1;
            L.dx = DX;
        } else {
            L.vram = &win[0x000]; L.scroll = &win[0x1000];
            L.scroll_x = rg[0]; L.scroll_y = rg[1];
            L.enabled = ((ctl >> 4) & 1) == 0;
            L.linescroll_en = (ctl >> 3) & 1;
            L.dx = DX + 2;      // MAME: scrolldx -(dx+2) for tmap[1]
        }
        L.dy = DY; L.rom = rom; L.chip1 = chip1;
        return L;
    };

    Layer layers[4] = {
        mklayer(w0, reg0, 0, false, &rom_t0),
        mklayer(w0, reg0, 1, false, &rom_t0),
        mklayer(w1, reg1, 0, true,  &rom_t1),
        mklayer(w1, reg1, 1, true,  &rom_t1),
    };

    printf("layers: ");
    for (int i = 0; i < 4; i++)
        printf("[%d en=%d ls=%d sx=%04x sy=%04x] ", i, layers[i].enabled,
               layers[i].linescroll_en, layers[i].scroll_x, layers[i].scroll_y);
    printf("\n");

    // -------------------------------------------------- sprite list via RTL
    struct Spr { uint32_t code, colour, prio; bool fx, fy; int x, y; };
    std::vector<Spr> sprites;
    sprites.reserve(1024);
    {
        for (int i = 0; i < 8; i++) {
            uint32_t lo = sreg[i * 2], hi = sreg[i * 2 + 1];
            dut->s_regs_flat[i] = lo | (hi << 16);
        }
        dut->s_sprite_xoffs = 0; dut->s_sprite_yoffs = 0;   // mgcrystl: none
        dut->s_visarea_min_y = VIS_MIN_Y;
        dut->s_wide_screen = (W > 0x100);
        dut->s_fliptype = 0;

        auto tick = [&]() {
            dut->clk = 0; dut->eval();
            dut->s_ram_data = rd16(sram, dut->s_ram_addr & 0xfff);
            dut->clk = 1; dut->eval();
        };
        dut->rst = 1; dut->s_start = 0; tick(); tick();
        dut->rst = 0; dut->s_start = 1; tick();
        dut->s_start = 0;
        long guard = 0;
        while (sprites.size() < 1024 && guard++ < 1024 * 64) {
            tick();
            if (dut->s_out_valid) {
                int sx = (int32_t)(int16_t)((dut->s_out_x & 0x3ff) << 6) >> 6;
                int sy = (int32_t)(int16_t)((dut->s_out_y & 0x3ff) << 6) >> 6;
                sprites.push_back(Spr{ (uint32_t)dut->s_out_code,
                                       (uint32_t)dut->s_out_colour,
                                       (uint32_t)dut->s_out_prio,
                                       (bool)dut->s_out_flipx, (bool)dut->s_out_flipy,
                                       sx, sy });
            }
        }
        printf("sprites parsed: %zu\n", sprites.size());
    }

    // Sprite bitmap, 512x512, drawn LAST-to-FIRST with first-writer-wins, which
    // together mean a higher RAM index is frontmost.
    std::vector<uint16_t> sbmp((size_t)512 * 512, 0);
    std::vector<uint8_t>  smask((size_t)512 * 512, 0);
    {
        const size_t elements = rom_sp.size() / 128;
        for (int i = (int)sprites.size() - 1; i >= 0; i--) {
            const Spr& s = sprites[i];
            for (int yy = 0; yy < 16; yy++) {
                const int py = s.y + yy;
                if (py < 0 || py >= 512) continue;
                for (int xx = 0; xx < 16; xx++) {
                    const int px = s.x + xx;
                    if (px < 0 || px >= 512) continue;
                    dut->p_code = s.code;
                    dut->p_fine_x = xx; dut->p_fine_y = yy;
                    dut->p_flip_x = s.fx; dut->p_flip_y = s.fy;
                    dut->eval();
                    const uint32_t tile = (uint32_t)(s.code % elements);
                    const uint8_t byte = rom_sp[tile * 128 + (dut->p_rom_addr & 0x7f)];
                    const uint8_t c = dut->p_nibble_hi ? (byte >> 4) : (byte & 0xf);
                    if (c == 0) continue;
                    const size_t o = (size_t)py * 512 + px;
                    if (smask[o] == 0)
                        sbmp[o] = (uint16_t)(((16 * s.colour + c) & 0x3fff) | ((s.prio & 3) << 14));
                    smask[o] = 0xff;
                }
            }
        }
    }

    // ------------------------------------------------------------- render
    const int* spr_pri_map = G->spr_pri;
    const uint32_t TILE_COLBASE = G->tile_colbase, SPR_COLBASE = G->spr_colbase;

    // Sweep a constant sampling offset first and report the grid, so the shape
    // of the error is measured rather than assumed.
    if (getenv("SWEEP")) {
        printf("  sweep (rows = yadj, cols = xadj), diff counts:\n        ");
        for (int xa = -2; xa <= 2; xa++) printf("%8d", xa);
        printf("\n");
        for (int ya = -2; ya <= 2; ya++) {
            printf("  %4d", ya);
            for (int xa = -2; xa <= 2; xa++) {
                g_xadj = xa; g_yadj = ya;
                long d = 0;
                for (int row = 0; row < H; row++) {
                    const int sy = VIS_MIN_Y + row;
                    for (int col = 0; col < W; col++) {
                        Pix p[4];
                        for (int l = 0; l < 4; l++) p[l] = layer_pixel(layers[l], col, sy);
                        uint32_t pen = 0; uint8_t prim = 0;
                        for (int cat = 0; cat < 8; cat++)
                            for (int l = 0; l < 4; l++)
                                if (p[l].solid && p[l].cat == cat) {
                                    pen = TILE_COLBASE + 16u * p[l].colour + p[l].c;
                                    prim = (layers[l].chip1 && !G->view2_2_pri) ? 0 : (uint8_t)cat;
                                }
                        const size_t so = (size_t)sy * 512 + col;
                        const uint16_t sv = sbmp[so];
                        const uint16_t spix = sv & 0x3fff;
                        if (spix && spr_pri_map[(sv >> 14) & 3] > prim) pen = SPR_COLBASE + spix;
                        const uint32_t rgb = xgrb555(rd16(pal, pen & 0x7ff));
                        const size_t o = (size_t)row * W + col;
                        const uint32_t want = (uint32_t)(ref[o*4+0] | (ref[o*4+1]<<8) | (ref[o*4+2]<<16));
                        if ((rgb & 0xffffff) != (want & 0xffffff)) d++;
                    }
                }
                printf("%8ld", d);
            }
            printf("\n");
        }
        g_xadj = 0; g_yadj = 0;
    }

    std::vector<uint32_t> out((size_t)W * H);
    long diff = 0;
    long first_bad = -1;
    long bad_sprite = 0, bad_tile = 0, bad_bg = 0;
    std::vector<long> bad_row((size_t)H, 0);

    for (int row = 0; row < H; row++) {
        const int sy = VIS_MIN_Y + row;
        for (int col = 0; col < W; col++) {
            const int sx = col;

            Pix p[4];
            for (int l = 0; l < 4; l++) p[l] = layer_pixel(layers[l], sx, sy);

            uint32_t pen = 0;          // fill_bitmap: pen 0 for sprite type 0
            uint8_t  prim = 0;

            for (int cat = 0; cat < 8; cat++)
                for (int l = 0; l < 4; l++)
                    if (p[l].solid && p[l].cat == cat) {
                        pen = TILE_COLBASE + 16u * p[l].colour + p[l].c;
                        prim = (layers[l].chip1 && !G->view2_2_pri) ? 0 : (uint8_t)cat;
                    }

            const size_t so = (size_t)sy * 512 + sx;
            const uint16_t sv = sbmp[so];
            const uint16_t spix = sv & 0x3fff;
            const uint16_t spri = (sv >> 14) & 3;
            if (spix && spr_pri_map[spri] > prim)
                pen = SPR_COLBASE + spix;

            const uint32_t rgb = xgrb555(rd16(pal, pen & 0x7ff));
            out[(size_t)row * W + col] = rgb;

            const uint32_t want = (uint32_t)(ref[((size_t)row * W + col) * 4 + 0]
                                  | (ref[((size_t)row * W + col) * 4 + 1] << 8)
                                  | (ref[((size_t)row * W + col) * 4 + 2] << 16)
                                  | (ref[((size_t)row * W + col) * 4 + 3] << 24));
            if ((rgb & 0x00ffffff) != (want & 0x00ffffff)) {
                diff++;
                if (first_bad < 0) first_bad = (long)row * W + col;
                // Attribute the miss, so the next step is localised rather
                // than guessed: was a sprite composited here, and did any
                // tile layer contribute?
                if (spix && spr_pri_map[spri] > prim) bad_sprite++;
                else if (pen != 0) bad_tile++;
                else bad_bg++;
                bad_row[row]++;
            }
        }
    }

    const long total = (long)W * H;
    printf("kaneko_frame: pixels=%ld diff=%ld match=%.4f%%\n",
           total, diff, 100.0 * (total - diff) / total);
    if (diff) {
        printf("  attribution: sprite-covered=%ld tile=%ld background=%ld\n",
               bad_sprite, bad_tile, bad_bg);
        printf("  worst rows:");
        for (int k = 0; k < 6; k++) {
            int best = -1; long bv = 0;
            for (int r = 0; r < H; r++) if (bad_row[r] > bv) { bv = bad_row[r]; best = r; }
            if (best < 0) break;
            printf(" %d(%ld)", best, bv);
            bad_row[best] = 0;
        }
        printf("\n");
    }
    // Re-walk the first few misses and report what the RTL decided there,
    // plus which palette entries carry the colour MAME produced. Guessing from
    // an RGB triple is how you end up chasing the wrong bug.
    if (diff) {
        int shown = 0;
        for (int row = 0; row < H && shown < 6; row++) {
            for (int col = 0; col < W && shown < 6; col++) {
                const size_t o = (size_t)row * W + col;
                const uint32_t want = (uint32_t)(ref[o * 4 + 0] | (ref[o * 4 + 1] << 8)
                                    | (ref[o * 4 + 2] << 16));
                if ((out[o] & 0xffffff) == (want & 0xffffff)) continue;
                const int sy = VIS_MIN_Y + row, sx = col;
                Pix p[4];
                for (int l = 0; l < 4; l++) p[l] = layer_pixel(layers[l], sx, sy);
                uint32_t pen = 0; uint8_t prim = 0; int winner = -1;
                for (int cat = 0; cat < 8; cat++)
                    for (int l = 0; l < 4; l++)
                        if (p[l].solid && p[l].cat == cat) {
                            pen = TILE_COLBASE + 16u * p[l].colour + p[l].c;
                            prim = (layers[l].chip1 && !G->view2_2_pri) ? 0 : (uint8_t)cat;
                            winner = l;
                        }
                printf("  miss row=%3d col=%3d  our pen=%03x (layer %d colour=%02x c=%x cat=%d)\n",
                       row, col, pen, winner,
                       winner >= 0 ? p[winner].colour : 0,
                       winner >= 0 ? p[winner].c : 0,
                       winner >= 0 ? p[winner].cat : 0);
                printf("      layers:");
                for (int l = 0; l < 4; l++)
                    printf(" [%d s=%d c=%x col=%02x cat=%d]", l, p[l].solid, p[l].c,
                           p[l].colour, p[l].cat);
                printf("\n      want=%06x got=%06x; palette entries with want:",
                       want & 0xffffff, out[o] & 0xffffff);
                int found = 0;
                for (int e = 0; e < 2048 && found < 6; e++)
                    if ((xgrb555(rd16(pal, e)) & 0xffffff) == (want & 0xffffff)) {
                        printf(" %03x", e); found++;
                    }
                if (!found) printf(" NONE (colour is not in the palette at all)");
                printf("\n");
                shown++;
            }
        }
    }

    // Write our frame next to the reference so the two can be looked at.
    FILE* f = fopen((dump + "/rtl_frame.raw").c_str(), "wb");
    if (f) { fwrite(out.data(), 4, out.size(), f); fclose(f); }

    dut->final();
    delete dut;
    return 0;   // reporting harness: the diff figure is the result
}
