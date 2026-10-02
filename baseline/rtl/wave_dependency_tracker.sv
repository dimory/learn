`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU M2 Wave Dependency Tracker
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// Tracks outstanding backend operations independently for each resident Wave.
// Each Wave owns LOAD, STORE, DS, KM, ASYNC, TENSOR and X counters.
// Dependency issue events increment counters; completion events decrement them.
// A nonzero counter does not itself block Wave scheduling.
//
// The Context Table owns READY / ISSUED / WAITCNT / DONE lifecycle state.
// This module owns only dependency counters and explicit Wait configuration.
// Registered counter and Wait storage are implemented below.
//
// Microarchitecture
// -----------------------------------------------------------------------------
// 1. Counter arrays: seven independent counters per resident Context slot.
// 2. Wait arrays: active bit, selected-counter mask and seven thresholds.
// 3. Incoming Wait query: compare input configuration with registered counters.
// 4. Stored Wait comparison: generate wait_satisfied_mask for all Context slots.
// 5. Zero comparison: generate all_counters_zero_mask for safe retirement.
//
// Wave ID meaning
// -----------------------------------------------------------------------------
// All event IDs refer to wave_context_table slots, not Workgroup-local indices.
// Completion must carry the ID saved when its backend operation was issued.
// It must not use the Wave currently selected by the Scheduler.
//
// Counter representation
// -----------------------------------------------------------------------------
// LOAD, STORE, DS, ASYNC, TENSOR and X counters are 6 bits (0..63).
// KM counters are 5 bits (0..31).
// Common event amounts are unsigned 6-bit values.
// Counters account for modeled instructions/work, not lanes or elapsed cycles.
// A valid issue/completion event must carry a nonzero amount.
// Counter widths and kind encodings come from gpu_pkg.
//
// Event protocol
// -----------------------------------------------------------------------------
// At most one dependency issue and one completion event occur per cycle.
// Scalar valid events are sampled on each rising edge; no ready port is used.
// Consecutive valid edges represent consecutive events.
// Backend acceptance, not Scheduler schedule_fire, produces dependency issue.
//
// Different Waves or kinds update independently on the same edge.
// For the same Wave and kind:
//     next_count = current_count + issue_amount - complete_amount
// Calculate the net result with sufficiently wide intermediate arithmetic.
// A legal net result must fit the selected counter, without wraparound.
// Underflow/overflow holds the affected counter and is reported by verification.
// Event producers must obey capacity; this module cannot backpressure events.
//
// Invalid Wave IDs, kind 7, zero amounts and events targeting nonresident Waves
// are ignored and reported by verification. Guard IDs before array indexing.
//
// Allocation and release
// -----------------------------------------------------------------------------
// alloc_fire / alloc_wave_id initialize a newly allocated Wave.
// release_valid / release_wave_id clear a safely retired Wave.
// Both clear all seven counters; Wait storage is managed separately.
// Per-Wave counter priority:
//     asynchronous reset > release > allocation > normal update
// Events to other Waves remain independent.
// resident_mask need not be set before allocation; allocation creates residency.
// No completion from an old Wave may arrive after its Context ID is reused.
//
// Wait configuration
// -----------------------------------------------------------------------------
// wait_arm_valid supplies an ID, counter mask and seven thresholds.
// Mask bit ordering matches dependency_kind_t:
//     [0] LOAD, [1] STORE, [2] DS, [3] KM,
//     [4] ASYNC, [5] TENSOR, [6] X.
// A selected counter satisfies its condition when current_count <= threshold.
// Unselected counters do not participate. All selected conditions must hold.
// An empty selection mask is satisfied.
//
// wait_arm_satisfied queries the incoming configuration using current registered
// counts. It is zero unless wait_arm_valid and a legal resident ID hold.
// The execution port uses it to choose READY or WAITCNT for Wait commit.
// An already satisfied Wait clears wait_active and does not enter WAITCNT.
// An unsatisfied Wait saves its configuration and sets wait_active.
// A new valid Wait arm replaces the old configuration for that Wave.
//
// Wakeup acknowledgement
// -----------------------------------------------------------------------------
// wait_satisfied_mask is a level mask, not a pulse.
// Its bit is high when an active stored Wait is satisfied.
// The control subsystem forms:
//     wait_wakeup_mask = waitcnt_mask & wait_satisfied_mask
// The same mask goes to Context Table (WAITCNT -> READY) and this module
// (clear wait_active). The subsystem qualifies acknowledgements with WAITCNT
// and stored satisfaction; this module clears each acknowledged active bit.
// Wait-state priority:
//     asynchronous reset > valid wait arm > wakeup acknowledgement > hold
// Allocation/release do not modify Wait storage. System protocol guarantees
// no active Wait in DONE/FREE; saved inactive configuration is ignored until
// a new arm replaces the complete mask and thresholds.
// Counter and Wait-state updates are independent; one must not suppress the other.
//
// Output timing and retirement
// -----------------------------------------------------------------------------
// Comparisons use current registered counters, without event bypass.
// A completion changes its count after the updating edge; the resulting wakeup
// is accepted by the Context Table at a subsequent edge.
// all_counters_zero_mask tests all seven counters, independently of Wait state.
// Zeroed FREE entries may have this bit set; done_mask qualifies retirement.
// The Retire Controller uses done_mask & all_counters_zero_mask.
//
// Reset
// -----------------------------------------------------------------------------
// Asynchronous active-low reset clears all counters and saved Wait configuration.
// Combinational logic does not gate outputs with rst_n. System logic suppresses
// events during reset; clearing wait_active clears the stored Wait mask output.
// Zeroed counters make all_counters_zero_mask all ones after reset takes effect.
//
// Verification
// -----------------------------------------------------------------------------
// Check independent Waves/kinds, net same-counter updates, arithmetic bounds,
// Wait masks/thresholds, empty masks, immediate Wait satisfaction, delayed wakeup,
// acknowledgement, invalid events, counter allocation/release clearing and reuse.
// Integration assertions check legal lifecycle, qualified wakeups and no late
// completions after retirement; these protocol checks do not add RTL branches.
//
// Implementation status
// -----------------------------------------------------------------------------
// Complete M2 tracker RTL. Compile gpu_pkg.sv first.
// ============================================================================
module wave_dependency_tracker #(
    parameter int NUM_WAVE_CONTEXTS = gpu_pkg::CDNA_NUM_RESIDENT_WAVES,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    input  logic clk,
    input  logic rst_n,

    // Context Table: one bit per currently allocated Context slot.
    input  logic [NUM_WAVE_CONTEXTS-1:0] resident_mask,

    // Context allocation handshake: initialize the newly allocated Wave.
    input  logic                    alloc_fire,
    input  logic [WAVE_ID_BITS-1:0] alloc_wave_id,

    // Retire Controller: clear the safely retired Wave.
    input  logic                    release_valid,
    input  logic [WAVE_ID_BITS-1:0] release_wave_id,

    // Accepted backend operation: increment one Wave's selected counter.
    input  logic                      dependency_issue_valid,
    input  logic [WAVE_ID_BITS-1:0]   dependency_issue_wave_id,
    input  gpu_pkg::dependency_kind_t dependency_issue_kind,
    input  logic [gpu_pkg::DEPENDENCY_AMOUNT_BITS-1:0]
                                      dependency_issue_amount,

    // Backend completion: decrement the original Wave's selected counter.
    input  logic                      dependency_complete_valid,
    input  logic [WAVE_ID_BITS-1:0]   dependency_complete_wave_id,
    input  gpu_pkg::dependency_kind_t dependency_complete_kind,
    input  logic [gpu_pkg::DEPENDENCY_AMOUNT_BITS-1:0]
                                      dependency_complete_amount,

    // Execution-port Wait event: query and save selected counters/thresholds.
    input  logic                    wait_arm_valid,
    input  logic [WAVE_ID_BITS-1:0] wait_arm_wave_id,
    input  logic [gpu_pkg::DEPENDENCY_COUNTER_COUNT-1:0] wait_counter_mask,

    input  logic [gpu_pkg::CDNA_LOAD_COUNTER_BITS-1:0]   wait_load_threshold,
    input  logic [gpu_pkg::CDNA_STORE_COUNTER_BITS-1:0]  wait_store_threshold,
    input  logic [gpu_pkg::CDNA_DS_COUNTER_BITS-1:0]     wait_ds_threshold,
    input  logic [gpu_pkg::CDNA_KM_COUNTER_BITS-1:0]     wait_km_threshold,
    input  logic [gpu_pkg::CDNA_ASYNC_COUNTER_BITS-1:0]  wait_async_threshold,
    input  logic [gpu_pkg::CDNA_TENSOR_COUNTER_BITS-1:0] wait_tensor_threshold,
    input  logic [gpu_pkg::CDNA_X_COUNTER_BITS-1:0]      wait_x_threshold,

    // Incoming Wait query: used to choose READY or WAITCNT at commit.
    output logic wait_arm_satisfied,

    // Control subsystem: acknowledgement of satisfied stored Waits.
    input  logic [NUM_WAVE_CONTEXTS-1:0] wait_wakeup_mask,

    // To Context Table through the control subsystem: stored Wait satisfaction.
    output logic [NUM_WAVE_CONTEXTS-1:0] wait_satisfied_mask,

    // To Retire Controller: all seven dependency counters are zero.
    output logic [NUM_WAVE_CONTEXTS-1:0] all_counters_zero_mask
);

import gpu_pkg::*;

// 每个 resident Wave 独立保存未完成 Load 数量
logic [CDNA_LOAD_COUNTER_BITS-1:0]
    load_count [0:NUM_WAVE_CONTEXTS-1];
// KM 使用独立的 5-bit 计数范围
logic [CDNA_KM_COUNTER_BITS-1:0]
    km_count [0:NUM_WAVE_CONTEXTS-1];
logic [CDNA_STORE_COUNTER_BITS-1:0]
	store_count [0:NUM_WAVE_CONTEXTS-1];
logic [CDNA_DS_COUNTER_BITS-1:0]
	ds_count [0:NUM_WAVE_CONTEXTS-1];
logic [CDNA_TENSOR_COUNTER_BITS-1:0]
	tensor_count [0:NUM_WAVE_CONTEXTS-1];
logic [CDNA_ASYNC_COUNTER_BITS-1:0]
	async_count [0:NUM_WAVE_CONTEXTS-1];
logic [CDNA_X_COUNTER_BITS-1:0]
	x_count [0:NUM_WAVE_CONTEXTS-1];

// 每一位对应一个 Wave 是否存在有效的等待条件
logic [NUM_WAVE_CONTEXTS-1:0] wait_active;

// 每个 Wave 独立保存等待哪些计数器
logic [DEPENDENCY_COUNTER_COUNT-1:0]
    saved_wait_counter_mask [0:NUM_WAVE_CONTEXTS-1];

// 每个 Wave 独立保存七类计数器的等待阈值
logic [CDNA_LOAD_COUNTER_BITS-1:0]
    saved_wait_load_threshold [0:NUM_WAVE_CONTEXTS-1];

logic [CDNA_STORE_COUNTER_BITS-1:0]
    saved_wait_store_threshold [0:NUM_WAVE_CONTEXTS-1];

logic [CDNA_DS_COUNTER_BITS-1:0]
    saved_wait_ds_threshold [0:NUM_WAVE_CONTEXTS-1];

logic [CDNA_KM_COUNTER_BITS-1:0]
    saved_wait_km_threshold [0:NUM_WAVE_CONTEXTS-1];

logic [CDNA_ASYNC_COUNTER_BITS-1:0]
    saved_wait_async_threshold [0:NUM_WAVE_CONTEXTS-1];

logic [CDNA_TENSOR_COUNTER_BITS-1:0]
    saved_wait_tensor_threshold [0:NUM_WAVE_CONTEXTS-1];

logic [CDNA_X_COUNTER_BITS-1:0]
    saved_wait_x_threshold [0:NUM_WAVE_CONTEXTS-1];

// 事件字段合法，且目标 Wave 当前已经分配
logic issue_event_legal;
logic complete_event_legal;
always_comb begin
    issue_event_legal    = '0;
    complete_event_legal = '0;

    if (dependency_issue_valid &&
        (dependency_issue_wave_id < NUM_WAVE_CONTEXTS)) begin

        if (resident_mask[dependency_issue_wave_id] &&
            (dependency_issue_kind < DEPENDENCY_COUNTER_COUNT) &&
            (dependency_issue_amount != '0))
            issue_event_legal = 1'b1;
    end

    if (dependency_complete_valid &&
        (dependency_complete_wave_id < NUM_WAVE_CONTEXTS)) begin

        if (resident_mask[dependency_complete_wave_id] &&
            (dependency_complete_kind < DEPENDENCY_COUNTER_COUNT) &&
            (dependency_complete_amount != '0))
            complete_event_legal = 1'b1;
    end
end

// 每个 Wave 的 LOAD 计数器下一值
logic [CDNA_LOAD_COUNTER_BITS-1:0]
    load_count_next [0:NUM_WAVE_CONTEXTS-1];

// 中间运算多保留一位，避免加法结果提前截断
logic [CDNA_LOAD_COUNTER_BITS:0] load_sum_comb;
logic [CDNA_LOAD_COUNTER_BITS:0] load_decrement_comb;
logic [CDNA_LOAD_COUNTER_BITS:0] load_result_comb;

// LOAD 计数器允许的最大值，默认 63
localparam logic [CDNA_LOAD_COUNTER_BITS-1:0] LOAD_COUNT_MAX =
    {CDNA_LOAD_COUNTER_BITS{1'b1}};

// 组合循环变量
integer load_scan_comb;

always_comb begin
	for ( load_scan_comb = 0; load_scan_comb < NUM_WAVE_CONTEXTS; load_scan_comb = load_scan_comb +1)begin
		load_count_next[load_scan_comb] = load_count[load_scan_comb];
		load_sum_comb       = {1'b0, load_count[load_scan_comb]};
		load_decrement_comb = '0;
		load_result_comb    = '0;
		if(issue_event_legal &&
			(dependency_issue_wave_id == load_scan_comb) &&
			(dependency_issue_kind == DEP_LOAD))
			load_sum_comb = load_sum_comb + dependency_issue_amount;
		if (complete_event_legal &&
			(dependency_complete_wave_id == load_scan_comb) &&
			(dependency_complete_kind == DEP_LOAD))
			load_decrement_comb = dependency_complete_amount;
		if (load_sum_comb >= load_decrement_comb) begin
			load_result_comb = load_sum_comb - load_decrement_comb;
			if (load_result_comb <= LOAD_COUNT_MAX)
				load_count_next[load_scan_comb] =
				load_result_comb[CDNA_LOAD_COUNTER_BITS-1:0];
		end	
	end
end
integer load_scan_ff;
always_ff @(posedge clk or negedge rst_n)begin
	for ( load_scan_ff = 0; load_scan_ff < NUM_WAVE_CONTEXTS; load_scan_ff = load_scan_ff +1)begin
		if (!rst_n)
			load_count[load_scan_ff] <= '0;
		else if (release_valid &&
			(release_wave_id == load_scan_ff))
			load_count[load_scan_ff] <= '0;

		else if (alloc_fire &&
			(alloc_wave_id == load_scan_ff))
			load_count[load_scan_ff] <= '0;
		else 
			load_count[load_scan_ff] <= load_count_next[load_scan_ff];
	end	
end

localparam int DEPENDENCY_CALC_BITS = DEPENDENCY_AMOUNT_BITS + 1;

// STORE: next values and intermediate arithmetic.
logic [CDNA_STORE_COUNTER_BITS-1:0] store_count_next [0:NUM_WAVE_CONTEXTS-1];
logic [DEPENDENCY_CALC_BITS-1:0] store_sum_comb;
logic [DEPENDENCY_CALC_BITS-1:0] store_decrement_comb;
logic [DEPENDENCY_CALC_BITS-1:0] store_result_comb;
localparam logic [CDNA_STORE_COUNTER_BITS-1:0] STORE_COUNT_MAX =
    {CDNA_STORE_COUNTER_BITS{1'b1}};
integer store_scan_comb;

// DS: next values and intermediate arithmetic.
logic [CDNA_DS_COUNTER_BITS-1:0] ds_count_next [0:NUM_WAVE_CONTEXTS-1];
logic [DEPENDENCY_CALC_BITS-1:0] ds_sum_comb;
logic [DEPENDENCY_CALC_BITS-1:0] ds_decrement_comb;
logic [DEPENDENCY_CALC_BITS-1:0] ds_result_comb;
localparam logic [CDNA_DS_COUNTER_BITS-1:0] DS_COUNT_MAX =
    {CDNA_DS_COUNTER_BITS{1'b1}};
integer ds_scan_comb;

// KM: next values and intermediate arithmetic.
logic [CDNA_KM_COUNTER_BITS-1:0] km_count_next [0:NUM_WAVE_CONTEXTS-1];
logic [DEPENDENCY_CALC_BITS-1:0] km_sum_comb;
logic [DEPENDENCY_CALC_BITS-1:0] km_decrement_comb;
logic [DEPENDENCY_CALC_BITS-1:0] km_result_comb;
localparam logic [CDNA_KM_COUNTER_BITS-1:0] KM_COUNT_MAX =
    {CDNA_KM_COUNTER_BITS{1'b1}};
integer km_scan_comb;

// ASYNC: next values and intermediate arithmetic.
logic [CDNA_ASYNC_COUNTER_BITS-1:0] async_count_next [0:NUM_WAVE_CONTEXTS-1];
logic [DEPENDENCY_CALC_BITS-1:0] async_sum_comb;
logic [DEPENDENCY_CALC_BITS-1:0] async_decrement_comb;
logic [DEPENDENCY_CALC_BITS-1:0] async_result_comb;
localparam logic [CDNA_ASYNC_COUNTER_BITS-1:0] ASYNC_COUNT_MAX =
    {CDNA_ASYNC_COUNTER_BITS{1'b1}};
integer async_scan_comb;

// TENSOR: next values and intermediate arithmetic.
logic [CDNA_TENSOR_COUNTER_BITS-1:0] tensor_count_next [0:NUM_WAVE_CONTEXTS-1];
logic [DEPENDENCY_CALC_BITS-1:0] tensor_sum_comb;
logic [DEPENDENCY_CALC_BITS-1:0] tensor_decrement_comb;
logic [DEPENDENCY_CALC_BITS-1:0] tensor_result_comb;
localparam logic [CDNA_TENSOR_COUNTER_BITS-1:0] TENSOR_COUNT_MAX =
    {CDNA_TENSOR_COUNTER_BITS{1'b1}};
integer tensor_scan_comb;

// X: next values and intermediate arithmetic.
logic [CDNA_X_COUNTER_BITS-1:0] x_count_next [0:NUM_WAVE_CONTEXTS-1];
logic [DEPENDENCY_CALC_BITS-1:0] x_sum_comb;
logic [DEPENDENCY_CALC_BITS-1:0] x_decrement_comb;
logic [DEPENDENCY_CALC_BITS-1:0] x_result_comb;
localparam logic [CDNA_X_COUNTER_BITS-1:0] X_COUNT_MAX =
    {CDNA_X_COUNTER_BITS{1'b1}};
integer x_scan_comb;

integer counter_scan_ff;

// Compute STORE net increment/decrement independently for every Wave.
always_comb begin
    store_sum_comb       = '0;
    store_decrement_comb = '0;
    store_result_comb    = '0;
    for (store_scan_comb = 0; store_scan_comb < NUM_WAVE_CONTEXTS; store_scan_comb = store_scan_comb + 1) begin
        store_count_next[store_scan_comb] = store_count[store_scan_comb];
        store_sum_comb =
            {{(DEPENDENCY_CALC_BITS-CDNA_STORE_COUNTER_BITS){1'b0}}, store_count[store_scan_comb]};
        store_decrement_comb = '0;
        store_result_comb    = '0;

        if (issue_event_legal &&
            (dependency_issue_wave_id == store_scan_comb) &&
            (dependency_issue_kind == DEP_STORE))
            store_sum_comb = store_sum_comb +
                {{(DEPENDENCY_CALC_BITS-DEPENDENCY_AMOUNT_BITS){1'b0}},
                 dependency_issue_amount};

        if (complete_event_legal &&
            (dependency_complete_wave_id == store_scan_comb) &&
            (dependency_complete_kind == DEP_STORE))
            store_decrement_comb =
                {{(DEPENDENCY_CALC_BITS-DEPENDENCY_AMOUNT_BITS){1'b0}},
                 dependency_complete_amount};

        if (store_sum_comb >= store_decrement_comb) begin
            store_result_comb = store_sum_comb - store_decrement_comb;
            if (store_result_comb <= STORE_COUNT_MAX)
                store_count_next[store_scan_comb] =
                    store_result_comb[CDNA_STORE_COUNTER_BITS-1:0];
        end
    end
end

// Compute DS net increment/decrement independently for every Wave.
always_comb begin
    ds_sum_comb       = '0;
    ds_decrement_comb = '0;
    ds_result_comb    = '0;
    for (ds_scan_comb = 0; ds_scan_comb < NUM_WAVE_CONTEXTS; ds_scan_comb = ds_scan_comb + 1) begin
        ds_count_next[ds_scan_comb] = ds_count[ds_scan_comb];
        ds_sum_comb =
            {{(DEPENDENCY_CALC_BITS-CDNA_DS_COUNTER_BITS){1'b0}}, ds_count[ds_scan_comb]};
        ds_decrement_comb = '0;
        ds_result_comb    = '0;

        if (issue_event_legal &&
            (dependency_issue_wave_id == ds_scan_comb) &&
            (dependency_issue_kind == DEP_DS))
            ds_sum_comb = ds_sum_comb +
                {{(DEPENDENCY_CALC_BITS-DEPENDENCY_AMOUNT_BITS){1'b0}},
                 dependency_issue_amount};

        if (complete_event_legal &&
            (dependency_complete_wave_id == ds_scan_comb) &&
            (dependency_complete_kind == DEP_DS))
            ds_decrement_comb =
                {{(DEPENDENCY_CALC_BITS-DEPENDENCY_AMOUNT_BITS){1'b0}},
                 dependency_complete_amount};

        if (ds_sum_comb >= ds_decrement_comb) begin
            ds_result_comb = ds_sum_comb - ds_decrement_comb;
            if (ds_result_comb <= DS_COUNT_MAX)
                ds_count_next[ds_scan_comb] =
                    ds_result_comb[CDNA_DS_COUNTER_BITS-1:0];
        end
    end
end

// Compute KM net increment/decrement independently for every Wave.
always_comb begin
    km_sum_comb       = '0;
    km_decrement_comb = '0;
    km_result_comb    = '0;
    for (km_scan_comb = 0; km_scan_comb < NUM_WAVE_CONTEXTS; km_scan_comb = km_scan_comb + 1) begin
        km_count_next[km_scan_comb] = km_count[km_scan_comb];
        km_sum_comb =
            {{(DEPENDENCY_CALC_BITS-CDNA_KM_COUNTER_BITS){1'b0}}, km_count[km_scan_comb]};
        km_decrement_comb = '0;
        km_result_comb    = '0;

        if (issue_event_legal &&
            (dependency_issue_wave_id == km_scan_comb) &&
            (dependency_issue_kind == DEP_KM))
            km_sum_comb = km_sum_comb +
                {{(DEPENDENCY_CALC_BITS-DEPENDENCY_AMOUNT_BITS){1'b0}},
                 dependency_issue_amount};

        if (complete_event_legal &&
            (dependency_complete_wave_id == km_scan_comb) &&
            (dependency_complete_kind == DEP_KM))
            km_decrement_comb =
                {{(DEPENDENCY_CALC_BITS-DEPENDENCY_AMOUNT_BITS){1'b0}},
                 dependency_complete_amount};

        if (km_sum_comb >= km_decrement_comb) begin
            km_result_comb = km_sum_comb - km_decrement_comb;
            if (km_result_comb <= KM_COUNT_MAX)
                km_count_next[km_scan_comb] =
                    km_result_comb[CDNA_KM_COUNTER_BITS-1:0];
        end
    end
end

// Compute ASYNC net increment/decrement independently for every Wave.
always_comb begin
    async_sum_comb       = '0;
    async_decrement_comb = '0;
    async_result_comb    = '0;
    for (async_scan_comb = 0; async_scan_comb < NUM_WAVE_CONTEXTS; async_scan_comb = async_scan_comb + 1) begin
        async_count_next[async_scan_comb] = async_count[async_scan_comb];
        async_sum_comb =
            {{(DEPENDENCY_CALC_BITS-CDNA_ASYNC_COUNTER_BITS){1'b0}}, async_count[async_scan_comb]};
        async_decrement_comb = '0;
        async_result_comb    = '0;

        if (issue_event_legal &&
            (dependency_issue_wave_id == async_scan_comb) &&
            (dependency_issue_kind == DEP_ASYNC))
            async_sum_comb = async_sum_comb +
                {{(DEPENDENCY_CALC_BITS-DEPENDENCY_AMOUNT_BITS){1'b0}},
                 dependency_issue_amount};

        if (complete_event_legal &&
            (dependency_complete_wave_id == async_scan_comb) &&
            (dependency_complete_kind == DEP_ASYNC))
            async_decrement_comb =
                {{(DEPENDENCY_CALC_BITS-DEPENDENCY_AMOUNT_BITS){1'b0}},
                 dependency_complete_amount};

        if (async_sum_comb >= async_decrement_comb) begin
            async_result_comb = async_sum_comb - async_decrement_comb;
            if (async_result_comb <= ASYNC_COUNT_MAX)
                async_count_next[async_scan_comb] =
                    async_result_comb[CDNA_ASYNC_COUNTER_BITS-1:0];
        end
    end
end

// Compute TENSOR net increment/decrement independently for every Wave.
always_comb begin
    tensor_sum_comb       = '0;
    tensor_decrement_comb = '0;
    tensor_result_comb    = '0;
    for (tensor_scan_comb = 0; tensor_scan_comb < NUM_WAVE_CONTEXTS; tensor_scan_comb = tensor_scan_comb + 1) begin
        tensor_count_next[tensor_scan_comb] = tensor_count[tensor_scan_comb];
        tensor_sum_comb =
            {{(DEPENDENCY_CALC_BITS-CDNA_TENSOR_COUNTER_BITS){1'b0}}, tensor_count[tensor_scan_comb]};
        tensor_decrement_comb = '0;
        tensor_result_comb    = '0;

        if (issue_event_legal &&
            (dependency_issue_wave_id == tensor_scan_comb) &&
            (dependency_issue_kind == DEP_TENSOR))
            tensor_sum_comb = tensor_sum_comb +
                {{(DEPENDENCY_CALC_BITS-DEPENDENCY_AMOUNT_BITS){1'b0}},
                 dependency_issue_amount};

        if (complete_event_legal &&
            (dependency_complete_wave_id == tensor_scan_comb) &&
            (dependency_complete_kind == DEP_TENSOR))
            tensor_decrement_comb =
                {{(DEPENDENCY_CALC_BITS-DEPENDENCY_AMOUNT_BITS){1'b0}},
                 dependency_complete_amount};

        if (tensor_sum_comb >= tensor_decrement_comb) begin
            tensor_result_comb = tensor_sum_comb - tensor_decrement_comb;
            if (tensor_result_comb <= TENSOR_COUNT_MAX)
                tensor_count_next[tensor_scan_comb] =
                    tensor_result_comb[CDNA_TENSOR_COUNTER_BITS-1:0];
        end
    end
end

// Compute X net increment/decrement independently for every Wave.
always_comb begin
    x_sum_comb       = '0;
    x_decrement_comb = '0;
    x_result_comb    = '0;
    for (x_scan_comb = 0; x_scan_comb < NUM_WAVE_CONTEXTS; x_scan_comb = x_scan_comb + 1) begin
        x_count_next[x_scan_comb] = x_count[x_scan_comb];
        x_sum_comb =
            {{(DEPENDENCY_CALC_BITS-CDNA_X_COUNTER_BITS){1'b0}}, x_count[x_scan_comb]};
        x_decrement_comb = '0;
        x_result_comb    = '0;

        if (issue_event_legal &&
            (dependency_issue_wave_id == x_scan_comb) &&
            (dependency_issue_kind == DEP_X))
            x_sum_comb = x_sum_comb +
                {{(DEPENDENCY_CALC_BITS-DEPENDENCY_AMOUNT_BITS){1'b0}},
                 dependency_issue_amount};

        if (complete_event_legal &&
            (dependency_complete_wave_id == x_scan_comb) &&
            (dependency_complete_kind == DEP_X))
            x_decrement_comb =
                {{(DEPENDENCY_CALC_BITS-DEPENDENCY_AMOUNT_BITS){1'b0}},
                 dependency_complete_amount};

        if (x_sum_comb >= x_decrement_comb) begin
            x_result_comb = x_sum_comb - x_decrement_comb;
            if (x_result_comb <= X_COUNT_MAX)
                x_count_next[x_scan_comb] =
                    x_result_comb[CDNA_X_COUNTER_BITS-1:0];
        end
    end
end

// Counter storage: events affecting other Waves do not suppress their updates.
always_ff @(posedge clk or negedge rst_n) begin
    for (counter_scan_ff = 0; counter_scan_ff < NUM_WAVE_CONTEXTS;
         counter_scan_ff = counter_scan_ff + 1) begin
        if (!rst_n) begin
            store_count[counter_scan_ff] <= '0;
            ds_count[counter_scan_ff] <= '0;
            km_count[counter_scan_ff] <= '0;
            async_count[counter_scan_ff] <= '0;
            tensor_count[counter_scan_ff] <= '0;
            x_count[counter_scan_ff] <= '0;
        end
        else if (release_valid && (release_wave_id == counter_scan_ff)) begin
            store_count[counter_scan_ff] <= '0;
            ds_count[counter_scan_ff] <= '0;
            km_count[counter_scan_ff] <= '0;
            async_count[counter_scan_ff] <= '0;
            tensor_count[counter_scan_ff] <= '0;
            x_count[counter_scan_ff] <= '0;
        end
        else if (alloc_fire && (alloc_wave_id == counter_scan_ff)) begin
            store_count[counter_scan_ff] <= '0;
            ds_count[counter_scan_ff] <= '0;
            km_count[counter_scan_ff] <= '0;
            async_count[counter_scan_ff] <= '0;
            tensor_count[counter_scan_ff] <= '0;
            x_count[counter_scan_ff] <= '0;
        end
        else begin
            store_count[counter_scan_ff] <= store_count_next[counter_scan_ff];
            ds_count[counter_scan_ff] <= ds_count_next[counter_scan_ff];
            km_count[counter_scan_ff] <= km_count_next[counter_scan_ff];
            async_count[counter_scan_ff] <= async_count_next[counter_scan_ff];
            tensor_count[counter_scan_ff] <= tensor_count_next[counter_scan_ff];
            x_count[counter_scan_ff] <= x_count_next[counter_scan_ff];
        end
    end
end

// 本次 Wait 事件有效，且目标 ID 合法、Wave 已分配
logic wait_arm_event_legal;

always_comb begin
    wait_arm_event_legal = 1'b0;
    wait_arm_satisfied   = 1'b0;

    if (wait_arm_valid &&
        (wait_arm_wave_id < NUM_WAVE_CONTEXTS)) begin

        if (resident_mask[wait_arm_wave_id]) begin
            wait_arm_event_legal = 1'b1;
            wait_arm_satisfied   = 1'b1;

            if (wait_counter_mask[DEP_LOAD] &&
                (load_count[wait_arm_wave_id] > wait_load_threshold))
                wait_arm_satisfied = 1'b0;

            if (wait_counter_mask[DEP_STORE] &&
                (store_count[wait_arm_wave_id] > wait_store_threshold))
                wait_arm_satisfied = 1'b0;

            if (wait_counter_mask[DEP_DS] &&
                (ds_count[wait_arm_wave_id] > wait_ds_threshold))
                wait_arm_satisfied = 1'b0;

            if (wait_counter_mask[DEP_KM] &&
                (km_count[wait_arm_wave_id] > wait_km_threshold))
                wait_arm_satisfied = 1'b0;

            if (wait_counter_mask[DEP_ASYNC] &&
                (async_count[wait_arm_wave_id] > wait_async_threshold))
                wait_arm_satisfied = 1'b0;

            if (wait_counter_mask[DEP_TENSOR] &&
                (tensor_count[wait_arm_wave_id] > wait_tensor_threshold))
                wait_arm_satisfied = 1'b0;

            if (wait_counter_mask[DEP_X] &&
                (x_count[wait_arm_wave_id] > wait_x_threshold))
                wait_arm_satisfied = 1'b0;
        end
    end
end

integer wait_scan_ff;
always_ff @(posedge clk or negedge rst_n) begin
    for (wait_scan_ff = 0;
         wait_scan_ff < NUM_WAVE_CONTEXTS;
         wait_scan_ff = wait_scan_ff + 1) begin

        if (!rst_n) begin
            wait_active[wait_scan_ff] <= '0;
            saved_wait_counter_mask[wait_scan_ff] <= '0;

            saved_wait_load_threshold[wait_scan_ff]   <= '0;
            saved_wait_store_threshold[wait_scan_ff]  <= '0;
            saved_wait_ds_threshold[wait_scan_ff]     <= '0;
            saved_wait_km_threshold[wait_scan_ff]     <= '0;
            saved_wait_async_threshold[wait_scan_ff]  <= '0;
            saved_wait_tensor_threshold[wait_scan_ff] <= '0;
            saved_wait_x_threshold[wait_scan_ff]      <= '0;
        end
        else if (wait_arm_event_legal &&
                 (wait_arm_wave_id == wait_scan_ff)) begin

            wait_active[wait_scan_ff] <= !wait_arm_satisfied;
            saved_wait_counter_mask[wait_scan_ff] <= wait_counter_mask;

            saved_wait_load_threshold[wait_scan_ff] <=
                wait_load_threshold;
            saved_wait_store_threshold[wait_scan_ff] <=
                wait_store_threshold;
            saved_wait_ds_threshold[wait_scan_ff] <=
                wait_ds_threshold;
            saved_wait_km_threshold[wait_scan_ff] <=
                wait_km_threshold;
            saved_wait_async_threshold[wait_scan_ff] <=
                wait_async_threshold;
            saved_wait_tensor_threshold[wait_scan_ff] <=
                wait_tensor_threshold;
            saved_wait_x_threshold[wait_scan_ff] <=
                wait_x_threshold;
        end
        else if (wait_wakeup_mask[wait_scan_ff]) begin
            wait_active[wait_scan_ff] <= 1'b0;
        end
    end
end

integer wait_scan_comb;

always_comb begin
    wait_satisfied_mask = '0;

    for (wait_scan_comb = 0;
         wait_scan_comb < NUM_WAVE_CONTEXTS;
         wait_scan_comb = wait_scan_comb + 1) begin

        if (wait_active[wait_scan_comb]) begin
            // 先假设该 Wave 保存的全部 Wait 条件都满足
            wait_satisfied_mask[wait_scan_comb] = 1'b1;

            if (saved_wait_counter_mask[wait_scan_comb][DEP_LOAD] &&
                (load_count[wait_scan_comb] >
                 saved_wait_load_threshold[wait_scan_comb]))
                wait_satisfied_mask[wait_scan_comb] = 1'b0;

            if (saved_wait_counter_mask[wait_scan_comb][DEP_STORE] &&
                (store_count[wait_scan_comb] >
                 saved_wait_store_threshold[wait_scan_comb]))
                wait_satisfied_mask[wait_scan_comb] = 1'b0;

            if (saved_wait_counter_mask[wait_scan_comb][DEP_DS] &&
                (ds_count[wait_scan_comb] >
                 saved_wait_ds_threshold[wait_scan_comb]))
                wait_satisfied_mask[wait_scan_comb] = 1'b0;

            if (saved_wait_counter_mask[wait_scan_comb][DEP_KM] &&
                (km_count[wait_scan_comb] >
                 saved_wait_km_threshold[wait_scan_comb]))
                wait_satisfied_mask[wait_scan_comb] = 1'b0;

            if (saved_wait_counter_mask[wait_scan_comb][DEP_ASYNC] &&
                (async_count[wait_scan_comb] >
                 saved_wait_async_threshold[wait_scan_comb]))
                wait_satisfied_mask[wait_scan_comb] = 1'b0;

            if (saved_wait_counter_mask[wait_scan_comb][DEP_TENSOR] &&
                (tensor_count[wait_scan_comb] >
                 saved_wait_tensor_threshold[wait_scan_comb]))
                wait_satisfied_mask[wait_scan_comb] = 1'b0;

            if (saved_wait_counter_mask[wait_scan_comb][DEP_X] &&
                (x_count[wait_scan_comb] >
                 saved_wait_x_threshold[wait_scan_comb]))
                wait_satisfied_mask[wait_scan_comb] = 1'b0;
        end
    end
end

integer zero_scan_comb;

always_comb begin
    all_counters_zero_mask = '0;

    for (zero_scan_comb = 0;
         zero_scan_comb < NUM_WAVE_CONTEXTS;
         zero_scan_comb = zero_scan_comb + 1) begin

        all_counters_zero_mask[zero_scan_comb] = ({
            load_count[zero_scan_comb],
            store_count[zero_scan_comb],
            ds_count[zero_scan_comb],
            km_count[zero_scan_comb],
            async_count[zero_scan_comb],
            tensor_count[zero_scan_comb],
            x_count[zero_scan_comb]
        } == '0);
    end
end

endmodule

`default_nettype wire
