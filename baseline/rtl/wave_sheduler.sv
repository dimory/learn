// ============================================================================
// TinyGPU M2 Wave Scheduler
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// This module selects one READY resident Wave and presents its wave_id to the
// execution port through a valid/ready handshake.
//
// Selection uses Round-Robin arbitration. A successful handshake advances the
// Round-Robin pointer to the entry immediately following the accepted Wave.
//
// If the execution port applies backpressure, the Scheduler saves the selected
// Wave ID and keeps the selection stable until it is accepted.
//
// This module does not own Wave lifecycle state, architectural registers,
// dependency counters or Kernel dispatch information.
//
// Microarchitecture
// -----------------------------------------------------------------------------
//
// The Scheduler contains three functional parts:
//
// 1. Round-Robin candidate selection
//    - Inputs: ready_mask and round_robin_pointer.
//    - Scans all Context entries in circular order.
//    - Selects the first READY entry.
//    - Produces candidate_valid and candidate_wave_id.
//
// 2. Selected-Wave output selection
//    - When locked, outputs the saved locked_wave_id.
//    - Otherwise, outputs the current Round-Robin candidate.
//    - Outputs an invalid selection when no candidate exists.
//
// 3. Round-Robin and backpressure registers
//    - round_robin_pointer stores the next scan starting point.
//    - locked records whether a selection is waiting for acceptance.
//    - locked_wave_id stores the Wave ID held during backpressure.
//
// Wave ID meaning
// -----------------------------------------------------------------------------
//
// selected_wave_id identifies an entry in wave_context_table.
//
// It is not the Wave's index inside its Workgroup. The Context entry stores
// the Workgroup ID, Workgroup-local Wave index and other dispatch metadata.
//
// Scheduler interface
// -----------------------------------------------------------------------------
//
// Signal              Meaning
// ------------------  --------------------------------------------------------
// ready_mask          One bit per resident Context entry.
//                     Bit N is 1 when Context entry N is READY.
//
// selected_valid      A valid Wave selection is being presented.
//
// selected_ready      The execution port can accept the presented Wave.
//
// selected_wave_id    Context entry selected for execution.
//
// clk                 Clock used to accept selections and update registers.
//
// rst_n               Asynchronous active-low reset.
//
// ready_mask is supplied by wave_context_table. selected_ready is supplied by
// the execution port.
//
// The selected Wave ID is also connected to the Context Table's read port so
// the execution port can obtain that Wave's architectural context.
//
// Allocation and scheduling are separate operations. This module schedules
// already allocated resident Waves; it does not allocate FREE entries.
//
// Scheduling handshake
// -----------------------------------------------------------------------------
//
//     schedule_fire = selected_valid && selected_ready
//
// A scheduling transfer occurs on a rising clock edge when schedule_fire is 1.
//
// The control subsystem sends this event to wave_context_table as issue_valid,
// together with selected_wave_id as issue_wave_id.
//
// The accepted Context entry then changes:
//
//     WAVE_STATE_READY -> WAVE_STATE_ISSUED
//
// The Scheduler does not directly write the Context state.
//
// selected_valid and selected_ready are level signals. If both remain high
// over consecutive clock edges, one scheduling transfer occurs on each edge.
//
// Round-Robin candidate selection
// -----------------------------------------------------------------------------
//
// The scan starts at round_robin_pointer and visits every entry once.
//
// For each scan position:
//
//     index = round_robin_pointer + scan_offset
//
// If index reaches NUM_WAVE_CONTEXTS, subtract NUM_WAVE_CONTEXTS to wrap around.
//
// The first entry whose ready_mask bit is 1 becomes the candidate. Later READY
// entries must not overwrite that candidate.
//
// Example:
//
//     NUM_WAVE_CONTEXTS = 4
//     ready_mask        = 4'b1011
//     pointer           = 2
//
// Scan order:
//
//     2, 3, 0, 1
//
// Entry 2 is not READY. Entry 3 is READY, so the selected candidate is Wave 3.
//
// If no entry is READY:
//
//     candidate_valid   = 0
//     candidate_wave_id = 0
//
// Pointer update
// -----------------------------------------------------------------------------
//
// The pointer changes only when schedule_fire is 1.
//
// The next pointer is the entry following selected_wave_id:
//
//     accepted ID 0 -> pointer 1
//     accepted ID 1 -> pointer 2
//     accepted ID 2 -> pointer 3
//     accepted ID 3 -> pointer 0
//
// This is based on the accepted Wave ID, not simply the previous pointer + 1.
//
// Explicit wraparound must also support non-power-of-two Context counts.
// For NUM_WAVE_CONTEXTS == 1, the pointer remains 0.
//
// Backpressure and selection locking
// -----------------------------------------------------------------------------
//
// When:
//
//     selected_valid = 1
//     selected_ready = 0
//
// the selected Wave ID must remain stable until acceptance.
//
// On the first stalled rising edge, the Scheduler saves the selected ID and
// sets locked. While locked, newly READY Waves cannot replace that selection.
//
// A successful scheduling handshake clears locked and advances the pointer.
//
// The Context Table must keep the selected entry READY until schedule_fire.
// Its READY -> ISSUED transition occurs only when the selection is accepted.
//
// Register update rules
// -----------------------------------------------------------------------------
//
// Condition                         Action
// --------------------------------  ------------------------------------------
// Reset                             Clear pointer and lock information.
// No valid selection                Hold pointer; remain unlocked.
// Valid selection, not accepted     Save selection and lock it.
// Locked selection, not accepted    Hold pointer and saved selection.
// Successful handshake              Advance pointer and clear lock.
//
// Reset behavior
// -----------------------------------------------------------------------------
//
// rst_n is asynchronous and active-low.
//
// On reset:
//
// - round_robin_pointer = 0;
// - locked              = 0;
// - locked_wave_id      = 0;
// - selected_valid      = 0;
// - selected_wave_id    = 0;
// - schedule_fire       = 0.
//
// Verification requirements
// -----------------------------------------------------------------------------
//
// The verification environment checks:
//
// - Every accepted Wave was READY before the accepting clock edge.
// - Selection remains stable while valid is high and ready is low.
// - The pointer changes only on schedule_fire.
// - The pointer wraps correctly.
// - No selection is issued when no READY Wave exists.
// - With continued downstream acceptance, persistently READY Waves are served.
// - Reset discards any previously locked selection.
//
// Module summary and future upgrades
// -----------------------------------------------------------------------------
//
// M2 provides a single-port Round-Robin Scheduler for resident READY Waves.
//
// It separates selection from Context ownership and preserves the selected
// payload during execution-port backpressure.
//
// Later milestones may add execution-class eligibility, dependency-aware
// candidate masks or several issue ports. Wave architectural state remains
// owned by the Context Table and related state-storage modules.
// ============================================================================
module wave_scheduler #(
    parameter int NUM_WAVE_CONTEXTS =
        gpu_pkg::CDNA_NUM_RESIDENT_WAVES,

    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ?
        $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic [NUM_WAVE_CONTEXTS-1:0] ready_mask,

    output logic                         selected_valid,
    input  logic                         selected_ready,
    output logic [WAVE_ID_BITS-1:0]      selected_wave_id
);

    // Round-Robin扫描起点
    logic [WAVE_ID_BITS-1:0] round_robin_pointer;
	logic [WAVE_ID_BITS-1:0] round_robin_pointer_nxt;
    // 背压期间保存选中的Wave
    logic                    locked;
    logic [WAVE_ID_BITS-1:0] locked_wave_id;

    // 当前Round-Robin组合仲裁结果
    logic                    candidate_valid;
    logic [WAVE_ID_BITS-1:0] candidate_wave_id;

    // 当前选择被执行端接受
    logic schedule_fire;

    // 组合扫描变量
    integer scan_comb;
    integer index_comb;

    // 后续由你逐块实现
