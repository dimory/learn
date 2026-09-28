`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Per-Lane Register File
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// Each active lane owns one independent 16 x DATA_BITS registers file.
// The registers file provides two synchronous read ports and one synchronous
// write port.
//
// Register map
// -----------------------------------------------------------------------------
//
// Register   Access       Function
// --------   -----------  -----------------------------------------------------
// R0-R12     Read/Write   General-purpose registers
// R13        Read-only    %blockIdx  : current block ID
// R14        Read-only    %blockDim  : THREADS_PER_BLOCK
// R15        Read-only    %threadIdx : THREAD_ID of this lane
//
// Internal storage
// -----------------------------------------------------------------------------
//
// logic [DATA_BITS-1:0] registers [0:15];
//
// Core-state behavior
// -----------------------------------------------------------------------------
//
// State      Operation
// ---------  ------------------------------------------------------------------
// REQUEST    Read Register[rs_address] and Register[rt_address] into rs and rt
// UPDATE     Write the selected result into Register[rd_address]
// Other      Hold rs, rt and all writable registers
//
// State encoding
// -----------------------------------------------------------------------------
//
// REQUEST = 3'b011
// UPDATE  = 3'b110
//
// Register writeback source
// -----------------------------------------------------------------------------
//
// decoded_reg_input_mux   Writeback data
// ---------------------   ------------------------------------------------------
// 2'b00                   ALU output
// 2'b01                   LSU load output
// 2'b10                   Decoded immediate value
// 2'b11                   Reserved; no registers write
//
// Register-write conditions
// -----------------------------------------------------------------------------
//
// A general-purpose registers is written only when all conditions are true:
//
// 1. enable == 1'b1
// 2. core_state == UPDATE
// 3. decoded_reg_write_enable == 1'b1
// 4. decoded_rd_address < 4'd13
//
// Condition 4 protects R13, R14 and R15 from instruction writes.
//
// Source-registers read conditions
// -----------------------------------------------------------------------------
//
// rs and rt are updated only when:
//
// 1. enable == 1'b1
// 2. core_state == REQUEST
//
// rs and rt hold their previous values in all other states.
//
// Lane enable behavior
// -----------------------------------------------------------------------------
//
// enable == 1'b1 : this lane can read and write its registers file.
// enable == 1'b0 : rs, rt and all registers hold their current values.
//
// A disabled lane is normally an unused lane in a partially filled block.
//
// Special-registers behavior
// -----------------------------------------------------------------------------
//
// R13, R14 and R15 are hardware-managed read-only registers.
//
// While enable is asserted, these registers are reloaded every clock cycle:
//
// Register   Loaded value
// --------   --------------------------------------------------
// R13        block_id
// R14        THREADS_PER_BLOCK
// R15        THREAD_ID
//
// Instruction writeback is restricted to R0-R12, so software instructions
// cannot overwrite R13, R14 or R15.
//
// This repeated reload behavior is used only by the single-wave baseline.
// A later multi-wave implementation will load these registers when a Wave
// Context is allocated.
//
// Reset behavior
// -----------------------------------------------------------------------------
//
// rst_n is an asynchronous active-low reset.
//
// On reset:
//   rs      = 0
//   rt      = 0
//   R0-R15  = 0
//
// After reset is released and enable is asserted, R13-R15 are automatically
// reloaded before the first instruction reaches the REQUEST stage.
//
// Timing sequence
// -----------------------------------------------------------------------------
//
// DECODE
//   -> REQUEST : latch source-registers values into rs and rt
//   -> WAIT
//   -> EXECUTE : ALU/LSU produces a result
//   -> UPDATE  : write selected result into destination registers
//
// Notes
// -----------------------------------------------------------------------------
// - Reads are synchronous, not combinational.
// - Writes are synchronous.
// - All state updates use nonblocking assignments.
// - Each hardware lane instantiates one registers_file module.
// - Register storage is expected to synthesize as flip-flops in this baseline.
// ============================================================================

module register_file #(
    parameter int DATA_BITS         = 8,
    parameter int THREADS_PER_BLOCK = 4,
    parameter int THREAD_ID         = 0
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 enable,

    // Current block metadata
    input  logic [DATA_BITS-1:0] block_id,

    // Current Core execution state
    input  logic [2:0]           core_state,

    // Decoded registers addresses
    input  logic [3:0]           decoded_rd_address,
    input  logic [3:0]           decoded_rs_address,
    input  logic [3:0]           decoded_rt_address,

    // Register-write control
    input  logic                 decoded_reg_write_enable,
    input  logic [1:0]           decoded_reg_input_mux,

    // Writeback data sources
    input  logic [DATA_BITS-1:0] decoded_immediate,
    input  logic [DATA_BITS-1:0] alu_out,
    input  logic [DATA_BITS-1:0] lsu_out,

    // Latched source-registers values
    output logic [DATA_BITS-1:0] rs,
    output logic [DATA_BITS-1:0] rt
);

// Register File organization
localparam int NUM_REGISTERS = 16;

// Core state encoding used by this module
localparam logic [2:0] CORE_STATE_REQUEST = 3'b011;
localparam logic [2:0] CORE_STATE_UPDATE  = 3'b110;

// Register writeback source selection
localparam logic [1:0] REG_INPUT_ALU       = 2'b00;
localparam logic [1:0] REG_INPUT_LSU       = 2'b01;
localparam logic [1:0] REG_INPUT_IMMEDIATE = 2'b10;
localparam logic [1:0] REG_INPUT_RESERVED  = 2'b11;

// Special-registers addresses
localparam logic [3:0] REG_BLOCK_ID  = 4'd13;
localparam logic [3:0] REG_BLOCK_DIM = 4'd14;
localparam logic [3:0] REG_THREAD_ID = 4'd15;

    // 由你实现
logic [DATA_BITS-1:0] registers [0:NUM_REGISTERS-1];

integer i;

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		rs <= '0;
		rt <= '0;
		for (i=0;i<NUM_REGISTERS;i++)begin
			registers[i] <= '0;
		end
	end
	else begin
		if (enable) begin
			registers[REG_BLOCK_ID] <= block_id; //Block index
			registers[REG_BLOCK_DIM] <= THREADS_PER_BLOCK;	//Block dim
			registers[REG_THREAD_ID] <= THREAD_ID;// thread index
			if(core_state == CORE_STATE_REQUEST)begin
				rs <= registers[decoded_rs_address];
				rt <= registers[decoded_rt_address];
			end
			else if ((core_state==CORE_STATE_UPDATE) && (decoded_reg_write_enable) && (decoded_rd_address<REG_BLOCK_ID) )begin
				case(decoded_reg_input_mux)
					REG_INPUT_ALU : 		registers[decoded_rd_address] <= alu_out;
					REG_INPUT_LSU : 		registers[decoded_rd_address] <= lsu_out;
					REG_INPUT_IMMEDIATE :   registers[decoded_rd_address] <= decoded_immediate;
					default : begin
					end
				endcase
			end
		end
	end
end


endmodule

`default_nettype wire