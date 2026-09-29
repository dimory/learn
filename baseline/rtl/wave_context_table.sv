`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU M2 Wave Context Table
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// This module stores the scheduling and architectural control context for all
// Waves that are resident in one TinyGPU execution subsystem.
//
// Each allocated entry has one stable wave_id. Every later issue, commit,
// wakeup and release event identifies the entry with that wave_id.
//
// This module is not the Wave Scheduler. It reports which entries are READY,
// but it does not choose the next Wave to execute.
//
// This module is not the Dependency Tracker. LOADcnt, STOREcnt, DScnt, KMcnt,
// ASYNCcnt, TENSORcnt, XCNT and wait thresholds are stored in the separate
// wave_dependency_tracker module under the same wave_id.
//
// Microarchitecture
// -----------------------------------------------------------------------------
//
//                           Wave Context Table
// ┌──────────────────────────────────────────────────────────────────────────┐
// │                                                                          │
// │  Wave Dispatcher                                                         │
// │  alloc_valid + initial context                                           │
// │             │                                                            │
// │             ▼                                                            │
// │  ┌───────────────────────────────┐                                       │
// │  │ Lowest-FREE Entry Allocator   │──── alloc_ready                       │
// │  │ free_mask -> alloc_wave_id    │──── alloc_wave_id                     │
// │  └───────────────┬───────────────┘                                       │
// │                  │                                                       │
// │                  ▼                                                       │
// │  ┌────────────────────────────────────────────────────────────────────┐  │
// │  │ Entry 0  state PC EXEC VCC SCC M0 workgroup/wave/thread metadata   │  │
// │  │ Entry 1  state PC EXEC VCC SCC M0 workgroup/wave/thread metadata   │  │
// │  │ Entry 2  state PC EXEC VCC SCC M0 workgroup/wave/thread metadata   │  │
// │  │ Entry 3  state PC EXEC VCC SCC M0 workgroup/wave/thread metadata   │  │
// │  └───────────▲────────────▲────────────▲────────────▲─────────────────┘  │
// │              │            │            │            │                    │
// │           issue         commit      wake/release    retire               │
// │                                                                          │
// │  state decode ──► free/ready/issued/waitcnt/barrier/done/resident masks  │
// │  read_wave_id ──► one combinational selected-context read port           │
// │                                                                          │
// └──────────────────────────────────────────────────────────────────────────┘
//
// Parameters
// -----------------------------------------------------------------------------
//
// Parameter                  Meaning
// -------------------------  -------------------------------------------------
// NUM_WAVE_CONTEXTS          Number of resident Wave Context entries
// PC_BITS                    Width of the byte-addressed Wave PC
// EXEC_BITS                  Width of EXEC storage; CDNA5 EXEC is 64 bits
// VCC_BITS                   Width of VCC storage; CDNA5 VCC is 64 bits
// DATA_BITS                  Width of scalar M0
// WORKGROUP_ID_BITS          Width of the one-dimensional Workgroup ID
// WG_WAVE_ID_BITS            Width of wave_id_in_workgroup
// WG_WAVE_COUNT_BITS         Width of waves_in_workgroup
// GLOBAL_THREAD_ID_BITS      Width of the first global thread ID in this Wave
// WAVE_ID_BITS               Width required to index NUM_WAVE_CONTEXTS entries
//
// M2 uses Wave32. EXEC and VCC are nevertheless stored as 64-bit architectural
// values. Only EXEC[31:0] and VCC[31:0] participate in Wave32 vector execution;
// their upper halves are kept for the CDNA5 architectural representation.
//
// Context entry organization
// -----------------------------------------------------------------------------
//
// Field                     Meaning
// ------------------------  --------------------------------------------------
// state                     Current Wave lifecycle state
// pc                        Byte address of the next instruction to issue
// exec                      Per-lane vector execution mask
// vcc                       Vector condition-code mask
// scc                       Scalar condition code
// m0                        Miscellaneous scalar architectural register
// workgroup_id              Workgroup owning this Wave
// wave_index                Wave index inside the Workgroup
// waves_in_workgroup        Number of valid Waves in that Workgroup
// global_thread_base        Global thread ID represented by Lane 0
//
// Wave lifecycle state encoding
// -----------------------------------------------------------------------------
//
// Value   Package name          Meaning                         Schedulable
// -----   --------------------  ------------------------------  -----------
// 3'd0    WAVE_STATE_FREE       Entry is unallocated            No
// 3'd1    WAVE_STATE_READY      May issue its next instruction  Yes
// 3'd2    WAVE_STATE_ISSUED     Waiting for instruction commit  No
// 3'd3    WAVE_STATE_WAITCNT    Sleeping on dependency counter  No
// 3'd4    WAVE_STATE_BARRIER    Sleeping on a barrier           No
// 3'd5    WAVE_STATE_DONE       Waiting for safe retirement     No
// 3'd6-7  Reserved              Must not be generated           No
//
// Legal state transitions
// -----------------------------------------------------------------------------
//
// Current state   Accepted event                         Next state
// --------------  -------------------------------------  ----------------------
// FREE            allocation handshake                  READY
// READY           issue_valid for this wave_id           ISSUED
// ISSUED          normal commit                          READY
// ISSUED          unsatisfied wait commit                WAITCNT
// ISSUED          barrier-wait commit                    BARRIER
// ISSUED          end-program commit                     DONE
// WAITCNT         wait_wakeup_mask bit                   READY
// BARRIER         barrier_release_mask bit               READY
// DONE            release_valid for this wave_id         FREE
//
// Allocation interface
// -----------------------------------------------------------------------------
//
// alloc_valid is asserted by wave_dispatcher together with one complete initial
// Wave descriptor. The table scans entries from Wave ID 0 upward and reports
// the lowest-numbered FREE entry on alloc_wave_id.
//
// Allocation occurs only on:
//
//     alloc_fire = alloc_valid && alloc_ready
//
// When no entry is FREE, alloc_ready is low. The Dispatcher must keep
// alloc_valid and all alloc_* payload fields stable until the handshake occurs.
//
// A successful allocation writes:
//
//     state              = WAVE_STATE_READY
//     pc                 = alloc_start_pc
//     exec               = alloc_initial_exec
//     vcc                = 0
//     scc                = 0
//     m0                 = 0
//     dispatch metadata  = alloc_* metadata
//
// An entry being released on the current edge is not bypassed to allocation on
// that same edge. If the table was full, allocation resumes on the next cycle.
//
// Issue interface
// -----------------------------------------------------------------------------
//
// issue_valid is a one-cycle schedule_fire event from wave_scheduler.
// issue_wave_id must identify an entry currently in WAVE_STATE_READY.
// A legal issue changes only the state from READY to ISSUED. Architectural
// fields remain unchanged.
//
// Commit interface
// -----------------------------------------------------------------------------
//
// commit_valid identifies the Wave whose currently issued instruction has
// reached architectural commit. commit_wave_id must identify an ISSUED entry.
//
// commit_next_state gives the lifecycle result of that instruction and must be
// one of READY, WAITCNT, BARRIER or DONE.
//
// PC, EXEC, VCC, SCC and M0 each have an independent write-enable so an
// instruction changes only the architectural fields it owns. Dispatch metadata
// is immutable for the complete lifetime of an allocated Wave.
//
// Wakeup interfaces
// -----------------------------------------------------------------------------
//
// wait_wakeup_mask is a multi-hot vector produced from:
//
//     waitcnt_mask & dependency_wait_satisfied_mask
//
// A set bit changes a WAITCNT entry to READY. It has no effect on entries in
// any other state.
//
// barrier_release_mask is a multi-hot vector from the Barrier Controller. In
// M2 it may be driven directly by the verification environment. A set bit
// changes a BARRIER entry to READY and has no effect on other states.
//
// Release interface
// -----------------------------------------------------------------------------
//
// release_valid is a one-cycle retire event. release_wave_id must identify a
// DONE entry whose dependency counters are all zero. Release clears every field
// and returns the entry to FREE. Clearing prevents a later Wave from observing
// stale architectural or dispatch metadata after the Wave ID is reused.
//
// Selected-context read interface
// -----------------------------------------------------------------------------
//
// read_wave_id selects one entry combinationally. read_valid is high only when
// the ID is in range and the selected entry is not FREE. When read_valid is low,
// every read payload output is defined as zero.
//
// The Scheduler normally drives read_wave_id with selected_wave_id. Context
// outputs then form the launch payload for the Wave-tagged instruction path.
//
// State-mask outputs
// -----------------------------------------------------------------------------
//
// Mask             Bit meaning when set
// ---------------  -----------------------------------------------------------
// free_mask         Entry is FREE and available for allocation
// resident_mask     Entry is allocated; equivalent to state != FREE
// ready_mask        Entry is eligible for Wave scheduling
// issued_mask       Entry owns one uncommitted instruction
// waitcnt_mask      Entry is sleeping on S_WAIT_*CNT
// barrier_mask      Entry is sleeping on a barrier
// done_mask         Entry executed end Program and awaits retirement
//
// Concurrent event behavior
// -----------------------------------------------------------------------------
//
// Different entries may accept different events on the same rising edge. For
// example, Wave0 may commit while Wave1 wakes, Wave2 issues and Wave3 releases.
// The implementation therefore updates entries independently in a for loop;
// it is not one global FSM that handles only one event per cycle.
//
// Legal traffic should not send conflicting events to one entry. The required
// defensive priority for one entry is:
//
//     asynchronous reset
//         > release
//         > allocation
//         > commit
//         > wait/barrier wakeup
//         > issue
//         > hold
//
// Reset behavior
// -----------------------------------------------------------------------------
//
// rst_n is an asynchronous active-low reset.
//
// On reset:
//
//     every state entry       = WAVE_STATE_FREE
//     every architectural field = 0
//     every metadata field      = 0
//
// Module summary and future upgrades
// -----------------------------------------------------------------------------
//
// This module is the physical home of resident Wave scheduling state and small
// architectural control registers. M2 verifies allocation, issue, commit,
// sleep, wakeup, retirement and Wave-ID reuse. Later milestones may add MODE,
// trap state, scratch/LDS bases and context-save fields, while SGPR/VGPR files,
// dependency counters, scoreboards and barrier member state remain separate.
// ============================================================================

module wave_context_table #(
    parameter int NUM_WAVE_CONTEXTS = gpu_pkg::CDNA_NUM_RESIDENT_WAVES,
    parameter int PC_BITS = gpu_pkg::CDNA_PC_BITS,
    parameter int EXEC_BITS = gpu_pkg::CDNA_EXEC_BITS,
    parameter int VCC_BITS = gpu_pkg::CDNA_VCC_BITS,
    parameter int DATA_BITS = gpu_pkg::CDNA_DATA_BITS,
    parameter int WORKGROUP_ID_BITS = gpu_pkg::CDNA_WORKGROUP_ID_BITS,
    parameter int WG_WAVE_ID_BITS = gpu_pkg::CDNA_WORKGROUP_WAVE_ID_BITS,
    parameter int WG_WAVE_COUNT_BITS =
        gpu_pkg::CDNA_WORKGROUP_WAVE_COUNT_BITS,
    parameter int GLOBAL_THREAD_ID_BITS =
        gpu_pkg::CDNA_GLOBAL_THREAD_ID_BITS,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    input  logic                              clk,
    input  logic                              rst_n,

    // Wave allocation from wave_dispatcher
    input  logic                              alloc_valid,
    output logic                              alloc_ready,
    output logic [WAVE_ID_BITS-1:0]           alloc_wave_id,
    input  logic [PC_BITS-1:0]                alloc_start_pc,
    input  logic [EXEC_BITS-1:0]              alloc_initial_exec,
    input  logic [WORKGROUP_ID_BITS-1:0]      alloc_workgroup_id,
    input  logic [WG_WAVE_ID_BITS-1:0]        alloc_wave_index,
    input  logic [WG_WAVE_COUNT_BITS-1:0]     alloc_waves_in_workgroup,
    input  logic [GLOBAL_THREAD_ID_BITS-1:0]  alloc_global_thread_base,

    // Accepted Wave issue from wave_scheduler
    input  logic                              issue_valid,
    input  logic [WAVE_ID_BITS-1:0]           issue_wave_id,

    // Architectural commit from the Wave-tagged execution path
    input  logic                              commit_valid,
    input  logic [WAVE_ID_BITS-1:0]           commit_wave_id,
    input  gpu_pkg::wave_context_state_t      commit_next_state,

    input  logic                              commit_pc_write_enable,
    input  logic [PC_BITS-1:0]                commit_pc,

    input  logic                              commit_exec_write_enable,
    input  logic [EXEC_BITS-1:0]              commit_exec,

    input  logic                              commit_vcc_write_enable,
    input  logic [VCC_BITS-1:0]               commit_vcc,

    input  logic                              commit_scc_write_enable,
    input  logic                              commit_scc,

    input  logic                              commit_m0_write_enable,
    input  logic [DATA_BITS-1:0]              commit_m0,

    // Multi-Wave wakeup events
    input  logic [NUM_WAVE_CONTEXTS-1:0]      wait_wakeup_mask,
    input  logic [NUM_WAVE_CONTEXTS-1:0]      barrier_release_mask,

    // Safe retirement and Context release
    input  logic                              release_valid,
    input  logic [WAVE_ID_BITS-1:0]           release_wave_id,

    // Combinational selected-context read port
    input  logic [WAVE_ID_BITS-1:0]           read_wave_id,
    output logic                              read_valid,
    output gpu_pkg::wave_context_state_t      read_state,
    output logic [PC_BITS-1:0]                read_pc,
    output logic [EXEC_BITS-1:0]              read_exec,
    output logic [VCC_BITS-1:0]               read_vcc,
    output logic                              read_scc,
    output logic [DATA_BITS-1:0]              read_m0,
    output logic [WORKGROUP_ID_BITS-1:0]      read_workgroup_id,
    output logic [WG_WAVE_ID_BITS-1:0]        read_wave_index,
    output logic [WG_WAVE_COUNT_BITS-1:0]     read_waves_in_workgroup,
    output logic [GLOBAL_THREAD_ID_BITS-1:0]  read_global_thread_base,

    // State masks consumed by allocation, scheduling and retirement logic
    output logic [NUM_WAVE_CONTEXTS-1:0]      free_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0]      resident_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0]      ready_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0]      issued_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0]      waitcnt_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0]      barrier_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0]      done_mask
);

// ============================================================================
// Local parameters
// ============================================================================

localparam int NUM_CONTEXT_ENTRIES = NUM_WAVE_CONTEXTS;

localparam gpu_pkg::wave_context_state_t CONTEXT_STATE_FREE =
    gpu_pkg::WAVE_STATE_FREE;

localparam gpu_pkg::wave_context_state_t CONTEXT_STATE_READY =
    gpu_pkg::WAVE_STATE_READY;

localparam gpu_pkg::wave_context_state_t CONTEXT_STATE_ISSUED =
    gpu_pkg::WAVE_STATE_ISSUED;

localparam gpu_pkg::wave_context_state_t CONTEXT_STATE_WAITCNT =
    gpu_pkg::WAVE_STATE_WAITCNT;

localparam gpu_pkg::wave_context_state_t CONTEXT_STATE_BARRIER =
    gpu_pkg::WAVE_STATE_BARRIER;

localparam gpu_pkg::wave_context_state_t CONTEXT_STATE_DONE =
    gpu_pkg::WAVE_STATE_DONE;

// ============================================================================
// Context storage arrays
// ============================================================================

gpu_pkg::wave_context_state_t
    context_state [0:NUM_CONTEXT_ENTRIES-1];

logic [PC_BITS-1:0]
    context_pc [0:NUM_CONTEXT_ENTRIES-1];

logic [EXEC_BITS-1:0]
    context_exec [0:NUM_CONTEXT_ENTRIES-1];

logic [VCC_BITS-1:0]
    context_vcc [0:NUM_CONTEXT_ENTRIES-1];

logic
    context_scc [0:NUM_CONTEXT_ENTRIES-1];

logic [DATA_BITS-1:0]
    context_m0 [0:NUM_CONTEXT_ENTRIES-1];

logic [WORKGROUP_ID_BITS-1:0]
    context_workgroup_id [0:NUM_CONTEXT_ENTRIES-1];

logic [WG_WAVE_ID_BITS-1:0]
    context_wave_index [0:NUM_CONTEXT_ENTRIES-1];

logic [WG_WAVE_COUNT_BITS-1:0]
    context_waves_in_workgroup [0:NUM_CONTEXT_ENTRIES-1];

logic [GLOBAL_THREAD_ID_BITS-1:0]
    context_global_thread_base [0:NUM_CONTEXT_ENTRIES-1];

// ============================================================================
// Allocation and event-decode signals
// ============================================================================

logic                              alloc_fire;
logic                              free_entry_found;
logic [WAVE_ID_BITS-1:0]           free_entry_id;

logic                              issue_wave_id_in_range;
logic                              commit_wave_id_in_range;
logic                              release_wave_id_in_range;
logic                              read_wave_id_in_range;

logic [NUM_CONTEXT_ENTRIES-1:0]    alloc_select_mask;
logic [NUM_CONTEXT_ENTRIES-1:0]    issue_select_mask;
logic [NUM_CONTEXT_ENTRIES-1:0]    commit_select_mask;
logic [NUM_CONTEXT_ENTRIES-1:0]    release_select_mask;

logic [NUM_CONTEXT_ENTRIES-1:0]    accepted_wait_wakeup_mask;
logic [NUM_CONTEXT_ENTRIES-1:0]    accepted_barrier_release_mask;

integer entry_ff;
integer entry_comb;
integer scan_comb;

assign issue_wave_id_in_range   = (issue_wave_id   < NUM_CONTEXT_ENTRIES);
assign commit_wave_id_in_range  = (commit_wave_id  < NUM_CONTEXT_ENTRIES);
assign release_wave_id_in_range = (release_wave_id < NUM_CONTEXT_ENTRIES);
assign read_wave_id_in_range    = (read_wave_id    < NUM_CONTEXT_ENTRIES);

always_comb begin
    free_mask     = '0;
    resident_mask = '0;
    ready_mask    = '0;
    issued_mask   = '0;
    waitcnt_mask  = '0;
    barrier_mask  = '0;
    done_mask     = '0;

    for (entry_comb = 0;
         entry_comb < NUM_CONTEXT_ENTRIES;
         entry_comb = entry_comb + 1) begin

        if (context_state[entry_comb] != CONTEXT_STATE_FREE)
            resident_mask[entry_comb] = 1'b1;

        case (context_state[entry_comb])
            CONTEXT_STATE_FREE 		: free_mask[entry_comb] = 1'b1;
			CONTEXT_STATE_READY		: ready_mask[entry_comb] = 1'b1;
			CONTEXT_STATE_ISSUED	: issued_mask[entry_comb] = 1'b1;
			CONTEXT_STATE_WAITCNT	: waitcnt_mask[entry_comb] = 1'b1;
			CONTEXT_STATE_BARRIER   : barrier_mask[entry_comb] = 1'b1;
			CONTEXT_STATE_DONE      : done_mask[entry_comb] = 1'b1;
			default : begin
			end
        endcase
    end
end
assign alloc_ready = free_entry_found;
assign alloc_fire  = alloc_valid && alloc_ready;
assign alloc_wave_id = free_entry_id;
always_comb begin
	free_entry_found = '0;
	free_entry_id = '0;
	for (scan_comb = 0;
		 scan_comb < NUM_CONTEXT_ENTRIES;
		 scan_comb = scan_comb + 1) begin
		if (free_mask[scan_comb] && !free_entry_found)begin
			free_entry_found = 1'b1;
			free_entry_id = scan_comb;
		end
		 
	end

end

always_comb begin
	alloc_select_mask		='0;
	issue_select_mask		='0;
	commit_select_mask		='0;
	release_select_mask		='0;
	if (alloc_fire)
		alloc_select_mask[alloc_wave_id] = 1'b1;
	if (issue_wave_id_in_range && issue_valid && context_state[issue_wave_id]== CONTEXT_STATE_READY)
		issue_select_mask[issue_wave_id] = 1'b1;
	if (commit_wave_id_in_range && commit_valid && context_state[commit_wave_id] == CONTEXT_STATE_ISSUED)
		commit_select_mask[commit_wave_id] = 1'b1;
	if (release_wave_id_in_range && release_valid && context_state[release_wave_id] == CONTEXT_STATE_DONE)
		release_select_mask[release_wave_id] = 1'b1;
end

assign accepted_wait_wakeup_mask = wait_wakeup_mask & waitcnt_mask;
assign accepted_barrier_release_mask = barrier_release_mask & barrier_mask;  

always_comb begin
	read_valid				= '0;
	read_state              = CONTEXT_STATE_FREE;
	read_pc                 = '0;
	read_exec               = '0;
	read_vcc                = '0;
	read_scc                = '0;
	read_m0                 = '0;
	read_workgroup_id       = '0;
	read_wave_index         = '0;
	read_waves_in_workgroup = '0;
    read_global_thread_base = '0;
	if(read_wave_id_in_range && context_state[read_wave_id]!= CONTEXT_STATE_FREE)begin
		read_valid = 1'b1;
		read_state = context_state[read_wave_id];
		read_pc    = context_pc [read_wave_id];
		read_exec  = context_exec[read_wave_id];
		read_vcc   = context_vcc [read_wave_id];
		read_scc   = context_scc [read_wave_id];
		read_m0    = context_m0  [read_wave_id];
		read_workgroup_id = context_workgroup_id [read_wave_id];
		read_wave_index   = context_wave_index   [read_wave_id];
		read_waves_in_workgroup = context_waves_in_workgroup [read_wave_id];
		read_global_thread_base = context_global_thread_base [read_wave_id];
	end
end
 
always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		for (entry_ff = 0; entry_ff <NUM_CONTEXT_ENTRIES; entry_ff = entry_ff +1)begin
			context_state		       [entry_ff] <= CONTEXT_STATE_FREE;
			context_pc   		       [entry_ff] <= '0;
			context_exec 		       [entry_ff] <= '0;
			context_vcc  		       [entry_ff] <= '0;
			context_scc  		       [entry_ff] <= '0;
			context_m0   		       [entry_ff] <= '0;
			context_workgroup_id       [entry_ff] <= '0; 
			context_wave_index         [entry_ff] <= '0;
			context_waves_in_workgroup [entry_ff] <= '0;
			context_global_thread_base [entry_ff] <= '0; 
		end
	end
	else begin
		for (entry_ff = 0; entry_ff <NUM_CONTEXT_ENTRIES; entry_ff = entry_ff +1)begin
			if (release_select_mask[entry_ff])begin
				context_state		       [entry_ff] <= CONTEXT_STATE_FREE;
				context_pc   		       [entry_ff] <= '0;
				context_exec 		       [entry_ff] <= '0;
				context_vcc  		       [entry_ff] <= '0;
				context_scc  		       [entry_ff] <= '0;
				context_m0   		       [entry_ff] <= '0;
				context_workgroup_id       [entry_ff] <= '0; 
				context_wave_index         [entry_ff] <= '0;
				context_waves_in_workgroup [entry_ff] <= '0;
				context_global_thread_base [entry_ff] <= '0; 
			end
			else if (alloc_select_mask[entry_ff])begin
				context_state		       [entry_ff] <= CONTEXT_STATE_READY;
				context_pc   		       [entry_ff] <= alloc_start_pc;
				context_exec 		       [entry_ff] <= alloc_initial_exec;
				context_vcc  		       [entry_ff] <= '0;
				context_scc  		       [entry_ff] <= '0;
				context_m0   		       [entry_ff] <= '0;
				context_workgroup_id       [entry_ff] <= alloc_workgroup_id; 
				context_wave_index         [entry_ff] <= alloc_wave_index;
				context_waves_in_workgroup [entry_ff] <= alloc_waves_in_workgroup;
				context_global_thread_base [entry_ff] <= alloc_global_thread_base; 
			end
			else if (commit_select_mask[entry_ff])begin
				context_state		       [entry_ff] <= commit_next_state;
				if (commit_pc_write_enable)
					context_pc   		       [entry_ff] <= commit_pc;
				if (commit_exec_write_enable)
					context_exec 		       [entry_ff] <= commit_exec;
				if (commit_vcc_write_enable)
					context_vcc  		       [entry_ff] <= commit_vcc;
				if (commit_scc_write_enable)
					context_scc  		       [entry_ff] <= commit_scc;
				if(commit_m0_write_enable)
					context_m0   		       [entry_ff] <= commit_m0;	
			end
			else if (accepted_wait_wakeup_mask[entry_ff] || accepted_barrier_release_mask[entry_ff])begin
				context_state[entry_ff]	<= CONTEXT_STATE_READY;
			end
			else if (issue_select_mask[entry_ff])begin
				context_state[entry_ff]	<= CONTEXT_STATE_ISSUED;
			end
		end
	end


end
 


endmodule

`default_nettype wire
