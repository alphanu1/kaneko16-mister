// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The CALC hitbox calculator, fuzzed against a transcription of MAME's type-1
// handlers.
//
// WHY A TRANSCRIPTION AND NOT A LIVE ORACLE
//
// Every other oracle in this project is MAME itself, running the game. That is
// right for anything whose behaviour depends on the machine around it, and
// wrong here: this device is eight registers and two arithmetic expressions
// with no state beyond the registers and no dependence on anything else. A
// transcription can be exhaustive where a running game visits whatever handful
// of rectangles its own logic produces.
//
// The transcription below is copied line for line from
// kaneko_hit.cpp::calc_compute_x / calc_compute_y / kaneko_hit_type1_r, with
// MAME's types preserved exactly. That is the whole point: the registers are
// uint16_t, the distances are int16_t, and the comparisons in the status word
// are unsigned. Get any of those wrong and the device computes plausible
// distances while reporting collisions that never happened -- which reads as a
// game bug rather than an arithmetic one.
//
// WHAT IS DELIBERATELY NOT COVERED
//
// The random register at 0x14. It is a random number in the oracle too, so
// there is nothing to agree with; the test checks only that it is not stuck,
// because a constant there would pass every other check and be wrong.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <random>
#include "Vkaneko_hit.h"
#include "verilated.h"

namespace {

Vkaneko_hit* d;
long checks = 0, fails = 0;

void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; if (fails <= 12) printf("  FAIL: %s\n", what); }
}

void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

// ---------------------------------------------------------------- the oracle
// kaneko_hit.cpp, type 1. Types are MAME's and must stay so.
struct Hit { uint16_t x1p, y1p, x1s, y1s, x2p, y2p, x2s, y2s; };

int16_t compute_x(const Hit& h) {
    if ((h.x2p >= h.x1p) && (h.x2p < (h.x1p + h.x1s)))
        return (int16_t)(h.x1s - (h.x2p - h.x1p));
    if ((h.x1p >= h.x2p) && (h.x1p < (h.x2p + h.x2s)))
        return (int16_t)(h.x2s - (h.x1p - h.x2p));
    return (int16_t)(((h.x1s + h.x2s) / 2)
                     - abs((h.x1p + h.x1s / 2) - (h.x2p + h.x2s / 2)));
}

int16_t compute_y(const Hit& h) {
    if ((h.y2p >= h.y1p) && (h.y2p < (h.y1p + h.y1s)))
        return (int16_t)(h.y1s - (h.y2p - h.y1p));
    if ((h.y1p >= h.y2p) && (h.y1p < (h.y2p + h.y2s)))
        return (int16_t)(h.y2s - (h.y1p - h.y2p));
    return (int16_t)(((h.y1s + h.y2s) / 2)
                     - abs((h.y1p + h.y1s / 2) - (h.y2p + h.y2s / 2)));
}

uint16_t compute_status(const Hit& h) {
    uint16_t data = 0;
    int16_t x_coll = compute_x(h), y_coll = compute_y(h);
    if      (h.y1p >  h.y2p) data |= 0x2000;
    else if (h.y1p == h.y2p) data |= 0x4000;
    else if (h.y1p <  h.y2p) data |= 0x8000;
    if (y_coll < 0) data |= 0x1000;
    if      (h.x1p >  h.x2p) data |= 0x0200;
    else if (h.x1p == h.x2p) data |= 0x0400;
    else if (h.x1p <  h.x2p) data |= 0x0800;
    if (x_coll < 0) data |= 0x0100;
    data |= 0x0040;
    if (x_coll >= 0) data |= 0x0004;
    if (y_coll >= 0) data |= 0x0002;
    if ((x_coll >= 0) && (y_coll >= 0)) data |= 0x000F;
    return data;
}

// ------------------------------------------------------------------ the DUT
void wr(uint8_t byte_off, uint16_t v) {
    d->addr = byte_off >> 1;
    d->din  = v;
    d->uds  = 1; d->lds = 1; d->we = 1;
    tick();
    d->we = 0; d->eval();
}

uint16_t rd(uint8_t byte_off) {
    d->addr = byte_off >> 1;
    d->eval();
    return d->dout;
}

void load(const Hit& h) {
    wr(0x20, h.x1p); wr(0x22, h.x1s); wr(0x24, h.y1p); wr(0x26, h.y1s);
    wr(0x2c, h.x2p); wr(0x2e, h.x2s); wr(0x30, h.y2p); wr(0x32, h.y2s);
}