always_ff @(posedge clk or negedge rst_n)begin
	if(!rst_n)
		round_robin_pointer <= '0;
	else 
		round_robin_pointer <= round_robin_pointer_nxt;
end


assign 	round_robin_pointer_nxt = 
		(schedule_fire && selected_wave_id == NUM_WAVE_CONTEXTS-1) ?
		'0 : schedule_fire ? 
		(selected_wave_id + 1'b1): round_robin_pointer;


always_comb begin
	candidate_valid = '0;
	candidate_wave_id = '0;
	for (scan_comb = 0; scan_comb < NUM_WAVE_CONTEXTS ; scan_comb = scan_comb +1)begin
		index_comb = scan_comb + round_robin_pointer;
		if (index_comb >= NUM_WAVE_CONTEXTS)
			index_comb = index_comb - NUM_WAVE_CONTEXTS;
		if( ready_mask[index_comb] == 1'b1&&!candidate_valid)begin
			candidate_valid = 1'b1;
			candidate_wave_id = index_comb;
		end
	end

end	
aalways_comb begin
    selected_valid   = '0;
    selected_wave_id = '0;

    if (rst_n) begin
        if (locked) begin
            selected_valid   = 1'b1;
            selected_wave_id = locked_wave_id;
        end
        else if (candidate_valid) begin
            selected_valid   = 1'b1;
            selected_wave_id = candidate_wave_id;
        end
    end
end
assign schedule_fire = selected_valid && selected_ready;

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		locked <= '0;
		locked_wave_id <= '0;
	end
	else if (schedule_fire)
		locked <='0;
	else if (selected_valid && !selected_ready)begin
		locked_wave_id <= selected_wave_id;
		locked <= 1'b1;
	end
end

endmodule

