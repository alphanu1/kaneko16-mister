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

// Bus trace, in the format tools/mame_bus_trace.lua emits, so the two can be
// diffed directly rather than eyeballed. Written only when --trace is given.
static FILE*    trace_fp    = nullptr;
static uint64_t trace_limit = 0;
static uint64_t trace_n     = 0;

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
    uint64_t iack[8] = {0};
    uint64_t iack_total = 0;
    uint64_t first_iack_tick = 0;
};


// Reset, bring up the SDRAM, and stream the program region in exactly as the
// HPS would. Split out of run() so the interrupt-acknowledge check can get a
// booted machine without also taking over the observation loop.
static bool boot_dut(const std::vector<uint8_t>& rom, bool swap, bool video_idle,
                     int lat, size_t limit_bytes)
{
    tick_count = 0;
    dut->rst = 1;
    dut->ioctl_download = 0; dut->ioctl_index = 0; dut->ioctl_wr = 0;
    dut->ioctl_addr = 0; dut->ioctl_dout = 0;
    dut->video_idle = video_idle;
    dut->rd_lat_sel = lat;
    dut->ipl_force  = 0;
    for (int i = 0; i < 32; i++) tick();
    dut->rst = 0;

    uint64_t guard = 0;
    while (!dut->mem_ready && guard < 200000) { tick(); guard++; }
    if (!dut->mem_ready) { std::printf("  SDRAM never became ready\n"); return false; }

    // The latency sweep only needs the reset vectors and the first few
    // instructions, so it streams a prefix — a full 512 KB load is 7.3 M ticks
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
    if (!dut->rom_loaded) { std::printf("  rom_loaded never asserted\n"); return false; }
    std::printf("  ROM loaded after %llu ticks\n", (unsigned long long)tick_count);
    return true;
}

