// SPDX-License-Identifier: GPL-3.0-only
// Kaneko 16-bit arcade core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// 93C46 serial EEPROM, 64 words x 16 bits.
//
// explbrkr reaches this chip through three different places, which is why it
// took a bus-trace diff to find rather than a reading of the memory map:
//
//     CLK, DI   eeprom_w at d00001 — bit 0 clk, bit 1 di
//     CS        YM2149 #1 port B, written at 40021e
//     DO        YM2149 #1 port A, read at 40021c
//
// Without it the game spins forever in a loop at 00c30a..00c31c, reading
// 40021c a hundred times in the last two thousand bus cycles.
//
// MODELLED ON eepromser.cpp, NOT ON THE DATASHEET
//
// Three behaviours here are not what a plain reading of a 93C46 datasheet
// suggests, and each one cost a round of "the model is right, the trace still
// disagrees" before the device source was read:
//
//   * DO IDLES HIGH. It is open-drain with a pull-up, so outside a read it
//     reads 1, not 0 (eepromser.cpp:288, m_do_tristate = ASSERT_LINE). A model
//     that idles low agrees with 99.7% of the trace, because most reads happen
//     while data is being shifted out and the formatted contents are mostly
//     zero — which is exactly the kind of near-miss that looks like success.
//
//   * WHILE WAITING FOR A START BIT, DO IS THE READY/BUSY STATUS, not the
//     idle level (eepromser.cpp:658, the 93Cxx override). That is what the
//     game polls after a write, and with no status it never leaves the loop.
//
//   * READS STREAM. 93Cxx enables streaming, so after the sixteenth bit the
//     address auto-increments and the next word follows with no new command
//     (eepromser.cpp:415).
//
// Timings are MAME's (eeprom.cpp:42-45) and are close to a real part: a write
// takes 1750 us, an erase 1000 us, and erase-all/write-all 8000 us. They are
// parameters in clocks so a different core clock does not silently change them.
//
// Verified two ways: a directed testbench for the protocol, and a replay of
// MAME's own captured CLK/DI/CS sequence checking every value the game reads
// back — 20,910 reads, zero mismatches (`make eetest`).
module kaneko_eeprom93c46 #(
    parameter int unsigned CLK_HZ    = 48_000_000,
    parameter int unsigned WRITE_US  = 1750,
    parameter int unsigned ERASE_US  = 1000,
    parameter int unsigned ALL_US    = 8000
) (
    input  wire        clk,          // core clock, not the EEPROM's serial clock
    input  wire        rst,

    input  wire        cs,           // chip select, active high
    input  wire        sk,           // serial clock, sampled — not a clock
    input  wire        di,           // data in
    output logic       do_out,       // data out

    // Telemetry for the replay testbench. Unused in the core.
    output logic [2:0] dbg_state,
    output logic [19:0] dbg_busy,
    output logic       dbg_wen,
    output logic [7:0] dbg_cmd,
    output logic       dbg_cmd_valid
);

    localparam int unsigned US        = CLK_HZ / 1_000_000;
    localparam int unsigned T_WRITE   = WRITE_US * US;
    localparam int unsigned T_ERASE   = ERASE_US * US;
    localparam int unsigned T_ALL     = ALL_US   * US;
    localparam int unsigned BUSY_W    = $clog2(T_ALL + 1);

    // sk and cs arrive from a CPU register write, so they change at the core
    // clock rate and are edge-detected here rather than used as clocks. Using
    // them as clocks would put a CPU-write-rate signal on a clock network.
    logic sk_d;
    always_ff @(posedge clk) sk_d <= sk;
    wire sk_rise = sk && !sk_d;

    logic [15:0] mem [0:63];

    // S_WAIT_DONE is eepromser.cpp's STATE_WAIT_FOR_COMPLETION. Every command
    // except READ ends there, and it is left only by CS falling. It matters
    // because DO reads HIGH throughout it — not the ready/busy status, which
    // only applies while waiting for a start bit (eepromser.cpp:658). Sending
    // the status here instead reported busy where MAME reported 1, on every
    // programming cycle the game performed.
    typedef enum logic [2:0] {
        S_RESET, S_WAIT_START, S_WAIT_CMD, S_READING, S_WAIT_DATA, S_WAIT_DONE
    } state_t;
    state_t state;

    logic [7:0]  cmd;          // 2 opcode bits then 6 address bits
    logic [31:0] sr;
    logic [4:0]  bits;
    logic [5:0]  addr;
    logic [9:0]  rcnt;         // bits shifted out this read, for streaming
    logic        wen;          // EWEN seen; cleared by EWDS and by reset
    logic [BUSY_W-1:0] busy;

    wire ready = (busy == '0);

    assign dbg_state = state;
    assign dbg_busy  = 20'(busy);
    assign dbg_wen   = wen;
    assign dbg_cmd   = cmd;

    // eepromser.cpp:658 — a 93Cxx returns the ready/busy status while it waits
    // for a start bit, and the ordinary DO level otherwise.
    always_comb begin
        if (state == S_WAIT_START) do_out = ready;
        else                       do_out = sr[31];
    end

    integer i;
    always_ff @(posedge clk) begin
        dbg_cmd_valid <= 1'b0;
        if (rst) begin
            state <= S_RESET; cmd <= 8'd0; sr <= 32'hffff_ffff;
            bits <= 5'd0; addr <= 6'd0; rcnt <= 10'd0;
            wen <= 1'b0; busy <= '0;
            for (i = 0; i < 64; i = i + 1) mem[i] <= 16'hffff;
        end else begin
            if (busy != '0) busy <= busy - 1'b1;

            if (!cs) begin
                state <= S_RESET;
                sr    <= 32'hffff_ffff;   // idles high: open drain with a pull-up
                bits  <= 5'd0;
            end else if (state == S_RESET) begin
                state <= S_WAIT_START;
                sr    <= 32'hffff_ffff;
                bits  <= 5'd0;
            end else if (sk_rise) begin
                case (state)
                    S_WAIT_START: if (di) begin
                        state <= S_WAIT_CMD;
                        bits  <= 5'd0;
                        sr    <= 32'hffff_ffff;
                    end

                    S_WAIT_CMD: begin
                        cmd  <= {cmd[6:0], di};
                        bits <= bits + 5'd1;
                        if (bits == 5'd7) begin
                            dbg_cmd_valid <= 1'b1;
                            // The command completes on THIS edge, so decode the
                            // value being shifted in rather than the register.
                            addr <= {cmd[4:0], di};
                            casez ({cmd[6:0], di})
                                8'b10??????: begin              // READ
                                    state <= S_READING;
                                    rcnt  <= 10'd0;
                                    sr    <= 32'd0;             // leading dummy 0
                                end
                                8'b01??????: begin              // WRITE
                                    state <= S_WAIT_DATA;
                                    bits  <= 5'd0;
                                    sr    <= 32'hffff_ffff;
                                end
                                8'b11??????: begin              // ERASE
                                    if (wen) begin
                                        mem[{cmd[4:0], di}] <= 16'hffff;
                                        busy <= BUSY_W'(T_ERASE);
                                    end
                                    state <= S_WAIT_DONE;
                                end
                                8'b0011????: begin              // EWEN
                                    wen   <= 1'b1;
                                    state <= S_WAIT_DONE;
                                end
                                8'b0000????: begin              // EWDS
                                    wen   <= 1'b0;
                                    state <= S_WAIT_DONE;
                                end
                                8'b0010????: begin              // ERAL
                                    if (wen) begin
                                        for (i = 0; i < 64; i = i + 1)
                                            mem[i] <= 16'hffff;
                                        busy <= BUSY_W'(T_ALL);
                                    end
                                    state <= S_WAIT_DONE;
                                end
                                default: begin                  // WRAL
                                    state <= S_WAIT_DATA;
                                    bits  <= 5'd0;
                                    sr    <= 32'hffff_ffff;
                                end
                            endcase
                        end
                    end

                    // Streaming: every sixteenth bit loads the next word, so a
                    // host that keeps clocking walks the whole array.
                    S_READING: begin
                        rcnt <= rcnt + 10'd1;
                        // Word boundary: load the next one. The address wraps
                        // at 64, so a host that keeps clocking walks the array
                        // and comes back round, which is what MAME does.
                        if (rcnt[3:0] == 4'd0)
                            sr <= {mem[6'(addr + rcnt[9:4])], 16'd0};
                        else
                            sr <= {sr[30:0], 1'b1};
                    end

                    S_WAIT_DATA: begin
                        sr   <= {sr[30:0], di};
                        bits <= bits + 5'd1;
                        if (bits == 5'd15) begin
                            if (wen) begin
                                if (cmd[7:6] == 2'b01) begin
                                    mem[addr] <= {sr[14:0], di};
                                    busy      <= BUSY_W'(T_WRITE);
                                end else begin
                                    for (i = 0; i < 64; i = i + 1)
                                        mem[i] <= {sr[14:0], di};
                                    busy <= BUSY_W'(T_ALL);
                                end
                                state <= S_WAIT_DONE;
                            end else begin
                                // A write attempted while locked does not wait
                                // for a completion it is never going to make;
                                // it resets (eepromser.cpp execute_write_command).
                                state <= S_RESET;
                            end
                        end
                    end

                    // Left only by CS falling, handled above.
                    S_WAIT_DONE: ;

                    default: state <= S_WAIT_START;
                endcase
            end
        end
    end

endmodule
