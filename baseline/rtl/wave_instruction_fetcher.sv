`timescale 1ns/1ns
`default_nettype none

// ============================================================================
// Module: wave_instruction_fetcher
//
// Function:
//   Fetch and assemble one complete instruction for each scheduled Wave.
//   Support instructions containing one, two, or three DWORDs.
//   Preserve the Wave identity and Context snapshot through instruction fetch.
//
// Microarchitecture:
//   Each Wave owns one instruction assembly slot.
//   occupied marks a reserved slot.
//   pending marks one outstanding DWORD request for that Wave.
//   assembled marks a complete instruction or a completed fault packet.
//   next_word identifies the next DWORD to request.
//   cdna_instruction_info determines the length from the first response DWORD.
//   Separate round-robin arbiters select memory requests and assembled outputs.
//   Each arbiter locks its selected owner while its output is backpressured.
//   Request addresses use the saved PC plus four times the DWORD index.
//
// Final interface connections:
//   selected_valid and selected_wave_id:
//     Driven by the M2 Scheduler through wave_control_subsystem.
//   selected_ready:
//     Returned to the M2 Scheduler to qualify schedule_fire.
//   selected_context:
//     Assembled in wave_compute_top from the M2 Context and launch snapshot.
//   imem_req_* and imem_rsp_*:
//     Connected to the external instruction-memory interface through
//     wave_execution_subsystem and wave_compute_top.
//   out_*:
//     Connected to the input interface of cdna_decoder.
//
// Timing and reset:
//   Context capture occurs on selected_valid && selected_ready.
//   Request ownership changes only after a request handshake.
//   Response data is stored on a response handshake.
//   Slot ownership is released only after an output handshake.
//   Registers use an asynchronous active-low reset.
//   Combinational logic contains no reset qualification.
//
// Architectural boundaries:
//   The fetcher assembles instructions and propagates fetch/header faults.
//   Full instruction decoding belongs to cdna_decoder.
//   Architectural PC updates belong to the commit path.
//   The memory response must return the original Wave ID and DWORD index.
//
// Compile dependencies:
//   Compile gpu_pkg.sv and cdna_instruction_info.sv before this module.
// ============================================================================

module wave_instruction_fetcher #(
    parameter int NUM_WAVE_CONTEXTS = 4,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    // Clock and asynchronous active-low reset.
    input  logic clk,
    input  logic rst_n,

    // Scheduled Wave and its Context snapshot.
    input  logic selected_valid,
    output logic selected_ready,
    input  logic [WAVE_ID_BITS-1:0] selected_wave_id,
    input  gpu_pkg::m3_context_t selected_context,

    // One-DWORD instruction-memory request.
    output logic imem_req_valid,
    input  logic imem_req_ready,
    output logic [WAVE_ID_BITS-1:0] imem_req_wave_id,
    output logic [1:0] imem_req_word_index,
    output logic [63:0] imem_req_address,

    // Tagged instruction-memory response.
    input  logic imem_rsp_valid,
    output logic imem_rsp_ready,
    input  logic [WAVE_ID_BITS-1:0] imem_rsp_wave_id,
    input  logic [1:0] imem_rsp_word_index,
    input  logic [31:0] imem_rsp_data,
    input  logic imem_rsp_error,

    // Complete instruction and saved Context delivered to the decoder.
    output logic out_valid,
    input  logic out_ready,
    output logic [WAVE_ID_BITS-1:0] out_wave_id,
    output gpu_pkg::m3_fetch_payload_t out_payload
);

import gpu_pkg::*;

// Per-Wave assembly-slot ownership and progress.
logic [NUM_WAVE_CONTEXTS-1:0] occupied;
logic [NUM_WAVE_CONTEXTS-1:0] pending;
logic [NUM_WAVE_CONTEXTS-1:0] assembled;

// Saved Context, instruction DWORDs, length, and fault.
m3_fetch_payload_t packets [0:NUM_WAVE_CONTEXTS-1];

// Next DWORD index: zero, one, or two.
logic [1:0] next_word [0:NUM_WAVE_CONTEXTS-1];

// Request-arbiter lock, held owner, and round-robin pointer.
logic req_locked;
logic [WAVE_ID_BITS-1:0] req_owner;
logic [WAVE_ID_BITS-1:0] req_pointer;

// Output-arbiter lock, held owner, and round-robin pointer.
logic out_locked;
logic [WAVE_ID_BITS-1:0] out_owner;
logic [WAVE_ID_BITS-1:0] out_pointer;

// Combinational classification of the response DWORD.
inst_format_t response_format;
logic [2:0] response_length;
m3_fault_t response_fault;

// Handshake events.
logic schedule_fire;
logic imem_req_fire;
logic imem_rsp_fire;
logic out_fire;

// Combinational arbitration loop variables.
integer scan_req;
integer scan_out;
integer index_req;
integer index_out;

// Sequential array loop variable.
integer w;

assign schedule_fire = selected_valid && selected_ready;
assign imem_req_fire = imem_req_valid && imem_req_ready;
assign imem_rsp_fire = imem_rsp_valid && imem_rsp_ready;
assign out_fire      = out_valid && out_ready;

// Classification results are consumed for the first response DWORD.
cdna_instruction_info u_info (
    .instruction0 (imem_rsp_data),
    .inst_format  (response_format),
    .inst_dwords  (response_length),
    .fault        (response_fault)
);
assign selected_ready = !occupied[selected_wave_id];
// TODO: Implement slot admission and request/output arbitration.

