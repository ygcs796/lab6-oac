// =============================================================================
// sc_top.sv
// Top-level module - single-cycle RISC-V with Memory-Mapped I/O
//
// Hierarchy:
//   sc_top
//     pll_10mhz       - ALTPLL: 50 MHz → 10 MHz
//     sc_cpu          - RISC-V CPU (control + datapath)
//       sc_control
//       sc_datapath
//         sc_imem, sc_regfile, sc_sign_ext
//         sc_alu_ctrl, sc_alu
//         sc_dmem
//         sc_mmio     - memory-mapped I/O (SW, KEY, LEDR, LEDG)
//
// Target board: DE2-115 (Intel Cyclone IV E, 50 MHz clock)
//   CLOCK_50    -> clk
//   KEY[0]      -> rst_n   (active-low push-button reset)
//   KEY[3:1]    -> KEY_IO  (push buttons available to software via MMIO)
//   SW[17:0]    -> SW      (slide switches, read via MMIO @ 0x400)
//   LEDR[17:0]  <- LEDR    (red LEDs,       write via MMIO @ 0x408)
//   LEDG[8:0]   <- LEDG    (green LEDs,     write via MMIO @ 0x40C)
//
// Clock domain
//   clk (50 MHz, CLOCK_50 pin) → pll_10mhz → clk_cpu (10 MHz)
//   The CPU reset is held low until the PLL asserts locked, ensuring
//   the CPU never starts on a glitchy or out-of-frequency clock.
//
// MMIO address map (byte addresses, word-aligned):
//   0x400  SW[17:0]   read-only   18 slide switches
//   0x404  KEY[3:0]   read-only    4 push buttons  (KEY[0] wired to rst_n above)
//   0x408  LEDR[17:0] write-only  18 red LEDs
//   0x40C  LEDG[8:0]  write-only   9 green LEDs
// =============================================================================

`timescale 1ns / 1ps

module sc_top (
    input  logic        clk,          // CLOCK_50 (50 MHz board clock)
    input  logic        rst_n,        // KEY[0] active-low reset
    output logic [31:0] PC,           // current PC (SignalTap / testbench)

    // Slide switches
    input  logic [17:0] SW,           // SW[17:0]

    // Push buttons (KEY[0] is reset; KEY[3:1] exposed to software)
    input  logic [3:1]  KEY,          // KEY[3:1]

    // LEDs
    output logic [17:0] LEDR,         // red LEDs
    output logic [8:0]  LEDG          // green LEDs
);

    // -------------------------------------------------------------------------
    // PLL — 50 MHz → 10 MHz
    // -------------------------------------------------------------------------
    logic clk_cpu;      // 10 MHz clock fed to the CPU
    logic pll_locked;   // high once PLL output is stable

    pll_10mhz pll_inst (
        .inclk0 (clk),
        .c0     (clk_cpu),
        .locked (pll_locked)
    );

    // -------------------------------------------------------------------------
    // Reset — held active until both the user button is released AND the PLL
    // has locked.  This prevents the CPU from running on a glitchy clock during
    // the PLL acquisition window (~1 ms after power-on / FPGA configuration).
    // -------------------------------------------------------------------------
    logic rst_cpu_n;
    assign rst_cpu_n = rst_n & pll_locked;

    // -------------------------------------------------------------------------
    // KEY bus
    // KEY[0] = rst_n (already a top-level port).
    // Reconstruct a 4-bit KEY bus for the CPU: KEY[0] = rst_n, [3:1] = KEY[3:1].
    // -------------------------------------------------------------------------
    logic [3:0] key_bus;
    assign key_bus = {KEY[3:1], rst_n};   // KEY[0] reflected as rst_n value

    sc_cpu cpu (
        .clk    (clk_cpu),
        .rst_n  (rst_cpu_n),
        .PC     (PC),
        .SW     (SW),
        .KEY_IO (key_bus),
        .LEDR   (LEDR),
        .LEDG   (LEDG)
    );

endmodule
