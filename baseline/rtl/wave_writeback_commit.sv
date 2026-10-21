`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU M3 Writeback and Commit Unit
// ============================================================================
//
// Purpose
// -----------------------------------------------------------------------------
// Share the physical RF write ports among execution/initialization results,
// and arbitrate architectural commit descriptors sent to the M2 control path.
//
// Result source mapping
// -----------------------------------------------------------------------------
// 0: SALU
// 1: VALU
// 2: asynchronous Load return
// 3: Register Init
//
// Commit source mapping
// -----------------------------------------------------------------------------
// 0: selected result packet requiring architectural commit
// 1: Control unit
// 2: Memory request-accept commit
//
// Microarchitecture
// -----------------------------------------------------------------------------
// - Result selection uses round-robin arbitration.
// - The selected result source owns the writeback path until its whole packet
//   completes. The producer holds its payload until result_ready is asserted.
// - SGPR writeback transfers one DWORD per beat.
// - VGPR writeback transfers four lanes per beat over eight beats.
// - VGPR lane masks preserve inactive register elements.
// - Normal final RF write and architectural commit occur on the same edge.
// - Load-return and Init results complete without advancing the Wave PC.
// - Scoreboard clear is generated only on the final completed result beat.
//
// Result ownership state
// -----------------------------------------------------------------------------
// IDLE:
//   Select a result source. Its first beat may advance in the same cycle.
//
// LOCKED:
//   Keep the selected owner through remaining beats and final-beat stalls.
//
// M2 commit behavior
// -----------------------------------------------------------------------------
// - The selected commit is an event consumed by the M2 control interface.
// - end selects DONE.
// - Wait selects READY or WAITCNT using the Tracker's satisfied response.
// - Other commits select READY.
// - Wait arm generation does not depend on the satisfied response.
// ============================================================================

module wave_writeback_commit #(
    parameter int WAVE_ID_BITS = 2
) (
    input  logic clk,
    input  logic rst_n,

    // Four held result packets.
    input  logic [3:0] result_valid,
    output logic [3:0] result_ready,

    input  logic [WAVE_ID_BITS-1:0] result_wave_ids [0:3],
    input  gpu_pkg::m3_result_t     result_payloads [0:3],

    // Commit-only producers.
    input  logic control_valid,
    output logic control_ready,
    input  logic [WAVE_ID_BITS-1:0] control_wave_id,
    input  gpu_pkg::m3_commit_t     control_payload,

    input  logic memory_commit_valid,
    output logic memory_commit_ready,
    input  logic [WAVE_ID_BITS-1:0] memory_commit_wave_id,
    input  gpu_pkg::m3_commit_t     memory_commit_payload,

    // Physical RF write interface.
    output logic sgpr_write_enable,
    output logic vgpr_write_enable,
    output logic [WAVE_ID_BITS-1:0] rf_write_wave_id,
    output logic [9:0]             rf_write_index,
    output logic [2:0]             rf_write_beat,
    output logic [31:0]            sgpr_write_data,
    output logic [3:0]             vgpr_write_mask,
    output logic [127:0]           vgpr_write_data,

    // Scoreboard completion interface.
    output logic clear_valid,
    output logic [WAVE_ID_BITS-1:0] clear_wave_id,
    output gpu_pkg::operand_kind_t clear_kind,
    output logic [9:0]             clear_index,
    output logic [4:0]             clear_count,

    // Architectural commit interface.
    output logic commit_valid,
    output logic [WAVE_ID_BITS-1:0] commit_wave_id,
    output gpu_pkg::m3_commit_t     commit_payload,
    output gpu_pkg::wave_context_state_t commit_next_state,

    // Wait query interface.
    output logic wait_arm_valid,
    output gpu_pkg::m3_wait_spec_t wait_spec,
    input  logic wait_arm_satisfied
);

import gpu_pkg::*;





// Result-source IDs, not Wave IDs.
logic [1:0] owner;
logic [1:0] result_pointer;
logic [1:0] selected_source;
logic       selected_valid;
logic       locked;

m3_result_t selected_result;

// Current writeback beat.
logic [2:0] beat;
logic       last_beat;
logic       step;
logic       step_grant;
// Integrated verification pressure probes; constants in production.
`ifdef M3_VERIFICATION
logic verification_rf_stall = 1'b0;
logic verification_control_stall = 1'b0;
`else
wire verification_rf_stall = 1'b0;
wire verification_control_stall = 1'b0;
`endif

// Three-way commit arbitration.
logic [1:0] commit_pointer;
logic [1:0] selected_commit;
logic [2:0] commit_requests;

// Separate loop variables for independent combinational blocks.
integer scan;
integer index;
integer cscan;
integer cindex;
integer p;

// Main logic will be added here.
always_comb begin
    selected_valid  = 1'b0;
    selected_source = owner;
    scan            = 0;
    index           = 0;

    if (locked) begin
        selected_valid = result_valid[owner];
    end
    else begin
        for (scan = 0; scan < 4; scan = scan + 1) begin
            index = int'(result_pointer) + scan;

            if (index >= 4)
                index = index - 4;

            if (!selected_valid && result_valid[index]) begin
                selected_valid  = 1'b1;
                selected_source = 2'(index);
            end
        end
    end

    selected_result = result_payloads[selected_source];
