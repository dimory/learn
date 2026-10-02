`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU CDNA5 Architecture Package
// ============================================================================
//
// Purpose
// -----------------------------------------------------------------------------
// This package defines the architectural constants, shared signal types and
// decoded Micro-op representation used by the CDNA5 upgrade path.
//
// The package contains no hardware state. Hardware is generated only when an
// RTL module declares signals or registers using these definitions.
//
// Decode paths
// -----------------------------------------------------------------------------
//
// Legacy 16-bit instruction -> Legacy Decoder -> Legacy Adapter --+
//                                                               +-> decoded_uop_t
// CDNA5 instruction          -> CDNA5 Decoder -------------------+
//
// Architectural defaults
// -----------------------------------------------------------------------------
//
// Item                              Initial implementation
// --------------------------------  -------------------------------------------
// Register element                  32 bits
// Architectural address            64 bits
// Wave PC                           64-bit byte address
// Logical Wave size                 32 lanes
// EXEC/VCC architectural storage    64 bits; Wave32 uses the low 32 bits
// Physical SIMD width               4 lanes
// Wave execution beats              8
// Resident Wave Contexts            4
// Initial SGPR/VGPR implementation  32 SGPRs / 64 VGPRs
//
// Logical and physical lane counts are intentionally independent. A Wave32
// operation is initially executed as eight groups of four lanes.
//
// decoded_uop_t
// -----------------------------------------------------------------------------
// decoded_uop_t is one packed bundle carrying:
//
// - original instruction format and opcode
// - normalized execution class and function
// - source and destination register descriptions
// - immediate and branch information
// - arithmetic modifiers
// - memory-space, operation and element-size information
// - architectural state write controls
//
// As a packed structure it can be assigned with '0, stored in a pipeline
// register or FIFO, and passed through a module port as one synthesizable bus.
//
// Compile order
// -----------------------------------------------------------------------------
// gpu_pkg.sv must be compiled before every module that references gpu_pkg.
// ============================================================================

package gpu_pkg;

// ============================================================================
// Architectural configuration
// ============================================================================

localparam int CDNA_DATA_BITS          = 32;
localparam int CDNA_ADDR_BITS          = 64;
localparam int CDNA_PC_BITS            = 64;
localparam int CDNA_INST_DWORD_BITS    = 32;

localparam int CDNA_WAVE_SIZE          = 32;
localparam int CDNA_EXEC_BITS          = 64;
localparam int CDNA_VCC_BITS           = 64;
localparam int CDNA_SIMD_LANES         = 4;
localparam int CDNA_NUM_WAVE_BEATS     =
    CDNA_WAVE_SIZE / CDNA_SIMD_LANES;

localparam int CDNA_NUM_RESIDENT_WAVES = 4;
localparam int CDNA_DEFAULT_NUM_SGPRS  = 32;
localparam int CDNA_DEFAULT_NUM_VGPRS  = 64;

localparam int CDNA_WAVE_ID_BITS =
    (CDNA_NUM_RESIDENT_WAVES > 1) ?
    $clog2(CDNA_NUM_RESIDENT_WAVES) : 1;

localparam int CDNA_LANE_ID_BITS =
    (CDNA_WAVE_SIZE > 1) ? $clog2(CDNA_WAVE_SIZE) : 1;

localparam int CDNA_SIMD_LANE_ID_BITS =
    (CDNA_SIMD_LANES > 1) ? $clog2(CDNA_SIMD_LANES) : 1;

localparam int CDNA_WAVE_BEAT_BITS =
    (CDNA_NUM_WAVE_BEATS > 1) ? $clog2(CDNA_NUM_WAVE_BEATS) : 1;

localparam int CDNA_REG_INDEX_BITS     = 10;
localparam int CDNA_TRANSACTION_BITS   = 8;
localparam int CDNA_WAIT_COUNTER_BITS  = 6;

// A 32-bit launch count can need more than 65536 Workgroups. Keep the ID
// wide enough for any default-width one-dimensional launch, including WG=1.
localparam int CDNA_WORKGROUP_ID_BITS       = 32;
localparam int CDNA_WORKGROUP_WAVE_ID_BITS  = 5;
localparam int CDNA_WORKGROUP_WAVE_COUNT_BITS = 6;
localparam int CDNA_GLOBAL_THREAD_ID_BITS   = 32;
localparam int CDNA_THREAD_COUNT_BITS       = 32;
localparam int CDNA_THREADS_PER_WORKGROUP   = 64;

// ============================================================================
// Common architectural types
// ============================================================================

typedef logic [CDNA_DATA_BITS-1:0]         cdna_data_t;
typedef logic [CDNA_ADDR_BITS-1:0]         cdna_addr_t;
typedef logic [CDNA_PC_BITS-1:0]           cdna_pc_t;
typedef logic [CDNA_EXEC_BITS-1:0]         cdna_exec_mask_t;
typedef logic [CDNA_VCC_BITS-1:0]          cdna_vcc_t;
typedef logic [CDNA_WAVE_ID_BITS-1:0]      cdna_wave_id_t;
typedef logic [CDNA_LANE_ID_BITS-1:0]      cdna_lane_id_t;
typedef logic [CDNA_SIMD_LANE_ID_BITS-1:0] cdna_simd_lane_id_t;
typedef logic [CDNA_WAVE_BEAT_BITS-1:0]    cdna_wave_beat_t;
typedef logic [CDNA_REG_INDEX_BITS-1:0]    cdna_reg_index_t;
typedef logic [CDNA_TRANSACTION_BITS-1:0]  cdna_transaction_id_t;
typedef logic [CDNA_WAIT_COUNTER_BITS-1:0] cdna_wait_counter_t;

typedef logic [CDNA_WORKGROUP_ID_BITS-1:0]
    cdna_workgroup_id_t;

typedef logic [CDNA_WORKGROUP_WAVE_ID_BITS-1:0]
    cdna_workgroup_wave_id_t;

typedef logic [CDNA_WORKGROUP_WAVE_COUNT_BITS-1:0]
    cdna_workgroup_wave_count_t;

typedef logic [CDNA_GLOBAL_THREAD_ID_BITS-1:0]
    cdna_global_thread_id_t;

// ============================================================================
// M2 Wave Context lifecycle
// ============================================================================

localparam int WAVE_CONTEXT_STATE_BITS = 3;
typedef logic [WAVE_CONTEXT_STATE_BITS-1:0] wave_context_state_t;

localparam wave_context_state_t WAVE_STATE_FREE    = 3'd0;
localparam wave_context_state_t WAVE_STATE_READY   = 3'd1;
localparam wave_context_state_t WAVE_STATE_ISSUED  = 3'd2;
localparam wave_context_state_t WAVE_STATE_WAITCNT = 3'd3;
localparam wave_context_state_t WAVE_STATE_BARRIER = 3'd4;
localparam wave_context_state_t WAVE_STATE_DONE    = 3'd5;

// ============================================================================
// M2 Memory dependency accounting
// ============================================================================
// These encodings are internal M2 event identifiers, not ISA opcode encodings.
// Kind N selects counter N and bit N of a Wait counter-selection mask.
// Encodings 0..6 are valid; 3'd7 is reserved/invalid.
// Counters account for outstanding modeled backend operations per Wave.
// They are not lane counts, transaction counts or elapsed-cycle counts.

localparam int DEPENDENCY_KIND_BITS     = 3;
localparam int DEPENDENCY_COUNTER_COUNT = 7;
localparam int DEPENDENCY_AMOUNT_BITS   = CDNA_WAIT_COUNTER_BITS;

typedef logic [DEPENDENCY_KIND_BITS-1:0] dependency_kind_t;
typedef logic [DEPENDENCY_COUNTER_COUNT-1:0] dependency_counter_mask_t;
typedef logic [DEPENDENCY_AMOUNT_BITS-1:0] dependency_amount_t;

localparam dependency_kind_t DEP_LOAD   = 3'd0;
localparam dependency_kind_t DEP_STORE  = 3'd1;
localparam dependency_kind_t DEP_DS     = 3'd2;
localparam dependency_kind_t DEP_KM     = 3'd3;
localparam dependency_kind_t DEP_ASYNC  = 3'd4;
localparam dependency_kind_t DEP_TENSOR = 3'd5;
localparam dependency_kind_t DEP_X      = 3'd6;

// Six counter classes use the common 6-bit width. KM has a 5-bit range.
// Preserve CDNA_WAIT_COUNTER_BITS and cdna_wait_counter_t for existing users.
localparam int CDNA_LOAD_COUNTER_BITS   = CDNA_WAIT_COUNTER_BITS;
localparam int CDNA_STORE_COUNTER_BITS  = CDNA_WAIT_COUNTER_BITS;
localparam int CDNA_DS_COUNTER_BITS     = CDNA_WAIT_COUNTER_BITS;
localparam int CDNA_KM_COUNTER_BITS     = 5;
localparam int CDNA_ASYNC_COUNTER_BITS  = CDNA_WAIT_COUNTER_BITS;
localparam int CDNA_TENSOR_COUNTER_BITS = CDNA_WAIT_COUNTER_BITS;
localparam int CDNA_X_COUNTER_BITS      = CDNA_WAIT_COUNTER_BITS;

// ============================================================================
// Instruction formats
// ============================================================================

localparam int INST_FORMAT_BITS = 5;
typedef logic [INST_FORMAT_BITS-1:0] inst_format_t;

localparam inst_format_t INST_FORMAT_NONE     = 5'd0;
localparam inst_format_t INST_FORMAT_LEGACY16 = 5'd1;
localparam inst_format_t INST_FORMAT_SOP1     = 5'd2;
localparam inst_format_t INST_FORMAT_SOP2     = 5'd3;
localparam inst_format_t INST_FORMAT_SOPK     = 5'd4;
localparam inst_format_t INST_FORMAT_SOPC     = 5'd5;
localparam inst_format_t INST_FORMAT_SOPP     = 5'd6;
localparam inst_format_t INST_FORMAT_VOP1     = 5'd7;
localparam inst_format_t INST_FORMAT_VOP2     = 5'd8;
localparam inst_format_t INST_FORMAT_VOPC     = 5'd9;
localparam inst_format_t INST_FORMAT_VOP3     = 5'd10;
localparam inst_format_t INST_FORMAT_VOP3P    = 5'd11;
localparam inst_format_t INST_FORMAT_VOP3PX2  = 5'd12;
localparam inst_format_t INST_FORMAT_SMEM     = 5'd13;
localparam inst_format_t INST_FORMAT_VGLOBAL  = 5'd14;
localparam inst_format_t INST_FORMAT_VDS      = 5'd15;
localparam inst_format_t INST_FORMAT_FLAT     = 5'd16;

// ============================================================================
// Micro-op classes
// ============================================================================

localparam int UOP_CLASS_BITS = 4;
typedef logic [UOP_CLASS_BITS-1:0] uop_class_t;

localparam uop_class_t UOP_CLASS_SYSTEM  = 4'd0;
localparam uop_class_t UOP_CLASS_SALU    = 4'd1;
localparam uop_class_t UOP_CLASS_VALU    = 4'd2;
localparam uop_class_t UOP_CLASS_BRANCH  = 4'd3;
localparam uop_class_t UOP_CLASS_SMEM    = 4'd4;
localparam uop_class_t UOP_CLASS_VMEM    = 4'd5;
localparam uop_class_t UOP_CLASS_LDS     = 4'd6;
localparam uop_class_t UOP_CLASS_WAIT    = 4'd7;
localparam uop_class_t UOP_CLASS_BARRIER = 4'd8;
localparam uop_class_t UOP_CLASS_MATRIX  = 4'd9;
localparam uop_class_t UOP_CLASS_TENSOR  = 4'd10;

// ============================================================================
// Normalized Micro-op functions
// ============================================================================

localparam int UOP_FUNCTION_BITS = 8;
typedef logic [UOP_FUNCTION_BITS-1:0] uop_function_t;

localparam uop_function_t UOP_FUNCTION_NOP     = 8'd0;
localparam uop_function_t UOP_FUNCTION_MOV     = 8'd1;
localparam uop_function_t UOP_FUNCTION_ADD     = 8'd2;
localparam uop_function_t UOP_FUNCTION_SUB     = 8'd3;
localparam uop_function_t UOP_FUNCTION_MUL     = 8'd4;
localparam uop_function_t UOP_FUNCTION_DIV     = 8'd5;
localparam uop_function_t UOP_FUNCTION_CMP     = 8'd6;
localparam uop_function_t UOP_FUNCTION_BRANCH  = 8'd7;
localparam uop_function_t UOP_FUNCTION_LOAD    = 8'd8;
localparam uop_function_t UOP_FUNCTION_STORE   = 8'd9;
localparam uop_function_t UOP_FUNCTION_ATOMIC  = 8'd10;
localparam uop_function_t UOP_FUNCTION_WAIT    = 8'd11;
localparam uop_function_t UOP_FUNCTION_BARRIER = 8'd12;
localparam uop_function_t UOP_FUNCTION_END     = 8'd13;
localparam uop_function_t UOP_FUNCTION_FMA     = 8'd14;
localparam uop_function_t UOP_FUNCTION_WMMA    = 8'd15;
localparam uop_function_t UOP_FUNCTION_SWMMAC  = 8'd16;
localparam uop_function_t UOP_FUNCTION_TENSOR  = 8'd17;

// ============================================================================
// Operand kinds
// ============================================================================

localparam int OPERAND_KIND_BITS = 3;
typedef logic [OPERAND_KIND_BITS-1:0] operand_kind_t;

localparam operand_kind_t OPERAND_NONE      = 3'd0;
localparam operand_kind_t OPERAND_SGPR      = 3'd1;
localparam operand_kind_t OPERAND_VGPR      = 3'd2;
localparam operand_kind_t OPERAND_SCC       = 3'd3;
localparam operand_kind_t OPERAND_VCC       = 3'd4;
localparam operand_kind_t OPERAND_EXEC      = 3'd5;
localparam operand_kind_t OPERAND_M0        = 3'd6;
localparam operand_kind_t OPERAND_IMMEDIATE = 3'd7;

// ============================================================================
// Branch conditions
// ============================================================================

localparam int BRANCH_CONDITION_BITS = 4;
typedef logic [BRANCH_CONDITION_BITS-1:0] branch_condition_t;

localparam branch_condition_t BRANCH_CONDITION_NONE       = 4'd0;
localparam branch_condition_t BRANCH_CONDITION_ALWAYS     = 4'd1;
localparam branch_condition_t BRANCH_CONDITION_SCC0       = 4'd2;
localparam branch_condition_t BRANCH_CONDITION_SCC1       = 4'd3;
localparam branch_condition_t BRANCH_CONDITION_VCCZ       = 4'd4;
localparam branch_condition_t BRANCH_CONDITION_VCCNZ      = 4'd5;
localparam branch_condition_t BRANCH_CONDITION_EXECZ      = 4'd6;
localparam branch_condition_t BRANCH_CONDITION_EXECNZ     = 4'd7;
localparam branch_condition_t BRANCH_CONDITION_LEGACY_NZP = 4'd8;

// ============================================================================
// Memory classification
// ============================================================================

localparam int MEM_SPACE_BITS = 3;
typedef logic [MEM_SPACE_BITS-1:0] mem_space_t;

localparam mem_space_t MEM_SPACE_NONE    = 3'd0;
localparam mem_space_t MEM_SPACE_SCALAR  = 3'd1;
localparam mem_space_t MEM_SPACE_GLOBAL  = 3'd2;
localparam mem_space_t MEM_SPACE_LDS     = 3'd3;
localparam mem_space_t MEM_SPACE_FLAT    = 3'd4;
localparam mem_space_t MEM_SPACE_SCRATCH = 3'd5;
localparam mem_space_t MEM_SPACE_TENSOR  = 3'd6;

localparam int MEM_OPERATION_BITS = 3;
typedef logic [MEM_OPERATION_BITS-1:0] mem_operation_t;

localparam mem_operation_t MEM_OP_NONE     = 3'd0;
localparam mem_operation_t MEM_OP_LOAD     = 3'd1;
localparam mem_operation_t MEM_OP_STORE    = 3'd2;
localparam mem_operation_t MEM_OP_ATOMIC   = 3'd3;
localparam mem_operation_t MEM_OP_PREFETCH = 3'd4;

localparam int MEM_SIZE_BITS = 3;
typedef logic [MEM_SIZE_BITS-1:0] mem_size_t;

localparam mem_size_t MEM_SIZE_B8   = 3'd0;
localparam mem_size_t MEM_SIZE_B16  = 3'd1;
localparam mem_size_t MEM_SIZE_B32  = 3'd2;
localparam mem_size_t MEM_SIZE_B64  = 3'd3;
localparam mem_size_t MEM_SIZE_B128 = 3'd4;

// ============================================================================
// Unified decoded Micro-op
// ============================================================================

localparam int CDNA_ISA_OPCODE_BITS = 12;
localparam int UOP_REG_COUNT_BITS   = 5;
localparam int UOP_MEM_OFFSET_BITS  = 24;

typedef struct packed {
    logic                                    valid;

    inst_format_t                            inst_format;
    uop_class_t                              uop_class;
    logic [CDNA_ISA_OPCODE_BITS-1:0]         isa_opcode;
    uop_function_t                           function_code;
    logic [2:0]                              inst_dwords;

    logic                                    dst_valid;
    operand_kind_t                           dst_kind;
    cdna_reg_index_t                         dst_index;
    logic [UOP_REG_COUNT_BITS-1:0]           dst_count;

    operand_kind_t                           src0_kind;
    cdna_reg_index_t                         src0_index;
    logic [UOP_REG_COUNT_BITS-1:0]           src0_count;

    operand_kind_t                           src1_kind;
    cdna_reg_index_t                         src1_index;
    logic [UOP_REG_COUNT_BITS-1:0]           src1_count;

    operand_kind_t                           src2_kind;
    cdna_reg_index_t                         src2_index;
    logic [UOP_REG_COUNT_BITS-1:0]           src2_count;

    logic [CDNA_DATA_BITS-1:0]               immediate;
    logic                                    immediate_valid;
    logic                                    immediate_signed;

    branch_condition_t                       branch_condition;
    logic [7:0]                              branch_condition_value;

    logic [2:0]                              src_neg;
    logic [2:0]                              src_abs;
    logic [3:0]                              op_sel;
    logic [2:0]                              op_sel_hi;
    logic                                    clamp;
    logic [1:0]                              output_modifier;

    mem_space_t                              mem_space;
    mem_operation_t                          mem_operation;
    mem_size_t                               mem_size;
    logic                                    mem_signed;
    logic [UOP_MEM_OFFSET_BITS-1:0]          mem_offset;

    logic                                    use_exec;
    logic                                    write_scc;
    logic                                    write_vcc;
    logic                                    write_exec;
    logic                                    write_pc;
    logic                                    end_program;
    logic                                    illegal;
} decoded_uop_t;

endpackage

`default_nettype wire
