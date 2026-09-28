`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Single-Port Synchronous SRAM Model
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// This module models a single-port synchronous SRAM.
//
// The SRAM has one shared port for both reads and writes. Therefore, only one
// memory operation can be performed in each clock cycle.
//
// Interface
// -----------------------------------------------------------------------------
//
// Signal   Direction   Description
// -------  ----------  -------------------------------------------------------
// clk      input       SRAM clock
// ce       input       Chip enable
// we       input       Write enable
// addr     input       Read/write address
// wdata    input       Write data
// rdata    output      Registered read data
//
// Operation table
// -----------------------------------------------------------------------------
//
// ce       we       Operation
// -------  -------  -----------------------------------------------------------
// 1'b0     X        SRAM idle; memory and rdata hold their current values
// 1'b1     1'b0     Synchronous read from memory[addr]
// 1'b1     1'b1     Synchronous write wdata into memory[addr]
//
// Read timing
// -----------------------------------------------------------------------------
//
// A read request is accepted on a rising clock edge when:
//
//     ce == 1'b1 && we == 1'b0
//
// At that edge, the addressed memory word is loaded into rdata.
//
// Example:
//
// Cycle N before rising edge:
//     ce    = 1
//     we    = 0
//     addr  = A
//
// Rising edge N:
//     SRAM samples address A
//
// Cycle N to N+1:
//     rdata contains memory[A]
//
// The LSU must not consume the new rdata value at the same rising edge that
// launches the read. It consumes rdata in the following LSU state/cycle.
//
// Write timing
// -----------------------------------------------------------------------------
//
// A write is committed on a rising clock edge when:
//
//     ce == 1'b1 && we == 1'b1
//
// At that edge:
//
//     memory[addr] <= wdata
//
// rdata is unchanged during a write.
//
// Single-port restriction
// -----------------------------------------------------------------------------
//
// Read and write cannot occur simultaneously:
//
//     we == 1'b0 selects read
//     we == 1'b1 selects write
//
// Reset behavior
// -----------------------------------------------------------------------------
//
// This SRAM has no reset input.
//
// The memory contents and rdata are not reset because physical SRAM macros
// normally do not provide per-bit reset. Testbenches or software must initialize
// required memory locations before they are read.
//
// Read-during-write behavior
// -----------------------------------------------------------------------------
//
// Read-during-write is not applicable because the port performs either a read
// or a write in one cycle. During a write, rdata holds its previous value.
//
// Parameters
// -----------------------------------------------------------------------------
//
// DATA_BITS   Width of each SRAM word
// ADDR_BITS   Width of the SRAM address
// DEPTH       Number of SRAM words
//
// Default organization:
//
//     256 words x 8 bits
//
// Synthesis notes
// -----------------------------------------------------------------------------
//
// - The memory array is not reset.
// - All accesses are synchronous.
// - The coding style can infer block RAM in FPGA synthesis tools.
// - In an ASIC implementation, this module can later be replaced by an SRAM
//   macro wrapper with the same logical interface.
// ============================================================================

module single_port_sram #(
    parameter int DATA_BITS = 8,
    parameter int ADDR_BITS = 8,
    parameter int DEPTH     = (1 << ADDR_BITS)
) (
    input  logic                 clk,
    input  logic                 ce,
    input  logic                 we,
    input  logic [ADDR_BITS-1:0] addr,
    input  logic [DATA_BITS-1:0] wdata,
    output logic [DATA_BITS-1:0] rdata
);

// ============================================================================
// Internal memory array
// ============================================================================

logic [DATA_BITS-1:0] memory [0:DEPTH-1];

// ============================================================================
// Synchronous single-port access
// ============================================================================

always @(posedge clk) begin
    if (ce) begin
        if (we) begin
            memory[addr] <= wdata;
        end
        else begin
            rdata <= memory[addr];
        end
    end
end

endmodule

`default_nettype wire