end
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        locked <= 1'b0;
        owner  <= '0;
		result_pointer <= '0;
    end
    else if (selected_valid) begin
        if (step && last_beat) begin
            locked <= 1'b0;
			result_pointer <= (selected_source == 2'd3) ? '0 : selected_source + 1'b1;	
        end
        else begin
            locked <= 1'b1;
            owner  <= selected_source;
        end
    end
end
always_comb begin
	last_beat = 1'b1;
	if (selected_result.dst_kind == OPERAND_VGPR)
		last_beat = ( beat == 3'd7 );
	else if (selected_result.dst_kind == OPERAND_SGPR)
		last_beat = (int'(beat) + 1 >= int'(selected_result.dst_count));
end
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        beat <= '0;
    end
    else if (selected_valid && step) begin
        if (last_beat)
            beat <= '0;
        else
            beat <= beat + 1'b1;
    end
end

assign commit_requests[0] =
    selected_valid && !verification_rf_stall && last_beat && selected_result.commit_needed;

// The directed Wait probe is pre-armed before the producer becomes valid.
assign commit_requests[1] = control_valid &&
    !(verification_control_stall && control_payload.is_wait);
assign commit_requests[2] = memory_commit_valid;

always_comb begin
	commit_valid = '0;
	selected_commit = '0;
	cscan = 0;
	cindex = 0;
	for (cscan = 0; cscan < 3; cscan = cscan + 1)begin
		cindex = cscan + commit_pointer;
		if (cindex >= 3)
			cindex = cindex - 3;
		if(!commit_valid && commit_requests[cindex])begin
			commit_valid = 1'b1;
			selected_commit = 2'(cindex);
		end
	end
end

always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n)
		commit_pointer <= '0;
	else begin
		if (commit_valid)begin
			if (int'(selected_commit) == 2)
				commit_pointer <= '0;
			else 
				commit_pointer <= selected_commit + 1'b1;	
		end
	
	end
end
assign control_ready =
    commit_valid && (selected_commit == 2'd1);
assign memory_commit_ready =
    commit_valid && (selected_commit == 2'd2);
always_comb begin
	commit_payload = '0;
	commit_wave_id = '0;
	case (selected_commit)
		2'b00 : begin
			commit_payload = selected_result.commit_data;
			commit_wave_id = result_wave_ids[selected_source];
		end
		2'b01 : begin
			commit_payload = control_payload;
			commit_wave_id = control_wave_id;
		end
		2'b10 : begin
			commit_payload = memory_commit_payload;
			commit_wave_id = memory_commit_wave_id;				
		end
		default : begin	
		end
	endcase
end

assign step_grant =
    commit_valid && (selected_commit == 2'd0);

always_comb begin
    step = 1'b0;

    if (selected_valid && !verification_rf_stall) begin
        if (!last_beat)
            step = 1'b1;
        else if (!selected_result.commit_needed)
            step = 1'b1;
        else if (step_grant)
            step = 1'b1;
    end
end
always_comb begin
    result_ready = '0;

    if (step && last_beat)
        result_ready[selected_source] = 1'b1;
end

always_comb begin
    sgpr_write_enable = 1'b0;
    vgpr_write_enable = 1'b0;

    rf_write_wave_id = result_wave_ids[selected_source];
    rf_write_index   = selected_result.dst_index;
    rf_write_beat    = beat;

    // Each SGPR beat writes one consecutive 32-bit register.
    if (selected_result.dst_kind == OPERAND_SGPR)
        rf_write_index = selected_result.dst_index + 10'(beat);

    sgpr_write_data =
        selected_result.data[beat*32 +: 32];

    // Each VGPR beat contains four lanes.
    vgpr_write_mask =
        selected_result.write_mask[beat*4 +: 4];

    vgpr_write_data = '0;
    for (p = 0; p < 4; p = p + 1) begin
        vgpr_write_data[p*32 +: 32] =
            selected_result.data[(beat*4 + p)*64 +: 32];
    end

    // Write only when the current beat is allowed to complete.
    if (step && !selected_result.suppress_write) begin
        case (selected_result.dst_kind)
            OPERAND_SGPR: begin
                sgpr_write_enable = 1'b1;
            end
            OPERAND_VGPR: begin
                vgpr_write_enable = |vgpr_write_mask;
            end
            default: begin
            end
        endcase
    end
end

assign clear_valid =
    step && last_beat && selected_result.clear_busy;

assign clear_wave_id =
    result_wave_ids[selected_source];

assign clear_kind =
    selected_result.dst_kind;

assign clear_index =
    selected_result.dst_index;

assign clear_count =
    selected_result.dst_count;

// Query the wait conditions for the selected commit.
assign wait_arm_valid =
    commit_valid && commit_payload.is_wait;

assign wait_spec =
    commit_payload.wait_spec;

// Select the Wave state after architectural commit.
always_comb begin
    commit_next_state = WAVE_STATE_READY;

    if (commit_payload.is_end) begin
        commit_next_state = WAVE_STATE_DONE;
    end
    else if (commit_payload.is_wait && !wait_arm_satisfied) begin
        commit_next_state = WAVE_STATE_WAITCNT;
    end
end

endmodule

`default_nettype wire