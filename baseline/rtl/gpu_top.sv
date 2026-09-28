`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Synthesizable Single-Core Integration Top
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// This module integrates the complete baseline GPU RTL:
//
//     Dispatcher -> Core -> Instruction SRAM
//                        -> 4-Bank Data Memory Subsystem
//
// The integration top contains no testbench logic, no initial blocks and no
// hierarchical memory initialization. Program/data initialization belongs to
// the separate verification environment.
//
// Microarchitecture
// -----------------------------------------------------------------------------
//
//  start/start_pc/thread_count
//              |
//              v
//      +------------------+
//      |    Dispatcher    |
//      +--------+---------+
//               | core_start, block_id, lane_valid_mask
//               v
//      +------------------+       +------------------+
//      |       Core       |<----->| Instruction SRAM |
//      +--------+---------+       +------------------+
//               |
//               | vector load/store request and completion
//               v
//      +--------------------------+
//      | 4-Bank Memory Subsystem  |
//      +--------------------------+
//
// Kernel launch interface
// -----------------------------------------------------------------------------
//
// Signal          Direction   Meaning
// --------------  ----------  ------------------------------------------------
// start           input       One-cycle kernel-launch pulse
// start_pc        input       Byte address of the first instruction
// thread_count    input       Number of one-dimensional kernel threads
// busy            output      Dispatcher is executing an active kernel
// done            output      One-cycle kernel-completion pulse
// divergence      output      Current Core divergence indication
//
// Baseline execution model
// -----------------------------------------------------------------------------
//
// NUM_CORES is intentionally fixed to one in this integration revision.
// Dispatcher still retains its multi-Core-shaped interface, but a multi-Core
// top would additionally require shared instruction/data-memory arbitration.
//
// One Block contains one Wave:
//
//     THREADS_PER_BLOCK == LANES_PER_WAVE
//
// A kernel with more than LANES_PER_WAVE threads is divided into Blocks and
// those Blocks execute sequentially on the single Core.
//
// Instruction memory
// -----------------------------------------------------------------------------
//
// - Byte-addressed PC, 16-bit instructions.
// - The instruction SRAM contains 2**IMEM_ADDR_BITS words.
// - The Instruction Fetcher converts byte PC to an SRAM word address.
// - Reads are synchronous and have one registered SRAM-read cycle.
//
// Data memory
// -----------------------------------------------------------------------------
//
// - DATA_BITS-wide byte-addressed words in the current 8-bit baseline.
// - Total logical address space is 2**ADDR_BITS words.
// - Four independent single-port synchronous SRAM banks are instantiated.
// - Bank number is address[$clog2(NUM_BANKS)-1:0].
// - Bank row is address[ADDR_BITS-1:$clog2(NUM_BANKS)].
//
// Reset behavior
// -----------------------------------------------------------------------------
//
// rst_n asynchronously resets the control/datapath registers.
// Physical SRAM contents are not reset. The verification environment loads
// program and input data before each kernel launch.
//
// Synthesis boundary
// -----------------------------------------------------------------------------
//
// This entire module and everything under rtl/ is synthesizable. The SRAM
// models can later be replaced by foundry/FPGA memory wrappers while retaining
// the same ce/we/addr/wdata/rdata interfaces.
// ============================================================================

module gpu_top #(
    parameter int DATA_BITS          = 8,
    parameter int ADDR_BITS          = 8,
    parameter int PC_BITS            = 8,
    parameter int INSTRUCTION_BITS   = 16,
    parameter int LANES_PER_WAVE     = 4,
    parameter int THREADS_PER_BLOCK  = LANES_PER_WAVE,
    parameter int THREAD_COUNT_BITS  = 8,
    parameter int NUM_BANKS          = 4
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         start,
    input  logic [PC_BITS-1:0]           start_pc,
    input  logic [THREAD_COUNT_BITS-1:0] thread_count,

    output logic                         busy,
    output logic                         done,
    output logic                         divergence_detected
);

localparam int NUM_CORES         = 1;
localparam int INSTRUCTION_BYTES = INSTRUCTION_BITS / 8;
localparam int IMEM_ADDR_BITS    =
    PC_BITS - $clog2(INSTRUCTION_BYTES);
localparam int IMEM_DEPTH        = 1 << IMEM_ADDR_BITS;

logic [NUM_CORES-1:0] core_start;
logic [NUM_CORES-1:0] core_busy;
logic [NUM_CORES-1:0] core_done;

logic [PC_BITS-1:0]
    core_start_pc [NUM_CORES-1:0];

logic [DATA_BITS-1:0]
    core_block_id [NUM_CORES-1:0];

logic [LANES_PER_WAVE-1:0]
    core_lane_valid_mask [NUM_CORES-1:0];

logic core_divergence_detected;

logic                       imem_ce;
logic [IMEM_ADDR_BITS-1:0]  imem_addr;
logic [INSTRUCTION_BITS-1:0] imem_rdata;

logic [LANES_PER_WAVE-1:0] memory_request_mask;
logic                      memory_write;

logic [ADDR_BITS-1:0]
    memory_address [LANES_PER_WAVE-1:0];

logic [DATA_BITS-1:0]
    memory_write_data [LANES_PER_WAVE-1:0];

logic [LANES_PER_WAVE-1:0] memory_done_mask;

logic [DATA_BITS-1:0]
    memory_read_data [LANES_PER_WAVE-1:0];

assign divergence_detected = core_divergence_detected;

dispatcher #(
    .THREAD_COUNT_BITS (THREAD_COUNT_BITS),
    .BLOCK_ID_BITS     (DATA_BITS),
    .PC_BITS           (PC_BITS),
    .NUM_CORES         (NUM_CORES),
    .LANES_PER_WAVE    (LANES_PER_WAVE),
    .THREADS_PER_BLOCK (THREADS_PER_BLOCK)
) u_dispatcher (
    .clk                  (clk),
    .rst_n                (rst_n),
    .start                (start),
    .start_pc             (start_pc),
    .thread_count         (thread_count),
    .core_done            (core_done),
    .busy                 (busy),
    .done                 (done),
    .core_start           (core_start),
    .core_busy            (core_busy),
    .core_start_pc        (core_start_pc),
    .core_block_id        (core_block_id),
    .core_lane_valid_mask (core_lane_valid_mask)
);

core #(
    .DATA_BITS          (DATA_BITS),
    .ADDR_BITS          (ADDR_BITS),
    .PC_BITS            (PC_BITS),
    .INSTRUCTION_BITS   (INSTRUCTION_BITS),
    .INSTRUCTION_BYTES  (INSTRUCTION_BYTES),
    .IMEM_ADDR_BITS     (IMEM_ADDR_BITS),
    .LANES_PER_WAVE     (LANES_PER_WAVE),
    .THREADS_PER_BLOCK  (THREADS_PER_BLOCK)
) u_core (
    .clk                 (clk),
    .rst_n               (rst_n),
    .start               (core_start[0]),
    .start_pc            (core_start_pc[0]),
    .lane_valid_mask     (core_lane_valid_mask[0]),
    .block_id            (core_block_id[0]),
    .done                (core_done[0]),
    .divergence_detected (core_divergence_detected),
    .imem_ce             (imem_ce),
    .imem_addr           (imem_addr),
    .imem_rdata          (imem_rdata),
    .memory_request_mask (memory_request_mask),
    .memory_write        (memory_write),
    .memory_address      (memory_address),
    .memory_write_data   (memory_write_data),
    .memory_done_mask    (memory_done_mask),
    .memory_read_data    (memory_read_data)
);

single_port_sram #(
    .DATA_BITS (INSTRUCTION_BITS),
    .ADDR_BITS (IMEM_ADDR_BITS),
    .DEPTH     (IMEM_DEPTH)
) u_instruction_sram (
    .clk   (clk),
    .ce    (imem_ce),
    .we    (1'b0),
    .addr  (imem_addr),
    .wdata ({INSTRUCTION_BITS{1'b0}}),
    .rdata (imem_rdata)
);

memory_subsystem #(
    .DATA_BITS      (DATA_BITS),
    .ADDR_BITS      (ADDR_BITS),
    .LANES_PER_WAVE (LANES_PER_WAVE),
    .NUM_BANKS      (NUM_BANKS)
) u_memory_subsystem (
    .clk                 (clk),
    .rst_n               (rst_n),
    .memory_request_mask (memory_request_mask),
    .memory_write        (memory_write),
    .memory_address      (memory_address),
    .memory_write_data   (memory_write_data),
    .memory_done_mask    (memory_done_mask),
    .memory_read_data    (memory_read_data)
);

endmodule

`default_nettype wire
