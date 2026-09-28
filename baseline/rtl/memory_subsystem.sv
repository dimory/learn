`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Banked Memory Subsystem
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// This structural wrapper combines one Wave Memory Backend with NUM_BANKS
// independent synchronous single-port SRAM banks.
//
// Microarchitecture
// -----------------------------------------------------------------------------
//
//  Wave LSU
//     |
//     | per-lane request/address/write-data
//     v
//  +--------------------+
//  | memory_backend     |
//  |                    |
//  | decode + arbitrate |
//  | per-bank FSM       |
//  +--+-----+-----+-----+
//     |     |     |     |
//     v     v     v     v
//   SRAM0 SRAM1 SRAM2 SRAM3
//     |     |     |     |
//     +-----+--+--+-----+
//              |
//              v
//  read data and completion to Wave LSU
//
// Address mapping
// -----------------------------------------------------------------------------
// For the default four-bank configuration:
//
// memory_address[1:0] = bank ID
// memory_address[7:2] = row address inside the selected bank
//
// Global address   SRAM bank   SRAM row
// --------------   ---------   --------
// 8'h20            Bank 0      6'h08
// 8'h21            Bank 1      6'h08
// 8'h22            Bank 2      6'h08
// 8'h23            Bank 3      6'h08
// 8'h24            Bank 0      6'h09
//
// Structural behavior
// -----------------------------------------------------------------------------
// This module contains no state machine and no procedural logic.
//
// It instantiates:
// - one memory_backend;
// - NUM_BANKS single_port_sram instances using a generate-for loop.
//
// Reset behavior
// -----------------------------------------------------------------------------
// rst_n resets the memory_backend transaction state.
// SRAM contents are not reset.
//
// Parameter restrictions
// -----------------------------------------------------------------------------
// - NUM_BANKS must be a power of two and greater than one.
// - LANES_PER_WAVE must be greater than one.
// - ADDR_BITS must be greater than $clog2(NUM_BANKS).
// - BANK_DEPTH must equal 2**BANK_ADDR_BITS.
// ============================================================================

module memory_subsystem #(
    parameter int DATA_BITS      = 8,
    parameter int ADDR_BITS      = 8,
    parameter int LANES_PER_WAVE = 4,
    parameter int NUM_BANKS      = 4
) (
    input  logic clk,
    input  logic rst_n,

    // Requests from Wave LSU
    input  logic [LANES_PER_WAVE-1:0] memory_request_mask,
    input  logic                      memory_write,

    input  logic [ADDR_BITS-1:0]
        memory_address [LANES_PER_WAVE-1:0],

    input  logic [DATA_BITS-1:0]
        memory_write_data [LANES_PER_WAVE-1:0],

    // Completions returned to Wave LSU
    output logic [LANES_PER_WAVE-1:0] memory_done_mask,

    output logic [DATA_BITS-1:0]
        memory_read_data [LANES_PER_WAVE-1:0]
);

// ============================================================================
// Derived parameters
// ============================================================================

localparam int BANK_SEL_BITS  = $clog2(NUM_BANKS);
localparam int BANK_ADDR_BITS = ADDR_BITS - BANK_SEL_BITS;
localparam int BANK_DEPTH     = 1 << BANK_ADDR_BITS;

// ============================================================================
// Internal SRAM-bank interfaces
// ============================================================================

logic [NUM_BANKS-1:0] sram_ce;
logic [NUM_BANKS-1:0] sram_we;

logic [BANK_ADDR_BITS-1:0]
    sram_addr [NUM_BANKS-1:0];

logic [DATA_BITS-1:0]
    sram_wdata [NUM_BANKS-1:0];

logic [DATA_BITS-1:0]
    sram_rdata [NUM_BANKS-1:0];

// ============================================================================
// Memory Backend
// ============================================================================

memory_backend #(
    .DATA_BITS      (DATA_BITS),
    .ADDR_BITS      (ADDR_BITS),
    .LANES_PER_WAVE (LANES_PER_WAVE),
    .NUM_BANKS      (NUM_BANKS),
    .BANK_ADDR_BITS (BANK_ADDR_BITS)
) u_memory_backend (
    .clk                 (clk),
    .rst_n               (rst_n),

    .memory_request_mask (memory_request_mask),
    .memory_write        (memory_write),
    .memory_address      (memory_address),
    .memory_write_data   (memory_write_data),

    .memory_done_mask    (memory_done_mask),
    .memory_read_data    (memory_read_data),

    .sram_ce             (sram_ce),
    .sram_we             (sram_we),
    .sram_addr           (sram_addr),
    .sram_wdata          (sram_wdata),
    .sram_rdata          (sram_rdata)
);

// ============================================================================
// SRAM Bank Instances
// ============================================================================

genvar bank;
generate
    for (bank = 0; bank < NUM_BANKS; bank = bank + 1) begin : gen_sram_bank
        single_port_sram #(
            .DATA_BITS (DATA_BITS),
            .ADDR_BITS (BANK_ADDR_BITS),
            .DEPTH     (BANK_DEPTH)
        ) u_sram (
            .clk   (clk),
            .ce    (sram_ce[bank]),
            .we    (sram_we[bank]),
            .addr  (sram_addr[bank]),
            .wdata (sram_wdata[bank]),
            .rdata (sram_rdata[bank])
        );
    end
endgenerate

endmodule

`default_nettype wire
