`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// M3 F04: Per-Wave decoded instruction buffer.
//
// Microarchitecture:
// - One independent decoded slot per resident Wave.
// - Each slot contains one valid bit and one m3_decoded_payload_t.
// - slot_valid and slots are the registered storage and module outputs.
// - One shared input writes the slot selected by in_wave_id.
// - All slots are visible to the Operand Collector in parallel.
// - Wave selection and dependency checks are performed by the Collector.
//
// Input handshake:
// - in_ready = !slot_valid[in_wave_id].
// - A valid/ready handshake stores in_payload and sets the selected valid bit.
// - An occupied slot holds its payload until the Collector consumes it.
//
// Slot consumption:
// - pop_mask[n] clears the valid bit of Wave n at the clock edge.
// - The Collector captures the complete payload at the same edge.
// - Popping a slot does not release the M2 ISSUED ownership.
// - Frontend ownership ends when the instruction commits.
//
// Timing:
// - Input ready depends on the currently registered slot_valid.
// - A full slot becomes available in the cycle following its pop edge.
// - Writes and pops targeting different Waves can occur at the same edge.
// - Popping a slot does not require clearing its payload.
//
// Reset:
// - Asynchronous active-low rst_n clears all valid bits.
// - A slot payload is meaningful only while its valid bit is set.
// ============================================================================

module wave_instruction_buffer #(
    parameter int NUM_WAVE_CONTEXTS = 4,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    input logic clk,
    input logic rst_n,

    // Decoded instruction input.
    input logic in_valid,
    output logic in_ready,
    input logic [WAVE_ID_BITS-1:0] in_wave_id,
    input gpu_pkg::m3_decoded_payload_t in_payload,

    // Slot consumption by the operand collector.
    input logic [NUM_WAVE_CONTEXTS-1:0] pop_mask,

    // One decoded slot per wave.
    output logic [NUM_WAVE_CONTEXTS-1:0] slot_valid,
    output gpu_pkg::m3_decoded_payload_t slots [0:NUM_WAVE_CONTEXTS-1]
);

logic in_fire;
integer wave_idx;
assign in_fire = in_valid && in_ready;
assign in_ready = !(slot_valid[in_wave_id]);

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (wave_idx = 0; wave_idx < NUM_WAVE_CONTEXTS; wave_idx = wave_idx + 1)begin
			slot_valid[wave_idx] <= '0;		
		end
    end 
	else begin
        for (wave_idx = 0; wave_idx < NUM_WAVE_CONTEXTS; wave_idx = wave_idx + 1)begin
			slot_valid[wave_idx] <= slot_valid[wave_idx] &(~pop_mask[wave_idx]);				
		end
		if(in_fire)begin
			slot_valid[in_wave_id] <= 1'b1;
			slots[in_wave_id]	   <= in_payload;
		end
    end
end

endmodule