// TODO: Implement Context capture and per-Wave fetch progress.
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        occupied <= '0;
        pending <= '0;
        assembled <= '0;
        req_locked <= 1'b0;
        req_owner <= '0;
        req_pointer <= '0;
        out_locked <= 1'b0;
        out_owner <= '0;
        out_pointer <= '0;
        for (w = 0; w < NUM_WAVE_CONTEXTS; w = w + 1) begin
            packets[w] <= '0;
            next_word[w] <= '0;
        end
    end
    else begin
		if (out_fire) begin
			// Release the consumed packet slot.
			occupied[out_wave_id] <= 1'b0;
			assembled[out_wave_id] <= 1'b0;
			out_locked <= 1'b0;

			// Advance past the wave whose packet was accepted.
			out_pointer <=
				(int'(out_wave_id) == NUM_WAVE_CONTEXTS-1) ?
				'0 : out_wave_id + 1'b1;
		end
		else if (out_valid) begin
			// Hold the selected packet during decoder backpressure.
			out_locked <= 1'b1;
			out_owner <= out_wave_id;
		end
        // Reserve a packet slot and save the selected wave context.
        if (schedule_fire) begin
            occupied[selected_wave_id] <= 1'b1;
            packets[selected_wave_id].context_data <= selected_context;
            packets[selected_wave_id].instruction <= '0;
            packets[selected_wave_id].inst_dwords <= 3'd1;
            packets[selected_wave_id].fault <= M3_FAULT_NONE;
            next_word[selected_wave_id] <= '0;
        end

        // Track an accepted request or lock a stalled request.
        if (imem_req_fire) begin
            pending[imem_req_wave_id] <= 1'b1;
            req_locked <= 1'b0;
            req_pointer <=
                (int'(imem_req_wave_id) == NUM_WAVE_CONTEXTS-1) ?
                '0 : imem_req_wave_id + 1'b1;
        end
        else if (imem_req_valid) begin
            req_locked <= 1'b1;
            req_owner <= imem_req_wave_id;
        end

        // Store the returned DWORD and update instruction assembly.
        if (imem_rsp_fire) begin
            pending[imem_rsp_wave_id] <= 1'b0;
            packets[imem_rsp_wave_id].instruction[
                imem_rsp_word_index*32 +: 32
            ] <= imem_rsp_data;

            if (imem_rsp_error) begin
                // Finish the packet with an instruction fetch fault.
                assembled[imem_rsp_wave_id] <= 1'b1;
                packets[imem_rsp_wave_id].fault <= M3_FAULT_FETCH;
            end
            else if (imem_rsp_word_index == 2'd0) begin
                // Save the length and fault classified from the header.
                packets[imem_rsp_wave_id].inst_dwords <= response_length;
                packets[imem_rsp_wave_id].fault <= response_fault;

                if ((response_length == 3'd1) ||
                    (response_fault != M3_FAULT_NONE))
                    assembled[imem_rsp_wave_id] <= 1'b1;
                else
                    next_word[imem_rsp_wave_id] <= 2'd1;
            end
            else begin
                // Use the saved header length for subsequent DWORDs.
                if ((imem_rsp_word_index + 3'd1) ==
                    packets[imem_rsp_wave_id].inst_dwords)
                    assembled[imem_rsp_wave_id] <= 1'b1;
                else
                    next_word[imem_rsp_wave_id] <=
                        imem_rsp_word_index + 2'd1;
            end
        end

        // Output handshake handling will be added next.
    end
end

assign imem_rsp_ready = 1'b1;
always_comb begin
    index_out = 0;
    out_valid = 1'b0;
    out_wave_id = out_owner;

    // Keep the locked packet selected during decoder backpressure.
    if (out_locked) begin
        out_valid = 1'b1;
    end
    else begin
        // Search assembled packets from the round-robin pointer.
        for (scan_out = 0; scan_out < NUM_WAVE_CONTEXTS; scan_out = scan_out + 1) begin
            index_out = scan_out + int'(out_pointer);
            if (index_out >= NUM_WAVE_CONTEXTS)
                index_out = index_out - NUM_WAVE_CONTEXTS;

            if (!out_valid && assembled[index_out]) begin
                out_valid = 1'b1;
                out_wave_id = WAVE_ID_BITS'(index_out);
            end
        end
    end

    // Forward the selected packet to the decoder.
    out_payload = packets[out_wave_id];
end


always_comb begin
    index_req = 0;
    imem_req_valid = 1'b0;
    imem_req_wave_id = req_owner;

    // Keep the locked request selected during memory backpressure.
    if (req_locked) begin
        imem_req_valid = 1'b1;
    end
    else begin
        // Search eligible slots from the round-robin pointer.
        for (scan_req = 0; scan_req < NUM_WAVE_CONTEXTS; scan_req = scan_req + 1) begin
            index_req = scan_req + int'(req_pointer);
            if (index_req >= NUM_WAVE_CONTEXTS)
                index_req = index_req - NUM_WAVE_CONTEXTS;

            if (!imem_req_valid &&
                occupied[index_req] &&
                !pending[index_req] &&
                !assembled[index_req]) begin
                imem_req_valid = 1'b1;
                imem_req_wave_id = WAVE_ID_BITS'(index_req);
            end
        end
    end

    // Request the next DWORD using the saved instruction PC.
    imem_req_word_index = next_word[imem_req_wave_id];
    imem_req_address = packets[imem_req_wave_id].context_data.pc +
        (64'(imem_req_word_index) << 2);
end


endmodule

`default_nettype wire