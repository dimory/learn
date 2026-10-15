`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Register dependency scoreboard
//
// Microarchitecture:
//   - Maintain independent SGPR and VGPR busy masks for each resident wave.
//   - Each SGPR busy bit covers one 32-bit register.
//   - Each VGPR busy bit covers one entire register across all 32 lanes.
//   - Check src0, src1, src2 and destination registers for RAW/WAW hazards.
//   - Check both adjacent registers when an operand count is two.
//   - issue_fire reserves destination registers.
//   - clear_valid clears reservations after physical writeback completes.
//   - release_valid clears all busy metadata for the released wave.
//
// Dataflow:
//   decoded slots -> register busy checks -> eligible_mask
//   execute issue -> destination reservation
//   final writeback -> destination release
//
// eligible_mask reports register dependency readiness only.
// The operand collector also checks slot validity and execution-unit readiness.
//
// SCC/VCC/EXEC/M0 remain serialized by the M2 wave context state.
// ============================================================================
module wave_scoreboard #(
    parameter int NUM_WAVE_CONTEXTS = 4,
    parameter int NUM_SGPRS = 32,
    parameter int NUM_VGPRS = 64,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    input logic clk,
    input logic rst_n,

    input gpu_pkg::m3_decoded_payload_t slots [0:NUM_WAVE_CONTEXTS-1],
    output logic [NUM_WAVE_CONTEXTS-1:0] eligible_mask,

    output logic [NUM_SGPRS-1:0] sgpr_busy [0:NUM_WAVE_CONTEXTS-1],
    output logic [NUM_VGPRS-1:0] vgpr_busy [0:NUM_WAVE_CONTEXTS-1],

    input logic issue_fire,
    input logic [WAVE_ID_BITS-1:0] issue_wave_id,
    input gpu_pkg::decoded_uop_t issue_uop,
    input logic [31:0] issue_exec,

    input logic clear_valid,
    input logic [WAVE_ID_BITS-1:0] clear_wave_id,
    input gpu_pkg::operand_kind_t clear_kind,
    input logic [9:0] clear_index,
    input logic [4:0] clear_count,

    input logic release_valid,
    input logic [WAVE_ID_BITS-1:0] release_wave_id
);

import gpu_pkg::*;

// Current operand being checked.
operand_kind_t checked_kind;
logic [9:0] checked_index;
logic [4:0] checked_count;

// Combinational scan variables.
integer w;
integer s;
integer r;

// Sequential update variables.
integer ffw;
integer ffr;

// Add dependency checks and busy-state updates here.
always_ff @(posedge clk or negedge rst_n)begin
	if(!rst_n)begin
		for ( ffw = 0 ; ffw < NUM_WAVE_CONTEXTS; ffw = ffw +1 )begin
			sgpr_busy[ffw] <= '0;
			vgpr_busy[ffw] <= '0;		
		end	
	end
	else begin
		if(clear_valid)begin
			for (ffr = 0 ; ffr < 2; ffr = ffr +1)begin
				if (ffr < clear_count)begin
					if(clear_kind == OPERAND_SGPR)
						sgpr_busy [clear_wave_id][clear_index+ffr] <= '0;
					else if(clear_kind == OPERAND_VGPR)
						vgpr_busy [clear_wave_id][clear_index+ffr] <= '0;
				end
			end
		end
		if(issue_fire)begin
			for (ffr = 0 ; ffr < 2; ffr = ffr +1)begin
				if (ffr < issue_uop.dst_count)begin
					if(issue_uop.dst_kind == OPERAND_SGPR)
						sgpr_busy [issue_wave_id][issue_uop.dst_index+ffr] <= 1'b1;
					else if((issue_uop.dst_kind == OPERAND_VGPR) && (|issue_exec))
						vgpr_busy [issue_wave_id][issue_uop.dst_index+ffr] <= 1'b1;
				end
			end			
		end
		if(release_valid)begin
			sgpr_busy[release_wave_id] <= '0;
			vgpr_busy[release_wave_id] <= '0;
		end	
	end
end
always_comb begin
	eligible_mask = '1;
	checked_kind = OPERAND_NONE;
	checked_index = '0;
	checked_count = '0;
	for ( w = 0; w < NUM_WAVE_CONTEXTS; w = w+1 )begin
		for ( s = 0; s < 4; s = s+1 )begin
			case(s)
				0:begin
					checked_index = slots[w].uop.src0_index;
					checked_kind  = slots[w].uop.src0_kind;
					checked_count = slots[w].uop.src0_count;
				end
				1:begin
					checked_index = slots[w].uop.src1_index;
					checked_kind  = slots[w].uop.src1_kind;
					checked_count = slots[w].uop.src1_count;					
				end
				2:begin
					checked_index = slots[w].uop.src2_index;
					checked_kind  = slots[w].uop.src2_kind;
					checked_count = slots[w].uop.src2_count;					
				end		
				3:begin
					checked_index = slots[w].uop.dst_index;
					checked_kind  = slots[w].uop.dst_kind;
					checked_count = slots[w].uop.dst_count;					
				end	
				default: begin
				end
			endcase
			for (r = 0; r < 2; r = r + 1) begin
				if (r < checked_count) begin
					if (checked_kind == OPERAND_SGPR) begin
						if (sgpr_busy[w][int'(checked_index) + r])
							eligible_mask[w] = 1'b0;
					end
					else if (checked_kind == OPERAND_VGPR) begin
						if (vgpr_busy[w][int'(checked_index) + r])
							eligible_mask[w] = 1'b0;
					end
				end
			end
		end
	end
end

endmodule

`default_nettype wire