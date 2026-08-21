// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// kaneko_tilerom: four byte ports served from one bursting SDRAM port.
//
// The reference is a plain byte array. What is being checked is that the
// caching and the stall protocol never hand a layer the wrong byte — a tile
// feeder that is right most of the time produces a picture that is wrong in a
// way no one can attribute.
#include <cstdio>
#include <cstdint>
#include <vector>
#include <random>
#include "Vkaneko_tilerom_harness.h"
#include "verilated.h"

namespace {

Vkaneko_tilerom_harness* dut;
std::vector<uint8_t> rom;
long checks = 0, fails = 0, bursts = 0, stall_cycles = 0;

// Four deliberately unhelpful SDRAM ports, one per layer, each with its own
// latency so the feeder cannot depend on them answering in step. They are
// independent because the controller's ports are: that overlap is the whole
// reason for giving each layer its own.
int      lat[4]   = {0, 0, 0, 0};
bool     pend[4]  = {false, false, false, false};
uint32_t paddr[4] = {0, 0, 0, 0};

uint32_t req_addr_of(int g) {
    switch (g) {
        case 0: return dut->sdr_addr0; case 1: return dut->sdr_addr1;
        case 2: return dut->sdr_addr2; default: return dut->sdr_addr3;
    }
}
void set_dout(int g, uint64_t v) {
    switch (g) {
        case 0: dut->sdr_dout0 = v; break; case 1: dut->sdr_dout1 = v; break;
        case 2: dut->sdr_dout2 = v; break; default: dut->sdr_dout3 = v; break;
    }
}

void sdram_step() {
    uint32_t ack = 0;
    for (int g = 0; g < 4; g++) {
        if (!pend[g] && ((dut->sdr_req >> g) & 1)) {
            pend[g] = true; paddr[g] = req_addr_of(g);
            lat[g] = 5 + (int)((paddr[g] + g * 3) % 7);
            bursts++;
        } else if (pend[g] && --lat[g] <= 0) {
            // Word address -> byte address; SDRAM word n holds file byte 2n in
            // its low half, so a burst is eight consecutive bytes.
            const uint64_t b = (uint64_t)paddr[g] * 2;
            uint64_t v = 0;
            for (int k = 0; k < 8; k++)
                v |= (uint64_t)rom[(b + k) % rom.size()] << (8 * k);
            set_dout(g, v);
            ack |= 1u << g;
            pend[g] = false;
        }
    }
    dut->sdr_ack = ack;
}

void tick() {
    sdram_step();
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

void ck(const char* what, uint32_t got, uint32_t want) {
    checks++;
    if (got != want && fails < 10) {
        fails++;
        std::printf("  FAIL %-38s got %02x want %02x\n", what, got, want);
    } else if (got != want) fails++;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // Fixed seed so counts are reproducible and do not drift with the host.
    std::mt19937 rng(0xA5A51234u);
    rom.resize(1 << 18);
    for (auto& b : rom) b = (uint8_t)rng();

    dut = new Vkaneko_tilerom_harness;
    dut->rst = 1; dut->sdr_ack = 0;
    dut->base0 = 0; dut->base1 = 0; dut->base2 = 0; dut->base3 = 0;
    dut->a0 = dut->a1 = dut->a2 = dut->a3 = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->rst = 0;

    // Four layers walking their own regions, the way the pipeline does: one
    // byte per pixel, sequential within a tile row, jumping between rows.
    uint32_t base[4] = {0x00000, 0x08000, 0x10000, 0x18000};
    uint32_t addr[4] = {0, 0, 0, 0};

    for (int pixel = 0; pixel < 60000; pixel++) {
        for (int L = 0; L < 4; L++) {
            // Mostly sequential, occasionally a jump — a new tile row.
            if ((rng() % 23) == 0) addr[L] = rng() % 0x7000;
            else                   addr[L] = (addr[L] + 1) % 0x7000;
        }
        dut->a0 = base[0] + addr[0]; dut->a1 = base[1] + addr[1];
        dut->a2 = base[2] + addr[2]; dut->a3 = base[3] + addr[3];
        dut->eval();

        // Stall until every port has its byte, exactly as the core will.
        int guard = 0;
        while (dut->port_ready != 0xf && guard++ < 500) { tick(); stall_cycles++; }
        if (guard >= 500) { std::printf("  FAIL feeder never became ready\n"); fails++; break; }

        ck("layer 0 byte", dut->d0, rom[(base[0] + addr[0]) % rom.size()]);
        ck("layer 1 byte", dut->d1, rom[(base[1] + addr[1]) % rom.size()]);
        ck("layer 2 byte", dut->d2, rom[(base[2] + addr[2]) % rom.size()]);
        ck("layer 3 byte", dut->d3, rom[(base[3] + addr[3]) % rom.size()]);
        tick();
    }

    // A hit must cost nothing: re-presenting the same addresses issues no
    // burst at all. If it does, the cache is not caching and the bandwidth
    // estimate this design rests on is wrong.
    const long before = bursts;
    for (int i = 0; i < 200; i++) { tick(); }
    ck("no burst while addresses are unchanged", (uint32_t)(bursts - before), 0);

    std::printf("kaneko_tilerom: checks=%ld fails=%ld bursts=%ld stall_cycles=%ld\n",
                checks, fails, bursts, stall_cycles);
    std::printf("                %.2f bursts/pixel across 4 layers "
                "(one per 8 bytes would be 0.50)\n", (double)bursts / 60000.0);
    delete dut;
    return fails ? 1 : 0;
}
