// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// 93C46 protocol: commands, write-enable gating, and read-back.
//
// Self-contained on purpose — no ROMs, no MAME — so it runs in `make test`
// everywhere. The fidelity check against MAME's own captured CLK/DI/CS
// sequence is a separate target (`make eetest`), because that stimulus is
// derived from a ROM and cannot live in the repository (hard rule 2).
#include <cstdio>
#include <cstdint>
#include "Vkaneko_eeprom93c46.h"
#include "verilated.h"

namespace {

Vkaneko_eeprom93c46* dut;
int fails = 0, checks = 0;

void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }
void settle() { for (int i = 0; i < 2; i++) tick(); }

void ck(const char* what, int got, int want) {
    checks++;
    if (got != want) {
        fails++;
        std::printf("  FAIL %-46s got %04x want %04x\n", what, got, want);
    }
}

void cs(int v)  { dut->cs = v; settle(); }

// One serial clock: present DI while SK is low, then raise SK. The part
// samples DI on the rising edge and moves DO on the same edge.
int shift_bit(int bit) {
    dut->di = bit; dut->sk = 0; settle();
    dut->sk = 1; settle();
    const int d = dut->do_out;
    dut->sk = 0; settle();
    return d;
}

void send(uint32_t bits, int n) {
    for (int i = n - 1; i >= 0; i--) shift_bit((bits >> i) & 1);
}

// start bit, 2-bit opcode, 6-bit address
void command(int opcode, int addr) {
    shift_bit(1);
    send(opcode, 2);
    send(addr, 6);
}

uint16_t read_word(int addr) {
    cs(1);
    command(0b10, addr);
    uint16_t v = 0;
    for (int i = 0; i < 16; i++) v = (uint16_t)((v << 1) | shift_bit(0));
    cs(0);
    return v;
}

void write_word(int addr, uint16_t data) {
    cs(1);
    command(0b01, addr);
    send(data, 16);
    cs(0);
}

void ewen()  { cs(1); shift_bit(1); send(0b00, 2); send(0b110000, 6); cs(0); }
void ewds()  { cs(1); shift_bit(1); send(0b00, 2); send(0b000000, 6); cs(0); }
void erase(int addr) { cs(1); command(0b11, addr); cs(0); }
void eral()  { cs(1); shift_bit(1); send(0b00, 2); send(0b100000, 6); cs(0); }

void reset() {
    dut->rst = 1; dut->cs = 0; dut->sk = 0; dut->di = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->rst = 0; settle();
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vkaneko_eeprom93c46;
    reset();

    // ------------------------------------------------ an unprogrammed part
    // Reads as all ones. This is what the game sees on a new PCB, and it is
    // what makes it format the EEPROM on first boot.
    ck("blank word 0",  read_word(0),  0xffff);
    ck("blank word 63", read_word(63), 0xffff);

    // ------------------------------------------------- writes need EWEN
    // A 93C46 powers up write-disabled. A model that ignores that accepts a
    // write the real part refuses, and the difference only shows up as the
    // game finding data it never managed to store.
    write_word(5, 0x1234);
    ck("write ignored while disabled", read_word(5), 0xffff);

    ewen();
    write_word(5, 0x1234);
    ck("write accepted after EWEN", read_word(5), 0x1234);

    // Neighbours untouched — an address decode that is one bit wrong shows up
    // here and nowhere else until the game misbehaves much later.
    ck("word 4 untouched", read_word(4), 0xffff);
    ck("word 6 untouched", read_word(6), 0xffff);

    // ------------------------------------------------- every address works
    for (int a = 0; a < 64; a++) write_word(a, (uint16_t)(0xa000 | a));
    for (int a = 0; a < 64; a++) {
        char what[64];
        std::snprintf(what, sizeof what, "word %d round-trips", a);
        ck(what, read_word(a), (uint16_t)(0xa000 | a));
    }

    // ------------------------------------------------------------ erase
    erase(9);
    ck("erase sets a word to all ones", read_word(9), 0xffff);
    ck("erase leaves its neighbour",    read_word(10), 0xa00a);

    eral();
    ck("ERAL clears word 0",  read_word(0),  0xffff);
    ck("ERAL clears word 63", read_word(63), 0xffff);

    // ------------------------------------------------------------ EWDS
    ewen();
    write_word(1, 0x5555);
    ewds();
    write_word(1, 0xaaaa);
    ck("write refused after EWDS", read_word(1), 0x5555);
    erase(1);
    ck("erase refused after EWDS", read_word(1), 0x5555);

    // ------------------------------------------- resynchronising the host
    // Leading zeros before the start bit are ignored, which is how a host that
    // has lost sync gets back in step. Deselecting mid-command must abandon it.
    ewen();
    cs(1);
    shift_bit(0); shift_bit(0); shift_bit(0);     // no start bit yet
    command(0b01, 2);
    send(0x7777, 16);
    cs(0);
    ck("leading zeros ignored before start", read_word(2), 0x7777);

    cs(1);
    shift_bit(1); send(0b01, 2); send(3, 6);      // a WRITE, abandoned
    cs(0);
    ck("abandoned command writes nothing", read_word(3), 0xffff);

    // DO IDLES HIGH, and this is the check that had it backwards.
    //
    // The pin is open drain with a pull-up, so outside a read it reads 1
    // (eepromser.cpp:288, m_do_tristate = ASSERT_LINE). Most of the port A
    // reads in MAME's trace are nevertheless zero, because they happen while
    // data is being shifted out and the formatted contents are mostly zero —
    // which is why a model that idled low agreed with 99.7% of them and still
    // hung the game.
    cs(0); settle();
    ck("DO idles high while deselected", dut->do_out, 1);

    std::printf("kaneko_eeprom: checks=%d fails=%d\n", checks, fails);
    delete dut;
    return fails ? 1 : 0;
}
