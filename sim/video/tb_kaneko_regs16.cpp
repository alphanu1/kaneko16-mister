// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// kaneko_regs16: sixteen registers, byte enables, and the flattened bank.
#include <cstdio>
#include <cstdint>
#include "Vkaneko_regs16.h"
#include "verilated.h"

namespace {
Vkaneko_regs16* dut;
int fails = 0, checks = 0;

void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

void ck(const char* what, uint32_t got, uint32_t want) {
    checks++;
    if (got != want) {
        fails++;
        std::printf("  FAIL %-40s got %04x want %04x\n", what, got, want);
    }
}

void wr(int a, uint16_t d, int uds, int lds) {
    dut->we = 1; dut->addr = a; dut->din = d; dut->uds = uds; dut->lds = lds;
    tick();
    dut->we = 0; tick();
}

uint16_t rd(int a) { dut->rd_addr = a; dut->eval(); return dut->rd_q; }

// regs_flat is 256 bits, presented by Verilator as an array of 32-bit words.
uint16_t flat(int i) {
    const uint32_t w = dut->regs_flat[i / 2];
    return (uint16_t)((i & 1) ? (w >> 16) : (w & 0xffff));
}
} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vkaneko_regs16;
    dut->we = 0; dut->uds = 0; dut->lds = 0; tick();

    // Every register is independently addressable — an address decode one bit
    // wrong shows up here and nowhere else until the picture is wrong.
    for (int a = 0; a < 16; a++) wr(a, (uint16_t)(0x1000 | (a * 0x111)), 1, 1);
    for (int a = 0; a < 16; a++) {
        char what[48];
        std::snprintf(what, sizeof what, "reg %d round-trips", a);
        ck(what, rd(a), (uint16_t)(0x1000 | (a * 0x111)));
    }

    // Byte enables. The 68000 writes single bytes — `move.b #$00,$900009` is
    // the very first store explbrkr's boot code makes — and a bank that
    // ignores them corrupts the half it was not asked to touch.
    wr(5, 0xaaaa, 1, 1);
    wr(5, 0x55ff, 1, 0);
    ck("upper byte only", rd(5), 0x55aa);
    wr(5, 0xff33, 0, 1);
    ck("lower byte only", rd(5), 0x5533);
    wr(5, 0x0000, 0, 0);
    ck("neither byte writes nothing", rd(5), 0x5533);

    // The flattened bank must agree with the read port, since the video side
    // uses one and the CPU the other.
    for (int a = 0; a < 16; a++) {
        char what[48];
        std::snprintf(what, sizeof what, "flat %d matches read port", a);
        ck(what, flat(a), rd(a));
    }

    // A write must not disturb its neighbours.
    wr(7, 0xbeef, 1, 1);
    ck("reg 6 untouched", rd(6), (uint16_t)(0x1000 | (6 * 0x111)));
    ck("reg 8 untouched", rd(8), (uint16_t)(0x1000 | (8 * 0x111)));

    std::printf("kaneko_regs16: checks=%d fails=%d\n", checks, fails);
    delete dut;
    return fails ? 1 : 0;
}