void one(const Hit& h, const char* label) {
    load(h);
    uint16_t gx = rd(0x00), gy = rd(0x02), gs = rd(0x04);
    uint16_t wx = (uint16_t)compute_x(h);
    uint16_t wy = (uint16_t)compute_y(h);
    uint16_t ws = compute_status(h);
    if (gx != wx || gy != wy || gs != ws) {
        check(false, label);
        if (fails <= 12)
            printf("    x1=%u+%u x2=%u+%u  y1=%u+%u y2=%u+%u\n"
                   "    x %04x/%04x  y %04x/%04x  st %04x/%04x (got/want)\n",
                   h.x1p, h.x1s, h.x2p, h.x2s, h.y1p, h.y1s, h.y2p, h.y2s,
                   gx, wx, gy, wy, gs, ws);
    } else {
        check(true, label);
    }
    // Every register must read back what was written.
    check(rd(0x20) == h.x1p && rd(0x22) == h.x1s
       && rd(0x24) == h.y1p && rd(0x26) == h.y1s
       && rd(0x2c) == h.x2p && rd(0x2e) == h.x2s
       && rd(0x30) == h.y2p && rd(0x32) == h.y2s, "registers read back");
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vkaneko_hit;
    d->rst = 1; d->we = 0; d->uds = 1; d->lds = 1; d->rnd = 0x1234;
    tick(); tick();
    d->rst = 0; tick();

    // ---------------------------------------------------------------- 1
    // The three cases the oracle's own comment draws, with the rectangles it
    // draws them with. A fuzz that never hits "one inside the other" would
    // pass while that branch was wrong.
    printf("== the three overlap cases, by construction\n");
    one({100, 100,  50,  50, 110, 110,  10,  10}, "2 inside 1");
    one({110, 110,  10,  10, 100, 100,  50,  50}, "1 inside 2");
    one({100, 100,  50,  50, 130, 130,  50,  50}, "partial overlap");
    one({100, 100,  10,  10, 500, 500,  10,  10}, "no overlap, far apart");
    one({100, 100,  10,  10, 110, 110,  10,  10}, "touching exactly");
    one({  0,   0,   0,   0,   0,   0,   0,   0}, "all zero");

    // ---------------------------------------------------------------- 2
    // Small coordinates, exhaustively. This is where the boundary conditions
    // live -- p2 == p1, p2 == p1+s1-1, zero sizes -- and it is cheap enough to
    // cover completely rather than sample.
    printf("== exhaustive over small rectangles\n");
    for (uint16_t x1p = 0; x1p < 6; x1p++)
    for (uint16_t x1s = 0; x1s < 6; x1s++)
    for (uint16_t x2p = 0; x2p < 6; x2p++)
    for (uint16_t x2s = 0; x2s < 6; x2s++)
        one({x1p, 3, x1s, 4, x2p, 5, x2s, 6}, "small exhaustive");

    // ---------------------------------------------------------------- 3
    // Full 16-bit range, including the values that make p+s wrap past 65535.
    // MAME computes those in int, so they do NOT wrap there, and a 16-bit
    // adder in the RTL would disagree. That is the single most likely way to
    // get this device subtly wrong.
    printf("== full range, including sums past 65535\n");
    std::mt19937 rng(20260824u);
    for (int i = 0; i < 60000; i++) {
        Hit h;
        h.x1p = rng(); h.x1s = rng(); h.y1p = rng(); h.y1s = rng();
        h.x2p = rng(); h.x2s = rng(); h.y2p = rng(); h.y2s = rng();
        one(h, "random full range");
    }

    // Biased towards large positions, where p+s exceeds 16 bits often.
    printf("== biased to overflow the position-plus-size sum\n");
    for (int i = 0; i < 40000; i++) {
        Hit h;
        h.x1p = 0xf000 + (rng() & 0x0fff); h.x1s = rng();
        h.y1p = 0xf000 + (rng() & 0x0fff); h.y1s = rng();
        h.x2p = 0xf000 + (rng() & 0x0fff); h.x2s = rng();
        h.y2p = 0xf000 + (rng() & 0x0fff); h.y2s = rng();
        one(h, "overflow-biased");
    }

    // ---------------------------------------------------------------- 4
    printf("== the register at 0x38 is accepted and changes nothing\n");
    {
        Hit h{1000, 2000, 300, 400, 1100, 2100, 350, 450};
        load(h);
        uint16_t before = rd(0x04);
        wr(0x38, 0x0000);
        check(rd(0x04) == before, "0x38 does not disturb the result");
        check(rd(0x20) == h.x1p, "0x38 does not disturb the registers");
    }

    printf("== unmapped offsets read zero\n");
    for (uint8_t off : {0x06, 0x08, 0x10, 0x28, 0x34, 0x3a, 0x40, 0x7e})
        check(rd(off) == 0x0000, "unmapped reads zero");

    printf("== the random register is not stuck\n");
    {
        d->rnd = 0x0000; d->eval();
        uint16_t a = rd(0x14);
        d->rnd = 0xbeef; d->eval();
        uint16_t b = rd(0x14);
        check(a == 0x0000 && b == 0xbeef, "0x14 follows its source");
    }

    printf("\ntb_kaneko_hit: %ld checks, %ld fails\n", checks, fails);
    delete d;
    return fails ? 1 : 0;
}
