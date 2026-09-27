`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Wave Scheduler
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// The Wave Scheduler controls one Wave through the complete instruction
// lifecycle.
//
// All active lanes execute under one shared core_state and one shared
// byte-addressed current_pc.
//
// Instruction lifecycle
// -----------------------------------------------------------------------------
//
// IDLE
//   -> FETCH
//   -> DECODE
//   -> REQUEST
//   -> WAIT
//   -> EXECUTE
//   -> UPDATE
//   -> FETCH
//
// A RET instruction changes:
//
// UPDATE -> DONE
//
// Microarchitecture
// -----------------------------------------------------------------------------
//
//                         Wave Scheduler
// ┌──────────────────────────────────────────────────────────────────────┐
// │                                                                      │
// │  start                                                               │
// │  start_pc                                                            │
// │  lane_valid_mask                                                     │
// │       │                                                              │
// │       ▼                                                              │
// │  ┌─────────────────────┐                                             │
// │  │ Wave Context State  │                                             │
// │  │                     │                                             │
// │  │ current_pc          │                                             │
// │  │ exec_mask           │                                             │
// │  └──────────┬──────────┘                                             │
// │             │                                                        │
// │             ▼                                                        │
// │  ┌─────────────────────┐                                             │
// │  │ Core-State FSM      │◄──────── fetch_done                         │
// │  │                     │◄──────── lsu_state                          │
// │  │ IDLE                │◄──────── decoded_ret                        │
// │  │ FETCH               │                                             │
// │  │ DECODE              │                                             │
// │  │ REQUEST             │                                             │
// │  │ WAIT                │                                             │
// │  │ EXECUTE             │                                             │
// │  │ UPDATE              │                                             │
// │  │ DONE                │                                             │
// │  └──────────┬──────────┘                                             │
// │             │                                                        │
// │             ▼                                                        │
// │  ┌─────────────────────┐                                             │
// │  │ Next-PC Selection   │◄──────── next_pc[lane]                      │
// │  │                     │◄──────── exec_mask                          │
// │  │ first active lane   │                                             │
// │  │ divergence check    │                                             │
// │  └──────────┬──────────┘                                             │
// │             │                                                        │
// │             ├────────────► current_pc                                │
// │             └────────────► divergence_detected                       │
// │                                                                      │
// └──────────────────────────────────────────────────────────────────────┘
//
// Core-state behavior
// -----------------------------------------------------------------------------
//
// State      Operation
// ---------  ------------------------------------------------------------------
// IDLE       Wait for a new Wave launch
// FETCH      Wait for the Instruction Fetcher
// DECODE     Allow Decoder to register instruction fields and controls
// REQUEST    Allow Register Files and Wave LSU to capture operands
// WAIT       Wait for the Wave LSU when the instruction accesses memory
// EXECUTE    Allow per-lane ALUs and PC units to calculate results
// UPDATE     Commit register/NZP results and update the shared current_pc
// DONE       Report Wave completion
//
// State transition table
// -----------------------------------------------------------------------------
//
// Current state   Condition                                  Next state
// --------------  -----------------------------------------  -------------------
// IDLE            start == 1                                 FETCH
// IDLE            start == 0                                 IDLE
// FETCH           fetch_done == 1                            DECODE
// FETCH           fetch_done == 0                            FETCH
// DECODE          unconditional                              REQUEST
// REQUEST         unconditional                              WAIT
// WAIT            non-memory instruction                     EXECUTE
// WAIT            memory instruction and LSU_STATE_DONE      EXECUTE
// WAIT            memory instruction and LSU not done        WAIT
// EXECUTE         unconditional                              UPDATE
// UPDATE          decoded_ret == 1                           DONE
// UPDATE          decoded_ret == 0                           FETCH
// DONE            start == 0                                 IDLE
// DONE            start == 1                                 DONE
//
// Wave launch
// -----------------------------------------------------------------------------
//
// When a new Wave starts:
//
// current_pc = start_pc
// exec_mask  = lane_valid_mask
//
// lane_valid_mask identifies hardware lanes occupied by valid threads.
//
// Example for a four-lane Wave containing three valid threads:
//
// lane_valid_mask = 4'b0111
// exec_mask       = 4'b0111
//
// The current baseline does not modify exec_mask during execution.
//
// A later divergence implementation may modify exec_mask while preserving
// lane_valid_mask as the permanent Wave occupancy mask.
//
// WAIT behavior
// -----------------------------------------------------------------------------
//
// For an instruction that does not access memory, WAIT lasts one Core cycle.
//
// For LDR or STR, the Scheduler remains in WAIT until:
//
// lsu_state == LSU_STATE_DONE
//
// The Scheduler does not inspect per-lane pending bits. The Wave LSU converts
// all per-lane completions into one Wave-level completion state.
//
// Shared PC selection
// -----------------------------------------------------------------------------
//
// Each active lane calculates one candidate next_pc.
//
// In the current baseline, the Scheduler selects the lowest-numbered active
// lane as the shared next-PC source.
//
// Example:
//
// exec_mask     = 4'b0111
// lane0 next_pc = 8'h10
// lane1 next_pc = 8'h10
// lane2 next_pc = 8'h10
// lane3 next_pc = disabled
//
// selected_next_pc = lane0 next_pc = 8'h10
//
// This avoids the original baseline problem where the Scheduler always used
// the last physical lane, even when that lane was disabled in a partial Wave.
//
// Divergence detection
// -----------------------------------------------------------------------------
//
// All active lanes are compared with selected_next_pc.
//
// If any active lane has a different next_pc:
//
// divergence_detected = 1
//
// Example:
//
// exec_mask     = 4'b1111
// lane0 next_pc = 8'h10
// lane1 next_pc = 8'h10
// lane2 next_pc = 8'h0A
// lane3 next_pc = 8'h0A
//
// selected_next_pc  = 8'h10
// divergence_detected = 1
//
// The baseline still follows selected_next_pc and does not execute both paths.
//
// A future implementation will replace this selection policy with:
//
// - EXEC-mask splitting
// - Divergence-stack allocation
// - Path scheduling
// - Reconvergence
//
// Byte-addressed PC
// -----------------------------------------------------------------------------
//
// current_pc and next_pc are byte addresses.
//
// With 16-bit instructions, normal sequential execution produces:
//
// 8'h00 -> 8'h02 -> 8'h04 -> 8'h06
//
// The per-lane PC modules perform the +2 calculation. The Scheduler only
// commits the selected next_pc.
//
// Done behavior
// -----------------------------------------------------------------------------
//
// done is asserted while core_state == CORE_STATE_DONE.
//
// DONE is held while start remains asserted. After start is deasserted, the
// Scheduler returns to IDLE and can accept another Wave launch.
//
// Reset behavior
// -----------------------------------------------------------------------------
//
// rst_n is an asynchronous active-low reset.
//
// On reset:
//
// core_state          = CORE_STATE_IDLE
// current_pc          = 0
// exec_mask           = 0
// done                = 0
// divergence_detected = 0
//
// Future upgrades
// -----------------------------------------------------------------------------
//
// The Wave Context can later add:
//
// - wave_id
// - saved execution mask
// - divergence stack pointer
// - outstanding-memory counters
// - scoreboard state
// - barrier state
//
// The Core can then hold several Wave Contexts and select one ready Wave each
// cycle without changing the lane datapath interfaces.
// ============================================================================

module wave_scheduler #(
    parameter int PC_BITS          = 8,
    parameter int LANES_PER_WAVE   = 4
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         start,
    input  logic [PC_BITS-1:0]           start_pc,
    input  logic [LANES_PER_WAVE-1:0]    lane_valid_mask,

    input  logic                         fetch_done,
    input  logic [1:0]                   lsu_state,

    input  logic                         decoded_mem_read_enable,
    input  logic                         decoded_mem_write_enable,
    input  logic                         decoded_ret,

    input  logic [PC_BITS-1:0]
        next_pc [LANES_PER_WAVE-1:0],

    output logic [2:0]                   core_state,
    output logic [PC_BITS-1:0]           current_pc,
    output logic [LANES_PER_WAVE-1:0]    exec_mask,

    output logic                         done,
    output logic                         divergence_detected
);

localparam logic [2:0] CORE_STATE_IDLE    = 3'b000;
localparam logic [2:0] CORE_STATE_FETCH   = 3'b001;
localparam logic [2:0] CORE_STATE_DECODE  = 3'b010;
localparam logic [2:0] CORE_STATE_REQUEST = 3'b011;
localparam logic [2:0] CORE_STATE_WAIT    = 3'b100;
localparam logic [2:0] CORE_STATE_EXECUTE = 3'b101;
localparam logic [2:0] CORE_STATE_UPDATE  = 3'b110;
localparam logic [2:0] CORE_STATE_DONE    = 3'b111;

localparam logic [1:0] LSU_STATE_IDLE     = 2'b00;
localparam logic [1:0] LSU_STATE_PREPARE  = 2'b01;
localparam logic [1:0] LSU_STATE_WAITING  = 2'b10;
localparam logic [1:0] LSU_STATE_DONE     = 2'b11;

logic [2:0] core_state_next;

logic [PC_BITS-1:0] current_pc_next;

logic [LANES_PER_WAVE-1:0] exec_mask_next;

logic [PC_BITS-1:0] selected_next_pc;
logic               selected_next_pc_valid;
logic               next_pc_diverged;

integer lane;

// 由你实现

endmodule

`default_nettype wire