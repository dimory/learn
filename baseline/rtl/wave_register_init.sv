`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// M3 F07: Per-Wave register initialization and launch metadata.
//
// Microarchitecture:
// - Each resident Wave has pending, cursor and saved wave_index metadata.
// - Allocation creates an initialization job and clears its initialized bit.
// - User SGPRs are written densely from s0 through s(count-1).
// - After User SGPR writes, one full-Wave v0 result packet is generated.
// - v0[lane] = wave_index * 32 + lane, including inactive lanes.
// - Other SGPRs and VGPRs have no guaranteed initial values.
// - Pending jobs are selected with round-robin arbitration.
// - A selected result packet is locked while Writeback applies backpressure.
//
// Writeback contract:
// - Initialization uses m3_result_t packets through shared Writeback.
// - This module does not directly drive the physical RF write ports.
// - result_valid/ready completes one whole result packet.
// - An SGPR completion advances the selected Wave's cursor.
// - v0 completion sets rf_initialized_mask after its final physical write beat.
// - The initialized mask gates Wave scheduling.
// - Release clears the corresponding job and initialized metadata.
//
// Launch and fault storage:
// - Legal launch parameters are captured once and held during the Kernel.
// - The first launch, decode or memory fault is retained until reset.
//
// Reset:
// - Asynchronous active-low rst_n clears control metadata and saved state.
// - Architectural RF arrays are initialized through writes, not reset.
// ============================================================================

module wave_register_init #(
    parameter int NUM_WAVE_CONTEXTS = 4,
    parameter int NUM_SGPRS = 32,
    parameter int MAX_GROUP_SEGMENT_BYTES = 4096,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    input logic clk,
    input logic rst_n,

    // Wave allocation and release.
    input logic alloc_fire,
    input logic [WAVE_ID_BITS-1:0] alloc_wave_id,
    input logic [4:0] alloc_wave_index,
    input logic release_valid,
    input logic [WAVE_ID_BITS-1:0] release_wave_id,

    // Live launch parameters.
    input logic launch_candidate,
    input logic [63:0] launch_start_pc,
    input logic [5:0] user_sgpr_count,
    input logic [1023:0] user_sgpr_data,
    input logic [24:0] launch_dispatch_index,
    input logic [31:0] launch_group_segment_bytes,
    output logic launch_config_legal,

    // Saved launch parameters.
    output logic [5:0] saved_user_sgpr_count,
    output logic [1023:0] saved_user_sgpr_data,
    output logic [24:0] saved_dispatch_index,
    output logic [31:0] saved_group_segment_bytes,

    // Decode fault input.
    input logic decode_fault_valid,
    input logic [WAVE_ID_BITS-1:0] decode_fault_wave_id,
    input gpu_pkg::m3_fault_t decode_fault_code,
    input logic [63:0] decode_fault_pc,
    input logic [31:0] decode_fault_instruction,

    // Memory fault input.
    input logic memory_fault_valid,
    input logic [WAVE_ID_BITS-1:0] memory_fault_wave_id,
    input logic [63:0] memory_fault_pc,
    input logic [31:0] memory_fault_instruction,

    // Sticky first-fault record.
    output logic fault_valid,
    output logic [WAVE_ID_BITS-1:0] fault_wave_id,
    output gpu_pkg::m3_fault_t fault_code,
    output logic [63:0] fault_pc,
    output logic [31:0] fault_instruction,

    // Initialization status and result output.
    output logic [NUM_WAVE_CONTEXTS-1:0] rf_initialized_mask,
    output logic result_valid,
    input logic result_ready,
    output logic [WAVE_ID_BITS-1:0] result_wave_id,
    output gpu_pkg::m3_result_t result_payload
);

import gpu_pkg::*;

// Per-Wave initialization jobs.
logic [NUM_WAVE_CONTEXTS-1:0] pending;
logic [5:0] cursor [0:NUM_WAVE_CONTEXTS-1];
logic [4:0] wave_index [0:NUM_WAVE_CONTEXTS-1];

// Arbitration and output ownership.
logic locked;
logic [WAVE_ID_BITS-1:0] owner;
logic [WAVE_ID_BITS-1:0] pointer;
logic result_fire;

// Loop and scan variables.
integer scan;
integer index;
integer lane;
integer wave_idx;

assign launch_config_legal = (user_sgpr_count <= NUM_SGPRS) && 
       (user_sgpr_count <= 6'd32) && 
	   (launch_start_pc[63:57] == '0) && 
	   (launch_start_pc[1:0] == '0) &&
       (launch_group_segment_bytes <= MAX_GROUP_SEGMENT_BYTES);
assign result_fire = result_valid && result_ready;
always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		saved_user_sgpr_count 		<= '0;
		saved_user_sgpr_data   	    <= '0;
		saved_dispatch_index	    <= '0;
		saved_group_segment_bytes   <= '0;
		pending <= '0;
		rf_initialized_mask <= '0;
		for (wave_idx = 0; wave_idx < NUM_WAVE_CONTEXTS; wave_idx = wave_idx + 1) begin
			cursor[wave_idx] <= '0;
			wave_index[wave_idx] <= '0;
		end
	end
	else begin
		if (launch_config_legal && launch_candidate)begin
			saved_user_sgpr_count <= user_sgpr_count;
			saved_user_sgpr_data  <= user_sgpr_data;
			saved_dispatch_index  <= launch_dispatch_index;
			saved_group_segment_bytes <= launch_group_segment_bytes;
		end
		if (result_fire) begin
			if (cursor[result_wave_id] < saved_user_sgpr_count) begin
				cursor[result_wave_id] <= cursor[result_wave_id] + 1'b1;
			end
			else begin
				pending[result_wave_id] <= 1'b0;
				rf_initialized_mask[result_wave_id] <= 1'b1;
			end		
		if (release_valid)begin
			pending[release_wave_id] <= '0;
			rf_initialized_mask[release_wave_id] <= '0;
		end
		if  (alloc_fire)begin
			pending[alloc_wave_id] <= 1'b1;
			rf_initialized_mask[alloc_wave_id] <= '0;
			cursor[alloc_wave_id] <= '0;	
			wave_index[alloc_wave_id] <= alloc_wave_index;
		end

		end		
	end
end

always_comb begin
	index = 0;
	result_valid = 1'b0;
	result_wave_id = owner;
	if(locked)begin
		result_valid = 1'b1;
		result_wave_id = owner;
	end
	else begin
		for (scan = 0; scan < NUM_WAVE_CONTEXTS; scan = scan + 1)begin
			index = scan + int'(pointer);
			if(index >= NUM_WAVE_CONTEXTS)
				index = index - NUM_WAVE_CONTEXTS;
			if(!result_valid && pending[index])begin
				result_valid = 1'b1;
				result_wave_id = WAVE_ID_BITS'(index);
			end
		end
	end
end
always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		locked <='0;
		pointer <= '0;
		owner <= '0;
	end
	else if(result_valid && !result_ready)begin
		locked <= 1'b1;
		owner <= result_wave_id;
	end
	
	else if (result_fire)begin
		locked  <= 1'b0;
		if (result_wave_id == NUM_WAVE_CONTEXTS-1)
			pointer <= '0;
		else
		pointer <= result_wave_id + 1'b1;
	end
end
// ============================================================================
// VGPR layout in result_payload.data
//
// The 2048-bit result bus contains 32 lane slots.
// Each lane occupies 64 bits:
//   Low 32 bits : destination VGPR dst_index.
//   High 32 bits: destination VGPR dst_index + 1, when dst_count == 2.
//
// Lane   64-bit slot       High 32 bits       Low 32 bits
// ----   ---------------   ---------------   ---------------
// 0      data[63:0]        data[63:32]        data[31:0]
// 1      data[127:64]      data[127:96]       data[95:64]
// 2      data[191:128]     data[191:160]      data[159:128]
// 3      data[255:192]     data[255:224]      data[223:192]
// ...    ...              ...               ...
// 31     data[2047:1984]   data[2047:2016]    data[2015:1984]
//
// General lane mapping:
//   Low DWORD : data[lane*64 +: 32]
//   High DWORD: data[lane*64 + 32 +: 32]
//
// Register initialization:
//   dst_kind  = OPERAND_VGPR
//   dst_index = 0              -> Select v0.
//   dst_count = 1              -> Use only the low DWORD of each lane.
//   write_mask = '1            -> Enable all 32 lanes.
//   v0[lane] = wave_index * 32 + lane.
//   Each high DWORD remains zero from the default payload assignment.
//
// For the v0 write, each writeback beat packs four lane low DWORDs
// into the 128-bit VGPR write port:
//   beat b, bank k -> lane 4*b + k
//   bank k data    -> data[(4*b + k)*64 +: 32]
// ============================================================================
always_comb begin
	result_payload = '0;
	result_payload.write_mask = '1;
	result_payload.dst_count = 5'd1;
	if (cursor[result_wave_id] < saved_user_sgpr_count)begin
		result_payload.dst_kind = OPERAND_SGPR;
		result_payload.dst_index = cursor[result_wave_id];
		result_payload.data[31:0] = saved_user_sgpr_data[cursor[result_wave_id]*32 +: 32];
	end
	else begin
		result_payload.dst_kind = OPERAND_VGPR;
		result_payload.dst_index = '0;
		for (lane = 0; lane < 32; lane = lane + 1) begin
			result_payload.data[lane*64 +: 32] =
			32'(wave_index[result_wave_id] * 32 + lane);
		end   
	end
end




endmodule

`default_nettype wire