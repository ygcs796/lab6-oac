// =============================================================================
// sc_mmio.sv
// Memory-Mapped I/O controller - DE2-115 peripherals
//
// Address map (byte address, word-aligned):
//   0x400  SW   [17:0]  read-only   18 slide switches
//   0x404  KEY  [3:0]   read-only    4 push buttons
//   0x408  LEDR [17:0]  write-only  18 red LEDs
//   0x40C  LEDG [8:0]   write-only   9 green LEDs
//
// Selection: alu_result[10] = 1 selects this module (addresses 0x400–0x7FF).
// The peripheral is chosen by alu_result[3:2] within the MMIO window.
//
// Reads are combinatorial; writes are registered on posedge clk.
// LED registers clear to 0 on active-low asynchronous reset.
// =============================================================================

`timescale 1ns / 1ps

module sc_mmio (
    input  logic        clk,
    input  logic        rst_n,       // active-low asynchronous reset
    input  logic        MemWrite,    // 1 = write (SW instruction)
    input  logic [1:0]  addr,        // alu_result[3:2]: selects peripheral
    input  logic [31:0] WriteData,   // data from rs2 (SW instruction)

    // Physical I/O (connect to FPGA top-level pins)
    input  logic [17:0] SW,          // slide switches
    input  logic [3:0]  KEY,         // push buttons

    output logic [31:0] ReadData,    // data returned for LW
    output logic [17:0] LEDR,        // red LED register
    output logic [8:0]  LEDG         // green LED register
);

    // -------------------------------------------------------------------------
    // Read mux (combinatorial)
    //   addr 2'b00 -> 0x400: return SW zero-extended to 32 bits
    //   addr 2'b01 -> 0x404: return KEY zero-extended to 32 bits
    //   others            : return 0 (write-only peripherals)
    // -------------------------------------------------------------------------
    always_comb begin
        case (addr)
            2'b00:   ReadData = {14'b0, SW};
            2'b01:   ReadData = {28'b0, KEY};
            default: ReadData = 32'b0;
        endcase
    end

    // -------------------------------------------------------------------------
    // LED write registers (synchronous write, asynchronous reset)
    //   addr 2'b10 -> 0x408: write LEDR[17:0]
    //   addr 2'b11 -> 0x40C: write LEDG[8:0]
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            LEDR <= 18'b0;
            LEDG <=  9'b0;
        end else if (MemWrite) begin
            case (addr)
                2'b10: LEDR <= WriteData[17:0];
                2'b11: LEDG <= WriteData[8:0];
                default: ;
            endcase
        end
    end

endmodule
