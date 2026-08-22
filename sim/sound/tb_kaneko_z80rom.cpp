// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The Z80 program ROM, driven from where the LOADER would be and read from
// where the Z80 would be.
//
// The three things that can go wrong here all produce a ROM of exactly the
// right size, so none of them is visible without reading the contents back:
//
//   1. the byte halves swapped        -- every opcode becomes its neighbour
//   2. the window offset by one word  -- the whole ROM shifts two bytes
//   3. the window catching writes that belong to another region, or missing
//      the first/last word of its own
//
// So this fills the region, surrounds it with data that must NOT land, and
// checks every one of the 49152 bytes.
#include <cstdio>
#include <cstdint>
#include <vector>
#include "Vkaneko_z80rom.h"
#include "verilated.h"

namespace {

Vkaneko_z80rom* d;
long checks = 0, fails = 0;

void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; if (fails <= 12) printf("  FAIL: %s\n", what); }
}

void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

// The loader's SDRAM write port: a word address and a 16-bit word.
void ld(uint32_t waddr, uint16_t din) {
    d->ld_wr = 1; d->ld_addr = waddr; d->ld_din = din;
    tick();
    d->ld_wr = 0;
    tick();
}

uint8_t rd(uint16_t a) {
    d->rom_addr = a;
    tick();          // address registered, data and byte-select land together
    tick();
    return d->rom_data;
}

// The byte a given stream position must end up as. Deliberately not a
// constant and not a ramp: a ramp with period 256 cannot tell an offset of
// 256 bytes from no offset at all.
uint8_t want(uint32_t byte_off) {
    return (uint8_t)(byte_off * 7 + (byte_off >> 8) * 31 + 5);
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vkaneko_z80rom;

    const uint32_t BYTES = 0xC000;
    const uint32_t WORDS = BYTES / 2;
    // A base that is NOT zero and not aligned to the region size, because both
    // of those hide an offset bug. This is Blaze On's real one: audiocpu sits
    // at SDRAM byte 0x400000, and the loader carries word addresses.
    const uint32_t BASE  = 0x400000 / 2;

    d->base = BASE;
    d->ld_wr = 0; d->rom_addr = 0;
    tick(); tick();

    // ---- data that must NOT land: the words immediately below the window,
    // and immediately above it. Off-by-one in either direction is caught by
    // the content check, because these carry a value no in-window byte has.
    for (uint32_t w = 0; w < 8; w++) ld(BASE - 8 + w, 0xDEAD);
    for (uint32_t w = 0; w < 8; w++) ld(BASE + WORDS + w, 0xDEAD);

    // ---- fill. byte[A] (even) is the LOW half, byte[A+1] the high half.
    for (uint32_t w = 0; w < WORDS; w++) {
        uint16_t word = (uint16_t)(want(w * 2 + 1) << 8) | want(w * 2);
        ld(BASE + w, word);
    }

    // ---- read every byte back
    long bad = 0;
    for (uint32_t b = 0; b < BYTES; b++) {
        uint8_t got = rd((uint16_t)b);
        if (got != want(b)) {
            if (bad < 8)
                printf("  FAIL: byte %04x = %02x, want %02x\n", b, got, want(b));
            bad++;
        }
    }
    checks += BYTES;
    fails  += bad;
    if (!bad) printf("  all %u bytes match, byte order included\n", BYTES);

    // ---- a write below the base must not wrap into the window. `off` is an
    // unsigned subtraction, so a bare `off < WORDS` without the `>= base`
    // guard lets addresses just under the base land near the top of the ROM.
    ld(BASE - 1, 0x1234);
    ld(BASE - 2, 0x1234);
    check(rd(BYTES - 2) == want(BYTES - 2), "a write below base did not wrap in (low byte)");
    check(rd(BYTES - 1) == want(BYTES - 1), "a write below base did not wrap in (high byte)");

    // ---- the boundaries themselves
    check(rd(0) == want(0),               "first byte");
    check(rd(1) == want(1),               "second byte, the odd half of word 0");
    check(rd(BYTES - 1) == want(BYTES - 1), "last byte");

    // ---- a second game's base. Wing Force puts audiocpu somewhere else
    // entirely, and the base is a runtime input, not a parameter.
    const uint32_t BASE2 = 0x580000 / 2;
    d->base = BASE2;
    ld(BASE2 + 3, 0xBEEF);
    check(rd(6) == 0xEF, "re-based load, low byte");
    check(rd(7) == 0xBE, "re-based load, high byte");
    // and the old base must now be inert
    ld(BASE + 4, 0x4321);
    check(rd(8) == want(8), "the previous base no longer writes");

    printf("\ntb_kaneko_z80rom: %ld checks, %ld fails\n", checks, fails);
    delete d;
    return fails ? 1 : 0;
}
