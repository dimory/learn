`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Wave operand collector
//
// Microarchitecture:
//   - Hold one active instruction across all resident waves.
//   - Select decoded slots using round-robin arbitration.
//   - Selection requires slot validity, register readiness and unit readiness.
//   - Capture the selected slot and remove it using pop_mask.
//   - Collect src0, src1 and src2 sequentially.
//   - An SGPR pair uses both read ports in one request.
//   - A VGPR source requires eight beats, with four lanes per beat.
//   - A VGPR pair uses both read ports for each beat.
//   - REQUEST launches a synchronous RF read.
//   - CAPTURE samples the registered RF outputs.
//   - Broadcast scalar, immediate and saved context values to all 32 lanes.
//   - Keep the captured packet stable in SEND until the output handshake.
//   - Destination busy bits are reserved at execution issue, after collection.
//
// Operand layout:
//   - Each source contains 32 lane slots, with 64 bits per lane.
//   - srcN[lane*64 +: 32] contains the low DWORD.
//   - srcN[lane*64+32 +: 32] contains the high DWORD for a register pair.
//   - A single-register operand has a zero high DWORD.
// ============================================================================

// State transitions (collector-local FSM):
//
//   Reset:
//     Enter IDLE.
//
//   IDLE:
//     Stay in IDLE when no candidate is available or halt is asserted.
//     When candidate_valid && !halt, capture the selected slot and owner.
//     The selected slot is popped at the same clock edge.
//     Initialize source_index and beat to zero, then enter SOURCE.
//
//   SOURCE:
//     For an SGPR or VGPR source, enter REQUEST.
//     For a non-RF source, broadcast its value to all 32 lane slots.
//     If source_index is 2, enter SEND.
//     Otherwise, advance source_index and remain in SOURCE.
//
//   REQUEST:
//     Launch the synchronous RF read at the clock edge.
//     Enter CAPTURE.
//
//   CAPTURE:
//     Sample the RF data returned by the preceding REQUEST.
//     An SGPR source is completed in one capture.
//     A VGPR source captures four lanes per beat.
//     If more VGPR beats remain, advance beat and return to REQUEST.
//     Otherwise, clear beat and finish the current source:
//       - If source_index is 2, enter SEND.
//       - Otherwise, advance source_index and enter SOURCE.
//
//   SEND:
//     Assert out_valid and hold packet, owner and out_unit stable.
//     Stay in SEND while out_ready is low.
//     On out_valid && out_ready, issue the instruction and return to IDLE.
//
//   Slot capture and execution issue are separate events.
//   Destination reservation occurs only at the SEND output handshake.
module wave_operand_collector #(
    parameter int NUM_WAVE_CONTEXTS = 4,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    input logic clk,
    input logic rst_n,
    input logic halt,

    // Per-wave decoded instruction slots.
    input logic [NUM_WAVE_CONTEXTS-1:0] slot_valid,
    input logic [NUM_WAVE_CONTEXTS-1:0] eligible_mask,
    input gpu_pkg::m3_decoded_payload_t slots [0:NUM_WAVE_CONTEXTS-1],
    input logic [3:0] unit_ready,
    output logic [NUM_WAVE_CONTEXTS-1:0] pop_mask,

    // Shared register-file read controls.
    output logic [1:0] sgpr_read_enable,
    output logic [1:0] vgpr_read_enable,
    output logic [WAVE_ID_BITS-1:0] rf_read_wave_id,
    output logic [9:0] rf_read_index0,
    output logic [9:0] rf_read_index1,
    output logic [2:0] rf_read_beat,

    // Synchronous register-file read data.
    input logic [31:0] sgpr_read_data0,
    input logic [31:0] sgpr_read_data1,
    input logic [127:0] vgpr_read_data0,
    input logic [127:0] vgpr_read_data1,

    // Collected instruction sent to an execution unit.
    output logic out_valid,
    input logic out_ready,
    output logic [WAVE_ID_BITS-1:0] out_wave_id,
    output logic [1:0] out_unit,
    output gpu_pkg::m3_operand_payload_t out_payload
);

import gpu_pkg::*;

localparam logic [2:0] IDLE = 3'd0;
localparam logic [2:0] SOURCE = 3'd1;
localparam logic [2:0] REQUEST = 3'd2;
localparam logic [2:0] CAPTURE = 3'd3;
localparam logic [2:0] SEND = 3'd4;

logic [2:0] state;
logic [2:0] next_state;
logic [1:0] source_index;
logic [2:0] beat;

logic [WAVE_ID_BITS-1:0] owner;
logic [WAVE_ID_BITS-1:0] pointer;
logic [WAVE_ID_BITS-1:0] candidate;
logic candidate_valid;

m3_operand_payload_t packet;

operand_kind_t source_kind;
logic [9:0] source_register;
logic [4:0] source_count;
logic [63:0] source_value;
logic [63:0] captured_value;

integer scan;
integer index;
integer lane;
integer physical_lane;

// Add execution-unit mapping, selection and collection logic here.
function automatic logic [1:0] execution_unit(
input uop_class_t c
);
	logic [1:0] unit_index;
	case (c)
		UOP_CLASS_SALU								 : unit_index = 2'd0;
		UOP_CLASS_VALU								 : unit_index = 2'd1;
		UOP_CLASS_SMEM,UOP_CLASS_VMEM,UOP_CLASS_LDS  : unit_index = 2'd3;
		default										 : unit_index = 2'd2;
	endcase
	return unit_index;
endfunction
always_comb begin
	candidate_valid = 1'b0;
	candidate = '0;
	index = 0;
	pop_mask = '0;	
	for (scan = 0 ; scan <NUM_WAVE_CONTEXTS; scan = scan +1)begin
		index = pointer + scan;
		if (index >= NUM_WAVE_CONTEXTS)
			index = index - NUM_WAVE_CONTEXTS;
		if (!candidate_valid &&slot_valid[index] && eligible_mask[index] && unit_ready[execution_unit(slots[index].uop.uop_class)])begin
			candidate_valid = 1'b1;
			candidate = WAVE_ID_BITS'(index);
		end		
	end
	if ((state == IDLE) && candidate_valid && !halt)
	pop_mask[candidate] = 1'b1;	
end
always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)
		pointer <= '0;
	else if ((state == IDLE) && candidate_valid && !halt)begin
		if (candidate == NUM_WAVE_CONTEXTS-1)
			pointer <= '0;
		else 
			pointer <= candidate + 1'b1;
	end
end
always_comb begin
	source_kind = OPERAND_NONE;
	source_register = '0;
	source_count = '0;
	source_value = '0;
	case (source_index)
		2'b00 : begin
			source_kind = packet.decoded.uop.src0_kind;
			source_register =  packet.decoded.uop.src0_index;
			source_count =  packet.decoded.uop.src0_count;
			source_value = packet.decoded.uop.src0_immediate;
		end
		2'b01 : begin
			source_kind = packet.decoded.uop.src1_kind;
			source_register =  packet.decoded.src1_uop.index;
			source_count =  packet.decoded.uop.src1_count;
			source_value = packet.decoded.uop.src1_immediate;		
		end
		default : begin
			source_kind = packet.decoded.uop.src2_kind;
			source_register =  packet.decoded.src2_uop.index;
			source_count =  packet.decoded.uop.src2_count;
			source_value = packet.decoded.uop.src2_immediate;				
		end
	endcase
	case (source_kind)
		OPERAND_NONE: begin
			source_value = '0;
		end

		OPERAND_EXEC: begin
			source_value = {
				32'b0,
				packet.decoded.context_data.exec_mask[31:0]
			};
		end

		OPERAND_VCC: begin
			source_value = {
				32'b0,
				packet.decoded.context_data.vcc[31:0]
			};
		end

		OPERAND_SCC: begin
			source_value = {
				63'b0,
				packet.decoded.context_data.scc
			};
		end

		OPERAND_M0: begin
			source_value = {
				32'b0,
				packet.decoded.context_data.m0
			};
		end

		OPERAND_TTMP: begin
			if (source_register == 10'd8) begin
				// M3 ttmp8: packed wave and dispatch metadata.
				source_value = {
					32'b0,
					2'b0,
					packet.decoded.context_data.wave_index,
					packet.decoded.context_data.dispatch_index
				};
			end
			else begin
				// M3 ttmp9: workgroup identifier.
				source_value = {
					32'b0,
					packet.decoded.context_data.workgroup_id
				};
			end
		end

		default: begin
			// Preserve the decoded immediate value.
			// SGPR/VGPR data will be collected from the RF in CAPTURE.
		end
	endcase	
end
always_comb begin
	sgpr_read_enable = 2'b00;
	vgpr_read_enable = 2'b00;
	rf_read_wave_id = owner;
	rf_read_index0 = source_register;
	rf_read_index1 = source_register + 10'd1;
	rf_read_beat = beat;	
	if(state == REQUEST)begin
		case(source_kind)
			OPERAND_SGPR : begin
				if(source_count == 5'd1)
					sgpr_read_enable = 2'b01;
				else if (source_count == 5'd2)
					sgpr_read_enable = 2'b11;
			end
			OPERAND_VGPR : begin
				if(source_count == 5'd1)
					vgpr_read_enable = 2'b01;
				else if (source_count == 5'd2)
					vgpr_read_enable = 2'b11;
			end
			default: begin
			end
		endcase
	end
	captured_value = {32'b0, sgpr_read_data0};
	if (source_count == 5'd2)
		captured_value[63:32] = sgpr_read_data1;
end

assign out_valid = (state == SEND);
assign out_wave_id = owner;
assign out_unit = execution_unit(packet.decoded.uop.uop_class);
assign out_payload = packet;

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)
		state <= IDLE;
	else 
		state <= next_state;
end

always_ff @ (posedge clk or negedge rst_n)begin
	if(!rst_n)begin
		source_index <= '0;
		beat		 <= '0;
		owner        <= '0;
		packet       <= '0;
	end
	else if ((state == IDLE) && candidate_valid && !halt )begin
		source_index <= '0;
		beat    <= '0;		
		owner	<= candidate;
		packet  <= '0;
		packet.decoded <= slots[candidate];
	end
	else if (state == SOURCE  && !(source_kind == OPERAND_SGPR || source_kind == OPERAND_VGPR))begin
		for (lane = 0 ; lane < 32; lane = lane + 1)begin
			case (source_index)
				2'b00  : packet.src0[lane*64 +: 64] <= source_value;
				2'b01  : packet.src1[lane*64 +: 64] <= source_value;
				default: packet.src2[lane*64 +: 64] <= source_value;
			endcase
		end
		if(source_index < 2)begin
			source_index <= source_index + 1'b1;
		end
	end
	else if (state == CAPTURE && source_kind == OPERAND_SGPR)begin
		for (lane = 0; lane < 32; lane = lane+1)begin
			case (source_index)
				2'b00   : packet.src0[lane*64 +: 64] <= captured_value;
				2'b01   : packet.src1[lane*64 +: 64] <= captured_value;
				default : packet.src2[lane*64 +: 64] <= captured_value;
			endcase
		end
		beat <= '0;
		if(source_index < 2)begin
			source_index <= source_index + 1'b1;
		end		
	end
	else if ((state == CAPTURE) && (source_kind == OPERAND_VGPR)) begin
		for (physical_lane = 0; physical_lane <4; physical_lane = physical_lane+1)begin
			case (source_index)
				2'b00   : begin
					packet.src0[(beat*4 + physical_lane)*64 +: 32]
						<= vgpr_read_data0[physical_lane*32 +: 32];
					packet.src0[(beat*4 + physical_lane)*64 + 32 +: 32]
						<= (source_count == 5'd2)
						   ? vgpr_read_data1[physical_lane*32 +: 32]
						   : 32'b0;						
				end
				2'b01   : begin
					packet.src1[(beat*4 + physical_lane)*64 +: 32]
						<= vgpr_read_data0[physical_lane*32 +: 32];
					packet.src1[(beat*4 + physical_lane)*64 + 32 +: 32]
						<= (source_count == 5'd2)
						   ? vgpr_read_data1[physical_lane*32 +: 32]
						   : 32'b0;							
				end
				default : begin
					packet.src2[(beat*4 + physical_lane)*64 +: 32]
						<= vgpr_read_data0[physical_lane*32 +: 32];
					packet.src2[(beat*4 + physical_lane)*64 + 32 +: 32]
						<= (source_count == 5'd2)
						   ? vgpr_read_data1[physical_lane*32 +: 32]
						   : 32'b0;						
				end
			endcase
		end
        if (beat == 3'd7) begin
            beat <= '0;
            if (source_index < 2) begin
                source_index <= source_index + 1'b1;
            end
        end
        else begin
            beat <= beat + 1'b1;
        end
    end 
end 
always_comb begin
	next_state = state;
	case(state)
		IDLE : begin
			if(candidate_valid && !halt)
				next_state = SOURCE;
		end
		SOURCE : begin
			if(source_kind == OPERAND_SGPR || source_kind == OPERAND_VGPR)begin
				next_state = REQUEST;
			end
			else if(source_index == 2)begin
				next_state = SEND;					
			end
		end
		REQUEST : begin
			next_state = CAPTURE;
		end
		CAPTURE: begin
			if (source_kind == OPERAND_SGPR) begin
				if (source_index == 2)
					next_state = SEND;
				else
					next_state = SOURCE;
			end
			else if(source_kind == OPERAND_VGPR)begin
				if(beat != 3'd7)
					next_state = REQUEST;
				else if (source_index == 2)
					next_state = SEND;
				else begin
					next_state = SOURCE;
				end
			end
		end
		SEND : begin
			if(out_ready)
			next_state = IDLE;
		end
	endcase
end
endmodule
`default_nettype wire