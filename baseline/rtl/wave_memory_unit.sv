`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU M3 Wave Memory Unit
// ============================================================================
//
// Purpose
// -----------------------------------------------------------------------------
// Execute scalar/global/LDS memory instructions through a Wave-level command
// interface. Track outstanding commands until their completion notification.
//
// Microarchitecture
// -----------------------------------------------------------------------------
// - One sending slot captures a command and its architectural commit descriptor.
// - A shared Tag table tracks outstanding commands from all resident Waves.
// - Each Tag saves Wave ID, destination, active mask, dependency kind,
//   sequence number and original instruction information.
// - Responses enter a FIFO and recover their metadata through transaction_id.
// - Loads produce RF writeback packets. Stores complete through backend ack.
// - Request sending, response handling and completion notification operate
//   concurrently.
//
// Sending state machine
// -----------------------------------------------------------------------------
// IDLE:
//   Accept an instruction. Reserve a Tag for an active command.
//   An inactive vector instruction proceeds directly to COMMIT.
//
// REQUEST:
//   Hold the saved command until the memory backend accepts it.
//
// COMMIT:
//   Hold the acceptance commit until Writeback/Commit consumes it.
//   Return to IDLE without waiting for the memory response.
//
// Event ownership
// -----------------------------------------------------------------------------
// - issue_fire reserves a Tag but does not increment dependency counters.
// - mem_req_fire marks the Tag sent and generates dependency issue, amount=1.
// - A Load response must finish RF writeback before becoming complete.
// - A Store response represents a completed-write acknowledgement.
// - LOAD/STORE/DS notify in per-Wave, per-kind issue order.
// - KM completion notification may occur out of order.
// - A Tag is released on its dependency completion notification edge.
//
// Masks and backpressure
// -----------------------------------------------------------------------------
// - Addresses, Store data and active mask are captured at instruction acceptance.
// - Load writeback uses the saved mask, independently of later EXEC changes.
// - SMEM uses lane 0 and executes regardless of EXEC.
// - An inactive vector instruction generates no backend request or counter event.
// - Request, commit and result payloads remain stable while stalled.
//
// Configuration
// -----------------------------------------------------------------------------
// - Default: 16 shared Tags and a four-entry response FIFO.
// - Supported Tag count: 1..31 for the current amount=1 admission model.
// - Physical transaction splitting/coalescing belongs to the later backend.
// ============================================================================

module wave_memory_unit #(
    parameter int NUM_WAVE_CONTEXTS = 4,
    parameter int NUM_MEMORY_TAGS   = 16,
    parameter int RETURN_FIFO_DEPTH = 4,

    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1,

    parameter int TAG_BITS =
        (NUM_MEMORY_TAGS > 1) ? $clog2(NUM_MEMORY_TAGS) : 1,

    parameter int FIFO_BITS =
        (RETURN_FIFO_DEPTH > 1) ? $clog2(RETURN_FIFO_DEPTH) : 1,

    parameter int FIFO_COUNT_BITS =
        $clog2(RETURN_FIFO_DEPTH + 1)
) (
    input logic clk,
    input logic rst_n,

    // Instruction input from Operand Collector.
    input  logic issue_valid,
    output logic issue_ready,
    input  logic [WAVE_ID_BITS-1:0] issue_wave_id,
    input  gpu_pkg::m3_operand_payload_t issue_payload,
    input  logic [31:0] group_segment_bytes,

    // Saved command sent to the memory backend.
    output logic mem_req_valid,
    input  logic mem_req_ready,
    output logic [WAVE_ID_BITS-1:0] mem_req_wave_id,
    output gpu_pkg::m3_memory_request_t mem_req_payload,

    // Backend response: Load data or Store acknowledgement.
    input  logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input  gpu_pkg::m3_memory_response_t mem_rsp_payload,

    // Request-acceptance PC commit.
    output logic memory_commit_valid,
    input  logic memory_commit_ready,
    output logic [WAVE_ID_BITS-1:0] memory_commit_wave_id,
    output gpu_pkg::m3_commit_t memory_commit_payload,

    // Load result sent to Writeback.
    output logic result_valid,
    input  logic result_ready,
    output logic [WAVE_ID_BITS-1:0] result_wave_id,
    output gpu_pkg::m3_result_t result_payload,

    // Dependency events; each event represents amount=1.
    output logic dependency_issue_valid,
    output logic [WAVE_ID_BITS-1:0] dependency_issue_wave_id,
    output gpu_pkg::dependency_kind_t dependency_issue_kind,

    output logic dependency_complete_valid,
    output logic [WAVE_ID_BITS-1:0] dependency_complete_wave_id,
    output gpu_pkg::dependency_kind_t dependency_complete_kind,

    // Response error information.
    output logic fault_valid,
    output logic [WAVE_ID_BITS-1:0] fault_wave_id,
    output logic [63:0] fault_pc,
    output logic [31:0] fault_instruction,

    // Outstanding Tag visibility.
    output logic [NUM_MEMORY_TAGS-1:0] allocated_mask
);

import gpu_pkg::*;

// Sending-slot state.
localparam logic [1:0] IDLE    = 2'd0;
localparam logic [1:0] REQUEST = 2'd1;
localparam logic [1:0] COMMIT  = 2'd2;

logic [1:0] state;
logic [1:0] next_state;

// Interface handshakes.
logic issue_fire;
logic mem_req_fire;
logic mem_rsp_fire;
logic memory_commit_fire;
logic result_fire;

// Metadata belonging to one outstanding memory command.
typedef struct packed {
    logic allocated;
    logic sent;
    logic rf_done;
    logic is_load;

    logic [WAVE_ID_BITS-1:0] wave_id;
    dependency_kind_t kind;

    operand_kind_t dst_kind;
    logic [9:0] dst_index;
    logic [4:0] dst_count;
    logic [31:0] mask;

    logic [7:0] sequence_id;
    logic [63:0] origin_pc;
    logic [31:0] instruction0;
} tag_t;

tag_t tags [0:NUM_MEMORY_TAGS-1];

// Per-Wave, per-kind allocation and completion sequence numbers.
logic [7:0] next_sequence
    [0:NUM_WAVE_CONTEXTS-1][0:DEPENDENCY_COUNTER_COUNT-1];

logic [7:0] head_sequence
    [0:NUM_WAVE_CONTEXTS-1][0:DEPENDENCY_COUNTER_COUNT-1];

// Incoming command preparation and saved sending slot.
m3_memory_request_t prepared;
m3_memory_request_t command;
m3_commit_t command_commit;

logic [WAVE_ID_BITS-1:0] command_wave;
dependency_kind_t prepared_kind;
logic no_active;

logic [63:0] address;
logic [63:0] offset;

// Tag allocation and response lookup.
logic free_valid;
logic [TAG_BITS-1:0] free_tag;
logic [TAG_BITS-1:0] request_tag;
logic [TAG_BITS-1:0] response_tag;
logic [TAG_BITS-1:0] head_tag;

// Backend response FIFO.
m3_memory_response_t response_fifo [0:RETURN_FIFO_DEPTH-1];

logic [FIFO_BITS-1:0] fifo_read;
logic [FIFO_BITS-1:0] fifo_write;
logic [FIFO_COUNT_BITS-1:0] fifo_count;

logic fifo_push;
logic fifo_pop;

// Completion notification arbitration.
logic complete_valid;
logic [TAG_BITS-1:0] complete_tag;
logic [TAG_BITS-1:0] complete_pointer;

// Independent combinational loop variables.
integer t;
integer lane;
integer p;
integer scan;
integer index;

// Sequential reset/update loop variables.
integer ft;
integer w;
integer k;
integer ff_fifo;
assign issue_ready = (state == IDLE) && free_valid;
assign issue_fire  = issue_valid && issue_ready;
always_comb begin
	free_valid     = 1'b0;
	free_tag       = '0;
	allocated_mask = '0;
	for (t = 0; t < NUM_MEMORY_TAGS; t = t + 1)begin
		allocated_mask[t] = tags[t].allocated;
		if(!allocated_mask[t] && !free_valid)begin
			free_tag = TAG_BITS'(t);
			free_valid = 1'b1;
		end
	end
end

always_comb begin
    prepared = '0;

    prepared.transaction_id = 8'(free_tag);
    prepared.space = issue_payload.decoded.uop.mem_space;
    prepared.operation = issue_payload.decoded.uop.mem_operation;
    prepared.workgroup_id =
        issue_payload.decoded.context_data.workgroup_id;
    prepared.group_segment_bytes = group_segment_bytes;

    // Default: vector memory follows the captured EXEC mask.
    prepared.active_mask =
        issue_payload.decoded.context_data.exec_mask[31:0];	
    if(prepared.space == MEM_SPACE_SCALAR)
		prepared.active_mask = 32'b1;
	else if (prepared.space == MEM_SPACE_GLOBAL || prepared.space == MEM_SPACE_LDS)
		    prepared.active_mask =
				issue_payload.decoded.context_data.exec_mask[31:0];	
		

    no_active = !(|prepared.active_mask);

    prepared_kind = DEP_LOAD;
	if (prepared.space == MEM_SPACE_SCALAR)
		prepared_kind = DEP_KM;
	else if (prepared.space == MEM_SPACE_LDS)
		prepared_kind = DEP_DS;
	else if (prepared.operation == MEM_OP_STORE)
		prepared_kind = DEP_STORE;
	else
		prepared_kind = DEP_LOAD;


    prepared.kind = prepared_kind;
// Sign-extend the 24-bit instruction offset to 64 bits.
	offset = {
		{40{issue_payload.decoded.uop.mem_offset[23]}},
		issue_payload.decoded.uop.mem_offset
	};

	address = '0;

	for (lane = 0; lane < 32; lane = lane + 1) begin
		if (prepared.space == MEM_SPACE_LDS) begin
			address = {32'b0,(issue_payload.src0[lane*64 +: 32] + issue_payload.decoded.uop.mem_offset[15:0])} ;
		end
		else if ((prepared.space == MEM_SPACE_GLOBAL) &&
				 issue_payload.decoded.uop.mem_gvs) begin
			address = issue_payload.src1[lane*64 +: 64] + {{32{issue_payload.src0[lane*64 + 31]}},issue_payload.src0[lane*64 +: 32]} + offset;
		end
		else begin
			address = issue_payload.src0[lane*64 +: 64] + offset;
		end

		prepared.addresses[lane*64 +: 64] = address;

		prepared.store_data[lane*32 +: 32] =
			issue_payload.src2[lane*64 +: 32];
	end	
    // Address and store-data generation will be added here.
end
assign mem_req_valid   = (state == REQUEST);
assign mem_req_wave_id = command_wave;
assign mem_req_payload = command;
assign mem_req_fire    = mem_req_valid && mem_req_ready;

assign memory_commit_valid   = (state == COMMIT);
assign memory_commit_wave_id = command_wave;
assign memory_commit_payload = command_commit;
assign memory_commit_fire =
    memory_commit_valid && memory_commit_ready;

// Count the operation when the memory backend accepts it.
assign dependency_issue_valid   = mem_req_fire;
assign dependency_issue_wave_id = command_wave;
assign dependency_issue_kind    = command.kind;

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)
		state <= IDLE;
	else 
		state <= next_state;
end
always_comb begin
	next_state = state;
	case(state)
		IDLE : begin
			if(!no_active && issue_fire)
				next_state = REQUEST;
			else if (no_active && issue_fire)
				next_state = COMMIT;
		end
		REQUEST : begin
			if (mem_req_fire)
				next_state = COMMIT;	
		end
		COMMIT : begin
			if (memory_commit_fire)begin
				next_state = IDLE;
			end
		end
		default : begin
			next_state = IDLE;
		end
	endcase
end
always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		command <= '0;
		command_wave <= '0;
		command_commit <= '0;
	end
	else begin
		if (issue_fire)begin
			command <= prepared;
			command_wave <= issue_wave_id;
			command_commit <= m3_sequential_commit(issue_payload.decoded);
		end
	end
end

assign request_tag = TAG_BITS'(command.transaction_id);
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // Clear all transaction tags.
        for (ft = 0; ft < NUM_MEMORY_TAGS; ft = ft + 1) begin
            tags[ft] <= '0;
        end

        // Initialize ordering state for each wave and dependency kind.
        for (w = 0; w < NUM_WAVE_CONTEXTS; w = w + 1) begin
            for (k = 0; k < DEPENDENCY_COUNTER_COUNT; k = k + 1) begin
                next_sequence[w][k] <= '0;
                head_sequence[w][k] <= '0;
            end
        end
    end
    else begin
        // Reserve a tag when accepting an active memory instruction.
        if (issue_fire && !no_active) begin
            tags[free_tag] <= '0;

            tags[free_tag].allocated <= 1'b1;
            tags[free_tag].wave_id   <= issue_wave_id;
            tags[free_tag].kind      <= prepared_kind;
            tags[free_tag].is_load   <=
                (prepared.operation == MEM_OP_LOAD);

            tags[free_tag].dst_kind <=
                issue_payload.decoded.uop.dst_kind;
            tags[free_tag].dst_index <=
                issue_payload.decoded.uop.dst_index;
            tags[free_tag].dst_count <=
                issue_payload.decoded.uop.dst_count;

            tags[free_tag].mask <= prepared.active_mask;

            tags[free_tag].sequence_id <=
                next_sequence[issue_wave_id][prepared_kind];

            tags[free_tag].origin_pc <=
                issue_payload.decoded.context_data.pc;
            tags[free_tag].instruction0 <=
                issue_payload.decoded.instruction[31:0];

            next_sequence[issue_wave_id][prepared_kind] <=
                next_sequence[issue_wave_id][prepared_kind] + 1'b1;
        end

        // Mark the saved request as accepted by the memory backend.
        if (mem_req_fire) begin
            tags[request_tag].sent <= 1'b1;
        end
		// The response has finished processing.
		if (fifo_pop) begin
			tags[head_tag].rf_done <= 1'b1;
		end
		if (complete_valid)begin
			tags[complete_tag].allocated <= 1'b0;
			if(tags[complete_tag].kind != DEP_KM)
				head_sequence[tags[complete_tag].wave_id][tags[complete_tag].kind] <= head_sequence[tags[complete_tag].wave_id][tags[complete_tag].kind] + 1'b1;		
		end
    end
end

// Accept a response when the FIFO has space.
assign mem_rsp_ready =
    (int'(fifo_count) < RETURN_FIFO_DEPTH);

assign mem_rsp_fire = mem_rsp_valid && mem_rsp_ready;
assign fifo_push = mem_rsp_fire;

// Look up the transaction information for the FIFO head.
assign head_tag =
    TAG_BITS'(response_fifo[fifo_read].transaction_id);

// Only loads produce a register-writeback result.
assign result_valid =
    (fifo_count != '0) && tags[head_tag].is_load;

assign result_fire = result_valid && result_ready;

// Stores consume their acknowledgement directly.
// Loads remain at the head until writeback accepts the full result.
assign fifo_pop =
    (fifo_count != '0) &&
    (!tags[head_tag].is_load || result_fire);

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		fifo_read  <= '0;
		fifo_write <= '0;
		fifo_count <= '0;	
		for (ff_fifo = 0; ff_fifo < RETURN_FIFO_DEPTH; ff_fifo = ff_fifo + 1)begin
			response_fifo[ff_fifo] <= '0;
		end
	end
	else begin
		case({fifo_push,fifo_pop})
			2'b10: begin
				fifo_count <= fifo_count +1'b1;
				response_fifo[fifo_write] <= mem_rsp_payload;
				fifo_write <= (fifo_write == (RETURN_FIFO_DEPTH-1)) ? '0 : fifo_write + 1'b1;
			end
			2'b01: begin
				fifo_count <= fifo_count -1'b1;
				fifo_read  <= (fifo_read == (RETURN_FIFO_DEPTH-1)) ? '0 : fifo_read + 1'b1;
			end
			2'b11: begin
				response_fifo[fifo_write] <= mem_rsp_payload;
				fifo_write <= (fifo_write == (RETURN_FIFO_DEPTH-1)) ? '0 : fifo_write + 1'b1;
				fifo_read  <= (fifo_read == (RETURN_FIFO_DEPTH-1)) ? '0 : fifo_read + 1'b1;
			end
			default: begin
			
			end
			
		endcase
	
	end
end

assign result_wave_id = tags[head_tag].wave_id;

always_comb begin
    result_payload = '0;

    result_payload.dst_kind  = tags[head_tag].dst_kind;
    result_payload.dst_index = tags[head_tag].dst_index;
    result_payload.dst_count = tags[head_tag].dst_count;
    result_payload.write_mask = tags[head_tag].mask;

    result_payload.clear_busy = 1'b1;
    result_payload.suppress_write =
        response_fifo[fifo_read].error;

    // Expand each 32-bit return value into a 64-bit lane slot.
    // The upper DWORD remains zero from the default assignment.
    for (p = 0; p < 32; p = p + 1) begin
        result_payload.data[p*64 +: 32] =
            response_fifo[fifo_read].load_data[p*32 +: 32];
    end
end

always_comb begin
	complete_valid = 1'b0;
	complete_tag   = '0;
	index         = 0;	
	for (scan = 0; scan < NUM_MEMORY_TAGS; scan = scan + 1)begin
		index = (complete_pointer  + scan) >= NUM_MEMORY_TAGS ? (complete_pointer  + scan - NUM_MEMORY_TAGS) : (complete_pointer  + scan);
		if (!complete_valid && tags[index].allocated &&
			tags[index].sent &&
			tags[index].rf_done &&
			(
				(tags[index].kind == DEP_KM) ||
				(tags[index].sequence_id ==
				head_sequence[tags[index].wave_id][tags[index].kind])
			))begin
			complete_valid = 1'b1;
			complete_tag = TAG_BITS'(index);
		end
	end
end
always_ff @ (posedge clk or negedge rst_n)begin
	if (!rst_n)
		complete_pointer <= '0;
	else if (complete_valid)
		complete_pointer <= (complete_tag == (NUM_MEMORY_TAGS-1))? '0 : complete_tag + 1'b1;
end
assign dependency_complete_valid = complete_valid;

assign dependency_complete_wave_id =
    tags[complete_tag].wave_id;

assign dependency_complete_kind =
    tags[complete_tag].kind;
// Identify the response being accepted into the FIFO.
assign response_tag = TAG_BITS'(mem_rsp_payload.transaction_id);

// Report an error when accepting the response.
assign fault_valid = mem_rsp_fire && mem_rsp_payload.error;

assign fault_wave_id =
    tags[response_tag].wave_id;

assign fault_pc =
    tags[response_tag].origin_pc;

assign fault_instruction =
    tags[response_tag].instruction0;

endmodule

`default_nettype wire