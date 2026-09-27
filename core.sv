`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Single-Wave Core
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// This module structurally connects the single-Wave execution datapath.
// It contains no additional instruction state machine and no memory array.
//
// Microarchitecture
// -----------------------------------------------------------------------------
//
//                         TinyGPU Single-Wave Core
// ┌──────────────────────────────────────────────────────────────────────────┐
// │                                                                          │
// │  start, start_pc, lane_valid_mask                                        │
// │                 │                                                        │
// │                 ▼                                                        │
// │  ┌──────────────────┐     current_pc     ┌──────────────────────────┐    │
// │  │    Scheduler     │───────────────────►│   Instruction Fetcher    │    │
// │  │                  │◄──── fetch_done ───│                          │    │
// │  │ core_state       │                    └────────────┬─────────────┘    │
// │  │ exec_mask        │                                 │ instruction      │
// │  └───────┬──────────┘                                 ▼                  │
// │          │                                  ┌──────────────────┐         │
// │          │                                  │     Decoder      │         │
// │          │                                  └────────┬─────────┘         │
// │          │                                           │ controls          │
// │          ▼                                           ▼                   │
// │  ┌───────────────────────────────────────────────────────────────┐       │
// │  │                         Lane Array                            │       │
// │  │                                                               │       │
// │  │  Register File ── rs/rt ──► ALU ── alu_out ──► Register File  │       │
// │  │        │                         │                            │       │
// │  │        │                         └──────────────► PC/NZP      │       │
// │  │        │                                         │ next_pc    │       │
// │  └────────┼─────────────────────────────────────────┼────────────┘       │
// │           │ rs/rt                                   │                    │
// │           ▼                                         └────► Scheduler     │
// │  ┌──────────────────┐                                                    │
// │  │     Wave LSU     │◄──────────── memory completion                     │
// │  │                  │─────────────► vector memory request                │
// │  └──────────────────┘                                                    │
// │                                                                          │
// └──────────────────────────────────────────────────────────────────────────┘
//
// Structural contents
// -----------------------------------------------------------------------------
//
// Instance                         Count
// -------------------------------  --------------------------------------------
// scheduler                        1
// instruction_fetcher              1
// decoder                          1
// wave_lsu                         1
// register_file                    LANES_PER_WAVE
// alu                              LANES_PER_WAVE
// pc                               LANES_PER_WAVE
//
// External memory boundaries
// -----------------------------------------------------------------------------
// The instruction SRAM and data memory_subsystem remain outside this module.
//
// Instruction interface:
//
//     imem_ce, imem_addr  -> instruction SRAM
//     imem_rdata          <- instruction SRAM
//
// Data interface:
//
//     memory_request_mask, memory_write, memory_address,
//     memory_write_data   -> memory_subsystem
//
//     memory_done_mask, memory_read_data
//                         <- memory_subsystem
//
// Keeping both memories outside the Core allows later multi-Wave or multi-Core
// arbitration without changing the lane datapath modules.
//
// Core-state distribution
// -----------------------------------------------------------------------------
// The Scheduler generates one shared core_state for all modules.
//
// State      Active operation
// ---------  ------------------------------------------------------------------
// IDLE       Wait for start
// FETCH      Instruction Fetcher reads the synchronous instruction SRAM
// DECODE     Decoder registers instruction fields and control signals
// REQUEST    Register Files read rs/rt; Wave LSU captures a memory instruction
// WAIT       Scheduler waits for the Wave LSU when required
// EXECUTE    Per-lane ALUs and PC/NZP units calculate results
// UPDATE     Register Files write back; Scheduler commits selected next_pc
// DONE       Core asserts done
//
// Lane enable
// -----------------------------------------------------------------------------
// exec_mask[lane] directly enables the Register File, ALU and PC/NZP unit for
// that lane. The Wave LSU receives the complete exec_mask as its instruction
// participation mask.
//
// Parameter restrictions
// -----------------------------------------------------------------------------
// The current ISA and ALU implementation require:
//
// DATA_BITS        = 8
// PC_BITS          = 8
// INSTRUCTION_BITS = 16
//
// LANES_PER_WAVE and THREADS_PER_BLOCK remain parameters. In this single-Wave
// baseline, THREAD_ID is the physical lane index.
//
// Reset behavior
// -----------------------------------------------------------------------------
// rst_n is distributed to every sequential submodule as an asynchronous
// active-low reset. The external SRAM contents are not reset by this module.
// ============================================================================

module core #(
    parameter int DATA_BITS         = 8,
    parameter int ADDR_BITS         = 8,
    parameter int PC_BITS           = 8,
    parameter int INSTRUCTION_BITS  = 16,
    parameter int INSTRUCTION_BYTES = INSTRUCTION_BITS / 8,
    parameter int IMEM_ADDR_BITS    =
        PC_BITS - $clog2(INSTRUCTION_BYTES),
    parameter int LANES_PER_WAVE    = 4,
    parameter int THREADS_PER_BLOCK = LANES_PER_WAVE
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         start,
    input  logic [PC_BITS-1:0]           start_pc,
    input  logic [LANES_PER_WAVE-1:0]    lane_valid_mask,
    input  logic [DATA_BITS-1:0]         block_id,

    output logic                         done,
    output logic                         divergence_detected,

    output logic                         imem_ce,
    output logic [IMEM_ADDR_BITS-1:0]    imem_addr,
    input  logic [INSTRUCTION_BITS-1:0]  imem_rdata,

    output logic [LANES_PER_WAVE-1:0]    memory_request_mask,
    output logic                         memory_write,

    output logic [ADDR_BITS-1:0]
        memory_address [LANES_PER_WAVE-1:0],

    output logic [DATA_BITS-1:0]
        memory_write_data [LANES_PER_WAVE-1:0],

    input  logic [LANES_PER_WAVE-1:0]    memory_done_mask,

    input  logic [DATA_BITS-1:0]
        memory_read_data [LANES_PER_WAVE-1:0]
);

logic [2:0] core_state;
logic [PC_BITS-1:0] current_pc;
logic [LANES_PER_WAVE-1:0] exec_mask;

logic [INSTRUCTION_BITS-1:0] instruction;
logic                        fetch_done;
logic [1:0]                  fetch_state;

logic [3:0] decoded_rd_address;
logic [3:0] decoded_rs_address;
logic [3:0] decoded_rt_address;
logic [2:0] decoded_nzp;
logic [7:0] decoded_immediate;

logic       decoded_reg_write_enable;
logic [1:0] decoded_reg_input_mux;

logic decoded_mem_read_enable;
logic decoded_mem_write_enable;

logic [1:0] decoded_alu_arithmetic_mux;
logic       decoded_alu_output_mux;

logic decoded_nzp_write_enable;
logic decoded_pc_mux;
logic decoded_ret;

logic [DATA_BITS-1:0] rs      [LANES_PER_WAVE-1:0];
logic [DATA_BITS-1:0] rt      [LANES_PER_WAVE-1:0];
logic [DATA_BITS-1:0] alu_out [LANES_PER_WAVE-1:0];
logic [DATA_BITS-1:0] lsu_out [LANES_PER_WAVE-1:0];

logic [PC_BITS-1:0] next_pc [LANES_PER_WAVE-1:0];

logic [1:0] lsu_state;

scheduler #(
    .PC_BITS        (PC_BITS),
    .LANES_PER_WAVE (LANES_PER_WAVE)
) u_scheduler (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .start                    (start),
    .start_pc                 (start_pc),
    .lane_valid_mask          (lane_valid_mask),
    .fetch_done               (fetch_done),
    .lsu_state                (lsu_state),
    .decoded_mem_read_enable  (decoded_mem_read_enable),
    .decoded_mem_write_enable (decoded_mem_write_enable),
    .decoded_ret              (decoded_ret),
    .next_pc                  (next_pc),
    .core_state               (core_state),
    .current_pc               (current_pc),
    .exec_mask                (exec_mask),
    .done                     (done),
    .divergence_detected      (divergence_detected)
);

instruction_fetcher #(
    .PC_BITS           (PC_BITS),
    .INSTRUCTION_BITS  (INSTRUCTION_BITS),
    .INSTRUCTION_BYTES (INSTRUCTION_BYTES),
    .IMEM_ADDR_BITS     (IMEM_ADDR_BITS)
) u_instruction_fetcher (
    .clk         (clk),
    .rst_n       (rst_n),
    .core_state  (core_state),
    .current_pc  (current_pc),
    .imem_ce     (imem_ce),
    .imem_addr   (imem_addr),
    .imem_rdata  (imem_rdata),
    .instruction (instruction),
    .fetch_done  (fetch_done),
    .fetch_state (fetch_state)
);

decoder u_decoder (
    .clk                         (clk),
    .rst_n                       (rst_n),
    .core_state                  (core_state),
    .instruction                 (instruction),
    .decoded_rd_address          (decoded_rd_address),
    .decoded_rs_address          (decoded_rs_address),
    .decoded_rt_address          (decoded_rt_address),
    .decoded_nzp                 (decoded_nzp),
    .decoded_immediate           (decoded_immediate),
    .decoded_reg_write_enable    (decoded_reg_write_enable),
    .decoded_reg_input_mux       (decoded_reg_input_mux),
    .decoded_mem_read_enable     (decoded_mem_read_enable),
    .decoded_mem_write_enable    (decoded_mem_write_enable),
    .decoded_alu_arithmetic_mux  (decoded_alu_arithmetic_mux),
    .decoded_alu_output_mux      (decoded_alu_output_mux),
    .decoded_nzp_write_enable    (decoded_nzp_write_enable),
    .decoded_pc_mux              (decoded_pc_mux),
    .decoded_ret                 (decoded_ret)
);

wave_lsu #(
    .DATA_BITS      (DATA_BITS),
    .ADDR_BITS      (ADDR_BITS),
    .LANES_PER_WAVE (LANES_PER_WAVE)
) u_wave_lsu (
    .clk                      (clk),
    .rst_n                    (rst_n),
    .core_state               (core_state),
    .exec_mask                (exec_mask),
    .decoded_mem_read_enable  (decoded_mem_read_enable),
    .decoded_mem_write_enable (decoded_mem_write_enable),
    .rs                       (rs),
    .rt                       (rt),
    .memory_request_mask      (memory_request_mask),
    .memory_write             (memory_write),
    .memory_address           (memory_address),
    .memory_write_data        (memory_write_data),
    .memory_done_mask         (memory_done_mask),
    .memory_read_data         (memory_read_data),
    .lsu_out                  (lsu_out),
    .lsu_state                (lsu_state)
);

genvar lane;
generate
    for (lane = 0; lane < LANES_PER_WAVE; lane = lane + 1) begin : gen_lane
        register_file #(
            .DATA_BITS         (DATA_BITS),
            .THREADS_PER_BLOCK (THREADS_PER_BLOCK),
            .THREAD_ID         (lane)
        ) u_register_file (
            .clk                      (clk),
            .rst_n                    (rst_n),
            .enable                   (exec_mask[lane]),
            .block_id                 (block_id),
            .core_state               (core_state),
            .decoded_rd_address       (decoded_rd_address),
            .decoded_rs_address       (decoded_rs_address),
            .decoded_rt_address       (decoded_rt_address),
            .decoded_reg_write_enable (decoded_reg_write_enable),
            .decoded_reg_input_mux    (decoded_reg_input_mux),
            .decoded_immediate        (decoded_immediate),
            .alu_out                  (alu_out[lane]),
            .lsu_out                  (lsu_out[lane]),
            .rs                       (rs[lane]),
            .rt                       (rt[lane])
        );

        alu u_alu (
            .clk                        (clk),
            .rst_n                      (rst_n),
            .enable                     (exec_mask[lane]),
            .core_state                 (core_state),
            .decoded_alu_arithmetic_mux (decoded_alu_arithmetic_mux),
            .decoded_alu_output_mux     (decoded_alu_output_mux),
            .rs                         (rs[lane]),
            .rt                         (rt[lane]),
            .alu_out                    (alu_out[lane])
        );

        pc #(
            .DATA_BITS        (DATA_BITS),
            .PC_BITS          (PC_BITS),
            .INSTRUCTION_BITS (INSTRUCTION_BITS)
        ) u_pc (
            .clk                      (clk),
            .rst_n                    (rst_n),
            .enable                   (exec_mask[lane]),
            .core_state               (core_state),
            .decoded_nzp               (decoded_nzp),
            .decoded_immediate         (decoded_immediate),
            .decoded_nzp_write_enable  (decoded_nzp_write_enable),
            .decoded_pc_mux            (decoded_pc_mux),
            .alu_out                   (alu_out[lane]),
            .current_pc                (current_pc),
            .next_pc                   (next_pc[lane])
        );
    end
endgenerate

endmodule

`default_nettype wire