// Run the whole sequence for one packing. swap=false is what the HPS really
// does; swap=true is what sim/cpu assumed.
static Stats run(const std::vector<uint8_t>& rom, bool swap, bool verbose,
                 bool video_idle, uint64_t run_ticks, int lat,
                 size_t limit_bytes)
{
    Stats st;
    if (!boot_dut(rom, swap, video_idle, lat, limit_bytes)) return st;

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
            if (trace_fp && trace_n < trace_limit) {
                // MAME reports the value on the bus and the lanes as a mask;
                // a read takes iEdb, a write takes oEdb.
                const bool rd = dut->cpu_rw;
                const uint16_t val = rd ? dut->cpu_din : dut->cpu_dout;
                const uint16_t msk = (uint16_t)((dut->cpu_uds ? 0xff00 : 0) |
                                                (dut->cpu_lds ? 0x00ff : 0));
                std::fprintf(trace_fp, "%06x %s %04x %04x\n",
                             a, rd ? "R" : "W", val, msk);
                trace_n++;
            }
            if (vec.size() < 4 && a < 8) vec.push_back(d);
            if (verbose && shown < 24) {
                std::printf("    %-6s %06X = %04X\n",
                            dut->cpu_rw ? "read" : "write", a, d);
                shown++;
            }
        }
        // Interrupt acknowledge: FC = 7. The level is on A3:A1. This is the
        // only end-to-end check that kaneko_irq, fx68k's VPAn autovectoring
        // and kaneko_bus's cpu_space gating actually work together — the unit
        // test covers the generator alone.
        {
            static int p_iack = 0;
            const int ia = dut->cpu_iack;
            if (ia && !p_iack) {
                const unsigned lvl = (unsigned)dut->cpu_addr & 7u;
                st.iack[lvl]++;
                st.iack_total++;
                if (!st.first_iack_tick) st.first_iack_tick = tick_count - start;
            }
            p_iack = ia;
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
    if (s.iack_total) {
        std::printf("    interrupts      %llu taken (IRQ5 %llu, IRQ4 %llu, IRQ3 %llu),"
                    " first at tick %llu\n",
                    (unsigned long long)s.iack_total,
                    (unsigned long long)s.iack[5], (unsigned long long)s.iack[4],
                    (unsigned long long)s.iack[3],
                    (unsigned long long)s.first_iack_tick);
    } else {
        std::printf("    interrupts      none taken\n");
    }
    if (s.unmapped)
        std::printf("    unmapped        %llu, first at %06X\n",
                    (unsigned long long)s.unmapped, s.first_unmapped);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    const char* path = "build/roms/explbrkr_maincpu.bin";
    const char* trace_path = nullptr;
    uint64_t    trace_count = 20000;
    uint64_t    run_ticks_override = 0;
    for (int i = 1; i < argc; i++) {
        if (!std::strcmp(argv[i], "--trace") && i + 1 < argc) trace_path = argv[++i];
        else if (!std::strcmp(argv[i], "--count") && i + 1 < argc)
            trace_count = std::strtoull(argv[++i], nullptr, 0);
        else if (!std::strcmp(argv[i], "--ticks") && i + 1 < argc)
            run_ticks_override = std::strtoull(argv[++i], nullptr, 0);
        else if (argv[i][0] != '-') path = argv[i];
    }
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
    if (trace_path) {
        trace_fp = std::fopen(trace_path, "w");
        if (!trace_fp) { std::fprintf(stderr, "cannot write %s\n", trace_path); return 2; }
        trace_limit = trace_count;
        trace_n = 0;
    }
    // A trace of N accesses needs a run long enough to make them. Bus cycles
    // land roughly one per 32 ticks here, so allow a wide margin.
    uint64_t run_a = trace_path ? (RUN + trace_count * 64) : RUN;
    if (run_ticks_override) run_a = run_ticks_override;
    Stats a = run(rom, false, !trace_path, false, run_a, good_lat, 0);
    report("result", a, run_a);
    delete dut;
    if (trace_fp) {
        std::fclose(trace_fp); trace_fp = nullptr;
        std::printf("  bus trace: %llu accesses -> %s\n",
                    (unsigned long long)trace_n, trace_path);
    }
    std::printf("\n");

    // -------------------------------------------- interrupt acknowledge path
    // Level 7 is non-maskable, so this fires even though explbrkr is still
    // masking at 7. What it proves is the wiring: fx68k raising a CPU-space
    // cycle, kaneko_irq answering with VPA, kaneko_bus keeping out of it, and
    // the CPU autovectoring through 0x7c instead of hanging or taking a
    // vectored interrupt off whatever the read mux was driving.
    std::printf("== C: interrupt acknowledge path (forced level 7)\n");
    dut = new Vkaneko_cpumem_harness;
    {
        if (!boot_dut(rom, false, true, good_lat, 0)) return 2;
        uint64_t acks = 0, vec_reads = 0;
        int p_ia = 0;
        dut->ipl_force = 7;
        for (uint64_t t = 0; t < 2000000; t++) {
            tick();
            if (dut->cpu_iack && !p_ia) {
                acks++;
                if (((unsigned)dut->cpu_addr & 7u) != 7u) {
                    std::printf("  acknowledge for level %u, expected 7\n",
                                (unsigned)dut->cpu_addr & 7u);
                    fails++;
                }
            }
            p_ia = dut->cpu_iack;
            // Autovector 31 lives at 0x7c; the CPU reads the handler address
            // from there after acknowledging.
            if (dut->cpu_dtack && dut->cpu_rw) {
                const uint32_t a = (uint32_t)dut->cpu_addr << 1;
                if (a == 0x00007c || a == 0x00007e) vec_reads++;
            }
        }
        std::printf("    acknowledges    %llu\n", (unsigned long long)acks);
        std::printf("    vector 0x7c/7e  %llu reads\n",
                    (unsigned long long)vec_reads);
        if (!acks)      { std::printf("  no acknowledge: the IPL never reached the CPU\n"); fails++; }
        if (!vec_reads) { std::printf("  acknowledged but never autovectored: VPAn is not working\n"); fails++; }
        dut->ipl_force = 0;
    }
    delete dut;
    std::printf("\n");

    std::printf("== B: byte-swapped packing (byte n -> dout[15:8])\n");
    dut = new Vkaneko_cpumem_harness;
    Stats b = run(rom, true, !trace_path && !run_ticks_override, false,
                  RUN, good_lat, 0);
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
