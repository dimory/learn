`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Per-Lane PC and NZP Unit
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// Each active lane owns one PC/NZP unit.
//
// This module stores the lane-private NZP condition code and calculates the
// lane's candidate next_pc.
//
// current_pc is shared by all lanes and is stored by the Core Scheduler.
// next_pc is calculated independently for each lane.
//
// NZP encoding
// -----------------------------------------------------------------------------
//
// Bit     Name       Meaning
// ------  ---------  ----------------------------------------------------------
// nzp[2]  Negative   Previous CMP result was rs < rt
// nzp[1]  Zero       Previous CMP result was rs == rt
// nzp[0]  Positive   Previous CMP result was rs > rt
//
// The ALU produces the CMP result in this same format:
//
// alu_out[2:0] = {N, Z, P}
//
// Core-state behavior
// -----------------------------------------------------------------------------
//
// State      Operation
// ---------  ------------------------------------------------------------------
// EXECUTE    Calculate and register this lane's candidate next_pc
// UPDATE     Update the saved NZP register when nzp_write_enable is asserted
// Other      Hold next_pc and NZP
//
// State encoding
// -----------------------------------------------------------------------------
//
// EXECUTE = 3'b101
// UPDATE  = 3'b110
//
// PC selection
// -----------------------------------------------------------------------------
//
// decoded_pc_mux   Next-PC behavior
// --------------   ------------------------------------------------------------
// 1'b0             next_pc = current_pc + 1
// 1'b1             Check the saved NZP value against decoded_nzp
//
// Conditional branch behavior
// -----------------------------------------------------------------------------
//
// branch_match = |(saved_nzp & decoded_nzp)
//
// branch_match == 1:
//     next_pc = decoded_immediate
//
// branch_match == 0:
//     next_pc = current_pc + 1
//
// decoded_immediate is an absolute instruction address, not a PC-relative
// offset.
//
// Example
// -----------------------------------------------------------------------------
//
// Saved NZP       = 3'b100  // Negative
// decoded_nzp     = 3'b100  // BRn
// NZP & mask      = 3'b100
// Branch decision = taken
//
// Saved NZP       = 3'b010  // Zero
// decoded_nzp     = 3'b100  // BRn
// NZP & mask      = 3'b000
// Branch decision = not taken
//
// Lane-enable behavior
// -----------------------------------------------------------------------------
//
// enable == 1'b1 : next_pc and NZP may be updated.
// enable == 1'b0 : next_pc and NZP hold their current values.
//
// Disabled lanes must not participate in the final Scheduler PC selection.
//
// Reset behavior
// -----------------------------------------------------------------------------
//
// rst_n is an asynchronous active-low reset.
//
// On reset:
//   next_pc  = 0
//   saved_nzp = 0
//
// Divergence behavior in the baseline
// -----------------------------------------------------------------------------
//
// Different lanes may calculate different next_pc values.
//
// Example:
//
// Lane0 next_pc = 8
// Lane1 next_pc = 8
// Lane2 next_pc = 5
// Lane3 next_pc = 5
//
// This module exposes the divergence, but it does not execute both paths.
// The current baseline Scheduler still selects one lane's next_pc as the
// shared current_pc.
//
// A later Wave Context implementation will add EXEC masks and reconvergence.
// ============================================================================

module pc #(
    parameter int DATA_BITS = 8,
    parameter int PC_BITS   = 8
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 enable,

    // Current Core execution state
    input  logic [2:0]           core_state,

    // Decoded branch fields
    input  logic [2:0]           decoded_nzp,
    input  logic [PC_BITS-1:0]   decoded_immediate,

    // Decoded controls
    input  logic                 decoded_nzp_write_enable,
    input  logic                 decoded_pc_mux,

    // ALU result; alu_out[2:0] contains the CMP result
    input  logic [DATA_BITS-1:0] alu_out,

    // Shared current PC
    input  logic [PC_BITS-1:0]   current_pc,

    // Per-lane candidate next PC
    output logic [PC_BITS-1:0]   next_pc
);

// ============================================================================
// Local parameters
// ============================================================================

// Core state encoding used by this module
localparam logic [2:0] CORE_STATE_EXECUTE = 3'b101;
localparam logic [2:0] CORE_STATE_UPDATE  = 3'b110;

// PC source selection
localparam logic PC_MUX_SEQUENTIAL = 1'b0;
localparam logic PC_MUX_BRANCH     = 1'b1;

// NZP encoding
localparam logic [2:0] NZP_NONE = 3'b000;

// ============================================================================
// Internal state
// ============================================================================

// Lane-private saved condition code
logic [2:0] saved_nzp;

// 由你实现

always_ff @ (posedge clk or negedge rst_n)begin
	if (!rst_n)
		saved_nzp <= '0;
	else if (enable && (core_state == CORE_STATE_UPDATE) && decoded_nzp_write_enable)
		saved_nzp <= alu_out[2:0];
end

always_ff @ (posedge clk or negedge rst_n)begin
	if (!rst_n)
		next_pc <= '0;
	else if (enable && (core_state==CORE_STATE_EXECUTE))begin
		if (decoded_pc_mux == PC_MUX_SEQUENTIAL)
			next_pc <= current_pc+1;
		else begin
			if (|(saved_nzp & decoded_nzp))
				next_pc <= decoded_immediate;
			else 
				next_pc <= current_pc+2;	
		end
	
	end
end

endmodule

`default_nettype wire