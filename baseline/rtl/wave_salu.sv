`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// Scalar execution unit.
//
// Datapath:
//   Collector operands -> scalar operation -> result register -> Writeback
//
// Result storage:
//   - One outstanding result is held in the output register.
//   - Accept an instruction only when the result register is empty.
//   - Hold the result and wave ID while result_valid && !result_ready.
//   - Release the result on result_valid && result_ready.
//
// Architectural updates:
//   - Ordinary SGPR destinations are written through Writeback.
//   - SCC, EXEC, VCC and M0 updates are carried in commit_data.
//   - Scalar execution is independent of the EXEC lane mask.
// ============================================================================
module wave_salu #(
    parameter int WAVE_ID_BITS = 2
) (
    input logic clk,
    input logic rst_n,

    input logic issue_valid,
    output logic issue_ready,
    input logic [WAVE_ID_BITS-1:0] issue_wave_id,
    input gpu_pkg::m3_operand_payload_t issue_payload,

    output logic result_valid,
    input logic result_ready,
    output logic [WAVE_ID_BITS-1:0] result_wave_id,
    output gpu_pkg::m3_result_t result_payload
);

import gpu_pkg::*;

logic issue_fire;
logic result_fire;

logic [31:0] a;
logic [31:0] b;
logic [32:0] sum;
logic [63:0] value;
logic scc;

m3_result_t computed;
	
assign issue_fire = issue_valid && issue_ready;
assign issue_ready = !result_valid;
assign result_fire = result_valid && result_ready;

always_comb begin
	a = issue_payload.src0[31:0];
	b = issue_payload.src1[31:0];
	sum = {1'b0,a} + {1'b0,b};
	value = '0;
	scc   = '0;
	case(issue_payload.decoded.uop.function_code)
		UOP_FUNCTION_MOV :  value[63:0] = issue_payload.src0[63:0];
		UOP_FUNCTION_ADD :	begin
			value[31:0] = sum[31:0];
			scc = sum[32];
		end
		UOP_FUNCTION_SUB :  begin
			value[31:0] = a - b;
			scc = (a < b);
		end
		UOP_FUNCTION_MUL : value[31:0] = a * b;
		UOP_FUNCTION_AND :  begin
			value = a & b;
			scc = |value;
		end
		UOP_FUNCTION_OR  :  begin
			value = a | b;
			scc = |value;
		end
		UOP_FUNCTION_XOR :  begin
			value = a ^ b;
			scc = | value;
		end
		UOP_FUNCTION_SHL :  begin
			value[31:0] = a << b[4:0];
			scc = | value;
		end
		UOP_FUNCTION_SHR :  begin
			value = a >> b[4:0];
			scc = | value;
		end
		UOP_FUNCTION_CMP : begin
			if (issue_payload.decoded.uop.compare_less)
				scc = (a < b);
			else 
				scc = (a == b);
		end
		default : begin
		end
	endcase
end

always_comb begin
	computed = '0;
	computed.commit_needed = 1'b1;
	computed.commit_data = m3_sequential_commit(issue_payload.decoded);
	computed.commit_data.scc_write = issue_payload.decoded.uop.write_scc;
	computed.commit_data.scc_data = scc;
	computed.dst_kind = issue_payload.decoded.uop.dst_kind;
	computed.dst_index = issue_payload.decoded.uop.dst_index;
	computed.dst_count = issue_payload.decoded.uop.dst_count;
	computed.data      = value;
	computed.write_mask = '1;
	computed.clear_busy = (computed.dst_kind == OPERAND_SGPR);
	case (issue_payload.decoded.uop.dst_kind)
		OPERAND_EXEC : begin
			computed.commit_data.exec_write = 1'b1;
			computed.commit_data.exec_data  = {32'b0,value[31:0]};
			computed.dst_kind = OPERAND_NONE;
			computed.dst_count = '0;
			
		end
		OPERAND_VCC  : begin
			computed.commit_data.vcc_write = 1'b1;
			computed.commit_data.vcc_data  = {32'b0,value[31:0]};
			computed.dst_kind = OPERAND_NONE;
			computed.dst_count = '0;			
		end
		OPERAND_M0   : begin
			computed.commit_data.m0_write = 1'b1;
			computed.commit_data.m0_data = value;
			computed.dst_kind = OPERAND_NONE;
			computed.dst_count = '0;
		end
	endcase
end

always_ff @(posedge clk or negedge rst_n)begin
	if(!rst_n)begin
		result_valid <= '0;
		result_wave_id <= '0;
		result_payload <= '0;
	end
	else begin
		if(issue_fire)begin
			result_valid <= 1'b1;
			result_payload <= computed;
			result_wave_id <= issue_wave_id;
		end
		else if (result_fire) begin
			result_valid <=1'b0;	
		end	
	end
end


endmodule

`default_nettype wire