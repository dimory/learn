`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Legacy Decode to CDNA Micro-op Adapter
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// This combinational adapter converts the registered outputs of the original
// 16-bit TinyGPU Decoder into the common gpu_pkg::decoded_uop_t format.
//
// The adapter is a compatibility bridge only. The legacy execution datapath
// continues to consume its original decoded_* controls during M1.
//
// Timing
// -----------------------------------------------------------------------------
// The Legacy Decoder captures a new instruction while core_state == DECODE.
// After that rising edge, core_state advances to REQUEST and the new registered
// Decoder outputs are stable. decoded_uop.valid is therefore asserted only
// while core_state == REQUEST.
//
// Legacy mapping
// -----------------------------------------------------------------------------
//
// Opcode  Instruction  UOP class   Function   Destination/source mapping
// ------  -----------  ----------  ---------  -------------------------------
// 0       NOP          SYSTEM      NOP        none
// 1       BRNZP        BRANCH      BRANCH     absolute target + NZP mask
// 2       CMP          VALU        CMP        VGPR[rs], VGPR[rt] -> VCC
// 3       ADD          VALU        ADD        VGPR[rs], VGPR[rt] -> VGPR[rd]
// 4       SUB          VALU        SUB        VGPR[rs], VGPR[rt] -> VGPR[rd]
// 5       MUL          VALU        MUL        VGPR[rs], VGPR[rt] -> VGPR[rd]
// 6       DIV          VALU        DIV        VGPR[rs], VGPR[rt] -> VGPR[rd]
// 7       LDR          VMEM        LOAD       VGPR[rs] -> VGPR[rd]
// 8       STR          VMEM        STORE      VGPR[rs], VGPR[rt]
// 9       CONST        VALU        MOV        immediate -> VGPR[rd]
// F       RET          SYSTEM      END        terminate Wave
//
// Legacy LDR/STR are represented as unsigned byte-wide global-memory accesses.
// Unsupported opcodes produce a valid Micro-op with illegal asserted.
//
// Synthesis
// -----------------------------------------------------------------------------
// This module is fully synthesizable and contains no sequential state.
// ============================================================================

module legacy_decode_adapter (
    input  logic       [2:0] core_state,
    input  logic       [3:0] legacy_opcode,

    input  logic       [3:0] decoded_rd_address,
    input  logic       [3:0] decoded_rs_address,
    input  logic       [3:0] decoded_rt_address,
    input  logic       [2:0] decoded_nzp,
    input  logic       [7:0] decoded_immediate,

    input  logic             decoded_reg_write_enable,
    input  logic       [1:0] decoded_reg_input_mux,
    input  logic             decoded_mem_read_enable,
    input  logic             decoded_mem_write_enable,
    input  logic       [1:0] decoded_alu_arithmetic_mux,
    input  logic             decoded_alu_output_mux,
    input  logic             decoded_nzp_write_enable,
    input  logic             decoded_pc_mux,
    input  logic             decoded_ret,

    output gpu_pkg::decoded_uop_t decoded_uop
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

localparam logic [1:0] LEGACY_REG_INPUT_ALU       = 2'b00;
localparam logic [1:0] LEGACY_REG_INPUT_LSU       = 2'b01;
localparam logic [1:0] LEGACY_REG_INPUT_IMMEDIATE = 2'b10;

localparam logic [1:0] LEGACY_ALU_ADD = 2'b00;
localparam logic [1:0] LEGACY_ALU_SUB = 2'b01;
localparam logic [1:0] LEGACY_ALU_MUL = 2'b10;
localparam logic [1:0] LEGACY_ALU_DIV = 2'b11;

always_comb begin
    decoded_uop = '0;

    if (core_state == CORE_STATE_REQUEST) begin
        decoded_uop.valid       = 1'b1;
        decoded_uop.inst_format = INST_FORMAT_LEGACY16;
        decoded_uop.inst_dwords = 3'd1;
        decoded_uop.isa_opcode  =
            {{(CDNA_ISA_OPCODE_BITS-4){1'b0}}, legacy_opcode};

        case (legacy_opcode)
            LEGACY_OPCODE_NOP: begin
                decoded_uop.uop_class     = UOP_CLASS_SYSTEM;
                decoded_uop.function_code = UOP_FUNCTION_NOP;
            end

            LEGACY_OPCODE_BRNZP: begin
                decoded_uop.uop_class              = UOP_CLASS_BRANCH;
                decoded_uop.function_code          = UOP_FUNCTION_BRANCH;
                decoded_uop.immediate              =
                    {{(CDNA_DATA_BITS-8){1'b0}}, decoded_immediate};
                decoded_uop.immediate_valid        = 1'b1;
                decoded_uop.immediate_signed       = 1'b0;
                decoded_uop.branch_condition       =
                    BRANCH_CONDITION_LEGACY_NZP;
                decoded_uop.branch_condition_value = {5'b0, decoded_nzp};
                decoded_uop.use_exec               = 1'b1;
                decoded_uop.write_pc               = decoded_pc_mux;
            end

            LEGACY_OPCODE_CMP: begin
                decoded_uop.uop_class = UOP_CLASS_VALU;
                decoded_uop.function_code = decoded_alu_output_mux ?
                    UOP_FUNCTION_CMP : UOP_FUNCTION_NOP;
                decoded_uop.src0_kind  = OPERAND_VGPR;
                decoded_uop.src0_index =
                    {{(CDNA_REG_INDEX_BITS-4){1'b0}},
                     decoded_rs_address};
                decoded_uop.src0_count = 5'd1;
                decoded_uop.src1_kind  = OPERAND_VGPR;
                decoded_uop.src1_index =
                    {{(CDNA_REG_INDEX_BITS-4){1'b0}},
                     decoded_rt_address};
                decoded_uop.src1_count = 5'd1;
                decoded_uop.use_exec   = 1'b1;
                decoded_uop.write_vcc  = decoded_nzp_write_enable;
            end

            LEGACY_OPCODE_ADD,
            LEGACY_OPCODE_SUB,
            LEGACY_OPCODE_MUL,
            LEGACY_OPCODE_DIV: begin
                decoded_uop.uop_class = UOP_CLASS_VALU;

                case (decoded_alu_arithmetic_mux)
                    LEGACY_ALU_ADD:
                        decoded_uop.function_code = UOP_FUNCTION_ADD;
                    LEGACY_ALU_SUB:
                        decoded_uop.function_code = UOP_FUNCTION_SUB;
                    LEGACY_ALU_MUL:
                        decoded_uop.function_code = UOP_FUNCTION_MUL;
                    LEGACY_ALU_DIV:
                        decoded_uop.function_code = UOP_FUNCTION_DIV;
                    default:
                        decoded_uop.function_code = UOP_FUNCTION_NOP;
                endcase

                decoded_uop.dst_valid =
                    decoded_reg_write_enable &&
                    (decoded_reg_input_mux == LEGACY_REG_INPUT_ALU);
                decoded_uop.dst_kind   = OPERAND_VGPR;
                decoded_uop.dst_index  =
                    {{(CDNA_REG_INDEX_BITS-4){1'b0}},
                     decoded_rd_address};
                decoded_uop.dst_count  = 5'd1;
                decoded_uop.src0_kind  = OPERAND_VGPR;
                decoded_uop.src0_index =
                    {{(CDNA_REG_INDEX_BITS-4){1'b0}},
                     decoded_rs_address};
                decoded_uop.src0_count = 5'd1;
                decoded_uop.src1_kind  = OPERAND_VGPR;
                decoded_uop.src1_index =
                    {{(CDNA_REG_INDEX_BITS-4){1'b0}},
                     decoded_rt_address};
                decoded_uop.src1_count = 5'd1;
                decoded_uop.use_exec   = 1'b1;
            end

            LEGACY_OPCODE_LDR: begin
                decoded_uop.uop_class     = UOP_CLASS_VMEM;
                decoded_uop.function_code = UOP_FUNCTION_LOAD;
                decoded_uop.dst_valid     =
                    decoded_reg_write_enable &&
                    (decoded_reg_input_mux == LEGACY_REG_INPUT_LSU);
                decoded_uop.dst_kind      = OPERAND_VGPR;
                decoded_uop.dst_index     =
                    {{(CDNA_REG_INDEX_BITS-4){1'b0}},
                     decoded_rd_address};
                decoded_uop.dst_count     = 5'd1;
                decoded_uop.src0_kind     = OPERAND_VGPR;
                decoded_uop.src0_index    =
                    {{(CDNA_REG_INDEX_BITS-4){1'b0}},
                     decoded_rs_address};
                decoded_uop.src0_count    = 5'd1;
                decoded_uop.mem_space     = MEM_SPACE_GLOBAL;
                decoded_uop.mem_operation = decoded_mem_read_enable ?
                    MEM_OP_LOAD : MEM_OP_NONE;
                decoded_uop.mem_size      = MEM_SIZE_B8;
                decoded_uop.mem_signed    = 1'b0;
                decoded_uop.use_exec      = 1'b1;
            end

            LEGACY_OPCODE_STR: begin
                decoded_uop.uop_class     = UOP_CLASS_VMEM;
                decoded_uop.function_code = UOP_FUNCTION_STORE;
                decoded_uop.src0_kind     = OPERAND_VGPR;
                decoded_uop.src0_index    =
                    {{(CDNA_REG_INDEX_BITS-4){1'b0}},
                     decoded_rs_address};
                decoded_uop.src0_count    = 5'd1;
                decoded_uop.src1_kind     = OPERAND_VGPR;
                decoded_uop.src1_index    =
                    {{(CDNA_REG_INDEX_BITS-4){1'b0}},
                     decoded_rt_address};
                decoded_uop.src1_count    = 5'd1;
                decoded_uop.mem_space     = MEM_SPACE_GLOBAL;
                decoded_uop.mem_operation = decoded_mem_write_enable ?
                    MEM_OP_STORE : MEM_OP_NONE;
                decoded_uop.mem_size      = MEM_SIZE_B8;
                decoded_uop.mem_signed    = 1'b0;
                decoded_uop.use_exec      = 1'b1;
            end

            LEGACY_OPCODE_CONST: begin
                decoded_uop.uop_class      = UOP_CLASS_VALU;
                decoded_uop.function_code  = UOP_FUNCTION_MOV;
                decoded_uop.dst_valid      =
                    decoded_reg_write_enable &&
                    (decoded_reg_input_mux == LEGACY_REG_INPUT_IMMEDIATE);
                decoded_uop.dst_kind       = OPERAND_VGPR;
                decoded_uop.dst_index      =
                    {{(CDNA_REG_INDEX_BITS-4){1'b0}},
                     decoded_rd_address};
                decoded_uop.dst_count      = 5'd1;
                decoded_uop.src0_kind      = OPERAND_IMMEDIATE;
                decoded_uop.immediate      =
                    {{(CDNA_DATA_BITS-8){1'b0}}, decoded_immediate};
                decoded_uop.immediate_valid = 1'b1;
                decoded_uop.immediate_signed = 1'b0;
                decoded_uop.use_exec        = 1'b1;
            end

            LEGACY_OPCODE_RET: begin
                decoded_uop.uop_class     = UOP_CLASS_SYSTEM;
                decoded_uop.function_code = UOP_FUNCTION_END;
                decoded_uop.end_program   = decoded_ret;
            end

            default: begin
                decoded_uop.uop_class     = UOP_CLASS_SYSTEM;
                decoded_uop.function_code = UOP_FUNCTION_NOP;
                decoded_uop.illegal       = 1'b1;
            end
        endcase
    end
end

endmodule

`default_nettype wire
