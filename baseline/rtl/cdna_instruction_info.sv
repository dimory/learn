`timescale 1ns/1ns
`default_nettype none

// ============================================================================
// Module: cdna_instruction_info
//
// Function:
//   Classify the first DWORD of an instruction in the supported M3 subset.
//   Determine the total instruction length, including appended literals.
//   Report unsupported format prefixes and conflicting literal encodings.
//
// Microarchitecture:
//   This module is a purely combinational instruction header classifier.
//   Format prefixes are checked in a priority-ordered if/else chain.
//   SOP1, SOPC, and SOPP must be checked before the broader SOP2 prefix.
//   VOP1 and VOPC must be checked before the broader VOP2 prefix.
//   Source selectors are extracted only when literal checking is required.
//   An eligible source selector of 255 appends one shared literal DWORD.
//   An eligible source selector of 254 appends two shared literal DWORDs.
//   Mixing literal32 and literal64 selectors is an encoding fault.
//
// Final interface connections:
//   instruction0:
//     Connected to imem_rsp_data inside wave_instruction_fetcher.
//   inst_format:
//     Connected to response_format inside wave_instruction_fetcher.
//   inst_dwords:
//     Connected to response_length inside wave_instruction_fetcher.
//     Used to determine how many DWORDs belong to the current instruction.
//   fault:
//     Connected to response_fault inside wave_instruction_fetcher.
//     Used to terminate assembly and report a header classification fault.
//
// Timing and reset:
//   Outputs are combinational functions of instruction0.
//   The fetcher consumes these outputs when accepting the first DWORD.
//   This module has no clock, reset, or valid/ready interface.
//   Default assignments are provided for all combinational outputs.
//
// Architectural boundaries:
//   Full opcode, operand, and modifier validation belongs to cdna_decoder.
//   Recognizing a format does not guarantee that its opcode is supported.
//   Architectural PC updates belong to the commit path.
//
// Compile dependency:
//   Compile gpu_pkg.sv before this module.
// ============================================================================

module cdna_instruction_info (
    // First 32-bit instruction word from the instruction memory response.
    input  logic [31:0] instruction0,

    // Instruction encoding format recognized from the first DWORD.
    output gpu_pkg::inst_format_t inst_format,

    // Total instruction length in DWORDs, including appended literals.
    output logic [2:0] inst_dwords,

    // Header classification fault; full decode faults are checked later.
    output gpu_pkg::m3_fault_t fault
);

    import gpu_pkg::*;

    // Source selectors, rather than register data.
    // Eight-bit scalar selectors are zero-extended to nine bits.
    logic [8:0] source0;
    logic [8:0] source1;

    // Enable appended-literal detection for eligible instruction formats.
    logic check_literals;

    always_comb begin
        // Default outputs and intermediate values.
        inst_format  = INST_FORMAT_NONE;
        inst_dwords  = 3'd1;
        fault        = M3_FAULT_NONE;

        source0       = '0;
        source1       = '0;
        check_literals = 1'b0;
		if (instruction0[31:23] == 9'b101111101)begin
			inst_format = INST_FORMAT_SOP1;
			source0 = {1'b0,instruction0[7:0]};
			check_literals = 1'b1;
		end
		else if (instruction0[31:23] == 9'b101111110)begin
			inst_format = INST_FORMAT_SOPC;
			source0 = {1'b0,instruction0[7:0]};
			source1 = {1'b0,instruction0[15:8]};
			check_literals = 1'b1;
		end
		else if (instruction0[31:23] == 9'b101111111)begin
			inst_format = INST_FORMAT_SOPP;	
		end
		else if (instruction0[31:30] == 2'b10)begin
			inst_format = INST_FORMAT_SOP2;
			source0 = {1'b0,instruction0[7:0]};
			source1 = {1'b0,instruction0[15:8]};
			check_literals = 1'b1;
		end
		else if (instruction0[31:25] == 7'b0111111)begin
			inst_format = INST_FORMAT_VOP1;
			source0 = instruction0[8:0];
			check_literals = 1'b1;		
		end
		else if (instruction0[31:25] == 7'b0111110)begin
			inst_format = INST_FORMAT_VOPC;
			source0 = instruction0[8:0];
			check_literals = 1'b1;		
		end
		else if (instruction0[31] == 1'b0)begin
			inst_format = INST_FORMAT_VOP2;
			source0 = instruction0[8:0];
			check_literals = 1'b1;						
		end
		else if (instruction0[31:26] == 6'b111101) begin
		inst_format = INST_FORMAT_SMEM;
		inst_dwords = 3'd2;
		end
		else if (instruction0[31:26] == 6'b110110) begin
			inst_format = INST_FORMAT_VDS;
			inst_dwords = 3'd2;
		end
		else if (instruction0[31:24] == 8'hee) begin
			inst_format = INST_FORMAT_VGLOBAL;
			inst_dwords = 3'd3;
		end
		else begin
			fault = M3_FAULT_UNSUPPORTED;
		end
		if (check_literals) begin
			// Determine the total length, including the shared appended literal.
			if ((source0 == 9'd254) || (source1 == 9'd254))
				inst_dwords = 3'd3;
			else if ((source0 == 9'd255) || (source1 == 9'd255))
				inst_dwords = 3'd2;
		
			// Reject mixed literal64 and literal32 selectors.
			if (((source0 == 9'd254) && (source1 == 9'd255)) ||
				((source0 == 9'd255) && (source1 == 9'd254)))
				fault = M3_FAULT_ENCODING;
		end

    end

endmodule

`default_nettype wire