`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// SIMD4 vector execution unit.
//
// Execution:
//   - Capture one Collector packet and its wave ID.
//   - Process four physical lanes per cycle.
//   - Complete Wave32 execution in eight registered beats.
//   - Logical lane index = beat * 4 + physical lane index.
//
// Lane control:
//   - Preserve the original EXEC mask in the captured packet.
//   - Use EXEC as the lane write mask for ordinary VGPR results.
//   - VOPC accumulates a 32-bit VCC mask; inactive lane bits are zero.
//
// State flow:
//   IDLE:    Accept and capture one instruction.
//   EXECUTE: Accumulate four lane results per cycle.
//   SEND:    Hold the complete result until Writeback accepts it.
//
// Only one instruction is owned by this unit at a time.
// ============================================================================
module wave_valu #(
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

localparam logic [1:0] IDLE    = 2'd0;
localparam logic [1:0] EXECUTE = 2'd1;
localparam logic [1:0] SEND    = 2'd2;

logic [1:0] state;
logic [1:0] next_state;

logic issue_fire;
logic result_fire;

logic [2:0] beat;
m3_operand_payload_t packet;

logic [31:0] lane_result [0:3];
logic [3:0] lane_compare;

logic [31:0] src0;
logic [31:0] src1;

integer p;
integer ffp;

assign issue_fire = issue_valid && issue_ready;
assign result_fire = result_valid && result_ready;
assign issue_ready = (state == IDLE);
assign result_valid = (state = SEND);
always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		state <= IDLE;
	end
	else begin
		state <= next_state;
	end
end

always_comb begin
	next_state = state;
	case(state)
		IDLE: begin
			next_state = issue_fire ? EXECUTE : IDLE;
		end
		EXECUTE: begin
			next_state = (beat == 3'd7) ? SEND : EXECUTE;
		end
		SEND : begin
			next_state = (result_fire) ? IDLE :SEND;
		end
		default : begin
			next_state = IDLE;
		end
	endcase

end


always_ff @(posedge clk or negedge rst_n) begin
	if(!rst_n)begin
		packet <= '0;
		beat   <= '0;
		result_payload <= '0;
		result_wave_id <= '0;
	end
	else begin
		if (issue_fire)begin
			packet <= issue_payload;
			beat   <= '0;
			result_wave_id <= issue_wave_id;
			result_payload <= '0;
			result_payload.commit_needed <= 1'b1;
			result_payload.commit_data <= m3_sequential_commit(issue_payload.decoded);
			result_payload.commit_data.vcc_write <= issue_payload.decoded.uop.write_vcc;
			result_payload.dst_kind    <= issue_payload.decoded.uop.dst_kind;
			result_payload.dst_index   <= issue_payload.decoded.uop.dst_index;
			result_payload.dst_count   <= issue_payload.decoded.uop.dst_count;
			result_payload.write_mask  <= issue_payload.decoded.context_data.exec_mask[31:0];
			result_payload.clear_busy  <=   (issue_payload.decoded.uop.dst_kind == OPERAND_VGPR) && (|issue_payload.decoded.context_data.exec_mask[31:0]);	
		end
		else if(state == EXECUTE)begin
			for (ffp = 0 ; ffp < 4; ffp = ffp + 1)begin
				result_payload.data[(beat*4+ffp)*64 +: 32] <= lane_result[ffp];
				if(packet.decoded.uop.write_vcc)
					result_payload.commit_data.vcc_data[beat*4+ffp] <= lane_compare[ffp] && packet.decoded.context_data.exec_mask[beat*4+ffp];
			end
			if(beat != 3'd7)
				beat <= beat + 1'b1;				
		end
	
	end

end



always_comb begin
    src0 = '0;
    src1 = '0;

    for (p = 0; p < 4; p = p + 1) begin
        lane_result[p]  = '0;
        lane_compare[p] = 1'b0;

        src0 = packet.src0[(beat*4+p)*64 +: 32];
        src1 = packet.src1[(beat*4+p)*64 +: 32];

        case (packet.decoded.uop.function_code)
            UOP_FUNCTION_MOV: begin
                lane_result[p] = src0;
            end

            UOP_FUNCTION_ADD: begin
                lane_result[p] = src0 + src1;
            end

            UOP_FUNCTION_SUB: begin
                lane_result[p] = src0 - src1;
            end

            UOP_FUNCTION_AND: begin
                lane_result[p] = src0 & src1;
            end

            UOP_FUNCTION_OR: begin
                lane_result[p] = src0 | src1;
            end

            UOP_FUNCTION_XOR: begin
                lane_result[p] = src0 ^ src1;
            end

            UOP_FUNCTION_SHL: begin
                lane_result[p] = src1 << src0[4:0];
            end

            UOP_FUNCTION_SHR: begin
                lane_result[p] = src1 >> src0[4:0];
            end

            UOP_FUNCTION_CMP: begin
                lane_compare[p] =
                    packet.decoded.uop.compare_less
                    ? (src0 < src1)
                    : (src0 == src1);
            end

            default: begin
            end
        endcase
    end
end



endmodule
`default_nettype wire