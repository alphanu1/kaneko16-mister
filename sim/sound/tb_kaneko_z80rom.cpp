// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The Z80 program ROM cache, driven from where the Z80 would be and answered
// from a model of the SDRAM port.
//
// This replaces a test of the block-RAM copy that used to live here. The copy
// cost 48 M10K blocks the device does not have; see the header of
// kaneko_z80rom.sv. The failure modes are different now and mostly WORSE,
// because a cache can return the right byte for the wrong reason:
//
//   1. byte lane within the burst wrong -- every opcode becomes its neighbour
//   2. tag too narrow, or index and tag overlapping -- two different addresses
//      alias to one line and the second read returns the first one's data,
//      which only shows up once the working set exceeds the cache
//   3. the fill writing the line but not the tag, or the tag but not valid --
//      a permanent miss, so it still works and merely runs slowly
//   4. rom_ready high on the cycle of a miss -- the caller does not stall, the
//      Z80 executes a stale byte, and nothing here would notice unless ready
//      is checked on every access rather than only on the ones that fill
//   5. the burst address not four-word aligned -- the controller's contract,
//      and the model asserts on it
//
// So: every one of the 49152 bytes is read back, in an order chosen to force
// eviction and re-fill, with ready checked on every single access.
#include <cstdio>
#include <cstdint>
#include <vector>
#include "Vkaneko_z80rom.h"
#include "verilated.h"

namespace {

Vkaneko_z80rom* d;
long checks = 0, fails = 0;
long fills  = 0;               // SDRAM bursts served

void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; if (fails <= 12) printf("  FAIL: %s\n", what); }
}

// The audiocpu region as it sits in SDRAM, plus guard data on either side that
// must never be returned.
constexpr uint32_t BASE_W = 0x200000;      // word address, four-word aligned
constexpr int      BYTES  = 0xC000;        // 48 KB

std::vector<uint8_t> rom;                  // what the region holds, by byte

uint8_t rom_byte(int i) { return rom[i]; }

void tick() {
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
}

// One SDRAM port cycle. The controller answers a burst-aligned word address
// with four words; the model checks alignment and range rather than trusting
// them, because a cache that asks for the wrong line and is answered anyway
// looks identical to one that works.
void sdram_service() {
    if (!d->p_req) { d->p_ack = 0; return; }

    uint32_t wa = d->p_addr;
    check((wa & 3) == 0, "burst address is four-word aligned");
    check(wa >= BASE_W, "burst address is not below the region");

    uint32_t byte_off = (wa - BASE_W) * 2;
    uint64_t line = 0;
    for (int k = 0; k < 8; k++) {
        uint32_t bi = byte_off + k;
        uint8_t v = (bi < (uint32_t)BYTES) ? rom_byte(bi) : 0xA5;
        line |= (uint64_t)v << (8 * k);
    }
    d->p_dout = line;
    d->p_ack  = 1;
    fills++;
    tick();
    d->p_ack = 0;
}

// Read one byte the way the core will: hold the address with rom_rd asserted,
// let the cache fill if it must, and only accept the byte once ready is high.
// Returns the byte; records whether it stalled.
uint8_t read_byte(uint16_t addr, bool* stalled) {
    d->rom_addr = addr;
    d->rom_rd   = 1;
    d->eval();

    int guard = 0;
    *stalled = false;
    while (!d->rom_ready) {
        *stalled = true;
        sdram_service();
        if (!d->p_req && !d->rom_ready) tick();
        d->eval();
        if (++guard > 200) { check(false, "cache made progress within 200 cycles"); break; }
    }
    uint8_t v = d->rom_data;
    d->rom_rd = 0;
    d->eval();
    return v;
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vkaneko_z80rom;

    // Content that makes a lane or offset error visible: every byte differs
    // from its neighbours and from the byte one line away.
    rom.resize(BYTES);
    for (int i = 0; i < BYTES; i++)
        rom[i] = (uint8_t)((i * 7) ^ (i >> 5) ^ (i >> 11));

    d->rst = 1; d->base = BASE_W; d->rom_rd = 0; d->rom_addr = 0;
    d->p_ack = 0; d->p_dout = 0;
    tick(); tick();
    d->rst = 0;
    tick();

    // ---- 1. every byte, ascending. Sequential fetching is what the Z80
    // actually does, and it should miss once per eight bytes and no more.
    printf("== sequential read of the whole 48 KB\n");
    long seq_stalls = 0;
    for (int i = 0; i < BYTES; i++) {
        bool st;
        uint8_t got = read_byte((uint16_t)i, &st);
        if (st) seq_stalls++;
        if (got != rom_byte(i)) {
            check(false, "sequential byte matches");
            if (fails <= 12)
                printf("    addr %04x got %02x want %02x\n", i, got, rom_byte(i));
        } else {
            check(true, "sequential byte matches");
        }
    }
    printf("   %ld stalls over %d bytes, %ld bursts\n", seq_stalls, BYTES, fills);
    // One miss per 8-byte line and not one more: a cache that re-fetches a line
    // it already holds still returns correct data and would pass every byte
    // check above while running eight times slower on hardware.
    check(seq_stalls == BYTES / 8, "sequential misses exactly once per line");

    // ---- 2. re-read the last 256 bytes. They are still resident, so a
    // correct cache answers every one without a single burst.
    printf("== re-read of a resident window\n");
    long before = fills;
    for (int i = BYTES - 256; i < BYTES; i++) {
        bool st;
        uint8_t got = read_byte((uint16_t)i, &st);
        check(got == rom_byte(i), "resident byte matches");
        check(!st, "resident byte does not stall");
    }
    check(fills == before, "resident window issues no bursts");

    // ---- 3. aliasing. Two addresses one cache-size apart map to the same
    // line, which is the case a too-narrow tag gets wrong. Alternate between
    // them and demand the right byte every time.
    printf("== alternating addresses that share a line\n");
    const int span = 32 * 8;                    // LINES * 8, one whole cache
    for (int rep = 0; rep < 64; rep++) {
        for (int k = 0; k < 8; k++) {
            int a = 0x1000 + k;
            int b = 0x1000 + k + span;
            bool st;
            check(read_byte((uint16_t)a, &st) == rom_byte(a), "alias A byte");
            check(read_byte((uint16_t)b, &st) == rom_byte(b), "alias B byte");
        }
    }

    // ---- 4. descending walk, which defeats any prefetch assumption and
    // exercises the fill path from the other direction.
    printf("== descending walk\n");
    for (int i = BYTES - 1; i >= BYTES - 2048; i--) {
        bool st;
        uint8_t got = read_byte((uint16_t)i, &st);
        check(got == rom_byte(i), "descending byte matches");
    }

    printf("\ntb_kaneko_z80rom: %ld checks, %ld fails, %ld bursts\n",
           checks, fails, fills);
    delete d;
    return fails ? 1 : 0;
}
