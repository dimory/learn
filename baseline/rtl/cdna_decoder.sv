`timescale 1ns/1ns
`default_nettype none

// ============================================================================
// Module: cdna_decoder
//
// Function:
//   Decode a complete instruction in the supported M3 subset.
//   Generate a normalized micro-operation and operand descriptors.
//   Propagate fetch faults and report instruction decoding faults.
//
// Microarchitecture:
//   This module is a purely combinational decoder with no internal storage.
//   cdna_instruction_info identifies the instruction encoding format.
//   Format-specific logic extracts the opcode and operand selectors.
//   Source selectors become register descriptors or immediate values.
//   Opcode, modifier, register capacity, and pair alignment are checked.
//   The original instruction, Context snapshot, and Wave ID are preserved.
//
// Final interface connections:
//   in_valid, in_wave_id, and in_payload:
//     Driven by the output interface of wave_instruction_fetcher.
//   in_ready:
//     Returned to wave_instruction_fetcher as its out_ready.
//   out_valid, out_wave_id, and out_payload:
//     Connected to the decoded packet path in wave_execution_subsystem.
//     Normal packets are stored in wave_instruction_buffer.
//     Fault packets are consumed by the fault path in wave_register_init.
//   out_ready:
//     Driven by decoded_ready in wave_execution_subsystem.
//     Normal packet acceptance depends on wave_instruction_buffer.in_ready.
//
// Timing and reset:
//   out_valid follows in_valid, and in_ready follows out_ready.
//   Input and output handshakes occur on the same rising clock edge.
//   The Fetcher holds the input packet stable during backpressure.
//   This module has no clock, reset, or sequential registers.
//
// Architectural boundaries:
//   Register values are collected later by wave_operand_collector.
//   Execution, register writes, and architectural commit occur downstream.
//
// Compile dependencies:
//   Compile gpu_pkg.sv and cdna_instruction_info.sv before this module.
// ============================================================================

module cdna_decoder #(
    parameter int NUM_SGPRS = 32,
    parameter int NUM_VGPRS = 64,
    parameter int WAVE_ID_BITS = 2
) (
    // Complete instruction packet from wave_instruction_fetcher.
    input logic in_valid,
    output logic in_ready,
    input logic [WAVE_ID_BITS-1:0] in_wave_id,
    input gpu_pkg::m3_fetch_payload_t in_payload,
    // Decoded packet sent through wave_execution_subsystem.
    output logic out_valid,
    input logic out_ready,
    output logic [WAVE_ID_BITS-1:0] out_wave_id,
    output gpu_pkg::m3_decoded_payload_t out_payload
);

import gpu_pkg::*;

// Forward handshake signals and preserve the Wave identity.
assign in_ready = out_ready;
assign out_valid = in_valid;
assign out_wave_id = in_wave_id;

// TODO: Add internal declarations and payload decoding.
// Normalized description of one source operand.
typedef struct packed {
    operand_kind_t kind;
    cdna_reg_index_t index;
    logic [UOP_REG_COUNT_BITS-1:0] count;
    logic [63:0] value;
    m3_fault_t fault;
} source_t;
// Temporary descriptors for the three source operands.
source_t s0;
source_t s1;
source_t s2;
// Instruction header classification outputs.
inst_format_t format;
logic [2:0] length;
m3_fault_t header_fault;
// Instruction fields used during decoding.
logic [31:0] word0;
logic [63:0] literal;
logic [CDNA_ISA_OPCODE_BITS-1:0] opcode;
// Destination selector and register count.
logic [8:0] dst_code;
logic [UOP_REG_COUNT_BITS-1:0] dst_count;
logic scalar_destination;
logic vector_destination;
// Instruction support and final decoding results.
logic supported;
decoded_uop_t u;
m3_fault_t decode_fault;

// Decode a source selector into an operand descriptor.
function automatic source_t source(
    input logic [8:0] code,
    input logic [UOP_REG_COUNT_BITS-1:0] count,
    input logic [63:0] literal_value
);
    source_t t;
    begin
        t = '0;
        t.count = count;
        if (code <= 9'd105) begin
            t.kind = OPERAND_SGPR;
            t.index = cdna_reg_index_t'(code);
            if ((int'(code) + int'(count)) > NUM_SGPRS)
                t.fault = M3_FAULT_RF_RANGE;
            else if ((count == 5'd2) && code[0])
                t.fault = M3_FAULT_OPERAND;
        end
		else if (code >= 9'd256) begin
			// Convert the vector source selector to a VGPR index.
			t.kind = OPERAND_VGPR;
			t.index = cdna_reg_index_t'(code - 9'd256);
			if ((int'(t.index) + int'(count)) > NUM_VGPRS)
				t.fault = M3_FAULT_RF_RANGE;
			else if ((count == 5'd2) && t.index[0])
				t.fault = M3_FAULT_OPERAND;
		end
		else if (code == 9'd124) begin
			// Read the NULL source as zero.
			t.kind = OPERAND_IMMEDIATE;
			t.value = '0;
		end
		else if ((code >= 9'd128) && (code <= 9'd192)) begin
			// Decode inline integer constants from 0 to 64.
			t.kind = OPERAND_IMMEDIATE;
			t.value = 64'(int'(code) - 128);
		end
		else if ((code >= 9'd193) && (code <= 9'd208)) begin
			// Decode inline integer constants from -1 to -16.
			t.kind = OPERAND_IMMEDIATE;
			t.value = 64'(-(int'(code) - 192));
		end
		else if (code == 9'd254) begin
			// Use the appended 64-bit literal.
			t.kind = OPERAND_IMMEDIATE;
			t.value = literal_value;
		end
		else if (code == 9'd255) begin
			// Zero-extend the appended 32-bit literal.
			t.kind = OPERAND_IMMEDIATE;
			t.value = {32'b0, literal_value[31:0]};
		end
		else if (code == 9'd106)
			t.kind = OPERAND_VCC;
		else if ((code == 9'd116) || (code == 9'd117)) begin
			t.kind = OPERAND_TTMP;
			t.index = cdna_reg_index_t'(code - 9'd108);
		end
		else if (code == 9'd125)
			t.kind = OPERAND_M0;
		else if (code == 9'd126)
			t.kind = OPERAND_EXEC;
		else if (code == 9'd253)
			t.kind = OPERAND_SCC;
		else begin
			// Reject source selectors outside the supported M3 subset.
			t.fault = M3_FAULT_UNSUPPORTED;
		end
		if ((count == 5'd2) &&
			(t.kind != OPERAND_SGPR) &&
			(t.kind != OPERAND_VGPR) &&
			(t.kind != OPERAND_IMMEDIATE))
			t.fault = M3_FAULT_UNSUPPORTED;
        source = t;
    end
endfunction


endmodule

`default_nettype wire