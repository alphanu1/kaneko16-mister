// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// 68000 booting out of the real memory system: loader, arbiter, SDRAM model.
//
// The point of this test is the packing question. hps_io in WIDE mode puts
// file byte n in ioctl_dout[7:0] and byte n+1 in [15:8]; the 68000's ROM is
// big-endian, byte n being the HIGH half of the word. sim/cpu fed the CPU
// big-endian words straight from the file and never went through the loader,
// so the two conventions never met. This runs both and prints the difference.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include "Vkaneko_cpumem_harness.h"
#include "verilated.h"

static Vkaneko_cpumem_harness* dut;
static uint64_t tick_count = 0;

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    tick_count++;
}

struct Stats {
    uint64_t as_edges = 0, dtack_edges = 0, req_edges = 0, ack_edges = 0;
    uint64_t last_dtack_tick = 0;
    uint32_t reset_ssp = 0, reset_pc = 0;
    bool     got_vectors = false;
    uint64_t unmapped = 0;
    uint32_t first_unmapped = 0;
};

// Run the whole sequence for one packing. swap=false is what the HPS really
// does; swap=true is what sim/cpu assumed.
static Stats run(const std::vector<uint8_t>& rom, bool swap, bool verbose,
                 bool video_idle, uint64_t run_ticks, int lat,
                 size_t limit_bytes)
{
    Stats st;
    tick_count = 0;

    dut->rst = 1;
    dut->ioctl_download = 0; dut->ioctl_index = 0; dut->ioctl_wr = 0;
    dut->ioctl_addr = 0; dut->ioctl_dout = 0;
    dut->video_idle = video_idle;
    dut->rd_lat_sel = lat;
    for (int i = 0; i < 32; i++) tick();
    dut->rst = 0;

    // JEDEC bring-up.
    uint64_t guard = 0;
    while (!dut->mem_ready && guard < 200000) { tick(); guard++; }
    if (!dut->mem_ready) { std::printf("  SDRAM never became ready\n"); return st; }

    // Stream the maincpu region, honouring ioctl_wait exactly as the HPS must.
    // The latency sweep only needs the reset vectors and the first few
    // instructions, so it streams a prefix — a full 512 KB load is 6.8 M ticks
    // and doing it eight times to answer a four-way question is waste.
    size_t bytes = limit_bytes && limit_bytes < rom.size() ? limit_bytes : rom.size();
    const size_t words = bytes / 2;
    dut->ioctl_download = 1;
    dut->ioctl_index = 0;
    for (size_t n = 0; n < words; n++) {
        while (dut->ioctl_wait) tick();
        uint8_t b0 = rom[n * 2], b1 = rom[n * 2 + 1];
        dut->ioctl_addr = (uint32_t)(n * 2);
        dut->ioctl_dout = swap ? (uint16_t)((b0 << 8) | b1)
                               : (uint16_t)(b0 | (b1 << 8));
        dut->ioctl_wr = 1; tick();
        dut->ioctl_wr = 0; tick();
    }
    dut->ioctl_download = 0;

    guard = 0;
    while (!dut->rom_loaded && guard < 200000) { tick(); guard++; }
    if (!dut->rom_loaded) { std::printf("  rom_loaded never asserted\n"); return st; }
    std::printf("  ROM loaded after %llu ticks\n", (unsigned long long)tick_count);

    // ------------------------------------------------------------- observe
    int p_as = 0, p_dt = 0, p_rq = 0, p_ak = 0;
    uint64_t start = tick_count;
    int shown = 0;
    std::vector<uint16_t> vec;

    while (tick_count - start < run_ticks) {
        tick();
        int as = dut->cpu_as, dt = dut->cpu_dtack;
        int rq = dut->rom_req, ak = dut->rom_ack;

        if (as && !p_as) st.as_edges++;
        if (rq && !p_rq) st.req_edges++;
        if (ak && !p_ak) st.ack_edges++;
        if (dt && !p_dt) {
            st.dtack_edges++;
            st.last_dtack_tick = tick_count;
            uint32_t a = (uint32_t)dut->cpu_addr << 1;
            uint16_t d = dut->cpu_din;
            if (vec.size() < 4 && a < 8) vec.push_back(d);
            if (verbose && shown < 24) {
                std::printf("    %-6s %06X = %04X\n",
                            dut->cpu_rw ? "read" : "write", a, d);
                shown++;
            }
        }
        if (dut->unmapped_hit) {
            if (!st.unmapped) st.first_unmapped = (uint32_t)dut->unmapped_addr << 1;
            st.unmapped++;
        }
        p_as = as; p_dt = dt; p_rq = rq; p_ak = ak;
    }

    if (vec.size() >= 4) {
        st.reset_ssp = ((uint32_t)vec[0] << 16) | vec[1];
        st.reset_pc  = ((uint32_t)vec[2] << 16) | vec[3];
        st.got_vectors = true;
    }
    st.last_dtack_tick = st.last_dtack_tick ? (st.last_dtack_tick - start) : 0;
    return st;
}

static uint32_t bswap32(uint32_t v) {
    return ((v & 0x00ff00ffu) << 8) | ((v & 0xff00ff00u) >> 8);
}

