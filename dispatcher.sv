`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Block Dispatcher
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// The Dispatcher accepts one kernel launch, divides its one-dimensional thread
// range into Blocks and assigns those Blocks to idle Cores.
//
// The current baseline executes one Wave per Block, therefore:
//
//     THREADS_PER_BLOCK == LANES_PER_WAVE
//
// A later multi-Wave implementation may remove this restriction and dispatch a
// Block Context containing several Waves.
//
// Microarchitecture
// -----------------------------------------------------------------------------
//
//                         TinyGPU Block Dispatcher
// ┌──────────────────────────────────────────────────────────────────────────┐
// │                                                                          │
// │  start, start_pc, thread_count                                           │
// │                  │                                                       │
// │                  ▼                                                       │
// │  ┌──────────────────────────┐                                            │
// │  │ Kernel Context Registers │                                            │
// │  │ saved_start_pc           │                                            │
// │  │ saved_thread_count       │                                            │
// │  │ total_blocks             │                                            │
// │  └─────────────┬────────────┘                                            │
// │                │                                                         │
// │                ▼                                                         │
// │  ┌──────────────────────────┐                                            │
// │  │ Block Allocation Control │◄──────── core_done                         │
// │  │ blocks_dispatched        │                                            │
// │  │ blocks_completed         │                                            │
// │  │ core_busy                │                                            │
// │  └─────────────┬────────────┘                                            │
// │                │                                                         │
// │                ▼                                                         │
// │  core_start, core_start_pc, core_block_id, core_lane_valid_mask          │
// │                                                                          │
// └──────────────────────────────────────────────────────────────────────────┘
//
// Kernel launch interface
// -----------------------------------------------------------------------------
//
// Signal          Meaning
// --------------  ------------------------------------------------------------
// start           One-cycle launch pulse. Accepted only in DISPATCH_IDLE.
// start_pc        Byte address of the first kernel instruction.
// thread_count    Total number of threads in the one-dimensional kernel.
// busy            The Dispatcher owns an active kernel context.
// done            One-cycle pulse after every dispatched Block has completed.
//
// start_pc and thread_count are captured when start is accepted. The external
// inputs may change after that clock edge without affecting the active kernel.
//
// Block calculation
// -----------------------------------------------------------------------------
//
//     total_blocks = ceil(thread_count / THREADS_PER_BLOCK)
//
//                  = (thread_count + THREADS_PER_BLOCK - 1)
//                    / THREADS_PER_BLOCK
//
// Example with THREADS_PER_BLOCK = 4 and thread_count = 10:
//
// Block        block_id        lane_valid_mask
// -----------  --------------  ----------------
// Block 0      0               4'b1111
// Block 1      1               4'b1111
// Block 2      2               4'b0011
//
// Lane-valid-mask generation
// -----------------------------------------------------------------------------
// For a Block with block_id B, lane L represents global thread:
//
//     global_thread_id = B * THREADS_PER_BLOCK + L
//
// A Lane is valid when:
//
//     global_thread_id < saved_thread_count
//
// The mask is packed with Lane 0 in bit 0.
//
// Core dispatch interface
// -----------------------------------------------------------------------------
//
// Signal                    Meaning
// ------------------------  --------------------------------------------------
// core_start[core]          One-cycle pulse that launches one assigned Block.
// core_start_pc[core]       Kernel entry byte address for the assigned Block.
// core_block_id[core]       Block index written into each Lane's R13.
// core_lane_valid_mask      Valid Lane mask loaded into the Core exec_mask.
// core_busy[core]           This Core currently owns an unfinished Block.
// core_done[core]           Completion indication from the Core Scheduler.
//
// Metadata remains stable while core_busy[core] is asserted.
// core_done is counted only when the corresponding core_busy bit is asserted.
// This prevents an idle or stale Core completion from incrementing the kernel
// completion counter.
//
// Allocation priority
// -----------------------------------------------------------------------------
// Idle Cores are scanned from Core 0 toward Core NUM_CORES-1.
// Available Blocks are assigned in increasing block_id order.
//
// If several Cores are idle, several different Blocks may be launched on the
// same clock edge. A temporary dispatch cursor is therefore required inside
// the combinational next-state calculation.
//
// FSM states
// -----------------------------------------------------------------------------
//
// State            Operation
// ---------------  -----------------------------------------------------------
// DISPATCH_IDLE    Wait for a one-cycle start pulse.
// DISPATCH_RUN     Allocate Blocks, track busy Cores and count completions.
// DISPATCH_DONE    Assert done for one cycle, then return to DISPATCH_IDLE.
//
// FSM transitions
// -----------------------------------------------------------------------------
//
// Current state    Condition                                      Next state
// ---------------  ---------------------------------------------  -------------
// DISPATCH_IDLE    start == 1 and thread_count != 0               DISPATCH_RUN
// DISPATCH_IDLE    start == 1 and thread_count == 0               DISPATCH_DONE
// DISPATCH_IDLE    otherwise                                      DISPATCH_IDLE
// DISPATCH_RUN     all Blocks dispatched and completed            DISPATCH_DONE
// DISPATCH_RUN     otherwise                                      DISPATCH_RUN
// DISPATCH_DONE    unconditional                                  DISPATCH_IDLE
//
// A Core that completes a Block becomes available for a later Block. The
// baseline may insert one idle cycle between completion and reassignment. This
// keeps the Core's one-cycle done indication and next one-cycle start pulse
// unambiguous.
//
// Counter meaning
// -----------------------------------------------------------------------------
//
// blocks_dispatched : Number of Blocks already assigned to Cores.
// blocks_completed  : Number of assigned Blocks whose core_done was accepted.
//
// Kernel completion requires:
//
//     blocks_dispatched == total_blocks
//     blocks_completed  == total_blocks
//     core_busy         == '0
//
// Reset behavior
// -----------------------------------------------------------------------------
// rst_n is an asynchronous active-low reset.
//
// On reset:
//
//     dispatcher_state  = DISPATCH_IDLE
//     busy               = 0
//     done               = 0
//     core_start         = 0
//     core_busy          = 0
//     counters           = 0
//     saved metadata     = 0
//
// Future upgrades
// -----------------------------------------------------------------------------
// The interface keeps launch metadata separate from Core execution state so a
// later design can add a launch queue, several resident Waves, Wave IDs,
// per-Wave PCs, scoreboards and resource-based dispatch without changing the
// current Lane datapath.
// ============================================================================

module dispatcher #(
    parameter int THREAD_COUNT_BITS  = 8,
    parameter int BLOCK_ID_BITS      = 8,
    parameter int PC_BITS            = 8,
    parameter int NUM_CORES          = 1,
    parameter int LANES_PER_WAVE     = 4,
    parameter int THREADS_PER_BLOCK  = LANES_PER_WAVE
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         start,
    input  logic [PC_BITS-1:0]           start_pc,
    input  logic [THREAD_COUNT_BITS-1:0] thread_count,

    input  logic [NUM_CORES-1:0]         core_done,

    output logic                         busy,
    output logic                         done,

    output logic [NUM_CORES-1:0]         core_start,
    output logic [NUM_CORES-1:0]         core_busy,

    output logic [PC_BITS-1:0]
        core_start_pc [NUM_CORES-1:0],

    output logic [BLOCK_ID_BITS-1:0]
        core_block_id [NUM_CORES-1:0],

    output logic [LANES_PER_WAVE-1:0]
        core_lane_valid_mask [NUM_CORES-1:0]
);

localparam logic [1:0] DISPATCH_IDLE = 2'b00;
localparam logic [1:0] DISPATCH_RUN  = 2'b01;
localparam logic [1:0] DISPATCH_DONE = 2'b10;

localparam int BLOCK_COUNT_BITS = THREAD_COUNT_BITS;

logic [1:0] dispatcher_state;
logic [1:0] dispatcher_state_next;

logic [PC_BITS-1:0] saved_start_pc;
logic [PC_BITS-1:0] saved_start_pc_next;

logic [THREAD_COUNT_BITS-1:0] saved_thread_count;
logic [THREAD_COUNT_BITS-1:0] saved_thread_count_next;

logic [THREAD_COUNT_BITS:0] thread_count_extended;
logic [THREAD_COUNT_BITS:0] total_blocks_extended;
logic [BLOCK_COUNT_BITS-1:0] total_blocks;

logic [BLOCK_COUNT_BITS-1:0] blocks_dispatched;
logic [BLOCK_COUNT_BITS-1:0] blocks_dispatched_next;

logic [BLOCK_COUNT_BITS-1:0] blocks_completed;
logic [BLOCK_COUNT_BITS-1:0] blocks_completed_next;

logic [NUM_CORES-1:0] core_start_next;
logic [NUM_CORES-1:0] core_busy_next;

logic [PC_BITS-1:0]
    core_start_pc_next [NUM_CORES-1:0];

logic [BLOCK_ID_BITS-1:0]
    core_block_id_next [NUM_CORES-1:0];

logic [LANES_PER_WAVE-1:0]
    core_lane_valid_mask_next [NUM_CORES-1:0];

logic [BLOCK_COUNT_BITS-1:0] dispatch_cursor;
logic [BLOCK_COUNT_BITS-1:0] completion_cursor;
logic [THREAD_COUNT_BITS:0]  block_thread_base;
logic [THREAD_COUNT_BITS:0]  remaining_threads;

logic all_blocks_dispatched;
logic all_blocks_completed;
logic all_cores_idle;

integer core;
integer lane;

// 由你实现

endmodule

`default_nettype wire
