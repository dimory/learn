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
// PC addressing
// -----------------------------------------------------------------------------
// The PC is a byte address.
//
// With the default 16-bit instruction width:
//
// Instruction   Byte PC
// -----------   -------
// 0             8'h00
// 1             8'h02
// 2             8'h04
// 3             8'h06
//
// Sequential execution increments the PC by INSTRUCTION_BYTES.
//
//     INSTRUCTION_BYTES = INSTRUCTION_BITS / 8
//
// For a 16-bit instruction:
//
//     next_pc = current_pc + 2
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
// Other      Hold next_pc and saved_nzp
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
// 1'b0             next_pc = current_pc + INSTRUCTION_BYTES
// 1'b1             Check saved_nzp against decoded_nzp
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
//     next_pc = current_pc + INSTRUCTION_BYTES
//
// decoded_immediate is an absolute byte address, not a PC-relative offset.
// Branch targets must be instruction aligned. With 16-bit instructions:
//
//     decoded_immediate[0] == 1'b0
//
// Misaligned-address exceptions are not implemented in this baseline.
//
// Lane-enable behavior
// -----------------------------------------------------------------------------
//
// enable == 1'b1 : next_pc and saved_nzp may be updated.
// enable == 1'b0 : next_pc and saved_nzp hold their current values.
//
// Disabled lanes must not participate in the Scheduler PC selection.
//
// Reset behavior
// -----------------------------------------------------------------------------
//
// rst_n is an asynchronous active-low reset.
//
// On reset:
//   next_pc   = 0
//   saved_nzp = 0
//
// Divergence behavior in the baseline
// -----------------------------------------------------------------------------
// Different lanes may calculate different byte-addressed next_pc values.
// This module exposes divergence but does not execute both control-flow paths.
// A later Wave Context implementation will add EXEC masks and reconvergence.
// ============================================================================

module pc #(
    parameter int DATA_BITS        = 8,
    parameter int PC_BITS          = 8,
    parameter int INSTRUCTION_BITS = 16
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 enable,

    input  logic [2:0]           core_state,

    input  logic [2:0]           decoded_nzp,
    input  logic [PC_BITS-1:0]   decoded_immediate,

    input  logic                 decoded_nzp_write_enable,
    input  logic                 decoded_pc_mux,

    input  logic [DATA_BITS-1:0] alu_out,
    input  logic [PC_BITS-1:0]   current_pc,

    output logic [PC_BITS-1:0]   next_pc
);

localparam logic [2:0] CORE_STATE_EXECUTE = 3'b101;
localparam logic [2:0] CORE_STATE_UPDATE  = 3'b110;

localparam logic PC_MUX_SEQUENTIAL = 1'b0;
localparam logic PC_MUX_BRANCH     = 1'b1;

localparam int INSTRUCTION_BYTES = INSTRUCTION_BITS / 8;

localparam logic [PC_BITS-1:0] PC_INCREMENT = INSTRUCTION_BYTES;

logic [2:0] saved_nzp;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        saved_nzp <= '0;
    end
    else if (enable &&
             (core_state == CORE_STATE_UPDATE) &&
             decoded_nzp_write_enable) begin
        saved_nzp <= alu_out[2:0];
    end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        next_pc <= '0;
    end
    else if (enable && (core_state == CORE_STATE_EXECUTE)) begin
        case (decoded_pc_mux)
            PC_MUX_SEQUENTIAL: begin
                next_pc <= current_pc + PC_INCREMENT;
            end

            PC_MUX_BRANCH: begin
                if (|(saved_nzp & decoded_nzp)) begin
                    next_pc <= decoded_immediate;
                end
                else begin
                    next_pc <= current_pc + PC_INCREMENT;
                end
            end

            default: begin
                next_pc <= current_pc + PC_INCREMENT;
            end
        endcase
    end
end

endmodule

`default_nettype wire
