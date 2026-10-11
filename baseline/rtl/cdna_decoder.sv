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

// Classify the first DWORD of the assembled instruction.
cdna_instruction_info u_instruction_info (
    .instruction0(in_payload.instruction[31:0]),
    .inst_format(format),
    .inst_dwords(),
    .fault(header_fault)
);

always_comb begin
    // Extract instruction words.
    word0 = in_payload.instruction[31:0];
    literal = in_payload.instruction[95:32];

    // Default decoded uop and source descriptors.
    u = '0;
    s0 = '0;
    s1 = '0;
    s2 = '0;

    opcode = '0;
    supported = 1'b1;
    scalar_destination = 1'b0;
    vector_destination = 1'b0;
    dst_code = 9'd124;
    dst_count = 5'd1;

    // Preserve an earlier fetch fault.
    decode_fault = in_payload.fault;
    if (decode_fault == M3_FAULT_NONE) begin
        decode_fault = header_fault;
    end

    // Common uop defaults.
    u.valid = 1'b1;
    u.inst_format = format;
    u.inst_dwords = in_payload.inst_dwords;
    u.write_pc = 1'b1;
    u.mem_size = MEM_SIZE_B32;

    // Decode format-specific fields.
    case (format)
        INST_FORMAT_SOP1: begin
            opcode = {4'b0, word0[15:8]};
            u.uop_class = UOP_CLASS_SALU;
            u.function_code = UOP_FUNCTION_MOV;

            scalar_destination = 1'b1;
            dst_code = {2'b0, word0[22:16]};

            case (opcode)
                12'd0: begin
                    // S_MOV_B32.
                    dst_count = 5'd1;
                end

                12'd1: begin
                    // S_MOV_B64.
                    dst_count = 5'd2;
                end

                default: begin
                    supported = 1'b0;
                end
            endcase

            s0 = source(
                {1'b0, word0[7:0]},
                dst_count,
                literal
            );
        end

        INST_FORMAT_SOP2: begin
            opcode = {5'b0, word0[29:23]};
            u.uop_class = UOP_CLASS_SALU;

            scalar_destination = 1'b1;
            dst_code = {2'b0, word0[22:16]};
            dst_count = 5'd1;
            u.write_scc = 1'b1;

            s0 = source({1'b0, word0[7:0]}, 5'd1, literal);
            s1 = source({1'b0, word0[15:8]}, 5'd1, literal);

            case (opcode)
                12'd0: u.function_code = UOP_FUNCTION_ADD;
                12'd1: u.function_code = UOP_FUNCTION_SUB;
                12'd8: u.function_code = UOP_FUNCTION_SHL;
                12'd10: u.function_code = UOP_FUNCTION_SHR;
                12'd22: u.function_code = UOP_FUNCTION_AND;
                12'd24: u.function_code = UOP_FUNCTION_OR;
                12'd26: u.function_code = UOP_FUNCTION_XOR;

                12'd44: begin
                    // S_MUL_I32 does not update SCC.
                    u.function_code = UOP_FUNCTION_MUL;
                    u.write_scc = 1'b0;
                end

                default: begin
                    supported = 1'b0;
                end
            endcase
        end

        INST_FORMAT_SOPC: begin
            opcode = {5'b0, word0[22:16]};
            u.uop_class = UOP_CLASS_SALU;
            u.function_code = UOP_FUNCTION_CMP;
            u.write_scc = 1'b1;

            s0 = source({1'b0, word0[7:0]}, 5'd1, literal);
            s1 = source({1'b0, word0[15:8]}, 5'd1, literal);

            // S_CMP_EQ_U32: 6; S_CMP_LT_U32: 10.
            u.compare_less = (opcode == 12'd10);

            if ((opcode != 12'd6) && (opcode != 12'd10)) begin
                supported = 1'b0;
            end
        end

        INST_FORMAT_SOPP: begin
            opcode = {5'b0, word0[22:16]};
            u.uop_class = UOP_CLASS_SYSTEM;
            u.function_code = UOP_FUNCTION_NOP;

            u.immediate = {{16{word0[15]}}, word0[15:0]};
            u.immediate_valid = 1'b1;

            case (opcode)
                12'd0: begin
                    // Support the single-cycle S_NOP form.
                    if (word0[15:0] != 16'd0) begin
                        supported = 1'b0;
                    end
                end

                12'd48: begin
                    // S_ENDPGM.
                    u.function_code = UOP_FUNCTION_END;
                    u.end_program = 1'b1;
                end

                12'd32, 12'd33, 12'd34, 12'd35,
                12'd36, 12'd37, 12'd38: begin
                    u.uop_class = UOP_CLASS_BRANCH;
                    u.function_code = UOP_FUNCTION_BRANCH;

                    case (opcode)
                        12'd32: begin
                            u.branch_condition = BRANCH_CONDITION_ALWAYS;
                        end

                        12'd33: begin
                            u.branch_condition = BRANCH_CONDITION_SCC0;
                        end

                        12'd34: begin
                            u.branch_condition = BRANCH_CONDITION_SCC1;
                        end

                        12'd35: begin
                            u.branch_condition = BRANCH_CONDITION_VCCZ;
                        end

                        12'd36: begin
                            u.branch_condition = BRANCH_CONDITION_VCCNZ;
                        end

                        12'd37: begin
                            u.branch_condition = BRANCH_CONDITION_EXECZ;
                        end

                        12'd38: begin
                            u.branch_condition = BRANCH_CONDITION_EXECNZ;
                        end

                        default: begin
                        end
                    endcase
                end

                12'd64, 12'd65, 12'd69, 12'd70, 12'd71,
                12'd72, 12'd73, 12'd74, 12'd75: begin
                    u.uop_class = UOP_CLASS_WAIT;
                    u.function_code = UOP_FUNCTION_WAIT;

                    case (opcode)
                        12'd64: begin
                            u.wait_spec.mask[DEP_LOAD] = 1'b1;
                            u.wait_spec.load_threshold = word0[5:0];
                        end

                        12'd65: begin
                            u.wait_spec.mask[DEP_STORE] = 1'b1;
                            u.wait_spec.store_threshold = word0[5:0];
                        end

                        12'd69: begin
                            u.wait_spec.mask[DEP_X] = 1'b1;
                            u.wait_spec.x_threshold = word0[5:0];
                        end

                        12'd70: begin
                            u.wait_spec.mask[DEP_DS] = 1'b1;
                            u.wait_spec.ds_threshold = word0[5:0];
                        end

                        12'd71: begin
                            u.wait_spec.mask[DEP_KM] = 1'b1;
                            u.wait_spec.km_threshold = word0[4:0];
                        end

                        12'd72: begin
                            u.wait_spec.mask[DEP_LOAD] = 1'b1;
                            u.wait_spec.mask[DEP_DS] = 1'b1;
                            u.wait_spec.load_threshold = word0[13:8];
                            u.wait_spec.ds_threshold = word0[5:0];
                        end

                        12'd73: begin
                            u.wait_spec.mask[DEP_STORE] = 1'b1;
                            u.wait_spec.mask[DEP_DS] = 1'b1;
                            u.wait_spec.store_threshold = word0[13:8];
                            u.wait_spec.ds_threshold = word0[5:0];
                        end

                        12'd74: begin
                            u.wait_spec.mask[DEP_ASYNC] = 1'b1;
                            u.wait_spec.async_threshold = word0[5:0];
                        end

                        12'd75: begin
                            u.wait_spec.mask[DEP_TENSOR] = 1'b1;
                            u.wait_spec.tensor_threshold = word0[5:0];
                        end

                        default: begin
                        end
                    endcase
                end

                default: begin
                    supported = 1'b0;
                end
            endcase
        end

        INST_FORMAT_VOP1: begin
            opcode = {5'b0, word0[15:9]};
            u.uop_class = UOP_CLASS_VALU;
            u.function_code = UOP_FUNCTION_MOV;
            u.use_exec = 1'b1;

            vector_destination = 1'b1;
            dst_code = {1'b0, word0[24:17]};
            dst_count = 5'd1;

            s0 = source(word0[8:0], 5'd1, literal);

            // Support V_MOV_B32 with the fixed modifier profile.
            if ((opcode != 12'd1) || word0[16]) begin
                supported = 1'b0;
            end
        end

        INST_FORMAT_VOP2: begin
            opcode = {6'b0, word0[30:25]};
            u.uop_class = UOP_CLASS_VALU;
            u.use_exec = 1'b1;

            vector_destination = 1'b1;
            dst_code = {1'b0, word0[24:17]};
            dst_count = 5'd1;

            s0 = source(word0[8:0], 5'd1, literal);
            s1 = source(
                9'd256 + {1'b0, word0[16:9]},
                5'd1,
                literal
            );

            case (opcode)
                12'd37: u.function_code = UOP_FUNCTION_ADD;
                12'd38: u.function_code = UOP_FUNCTION_SUB;
                12'd24: u.function_code = UOP_FUNCTION_SHL;
                12'd25: u.function_code = UOP_FUNCTION_SHR;
                12'd27: u.function_code = UOP_FUNCTION_AND;
                12'd28: u.function_code = UOP_FUNCTION_OR;
                12'd29: u.function_code = UOP_FUNCTION_XOR;

                default: begin
                    supported = 1'b0;
                end
            endcase
        end

        INST_FORMAT_VOPC: begin
            opcode = {4'b0, word0[24:17]};
            u.uop_class = UOP_CLASS_VALU;
            u.function_code = UOP_FUNCTION_CMP;
            u.use_exec = 1'b1;
            u.write_vcc = 1'b1;

            s0 = source(word0[8:0], 5'd1, literal);
            s1 = source(
                9'd256 + {1'b0, word0[16:9]},
                5'd1,
                literal
            );

            // V_CMP_LT_U32: 73; V_CMP_EQ_U32: 74.
            u.compare_less = (opcode == 12'd73);

            if ((opcode != 12'd73) && (opcode != 12'd74)) begin
                supported = 1'b0;
            end
        end

        INST_FORMAT_SMEM: begin
            opcode = {6'b0, word0[18:13]};
            u.uop_class = UOP_CLASS_SMEM;
            u.function_code = UOP_FUNCTION_LOAD;
            u.mem_space = MEM_SPACE_SCALAR;
            u.mem_operation = MEM_OP_LOAD;

            // SBASE encodes an SGPR pair number.
            s0 = source(
                {2'b0, word0[5:0], 1'b0},
                5'd2,
                literal
            );

            scalar_destination = 1'b1;
            dst_code = {2'b0, word0[12:6]};
            dst_count = 5'd1;

            // Support ordinary SGPR and NULL load destinations.
            if ((dst_code >= 9'd106) && (dst_code != 9'd124)) begin
                supported = 1'b0;
            end

            u.mem_offset = in_payload.instruction[55:32];

            // Support S_LOAD_B32 with IOFFSET and NULL SOFFSET.
            if ((opcode != 12'd0) ||
                (word0[25:19] != 7'd0) ||
                in_payload.instruction[56] ||
                (in_payload.instruction[63:57] != 7'd124)) begin
                supported = 1'b0;
            end
        end

        INST_FORMAT_VGLOBAL: begin
            opcode = {4'b0, word0[20:13]};
            u.uop_class = UOP_CLASS_VMEM;
            u.use_exec = 1'b1;
            u.mem_space = MEM_SPACE_GLOBAL;
            u.mem_offset = in_payload.instruction[95:72];

            // NULL and selector 127 select the GV address form.
            u.mem_gvs = (word0[6:0] != 7'd124) &&
                        (word0[6:0] != 7'd127);

            if (u.mem_gvs) begin
                // GVS: VGPR offset plus SGPR base pair.
                s0 = source(
                    9'd256 + {1'b0, in_payload.instruction[71:64]},
                    5'd1,
                    literal
                );

                s1 = source(
                    {2'b0, word0[6:0]},
                    5'd2,
                    literal
                );

                if (s1.kind != OPERAND_SGPR) begin
                    supported = 1'b0;
                end
            end else begin
                // GV: per-lane address from a VGPR pair.
                s0 = source(
                    9'd256 + {1'b0, in_payload.instruction[71:64]},
                    5'd2,
                    literal
                );
            end

            case (opcode)
                12'd20: begin
                    // GLOBAL_LOAD_B32.
                    u.function_code = UOP_FUNCTION_LOAD;
                    u.mem_operation = MEM_OP_LOAD;

                    vector_destination = 1'b1;
                    dst_code = {1'b0, in_payload.instruction[39:32]};
                    dst_count = 5'd1;

                    if (in_payload.instruction[62:55] != 8'd0) begin
                        supported = 1'b0;
                    end
                end

                12'd26: begin
                    // GLOBAL_STORE_B32.
                    u.function_code = UOP_FUNCTION_STORE;
                    u.mem_operation = MEM_OP_STORE;

                    s2 = source(
                        9'd256 + {1'b0, in_payload.instruction[62:55]},
                        5'd1,
                        literal
                    );

                    if (in_payload.instruction[39:32] != 8'd0) begin
                        supported = 1'b0;
                    end
                end

                default: begin
                    supported = 1'b0;
                end
            endcase

            // Enforce the fixed modifier profile.
            if ((word0[12:7] != 6'd0) ||
                (word0[23:21] != 3'd0) ||
                (in_payload.instruction[54:40] != 15'd0) ||
                in_payload.instruction[63]) begin
                supported = 1'b0;
            end
        end

        INST_FORMAT_VDS: begin
            opcode = {4'b0, word0[25:18]};
            u.uop_class = UOP_CLASS_LDS;
            u.use_exec = 1'b1;
            u.mem_space = MEM_SPACE_LDS;

            // DS byte offset is unsigned for these operations.
            u.mem_offset = {8'b0, word0[15:0]};

            s0 = source(
                9'd256 + {1'b0, in_payload.instruction[39:32]},
                5'd1,
                literal
            );

            case (opcode)
                12'd54: begin
                    // DS_LOAD_B32.
                    u.function_code = UOP_FUNCTION_LOAD;
                    u.mem_operation = MEM_OP_LOAD;

                    vector_destination = 1'b1;
                    dst_code = {1'b0, in_payload.instruction[63:56]};
                    dst_count = 5'd1;

                    if (in_payload.instruction[55:40] != 16'd0) begin
                        supported = 1'b0;
                    end
                end

                12'd13: begin
                    // DS_STORE_B32.
                    u.function_code = UOP_FUNCTION_STORE;
                    u.mem_operation = MEM_OP_STORE;

                    s2 = source(
                        9'd256 + {1'b0, in_payload.instruction[47:40]},
                        5'd1,
                        literal
                    );

                    if (in_payload.instruction[63:48] != 16'd0) begin
                        supported = 1'b0;
                    end
                end

                default: begin
                    supported = 1'b0;
                end
            endcase

            if (word0[17:16] != 2'd0) begin
                supported = 1'b0;
            end
        end

        default: begin
            supported = 1'b0;
        end
    endcase

    // Normalize and validate the scalar destination.
    if (scalar_destination) begin
        u.dst_index = cdna_reg_index_t'(dst_code);
        u.dst_count = dst_count;

        if (dst_code <= 9'd105) begin
            u.dst_kind = OPERAND_SGPR;
            u.dst_valid = 1'b1;

            if (decode_fault == M3_FAULT_NONE) begin
                if ((int'(dst_code) + int'(dst_count)) > NUM_SGPRS) begin
                    decode_fault = M3_FAULT_RF_RANGE;
                end else if ((dst_count == 5'd2) && dst_code[0]) begin
                    decode_fault = M3_FAULT_OPERAND;
                end
            end
        end else if (dst_count == 5'd1) begin
            case (dst_code)
                9'd106: begin
                    u.dst_kind = OPERAND_VCC;
                    u.dst_valid = 1'b1;
                    u.write_vcc = 1'b1;
                end

                9'd124: begin
                    // NULL discards SDST and preserves the SCC update.
                    u.dst_kind = OPERAND_NONE;
                    u.dst_valid = 1'b0;
                    u.dst_count = '0;
                end

                9'd125: begin
                    u.dst_kind = OPERAND_M0;
                    u.dst_valid = 1'b1;
                end

                9'd126: begin
                    u.dst_kind = OPERAND_EXEC;
                    u.dst_valid = 1'b1;
                    u.write_exec = 1'b1;
                end

                default: begin
                    supported = 1'b0;
                end
            endcase
        end else begin
            supported = 1'b0;
        end
    end

    // Normalize and validate the vector destination.
    if (vector_destination) begin
        u.dst_kind = OPERAND_VGPR;
        u.dst_index = cdna_reg_index_t'(dst_code);
        u.dst_count = 5'd1;
        u.dst_valid = 1'b1;

        if ((int'(dst_code) >= NUM_VGPRS) &&
            (decode_fault == M3_FAULT_NONE)) begin
            decode_fault = M3_FAULT_RF_RANGE;
        end
    end

    // Merge faults without overwriting an earlier fault.
    if (!supported && decode_fault == M3_FAULT_NONE) begin
        decode_fault = M3_FAULT_UNSUPPORTED;
    end

    if (s0.fault != M3_FAULT_NONE && decode_fault == M3_FAULT_NONE) begin
        decode_fault = s0.fault;
    end

    if (s1.fault != M3_FAULT_NONE && decode_fault == M3_FAULT_NONE) begin
        decode_fault = s1.fault;
    end

    if (s2.fault != M3_FAULT_NONE && decode_fault == M3_FAULT_NONE) begin
        decode_fault = s2.fault;
    end

    // Copy source operand descriptors into the decoded uop.
    u.src0_kind = s0.kind;
    u.src0_index = s0.index;
    u.src0_count = s0.count;
    u.src0_immediate = s0.value;

    u.src1_kind = s1.kind;
    u.src1_index = s1.index;
    u.src1_count = s1.count;
    u.src1_immediate = s1.value;

    u.src2_kind = s2.kind;
    u.src2_index = s2.index;
    u.src2_count = s2.count;
    u.src2_immediate = s2.value;

    // Preserve the ISA opcode and mark decode faults.
    u.isa_opcode = opcode;
    u.illegal = (decode_fault != M3_FAULT_NONE);

    // Assemble the output payload.
    out_payload = '0;
    out_payload.context_data = in_payload.context_data;
    out_payload.instruction = in_payload.instruction;
    out_payload.uop = u;
    out_payload.fault = decode_fault;
end


endmodule

`default_nettype wire