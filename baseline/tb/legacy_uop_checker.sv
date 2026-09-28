`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Legacy Micro-op Checker
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// This simulation-only checker independently derives the expected Micro-op
// from the raw Legacy instruction and compares it with the Adapter output.
// It therefore checks Decoder field extraction, Adapter mapping and Core
// integration without affecting the synthesizable design.
//
// Sampling
// -----------------------------------------------------------------------------
// Checks run on the falling edge while core_state == REQUEST. Decoder outputs
// and decoded_uop have already settled following the preceding rising edge.
//
// Error and coverage accounting
// -----------------------------------------------------------------------------
// error_count increases once per faulty instruction. checked_count and
// opcode_seen accumulate across every kernel in the simulation.
// ============================================================================

module legacy_uop_checker (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic [2:0]            core_state,
    input  logic [15:0]           legacy_instruction,
    input  gpu_pkg::decoded_uop_t decoded_uop,
    output logic [31:0]           error_count,
    output logic [31:0]           checked_count,
    output logic [15:0]           opcode_seen
);

import gpu_pkg::*;

localparam logic [2:0] CORE_STATE_REQUEST = 3'b011;

localparam logic [3:0] LEGACY_OPCODE_NOP   = 4'h0;
localparam logic [3:0] LEGACY_OPCODE_BRNZP = 4'h1;
localparam logic [3:0] LEGACY_OPCODE_CMP   = 4'h2;
localparam logic [3:0] LEGACY_OPCODE_ADD   = 4'h3;
localparam logic [3:0] LEGACY_OPCODE_SUB   = 4'h4;
localparam logic [3:0] LEGACY_OPCODE_MUL   = 4'h5;
localparam logic [3:0] LEGACY_OPCODE_DIV   = 4'h6;
localparam logic [3:0] LEGACY_OPCODE_LDR   = 4'h7;
localparam logic [3:0] LEGACY_OPCODE_STR   = 4'h8;
localparam logic [3:0] LEGACY_OPCODE_CONST = 4'h9;
localparam logic [3:0] LEGACY_OPCODE_RET   = 4'hF;

logic [3:0] opcode;
logic [3:0] rd;
logic [3:0] rs;
logic [3:0] rt;
logic [2:0] nzp;
logic [7:0] immediate;

integer instruction_error;

assign opcode    = legacy_instruction[15:12];
assign rd        = legacy_instruction[11:8];
assign rs        = legacy_instruction[7:4];
assign rt        = legacy_instruction[3:0];
assign nzp       = legacy_instruction[11:9];
assign immediate = legacy_instruction[7:0];

task automatic report_uop_error(input string field_name);
    begin
        instruction_error = 1;
        $display(
            "[UOP FAIL] time=%0t instruction=0x%04h opcode=0x%01h field=%s",
            $time,
            legacy_instruction,
            opcode,
            field_name
        );
    end
endtask

initial begin
    error_count   = '0;
    checked_count = '0;
    opcode_seen   = '0;
end

always @(negedge clk) begin
    instruction_error = 0;

    if (rst_n === 1'b1) begin
        if (core_state == CORE_STATE_REQUEST) begin
            checked_count       <= checked_count + 1'b1;
            opcode_seen[opcode] <= 1'b1;

            if (decoded_uop.valid !== 1'b1)
                report_uop_error("valid");
            if (decoded_uop.inst_format !== INST_FORMAT_LEGACY16)
                report_uop_error("inst_format");
            if (decoded_uop.inst_dwords !== 3'd1)
                report_uop_error("inst_dwords");
            if (decoded_uop.isa_opcode !==
                {{(CDNA_ISA_OPCODE_BITS-4){1'b0}}, opcode})
                report_uop_error("isa_opcode");

            case (opcode)
                LEGACY_OPCODE_NOP: begin
                    if (decoded_uop.uop_class !== UOP_CLASS_SYSTEM)
                        report_uop_error("NOP.uop_class");
                    if (decoded_uop.function_code !== UOP_FUNCTION_NOP)
                        report_uop_error("NOP.function_code");
                    if (decoded_uop.dst_valid !== 1'b0)
                        report_uop_error("NOP.dst_valid");
                    if (decoded_uop.use_exec !== 1'b0)
                        report_uop_error("NOP.use_exec");
                    if (decoded_uop.illegal !== 1'b0)
                        report_uop_error("NOP.illegal");
                end

                LEGACY_OPCODE_BRNZP: begin
                    if (decoded_uop.uop_class !== UOP_CLASS_BRANCH)
                        report_uop_error("BRNZP.uop_class");
                    if (decoded_uop.function_code !== UOP_FUNCTION_BRANCH)
                        report_uop_error("BRNZP.function_code");
                    if (decoded_uop.immediate !==
                        {{(CDNA_DATA_BITS-8){1'b0}}, immediate})
                        report_uop_error("BRNZP.immediate");
                    if (decoded_uop.immediate_valid !== 1'b1)
                        report_uop_error("BRNZP.immediate_valid");
                    if (decoded_uop.branch_condition !==
                        BRANCH_CONDITION_LEGACY_NZP)
                        report_uop_error("BRNZP.branch_condition");
                    if (decoded_uop.branch_condition_value !== {5'b0, nzp})
                        report_uop_error("BRNZP.condition_value");
                    if (decoded_uop.write_pc !== 1'b1)
                        report_uop_error("BRNZP.write_pc");
                    if (decoded_uop.use_exec !== 1'b1)
                        report_uop_error("BRNZP.use_exec");
                    if (decoded_uop.illegal !== 1'b0)
                        report_uop_error("BRNZP.illegal");
                end

                LEGACY_OPCODE_CMP: begin
                    if (decoded_uop.uop_class !== UOP_CLASS_VALU)
                        report_uop_error("CMP.uop_class");
                    if (decoded_uop.function_code !== UOP_FUNCTION_CMP)
                        report_uop_error("CMP.function_code");
                    if (decoded_uop.src0_kind !== OPERAND_VGPR)
                        report_uop_error("CMP.src0_kind");
                    if (decoded_uop.src0_index !==
                        {{(CDNA_REG_INDEX_BITS-4){1'b0}}, rs})
                        report_uop_error("CMP.src0_index");
                    if (decoded_uop.src1_kind !== OPERAND_VGPR)
                        report_uop_error("CMP.src1_kind");
                    if (decoded_uop.src1_index !==
                        {{(CDNA_REG_INDEX_BITS-4){1'b0}}, rt})
                        report_uop_error("CMP.src1_index");
                    if (decoded_uop.write_vcc !== 1'b1)
                        report_uop_error("CMP.write_vcc");
                    if (decoded_uop.use_exec !== 1'b1)
                        report_uop_error("CMP.use_exec");
                    if (decoded_uop.illegal !== 1'b0)
                        report_uop_error("CMP.illegal");
                end

                LEGACY_OPCODE_ADD,
                LEGACY_OPCODE_SUB,
                LEGACY_OPCODE_MUL,
                LEGACY_OPCODE_DIV: begin
                    if (decoded_uop.uop_class !== UOP_CLASS_VALU)
                        report_uop_error("ALU.uop_class");
                    case (opcode)
                        LEGACY_OPCODE_ADD:
                            if (decoded_uop.function_code !== UOP_FUNCTION_ADD)
                                report_uop_error("ADD.function_code");
                        LEGACY_OPCODE_SUB:
                            if (decoded_uop.function_code !== UOP_FUNCTION_SUB)
                                report_uop_error("SUB.function_code");
                        LEGACY_OPCODE_MUL:
                            if (decoded_uop.function_code !== UOP_FUNCTION_MUL)
                                report_uop_error("MUL.function_code");
                        LEGACY_OPCODE_DIV:
                            if (decoded_uop.function_code !== UOP_FUNCTION_DIV)
                                report_uop_error("DIV.function_code");
                        default: begin
                        end
                    endcase
                    if (decoded_uop.dst_valid !== 1'b1)
                        report_uop_error("ALU.dst_valid");
                    if (decoded_uop.dst_kind !== OPERAND_VGPR)
                        report_uop_error("ALU.dst_kind");
                    if (decoded_uop.dst_index !==
                        {{(CDNA_REG_INDEX_BITS-4){1'b0}}, rd})
                        report_uop_error("ALU.dst_index");
                    if (decoded_uop.src0_kind !== OPERAND_VGPR)
                        report_uop_error("ALU.src0_kind");
                    if (decoded_uop.src0_index !==
                        {{(CDNA_REG_INDEX_BITS-4){1'b0}}, rs})
                        report_uop_error("ALU.src0_index");
                    if (decoded_uop.src1_kind !== OPERAND_VGPR)
                        report_uop_error("ALU.src1_kind");
                    if (decoded_uop.src1_index !==
                        {{(CDNA_REG_INDEX_BITS-4){1'b0}}, rt})
                        report_uop_error("ALU.src1_index");
                    if (decoded_uop.use_exec !== 1'b1)
                        report_uop_error("ALU.use_exec");
                    if (decoded_uop.illegal !== 1'b0)
                        report_uop_error("ALU.illegal");
                end

                LEGACY_OPCODE_LDR: begin
                    if (decoded_uop.uop_class !== UOP_CLASS_VMEM)
                        report_uop_error("LDR.uop_class");
                    if (decoded_uop.function_code !== UOP_FUNCTION_LOAD)
                        report_uop_error("LDR.function_code");
                    if (decoded_uop.dst_valid !== 1'b1)
                        report_uop_error("LDR.dst_valid");
                    if (decoded_uop.dst_kind !== OPERAND_VGPR)
                        report_uop_error("LDR.dst_kind");
                    if (decoded_uop.dst_index !==
                        {{(CDNA_REG_INDEX_BITS-4){1'b0}}, rd})
                        report_uop_error("LDR.dst_index");
                    if (decoded_uop.src0_kind !== OPERAND_VGPR)
                        report_uop_error("LDR.src0_kind");
                    if (decoded_uop.src0_index !==
                        {{(CDNA_REG_INDEX_BITS-4){1'b0}}, rs})
                        report_uop_error("LDR.src0_index");
                    if (decoded_uop.mem_space !== MEM_SPACE_GLOBAL)
                        report_uop_error("LDR.mem_space");
                    if (decoded_uop.mem_operation !== MEM_OP_LOAD)
                        report_uop_error("LDR.mem_operation");
                    if (decoded_uop.mem_size !== MEM_SIZE_B8)
                        report_uop_error("LDR.mem_size");
                    if (decoded_uop.use_exec !== 1'b1)
                        report_uop_error("LDR.use_exec");
                    if (decoded_uop.illegal !== 1'b0)
                        report_uop_error("LDR.illegal");
                end

                LEGACY_OPCODE_STR: begin
                    if (decoded_uop.uop_class !== UOP_CLASS_VMEM)
                        report_uop_error("STR.uop_class");
                    if (decoded_uop.function_code !== UOP_FUNCTION_STORE)
                        report_uop_error("STR.function_code");
                    if (decoded_uop.dst_valid !== 1'b0)
                        report_uop_error("STR.dst_valid");
                    if (decoded_uop.src0_kind !== OPERAND_VGPR)
                        report_uop_error("STR.src0_kind");
                    if (decoded_uop.src0_index !==
                        {{(CDNA_REG_INDEX_BITS-4){1'b0}}, rs})
                        report_uop_error("STR.src0_index");
                    if (decoded_uop.src1_kind !== OPERAND_VGPR)
                        report_uop_error("STR.src1_kind");
                    if (decoded_uop.src1_index !==
                        {{(CDNA_REG_INDEX_BITS-4){1'b0}}, rt})
                        report_uop_error("STR.src1_index");
                    if (decoded_uop.mem_space !== MEM_SPACE_GLOBAL)
                        report_uop_error("STR.mem_space");
                    if (decoded_uop.mem_operation !== MEM_OP_STORE)
                        report_uop_error("STR.mem_operation");
                    if (decoded_uop.mem_size !== MEM_SIZE_B8)
                        report_uop_error("STR.mem_size");
                    if (decoded_uop.use_exec !== 1'b1)
                        report_uop_error("STR.use_exec");
                    if (decoded_uop.illegal !== 1'b0)
                        report_uop_error("STR.illegal");
                end

                LEGACY_OPCODE_CONST: begin
                    if (decoded_uop.uop_class !== UOP_CLASS_VALU)
                        report_uop_error("CONST.uop_class");
                    if (decoded_uop.function_code !== UOP_FUNCTION_MOV)
                        report_uop_error("CONST.function_code");
                    if (decoded_uop.dst_valid !== 1'b1)
                        report_uop_error("CONST.dst_valid");
                    if (decoded_uop.dst_kind !== OPERAND_VGPR)
                        report_uop_error("CONST.dst_kind");
                    if (decoded_uop.dst_index !==
                        {{(CDNA_REG_INDEX_BITS-4){1'b0}}, rd})
                        report_uop_error("CONST.dst_index");
                    if (decoded_uop.src0_kind !== OPERAND_IMMEDIATE)
                        report_uop_error("CONST.src0_kind");
                    if (decoded_uop.immediate !==
                        {{(CDNA_DATA_BITS-8){1'b0}}, immediate})
                        report_uop_error("CONST.immediate");
                    if (decoded_uop.immediate_valid !== 1'b1)
                        report_uop_error("CONST.immediate_valid");
                    if (decoded_uop.use_exec !== 1'b1)
                        report_uop_error("CONST.use_exec");
                    if (decoded_uop.illegal !== 1'b0)
                        report_uop_error("CONST.illegal");
                end

                LEGACY_OPCODE_RET: begin
                    if (decoded_uop.uop_class !== UOP_CLASS_SYSTEM)
                        report_uop_error("RET.uop_class");
                    if (decoded_uop.function_code !== UOP_FUNCTION_END)
                        report_uop_error("RET.function_code");
                    if (decoded_uop.end_program !== 1'b1)
                        report_uop_error("RET.end_program");
                    if (decoded_uop.use_exec !== 1'b0)
                        report_uop_error("RET.use_exec");
                    if (decoded_uop.illegal !== 1'b0)
                        report_uop_error("RET.illegal");
                end

                default: begin
                    if (decoded_uop.illegal !== 1'b1)
                        report_uop_error("unsupported.illegal");
                end
            endcase

            if (instruction_error != 0)
                error_count <= error_count + 1'b1;
        end
        else if (decoded_uop.valid !== 1'b0) begin
            report_uop_error("valid_outside_REQUEST");
            error_count <= error_count + 1'b1;
        end
    end
end

endmodule

`default_nettype wire
