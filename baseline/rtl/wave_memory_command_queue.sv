`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU M4 G01: wave_memory_command_queue
// ============================================================================
// Function and state ownership
// -----------------------------------------------------------------------------
// Accept complete M3 memory commands into COMMAND_SLOTS independent entries.
// Every entry retains its original request, resident Wave ID, acceptance
// sequence, generation state, dispatch progress, and backend completion state.
// One Wave may own several command entries. A command entry is retained until
// the complete response is accepted by M3 (response_fire), including stores.
//
// A round-robin selector starts at most one eligible command per rising edge:
//   generator[0] -> G02 wave_global_coalescer
//   generator[1] -> G07 wave_scalar_memory_path
//   generator[2] -> G10 lds_wave_engine
// The selector admits only a ready destination; each admitted generator then
// retains its own command. Same-Wave generation ordering is checked before
// selection. The sequence comparison uses an 8-bit half-range ordering rule.
//
// Per-entry lifecycle:
//   command_accept -> allocated
//   generator admission -> started
//   generation_finished -> generation_done
//   generation_done && no queued/held subrequests -> dispatch_done
//   backend_finished -> backend_done
//   response_fire -> release the command entry
// These events describe different boundaries; none substitutes for RF writeback
// or for the M3 dependency-complete notification.
//
// dispatch_pending counts subrequests enqueued but not yet accepted by a Cache.
// Apply enqueue and dispatch contributions together when they occur on one edge.
// LDS admission is reported through generation_finished by the structural top;
// it does not enqueue sector descriptors in G03.
//
// Independent launch coordination:
//   LAUNCH_IDLE -> LAUNCH_INVALIDATE -> LAUNCH_START -> LAUNCH_IDLE
// Capture launch fields once, round supported LDS sizes to 2 KiB, wait for both
// Caches to become idle, invalidate them, and pulse compute_start for M3.
// Use state/next_state for this FSM. Command entries remain per-entry state;
// the launch FSM does not serialize all commands through one shared command FSM.
//
// Final connections
// -----------------------------------------------------------------------------
// M3 F13 -> mem_req_*.
// G01 -> G02/G07/G10 through generator_*.
// G01 -> G04 through command records and lifecycle query outputs.
// G01 -> G05 through command_accept/profile_error/accepted_slot and query state.
// G03 -> enqueue_*; G04 -> dispatch_*; G05 -> backend_finished.
// G02/G07/G10 -> generation_finished, combined by T41.
// G12 -> response_*; T42/M3 -> external_start/launch_*/compute_* status.
// G06 Cache pair -> caches_idle; G01 -> invalidate and saved launch/compute_start.
//
// Timing and reset
// -----------------------------------------------------------------------------
// Valid/ready transfers are sampled at rising clock edges. Single-edge progress
// events have no second handshake. New entries participate in selection from
// the following cycle. Free-entry selection uses the current allocated bitmap;
// a releasing entry becomes reusable after the release edge.
// Control registers use asynchronous active-low reset. Payload storage is
// qualified by allocated/start state and need not be cleared on reset.
// Combinational logic does not gate rst_n. The system jointly flushes backend
// ownership on reset. Interface and ordering requirements follow the frozen
// M4_MEMORY_SUBSYSTEM_SPEC.md.
// ============================================================================

module wave_memory_command_queue #(
    parameter int NUM_WAVE_CONTEXTS       = 4,
    parameter int COMMAND_SLOTS           = 16,
    parameter int MAX_GROUP_SEGMENT_BYTES = 4096,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1,
    parameter int SLOT_BITS =
        (COMMAND_SLOTS > 1) ? $clog2(COMMAND_SLOTS) : 1
) (
    input  logic clk,
    input  logic rst_n,

    // Complete command admission from M3 F13.
    input  logic mem_req_valid,
    output logic mem_req_ready,
    input  logic [WAVE_ID_BITS-1:0] mem_req_wave_id,
    input  gpu_pkg::m3_memory_request_t mem_req_payload,
    output logic command_accept,
    output logic command_profile_error,
    output logic [7:0] accepted_slot,

    // Per-command lifecycle and original-request queries.
    output logic [COMMAND_SLOTS-1:0] allocated,
    output logic [COMMAND_SLOTS-1:0] generation_done,
    output logic [COMMAND_SLOTS-1:0] dispatch_done,
    output logic [COMMAND_SLOTS-1:0] backend_done,
    output gpu_pkg::m3_memory_request_t commands [0:COMMAND_SLOTS-1],
    output logic [WAVE_ID_BITS-1:0] command_wave [0:COMMAND_SLOTS-1],
    output logic [7:0] sequence_id [0:COMMAND_SLOTS-1],

    // Shared command payload with a one-hot Global/Scalar/LDS destination.
    output logic [2:0] generator_valid,
    input  logic [2:0] generator_ready,
    output logic [7:0] generator_slot,
    output gpu_pkg::m3_memory_request_t generator_payload,

    // Per-command progress events from the physical backend.
    input  logic [COMMAND_SLOTS-1:0] generation_finished,
    input  logic enqueue_fire,
    input  logic [7:0] enqueue_slot,
    input  logic dispatch_fire,
    input  logic [7:0] dispatch_slot,
    input  logic [COMMAND_SLOTS-1:0] backend_finished,
    input  logic response_fire,
    input  logic [7:0] response_slot,

    // External launch and current M3 compute status.
    input  logic external_start,
    input  logic compute_busy,
    input  logic compute_done,
    input  logic compute_fault,
    input  logic [63:0] launch_pc,
    input  logic [31:0] launch_threads,
    input  logic [31:0] launch_group_bytes,
    input  logic [5:0] launch_user_count,
    input  logic [1023:0] launch_user_data,
    input  logic [24:0] launch_dispatch,

    // Cache startup invalidation and the saved launch sent to M3.
    input  logic caches_idle,
    output logic invalidate,
    output logic launch_pending,
    output logic compute_start,
    output logic [63:0] saved_pc,
    output logic [31:0] saved_threads,
    output logic [31:0] saved_group_bytes,
    output logic [5:0] saved_user_count,
    output logic [1023:0] saved_user_data,
    output logic [24:0] saved_dispatch
);

import gpu_pkg::*;

// Per-entry generation admission and queued/held subrequest counts.
logic [COMMAND_SLOTS-1:0] started;
logic [5:0] dispatch_pending [0:COMMAND_SLOTS-1];

// Next memory-command acceptance sequence for each resident Wave.
logic [7:0] next_sequence [0:NUM_WAVE_CONTEXTS-1];

// Lowest-numbered free command-entry selection.
logic free_valid;
logic [SLOT_BITS-1:0] free_slot;

// Round-robin command-generation selection.
logic [SLOT_BITS-1:0] pointer;
logic choice_valid;
logic [SLOT_BITS-1:0] choice;
logic [1:0] path;
logic generation_ordered;
logic [7:0] delta;

// Extended addition prevents overflow before 2 KiB rounding.
logic [32:0] rounded_bytes;

// Launch FSM; independent of the per-command lifecycle bitmaps.
typedef enum logic [1:0] {
    LAUNCH_IDLE       = 2'd0,
    LAUNCH_INVALIDATE = 2'd1,
    LAUNCH_START      = 2'd2
} launch_state_t;

launch_state_t state;
launch_state_t next_state;

// Combinational loop and arithmetic temporaries.
integer free_scan;
integer scan;
integer index;
integer older;
integer profile_lane;

// Sequential update loops and combined dispatch-count arithmetic.
integer c;
integer w;
integer next_dispatch;

assign mem_req_ready = free_valid;

assign command_accept =
    mem_req_valid && mem_req_ready;

assign accepted_slot = 8'(free_slot);	

always_comb begin
	free_slot = '0;
	free_valid = '0;
	for ( free_scan = 0; free_scan < COMMAND_SLOTS; free_scan = free_scan + 1)
		begin
			if (!allocated[free_scan] && !free_valid)begin
				free_valid = 1'b1;
				free_slot   = SLOT_BITS'(free_scan);
			end	
		end
end


always_comb begin
	command_profile_error = 1'b0;
	for (profile_lane = 0 ; profile_lane < 32; profile_lane = profile_lane + 1)begin		 
		if(mem_req_payload.active_mask[profile_lane] &&
		(mem_req_payload.space != MEM_SPACE_LDS) &&
		(mem_req_payload.addresses[profile_lane*64 +: 2] != 2'b00))
			command_profile_error = 1'b1;
	end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        allocated       <= '0;
        started         <= '0;
        generation_done <= '0;
        dispatch_done   <= '0;
        backend_done    <= '0;

        for (c = 0; c < COMMAND_SLOTS; c = c + 1) begin
            dispatch_pending[c] <= '0;
        end

        for (w = 0; w < NUM_WAVE_CONTEXTS; w = w + 1) begin
            next_sequence[w] <= '0;
        end
    end
    else begin
		for (c = 0; c < COMMAND_SLOTS; c = c + 1) begin
			// Calculate the pending count after this cycle's events.
			next_dispatch = int'(dispatch_pending[c]);

			if (enqueue_fire && (enqueue_slot == 8'(c)))
				next_dispatch = next_dispatch + 1;

			if (dispatch_fire && (dispatch_slot == 8'(c)))
				next_dispatch = next_dispatch - 1;

			dispatch_pending[c] <= 6'(next_dispatch);

			// Record completion of transaction generation.
			if (generation_finished[c])
				generation_done[c] <= 1'b1;

			// All transactions have been generated and dispatched.
			if ((generation_done[c] || generation_finished[c]) &&
				(next_dispatch == 0))
				dispatch_done[c] <= 1'b1;

			// Record completion of backend processing.
			if (backend_finished[c])
				backend_done[c] <= 1'b1;
		end
		if (choice_valid)
			started[choice] <= 1'b1;
		if (response_fire)begin
			allocated[response_slot] 			<= '0;
			started[response_slot]				<= '0;
			generation_done[response_slot]		<= '0;
			dispatch_done[response_slot]		<= '0;
			backend_done[response_slot]			<= '0;
			dispatch_pending[response_slot]		<= '0;	
		end		
		if (command_accept)begin
			allocated[free_slot] 			<= 1'b1;
			commands[free_slot]  			<= mem_req_payload;
			command_wave[free_slot] 		<= mem_req_wave_id;
			sequence_id[free_slot]			<= next_sequence[mem_req_wave_id];
			next_sequence[mem_req_wave_id]  <= next_sequence[mem_req_wave_id] + 1'b1;
			started[free_slot]				<= command_profile_error;
			generation_done[free_slot] 		<= command_profile_error;
			dispatch_done[free_slot]  		<= command_profile_error;
			backend_done[free_slot]	   		<= '0;
			dispatch_pending[free_slot] 	<= '0;
		end
    end
end

always_comb begin
    choice_valid       = 1'b0;
    choice             = '0;
    index              = 0;
    older              = 0;
    path               = '0;
    generation_ordered = 1'b1;
    delta              = '0;

    for (scan = 0; scan < COMMAND_SLOTS; scan = scan + 1) begin
        // Scan command slots in round-robin order.
        index = int'(pointer) + scan;

        if (index >= COMMAND_SLOTS)
            index = index - COMMAND_SLOTS;

        // Select the destination generator.
        case (commands[index].space)
            MEM_SPACE_GLOBAL: path = 2'd0;
            MEM_SPACE_SCALAR: path = 2'd1;
            MEM_SPACE_LDS:    path = 2'd2;
            default:          path = 2'd0;
        endcase

        // Recalculate ordering eligibility for this candidate.
        generation_ordered = 1'b1;

        if (allocated[index] &&
            ((commands[index].space == MEM_SPACE_GLOBAL) ||
             (commands[index].space == MEM_SPACE_LDS))) begin

            for (older = 0;
                 older < COMMAND_SLOTS;
                 older = older + 1) begin

                // Eight-bit modular sequence difference.
                delta = sequence_id[index] - sequence_id[older];

                if (allocated[older] &&
                    (command_wave[older] == command_wave[index]) &&
                    (commands[older].space == commands[index].space) &&
                    (delta != 8'd0) &&
                    !delta[7]) begin

                    if ((commands[index].space == MEM_SPACE_GLOBAL) &&
                        !generation_done[older]) begin
                        generation_ordered = 1'b0;
                    end
                    else if ((commands[index].space == MEM_SPACE_LDS) &&
                             !backend_done[older]) begin
                        generation_ordered = 1'b0;
                    end
                end
            end
        end

        // Select the first eligible command in scan order.
        if (!choice_valid &&
            allocated[index] &&
            !started[index] &&
            generator_ready[path] &&
            generation_ordered) begin

            choice_valid = 1'b1;
            choice       = SLOT_BITS'(index);
        end
    end
end
assign generator_slot    = 8'(choice);
assign generator_payload = commands[choice];

always_comb begin
	generator_valid = '0;
	if (choice_valid)begin
		case (generator_payload.space)
            MEM_SPACE_GLOBAL: generator_valid = 3'b001;
            MEM_SPACE_SCALAR: generator_valid = 3'b010;
            MEM_SPACE_LDS:    generator_valid = 3'b100;
            default:          generator_valid = '0;
        endcase			
	end
end

always_ff @( posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		pointer <= '0;
	end
	else if (choice_valid)begin
		 if (choice == SLOT_BITS'(COMMAND_SLOTS - 1))
			pointer <= '0;
		else 
			pointer <= choice + 1'b1;	
	end
end

assign rounded_bytes =
    ({1'b0, launch_group_bytes} + 33'd2047) &
    33'h1fffff800;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        saved_pc          <= '0;
        saved_threads     <= '0;
        saved_user_count  <= '0;
        saved_user_data   <= '0;
        saved_dispatch    <= '0;
        saved_group_bytes <= '0;
    end
    else if ((state == LAUNCH_IDLE) &&
             external_start &&
             !compute_busy &&
             !compute_done &&
             !compute_fault) begin

        saved_pc         <= launch_pc;
        saved_threads    <= launch_threads;
        saved_user_count <= launch_user_count;
        saved_user_data  <= launch_user_data;
        saved_dispatch   <= launch_dispatch;

        if (launch_group_bytes > MAX_GROUP_SEGMENT_BYTES)
            saved_group_bytes <= launch_group_bytes;
        else
            saved_group_bytes <= rounded_bytes[31:0];
    end
end


always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)
		state <= LAUNCH_IDLE;
	else 
		state <= next_state;
end
assign launch_pending =
    (state != LAUNCH_IDLE);

assign invalidate =
    (state == LAUNCH_INVALIDATE) && caches_idle;

assign compute_start =
    (state == LAUNCH_START);
always_comb begin
	next_state = state;
	case (state)
		LAUNCH_IDLE : begin
			next_state = (external_start && !compute_busy && !compute_done && !compute_fault) ? LAUNCH_INVALIDATE : LAUNCH_IDLE;
		end
		LAUNCH_INVALIDATE : begin
			next_state	= caches_idle ? LAUNCH_START : LAUNCH_INVALIDATE;
		end
		LAUNCH_START : begin
			next_state = LAUNCH_IDLE;
		end
		default : begin
			next_state = LAUNCH_IDLE;
		end
	endcase

end

endmodule

`default_nettype wire
