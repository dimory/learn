`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU M3 Writeback and Commit Unit
// ============================================================================
//
// Purpose
// -----------------------------------------------------------------------------
// Share the physical RF write ports among execution/initialization results,
// and arbitrate architectural commit descriptors sent to the M2 control path.
//
// Result source mapping
// -----------------------------------------------------------------------------
// 0: SALU
// 1: VALU
// 2: asynchronous Load return
// 3: Register Init
//
// Commit source mapping
// -----------------------------------------------------------------------------
// 0: selected result packet requiring architectural commit
// 1: Control unit
// 2: Memory request-accept commit
//
// Microarchitecture
// -----------------------------------------------------------------------------
// - Result selection uses round-robin arbitration.
// - The selected result source owns the writeback path until its whole packet
//   completes. The producer holds its payload until result_ready is asserted.
// - SGPR writeback transfers one DWORD per beat.
// - VGPR writeback transfers four lanes per beat over eight beats.
// - VGPR lane masks preserve inactive register elements.
// - Normal final RF write and architectural commit occur on the same edge.
// - Load-return and Init results complete without advancing the Wave PC.
// - Scoreboard clear is generated only on the final completed result beat.
//
// Result ownership state
// -----------------------------------------------------------------------------
// IDLE:
//   Select a result source. Its first beat may advance in the same cycle.
//
// LOCKED:
//   Keep the selected owner through remaining beats and final-beat stalls.
//
// M2 commit behavior
// -----------------------------------------------------------------------------
// - The selected commit is an event consumed by the M2 control interface.
// - End selects DONE.
// - Wait selects READY or WAITCNT using the Tracker's satisfied response.
// - Other commits select READY.
// - Wait arm generation does not depend on the satisfied response.
// ============================================================================

module wave_writeback_commit #(
    parameter int WAVE_ID_BITS = 2
) (
    input  logic clk,
    input  logic rst_n,

    // Four held result packets.
    input  logic [3:0] result_valid,
    output logic [3:0] result_ready,

    input  logic [WAVE_ID_BITS-1:0] result_wave_ids [0:3],
    input  gpu_pkg::m3_result_t     result_payloads [0:3],

    // Commit-only producers.
    input  logic control_valid,
    output logic control_ready,
    input  logic [WAVE_ID_BITS-1:0] control_wave_id,
    input  gpu_pkg::m3_commit_t     control_payload,

    input  logic memory_commit_valid,
    output logic memory_commit_ready,
    input  logic [WAVE_ID_BITS-1:0] memory_commit_wave_id,
    input  gpu_pkg::m3_commit_t     memory_commit_payload,

    // Physical RF write interface.
    output logic sgpr_write_enable,
    output logic vgpr_write_enable,
    output logic [WAVE_ID_BITS-1:0] rf_write_wave_id,
    output logic [9:0]             rf_write_index,
    output logic [2:0]             rf_write_beat,
    output logic [31:0]            sgpr_write_data,
    output logic [3:0]             vgpr_write_mask,
    output logic [127:0]           vgpr_write_data,

    // Scoreboard completion interface.
    output logic clear_valid,
    output logic [WAVE_ID_BITS-1:0] clear_wave_id,
    output gpu_pkg::operand_kind_t clear_kind,
    output logic [9:0]             clear_index,
    output logic [4:0]             clear_count,

    // Architectural commit interface.
    output logic commit_valid,
    output logic [WAVE_ID_BITS-1:0] commit_wave_id,
    output gpu_pkg::m3_commit_t     commit_payload,
    output gpu_pkg::wave_context_state_t commit_next_state,

    // Wait query interface.
    output logic wait_arm_valid,
    output gpu_pkg::m3_wait_spec_t wait_spec,
    input  logic wait_arm_satisfied
);

    import gpu_pkg::*;

    localparam logic IDLE   = 1'b0;
    localparam logic LOCKED = 1'b1;

    logic state;
    logic next_state;

    // Result-source IDs, not Wave IDs.
    logic [1:0] owner;
    logic [1:0] result_pointer;
    logic [1:0] selected_source;
    logic       selected_valid;

    m3_result_t selected_result;

    // Current writeback beat.
    logic [2:0] beat;
    logic       last_beat;
    logic       step;

    // Three-way commit arbitration.
    logic [1:0] commit_pointer;
    logic [1:0] selected_commit;
    logic [2:0] commit_requests;

    // Separate loop variables for independent combinational blocks.
    integer scan;
    integer index;
    integer cscan;
    integer cindex;
    integer p;

    // Main logic will be added here.

endmodule

`default_nettype wire