static void report(const char* name, const Stats& s, uint64_t run_ticks) {
    std::printf("  %s\n", name);
    std::printf("    AS cycles       %llu\n", (unsigned long long)s.as_edges);
    std::printf("    DTACKs          %llu\n", (unsigned long long)s.dtack_edges);
    std::printf("    ROM req / ack   %llu / %llu\n",
                (unsigned long long)s.req_edges, (unsigned long long)s.ack_edges);
    if (s.got_vectors)
        std::printf("    reset SSP/PC    %08X / %08X\n", s.reset_ssp, s.reset_pc);
    std::printf("    last DTACK at   %llu of %llu ticks%s\n",
                (unsigned long long)s.last_dtack_tick,
                (unsigned long long)run_ticks,
                (s.last_dtack_tick && s.last_dtack_tick < run_ticks * 9 / 10)
                    ? "   <-- CPU STOPPED" : "");
    if (s.unmapped)
        std::printf("    unmapped        %llu, first at %06X\n",
                    (unsigned long long)s.unmapped, s.first_unmapped);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    const char* path = (argc > 1) ? argv[1] : "build/roms/explbrkr_maincpu.bin";
    FILE* f = std::fopen(path, "rb");
    if (!f) { std::fprintf(stderr, "cannot open %s\n", path); return 2; }
    std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> rom((size_t)n);
    if (std::fread(rom.data(), 1, (size_t)n, f) != (size_t)n) return 2;
    std::fclose(f);

    const uint32_t want_ssp = ((uint32_t)rom[0] << 24) | ((uint32_t)rom[1] << 16)
                            | ((uint32_t)rom[2] << 8)  | rom[3];
    const uint32_t want_pc  = ((uint32_t)rom[4] << 24) | ((uint32_t)rom[5] << 16)
                            | ((uint32_t)rom[6] << 8)  | rom[7];
    std::printf("ROM %s (%ld bytes)\n", path, n);
    std::printf("  file reset vectors: SSP %08X  PC %08X\n\n", want_ssp, want_pc);

    int fails = 0;

    // ------------------------------------------------- read capture depth
    // The controller's capture point is run-time selectable and the two
    // machines disagree: the board wants CL+1 (sel 0) on the evidence of a
    // write-then-read self-test, the device model wants CL+3 (sel 3). Find the
    // one this model needs before drawing any conclusion about byte order,
    // because a wrong capture depth returns zeros and zeros look like every
    // other failure.
    std::printf("== read capture depth sweep (HPS packing, 8 KB prefix)\n");
    int good_lat = -1;
    for (int lat = 0; lat < 4; lat++) {
        dut = new Vkaneko_cpumem_harness;
        Stats s = run(rom, false, false, true, 60000, lat, 8192);
        std::printf("  sel %d -> SSP %08X  PC %08X  DTACKs %llu\n",
                    lat, s.reset_ssp, s.reset_pc,
                    (unsigned long long)s.dtack_edges);
        if (s.got_vectors && (s.reset_ssp == want_ssp || s.reset_ssp == bswap32(want_ssp)))
            good_lat = lat;
        delete dut;
    }
    if (good_lat < 0) {
        std::printf("  no capture depth returned the ROM's reset vectors.\n");
        std::printf("\nFAIL\n");
        return 1;
    }
    std::printf("  model needs sel %d\n\n", good_lat);

    const uint64_t RUN = 2000000;   // ~42 ms at 48 MHz, two and a half frames

    std::printf("== A: HPS packing (byte n -> dout[7:0]), video port hammering\n");
    dut = new Vkaneko_cpumem_harness;
    Stats a = run(rom, false, true, false, RUN, good_lat, 0);
    report("result", a, RUN);
    delete dut;
    std::printf("\n");

    std::printf("== B: byte-swapped packing (byte n -> dout[15:8])\n");
    dut = new Vkaneko_cpumem_harness;
    Stats b = run(rom, true, true, false, RUN, good_lat, 0);
    report("result", b, RUN);
    delete dut;
    std::printf("\n");

    // ------------------------------------------------------------ verdict
    std::printf("== verdict\n");
    const bool a_ok = a.got_vectors && a.reset_ssp == want_ssp && a.reset_pc == want_pc;
    const bool b_ok = b.got_vectors && b.reset_ssp == want_ssp && b.reset_pc == want_pc;
    const Stats& good = b_ok ? b : a;

    if (b_ok && !a_ok) {
        std::printf("  The 68000 needs the bytes the other way round. Packing A is\n"
                    "  what hps_io delivers in WIDE mode and it produced SSP %08X\n"
                    "  PC %08X instead of %08X / %08X. The ROM path needs a\n"
                    "  byte swap that is not there.\n",
                    a.reset_ssp, a.reset_pc, want_ssp, want_pc);
        fails++;
    } else if (a_ok) {
        std::printf("  Packing A (real HPS order) boots: SSP %08X PC %08X.\n",
                    a.reset_ssp, a.reset_pc);
    } else {
        std::printf("  Neither packing produced the file's reset vectors\n"
                    "  (A %08X/%08X, B %08X/%08X).\n",
                    a.reset_ssp, a.reset_pc, b.reset_ssp, b.reset_pc);
        fails++;
    }

    if (good.dtack_edges == 0) {
        std::printf("  No bus cycles at all in the better run.\n");
        fails++;
    } else if (good.last_dtack_tick && good.last_dtack_tick < RUN * 9 / 10) {
        std::printf("  Bus went quiet at tick %llu and never resumed: the 68000\n"
                    "  executed STOP, or is spinning without fetching.\n",
                    (unsigned long long)good.last_dtack_tick);
        fails++;
    }

    std::printf("\n%s\n", fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
