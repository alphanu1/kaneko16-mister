// SPDX-License-Identifier: GPL-3.0-or-later
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// STREAM INTEGRITY: does a whole ROM image arrive in SDRAM byte for byte?
//
// The loader's entire design rests on one property — "stream layout IS the
// SDRAM layout", so stream byte N lands at SDRAM byte N with no per-region
// arithmetic anywhere. The inherited testbench proves the path moves data at
// all (6 checks, a boot-readback scenario). Nothing proved the property the
// design depends on.
//
// This feeds the real assembled explbrkr image — 5.75 MB, produced by
// tools/build_rom_regions.py --stream in the same order the MRA emits — and
// watches every SDRAM write the loader issues. It checks:
//
//   - every input word is written exactly once
//   - each lands at address (byte offset >> 1), the identity mapping
//   - no write appears that no input word asked for
//   - overflow never asserts, and rom_loaded does
//
// Backpressure is exercised on purpose, with the host continuing to send for
// several words after ioctl_wait asserts. That is what the HPS does — the
// signal asks the host to stop and everything already in flight still
// arrives — and it is the case the ported file records as having silently
// dropped words when the margin was too small.

#include "Vkaneko_romstream_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <random>

namespace {

Vkaneko_romstream_harness* dut;
long checks = 0, fails = 0;

std::vector<uint8_t> written;      // 1 per SDRAM word address seen
std::vector<uint16_t> got;         // data seen at that address
long n_writes = 0, n_dup = 0, n_stray = 0;
int ack_prev = 0;

std::vector<uint16_t> stream;      // the image, as 16-bit words

void tick()
{
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();

    // One transaction per rising edge of ack, matching the controller's
    // contract. Sampling the level would count a stretched ack many times.
    if (dut->dbg_wr_ack && !ack_prev) {
        const uint32_t a = dut->dbg_wr_addr;
        n_writes++;
        if (a >= written.size()) {
            n_stray++;
        } else if (written[a]) {
            n_dup++;
        } else {
            written[a] = 1;
            got[a] = dut->dbg_wr_din;
        }
    }
    ack_prev = dut->dbg_wr_ack;
}

} // namespace

int main(int argc, char** argv)
{
    Verilated::commandArgs(argc, argv);
    const char* path = (argc > 1) ? argv[1] : "build/roms/explbrkr_stream.bin";

    FILE* f = fopen(path, "rb");
    if (!f) { printf("kaneko_romstream: SKIP (no %s — run `make regions`)\n", path); return 0; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> raw(n);
    if (fread(raw.data(), 1, n, f) != (size_t)n) { printf("short read\n"); return 2; }
    fclose(f);

    stream.resize(n / 2);
    for (size_t i = 0; i < stream.size(); i++)
        stream[i] = (uint16_t)(raw[i * 2] | (raw[i * 2 + 1] << 8));

    written.assign(stream.size(), 0);
    got.assign(stream.size(), 0);

    dut = new Vkaneko_romstream_harness;
    dut->rst_n = 0; dut->rd_lat_sel = 0;
    dut->ioctl_download = 0; dut->ioctl_index = 0;
    dut->ioctl_wr = 0; dut->ioctl_addr = 0; dut->ioctl_dout = 0;
    for (int i = 0; i < 16; i++) tick();
    dut->rst_n = 1;

    long guard = 0;
    while (!dut->mem_ready && guard++ < 200000) tick();
    if (!dut->mem_ready) { printf("  FAIL controller never became ready\n"); return 1; }

    std::mt19937 rng(0x53545245u);   // 'STRE'
    dut->ioctl_download = 1;
    dut->ioctl_index = 0;

    long in_flight_budget = 0;
    long stalled_words = 0;

    for (size_t i = 0; i < stream.size(); i++) {
        // Honour ioctl_wait the way the HPS does: keep sending a few more
        // words, then hold off until it clears.
        if (dut->ioctl_wait) {
            if (in_flight_budget == 0) in_flight_budget = 4 + (rng() % 12);
            if (in_flight_budget > 0) {
                in_flight_budget--;
            } else {
                while (dut->ioctl_wait) { tick(); stalled_words++; }
            }
        } else {
            in_flight_budget = 0;
        }
        while (dut->ioctl_wait && in_flight_budget == 0) { tick(); stalled_words++; }

        dut->ioctl_addr = (uint32_t)(i * 2);
        dut->ioctl_dout = stream[i];
        dut->ioctl_wr = 1; tick();
        dut->ioctl_wr = 0;
        // A small random gap, so the loader is not only ever driven back to back.
        if ((rng() & 7) == 0) tick();
    }

    dut->ioctl_download = 0;
    tick();
    guard = 0;
    while (!dut->rom_loaded && guard++ < 5000000) tick();

    // ------------------------------------------------------------- checks
    auto ck = [&](const char* what, long a, long b) {
        checks++;
        if (a != b) { fails++; printf("  FAIL %s: got %ld want %ld\n", what, a, b); }
    };

    ck("rom_loaded", dut->rom_loaded, 1);
    ck("overflow",   dut->overflow, 0);
    ck("stray writes outside the image", n_stray, 0);
    ck("duplicate writes to one address", n_dup, 0);
    ck("writes issued", n_writes, (long)stream.size());

    long missing = 0, wrong = 0;
    for (size_t a = 0; a < stream.size(); a++) {
        if (!written[a]) { if (missing < 5) printf("  FAIL word %zu never written\n", a); missing++; }
        else if (got[a] != stream[a]) {
            if (wrong < 5) printf("  FAIL word %zu: sdram=%04x stream=%04x\n", a, got[a], stream[a]);
            wrong++;
        }
    }
    ck("words never written", missing, 0);
    ck("words written with wrong data", wrong, 0);

    printf("kaneko_romstream: image=%zu words (%.2f MB) writes=%ld checks=%ld fails=%ld "
           "stalled=%ld\n",
           stream.size(), n / 1048576.0, n_writes, checks, fails, stalled_words);

    dut->final();
    delete dut;
    return fails ? 1 : 0;
}
