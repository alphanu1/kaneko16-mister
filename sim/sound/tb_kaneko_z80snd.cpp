// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The Blaze On board's Z80 sound subsystem, driven from where the Z80 would be.
//
// T80 is not simulated — it is VHDL, and it is also not what needs testing.
// What needs testing is the decode, the latch and its NMI, all read from
// MAME's blazeon_soundmem / blazeon_soundport rather than assumed.
#include <cstdio>
#include <cstdint>
#include "Vkaneko_z80snd.h"
#include "verilated.h"

namespace {

Vkaneko_z80snd* d;
long checks = 0, fails = 0;
int  ce_div = 0;

// Deliveries the YM2151 would actually latch. jt51 forms
// `write = !cs_n && !wr_n` and samples it at the RISING EDGE with cen_p1 as
// the enable, so the values that matter are the ones settled before the edge,
// not after it. Counting after the edge reads a write that was taken as if it
// never happened -- which it does, because taking it releases the request.
long ym_deliv = 0;
uint8_t ym_deliv_din = 0;
int     ym_deliv_a0  = -1;

void tick(int n = 1) {
    for (int i = 0; i < n; i++) {
        d->ym_ce = (ce_div == 0);   // free-running; the CPU's stall never gates it
        ce_div = (ce_div + 1) % 12;      // 48 MHz / 12 = 4 MHz
        d->clk = 0; d->eval();
        if (d->ym_cen_p1 && !d->ym_cs_n && !d->ym_wr_n) {
            ym_deliv++;
            ym_deliv_din = d->ym_din;
            ym_deliv_a0  = d->ym_a0;
        }
        d->clk = 1; d->eval();
    }
}

// LONG ENOUGH FOR THE SOUND CHIP'S CLOCK TO RUN, which is the point.
//
// This ticked once, and that made the bench unable to represent hardware: the
// YM2151's write is delivered in its cen_p1 domain -- half the 4 MHz enable,
// so one pulse every 24 of these -- and the module holds a request until a
// cen_p1 has taken it. A one-tick idle never produces one, so a write stayed
// pending forever and the chip select never released, which read as "a memory
// cycle selects the YM" when the real behaviour is "the write has not been
// collected yet". On the board the bus is never idle for zero time and the
// chip's clock never stops.
void idle() {
    d->mreq_n = 1; d->iorq_n = 1; d->rd_n = 1; d->wr_n = 1;
    tick(32);
}

// A Z80 memory read: address, MREQ and RD asserted, data sampled after the
// memory's one clock of latency.
uint8_t mem_rd(uint16_t a) {
    d->cpu_addr = a; d->mreq_n = 0; d->rd_n = 0;
    tick(2);
    uint8_t v = d->cpu_din;
    idle();
    return v;
}
void mem_wr(uint16_t a, uint8_t v) {
    d->cpu_addr = a; d->cpu_dout = v; d->mreq_n = 0; d->wr_n = 0;
    tick(2);
    idle();
}
// A Z80 IN/OUT. The accumulator sits on the HIGH half of the address bus, and
// the port map masks to 8 bits, so the high half must not decode.
uint8_t io_rd(uint16_t a) {
    d->cpu_addr = a; d->iorq_n = 0; d->rd_n = 0;
    tick(2);
    uint8_t v = d->cpu_din;
    idle();
    return v;
}
void io_wr(uint16_t a, uint8_t v) {
    d->cpu_addr = a; d->cpu_dout = v; d->iorq_n = 0; d->wr_n = 0;
    tick(2);
    idle();
}

void check(bool ok, const char* what) {
    checks++;
    if (!ok) { fails++; printf("  FAIL: %s\n", what); }
}

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vkaneko_z80snd;

    d->rst = 1; d->latch_we = 0; d->latch_din = 0; d->rom_data = 0;
    d->cpu_addr = 0; d->cpu_dout = 0;
    idle(); tick(8);
    d->rst = 0; tick(8);

    // ---------------------------------------------------------------- 1
    printf("== ROM window: 0x0000-0xbfff\n");
    d->rom_data = 0xa5;
    check(mem_rd(0x0000) == 0xa5, "ROM read at 0x0000");
    check(mem_rd(0x7fff) == 0xa5, "ROM read at 0x7fff");
    check(mem_rd(0xbfff) == 0xa5, "ROM read at 0xbfff — the second ROM half");
    // The address must reach the ROM unchanged.
    d->cpu_addr = 0x1234; d->mreq_n = 0; d->rd_n = 0; tick();
    check(d->rom_addr == 0x1234, "rom_addr follows the CPU address");
    idle();

    // ---------------------------------------------------------------- 2
    printf("== RAM: 0xc000-0xdfff\n");
    mem_wr(0xc000, 0x11);
    mem_wr(0xdfff, 0x22);
    mem_wr(0xc123, 0x33);
    check(mem_rd(0xc000) == 0x11, "RAM read back at 0xc000");
    check(mem_rd(0xdfff) == 0x22, "RAM read back at 0xdfff");
    check(mem_rd(0xc123) == 0x33, "RAM read back at 0xc123");
    // 0xbfff is ROM, not RAM: a write there must not land anywhere readable.
    d->rom_data = 0x5a;
    mem_wr(0xbfff, 0x99);
    check(mem_rd(0xbfff) == 0x5a, "0xbfff is ROM and a write there is ignored");

    // ---------------------------------------------------------------- 3
    printf("== sound latch and NMI\n");
    check(d->nmi_n == 1, "NMI is idle before anything is written");

    d->latch_din = 0x7e; d->latch_we = 1; tick(); d->latch_we = 0; tick(2);
    check(d->nmi_n == 0, "NMI asserts when the 68000 writes the latch");

