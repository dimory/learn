`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU M2 Wave Retire Controller
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// Selects at most one safely completed resident Wave for retirement per cycle.
// A Wave is eligible only when its Context state is DONE and all seven
// dependency counters are zero:
//     retire_eligible_mask = done_mask & all_counters_zero_mask
//
// Microarchitecture
// -----------------------------------------------------------------------------
// 1. Combine the two input masks to form the retirement candidates.
// 2. Scan Context IDs from zero upward and select the first eligible entry.
// 3. Present one release event and the matching Dispatcher completion event.
// This module contains combinational logic only; it has no clock/reset port,
// registers, round-robin pointer or selection lock.
//
// Interface ownership
// -----------------------------------------------------------------------------
// done_mask              From wave_context_table: Context entries in DONE.
// all_counters_zero_mask From wave_dependency_tracker: seven counters are zero.
// release_valid          To Context Table and Dependency Tracker.
// release_wave_id        Context entry released by release_valid.
// wave_completed         To wave_dispatcher: one retirement on this clock edge.
// Wave IDs identify resident Context slots, not Workgroup-local Wave indices.
//
// Selection
// -----------------------------------------------------------------------------
// The lowest eligible ID wins. Later matches must not overwrite it.
// With no eligible entry, release_valid=0 and release_wave_id=0.
// wave_completed equals release_valid; it does not mean an individual backend
// operation completed and it is not the Kernel done signal.
//
// Event timing
// -----------------------------------------------------------------------------
// Context Table and Dependency Tracker always accept a legal release, so no
// ready port is required. On each rising edge with release_valid=1:
//   - Context Table changes the selected entry from DONE to FREE.
//   - Dependency Tracker clears that entry's counters.
//   - Dispatcher increments its waves_completed count once.
// The subsystem may name this common event retire_fire = release_valid.
//
// Several eligible entries can produce consecutive cycles of release_valid=1.
// Each accepted edge retires one entry; no edge detector or pulse shaper is used.
// Selection is recomputed after the Context Table updates its registered state.
// Allocation uses currently FREE entries, without bypassing a same-edge release.
//
// Reset and protocol
// -----------------------------------------------------------------------------
// Upstream registers use asynchronous active-low reset. A reset Context Table
// produces done_mask=0, so this module naturally has no retirement candidate.
// No combinational reset checks are added here.
// System protocol guarantees no active Wait in DONE/FREE and no late backend
// completion after retirement. Integration assertions check these invariants.
//
// Implementation status
// -----------------------------------------------------------------------------
// Complete M2 fixed-priority retirement selector.
// Compile gpu_pkg.sv first.
// ============================================================================
module wave_retire_controller #(
    parameter int NUM_WAVE_CONTEXTS = gpu_pkg::CDNA_NUM_RESIDENT_WAVES,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    // Context Table: one bit for every Context currently in DONE.
    input  logic [NUM_WAVE_CONTEXTS-1:0] done_mask,

    // Dependency Tracker: one bit when all seven counters are zero.
    input  logic [NUM_WAVE_CONTEXTS-1:0] all_counters_zero_mask,

    // To Context Table and Dependency Tracker: release one Context entry.
    output logic                    release_valid,
    output logic [WAVE_ID_BITS-1:0] release_wave_id,

    // To Dispatcher: sampled once per rising edge with a valid retirement.
    output logic wave_completed
);

    // Both DONE and counter-zero are required for safe retirement.
    logic [NUM_WAVE_CONTEXTS-1:0] retire_eligible_mask;

    // Combinational loop variable for lowest-ID-first selection.
    integer retire_scan_comb;

    assign retire_eligible_mask = done_mask & all_counters_zero_mask;

    always_comb begin
        release_valid = '0;
        release_wave_id = '0;
        for (retire_scan_comb = 0; retire_scan_comb < NUM_WAVE_CONTEXTS;
             retire_scan_comb = retire_scan_comb + 1) begin
            if (retire_eligible_mask[retire_scan_comb] && !release_valid) begin
                release_valid = 1'b1;
                release_wave_id = retire_scan_comb[WAVE_ID_BITS-1:0];
            end
        end
    end

    assign wave_completed = release_valid;

endmodule

`default_nettype wire