    const uint8_t got = io_rd(0x0006);
    check(got == 0x7e, "the Z80 reads back the byte the 68000 wrote");
    check(d->nmi_n == 1, "reading the latch clears NMI");

    // A second write re-arms it; two writes without a read stay one interrupt,
    // which is what a data-pending line does and a counter would not.
    d->latch_din = 0x01; d->latch_we = 1; tick(); d->latch_we = 0; tick();
    d->latch_din = 0x02; d->latch_we = 1; tick(); d->latch_we = 0; tick(2);
    check(d->nmi_n == 0, "NMI re-asserts on a later write");
    check(io_rd(0x0006) == 0x02, "the latch holds the most recent byte");
    check(d->nmi_n == 1, "one read clears it however many writes there were");

    // ---------------------------------------------------------------- 4
    printf("== port decode, and the accumulator on the high address half\n");
    // global_mask(0xff): a Z80 IN/OUT drives A15-A8 with the accumulator, so
    // 0x7e06 must decode exactly as 0x06 does. Getting this wrong gives a
    // sound CPU that works until the accumulator happens to be non-zero.
    d->latch_din = 0x44; d->latch_we = 1; tick(); d->latch_we = 0; tick(2);
    check(io_rd(0x7e06) == 0x44, "port 0x06 decodes with junk in the high half");

    // Ports that are not mapped must not read as the latch.
    d->latch_din = 0x55; d->latch_we = 1; tick(); d->latch_we = 0; tick(2);
    check(io_rd(0x0007) != 0x55 || d->nmi_n == 0,
          "port 0x07 is not the latch");
    check(io_rd(0x0000) != 0x55 || d->nmi_n == 0,
          "port 0x00 is not the latch");

    // ---------------------------------------------------------------- 5
    // The YM2151 is instantiated by the top level, so what is testable here is
    // that the decode drives its bus correctly — which is the part that is
    // ours. jt51 itself is jotego's and verified.
    printf("== YM2151 bus\n");
    io_rd(0x0006);                       // clear the pending NMI

    // A write to 0x02 is the register-select half: chip selected, a0 low.
    d->cpu_addr = 0x0002; d->cpu_dout = 0x28; d->iorq_n = 0; d->wr_n = 0;
    tick();
    check(d->ym_cs_n == 0, "port 0x02 selects the YM2151");
    check(d->ym_a0 == 0,   "port 0x02 is the register-select half, a0 low");
    check(d->ym_wr_n == 0, "a write reaches the chip as a write");
    check(d->ym_din == 0x28, "the data byte reaches the chip");
    idle();

    // 0x03 is the data half: a0 high.
    d->cpu_addr = 0x0003; d->iorq_n = 0; d->wr_n = 0;
    tick();
    check(d->ym_cs_n == 0, "port 0x03 selects the YM2151");
    check(d->ym_a0 == 1,   "port 0x03 is the data half, a0 high");
    idle();

    // And the accumulator on the high half must not stop it decoding.
    d->cpu_addr = 0x9f03; d->iorq_n = 0; d->wr_n = 0;
    tick();
    check(d->ym_cs_n == 0, "the YM decodes with junk in the high address half");
    idle();

    // Nothing else may select it — a stray chip select is silent corruption.
    d->cpu_addr = 0x0004; d->iorq_n = 0; d->wr_n = 0;
    tick();
    check(d->ym_cs_n == 1, "port 0x04 does not select the YM2151");
    idle();
    d->cpu_addr = 0x0002; d->mreq_n = 0; d->rd_n = 0;   // memory, not I/O
    tick();
    check(d->ym_cs_n == 1, "a MEMORY cycle at 0x0002 does not select the YM");
    idle();

    // ---- EVERY WRITE REACHES THE CHIP'S SAMPLING DOMAIN, EXACTLY ONCE.
    //
    // This is the check that was missing, and its absence cost a day. jt51
    // does not latch a write when the CPU makes it: jt51.v forms
    // `write = !cs_n && !wr_n` and samples it in the cen_p1 domain, which is
    // HALF the 4 MHz enable -- one opportunity every 24 clocks. A Z80 I/O
    // strobe is only one or two 4 MHz ticks wide, so passing it through raw
    // makes delivery depend on parity: land on the wrong tick and the write
    // is dropped in silence, with every signal looking correct.
    //
    // On hardware that was Wing Force writing the YM at MAME's rate -- about
    // fifteen times a frame -- while jt51's output sat at exactly zero.
    //
    // So: issue the same write at EVERY phase relative to cen_p1, and demand
    // that the chip sees it once. Once, not "at least once" -- a duplicate is
    // its own bug, because a repeated key-on retriggers a note.
    printf("== every write is delivered once, at every cen_p1 phase\n");
    for (int phase = 0; phase < 24; phase++) {
        idle();
        for (int k = 0; k < phase; k++) tick();     // slide against cen_p1

        ym_deliv = 0; ym_deliv_a0 = -1; ym_deliv_din = 0;
        d->cpu_addr = 0x0003; d->cpu_dout = 0x5a;
        d->iorq_n = 0; d->wr_n = 0;
        tick(2);                       // a short strobe, as an OUT presents
        d->iorq_n = 1; d->wr_n = 1;
        tick(64);                      // let any held request drain

        if (ym_deliv != 1) {
            check(false, "write delivered exactly once");
            if (fails <= 12) printf("    phase %2d: chip saw it %ld times\n", phase, ym_deliv);
        } else {
            check(true, "write delivered exactly once");
            check(ym_deliv_din == 0x5a, "delivered data is the byte written");
            check(ym_deliv_a0  == 1,    "delivered a0 is the data half");
        }
    }

    printf("\ntb_kaneko_z80snd: %ld checks, %ld fails\n", checks, fails);
    delete d;
    return fails ? 1 : 0;
}
