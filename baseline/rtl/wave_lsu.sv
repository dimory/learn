`default_nettype none
`timescale 1ns/1ns
// Microarchitecture
// -----------------------------------------------------------------------------
//                            Wave LSU
// ┌────────────────────────────────────────────────────────────────────┐
// │                                                                    │
// │   exec_mask                                                        │
// │       │                                                            │
// │       ▼                                                            │
// │   ┌───────────────────┐                                            │
// │   │ instruction_mask  │                                            │
// │   │                   │                                            │
// │   │ Captured when the │                                            │
// │   │ memory instruction│                                            │
// │   │ enters REQUEST    │                                            │
// │   └─────────┬─────────┘                                            │
// │             │                                                      │
// │             ▼                                                      │
// │   ┌───────────────────┐       memory_done_mask                     │
// │   │ pending_mask      │◄──────────────────────┐                    │
// │   │                   │                       │                    │
// │   │ Set from the      │                       │                    │
// │   │ instruction mask  │                       │                    │
// │   │                   │                       │                    │
// │   │ Clear completed   │                       │                    │
// │   │ lane bits         │                       │                    │
// │   └─────────┬─────────┘                       │                    │
// │             │                                 │                    │
// │             ├────────► memory_request_mask    │                    │
// │             │                                 │                    │
// │             ▼                                 │                    │
// │   ┌─────────────────────────┐                 │                    │
// │   │ Per-Lane Operand Capture│                 │                    │
// │   │                         │                 │                    │
// │   │ address[lane] = rs[lane]│                 │                    │
// │   │ wdata[lane]   = rt[lane]│                 │                    │
// │   │ write = decoded STR     │                 │                    │
// │   └────────────┬────────────┘                 │                    │
// │                │                              │                    │
// │                ▼                              │                    │
// │   memory_address[lane]                        │                    │
// │   memory_write_data[lane]                     │                    │
// │   memory_write                                │                    │
// │                │                              │                    │
// │                ▼                              │                    │
// │   ┌─────────────────────────┐                 │                    │
// │   │ Banked Memory Backend   │                 │                    │
// │   │                         │                 │                    │
// │   │ Lane arbitration        │                 │                    │
// │   │ Bank-conflict handling  │                 │                    │
// │   │ SRAM access             │                 │                    │
// │   └────────────┬────────────┘                 │                    │
// │                │                              │                    │
// │                ├──── memory_done_mask ────────┘                    │
// │                │                                                   │
// │                ▼                                                   │
// │       memory_read_data[lane]                                       │
// │                │                                                   │
// │                ▼                                                   │
// │   ┌─────────────────────────┐                                      │
// │   │ Load Result Capture     │                                      │
// │   │                         │                                      │
// │   │ Capture data only when: │                                      │
// │   │ pending[lane] = 1       │                                      │
// │   │ done[lane]    = 1       │                                      │
// │   │ operation is LDR        │                                      │
// │   └────────────┬────────────┘                                      │
// │                │                                                   │
// │                ▼                                                   │
// │          lsu_out[lane]                                             │
// │                                                                    │
// └────────────────────────────────────────────────────────────────────┘
//

// LSU control sequence
// -----------------------------------------------------------------------------
//       Core REQUEST
//            │
//            ▼
//   ┌────────────────┐
//   │ IDLE           │
//   │                │
//   │ Detect LDR/STR │
//   │ Capture EXEC   │
//   └───────┬────────┘
//           │
//           ▼
//   ┌────────────────┐
//   │ PREPARE        │
//   │                │
//   │ Capture rs/rt  │
//   │ Load pending   │
//   └───────┬────────┘
//           │
//           ▼
//   ┌────────────────┐
//   │ WAITING        │◄──────────────┐
//   │                │               │
//   │ Issue requests │               │ pending_mask != 0
//   │ Capture loads  │               │
//   │ Clear done bits│───────────────┘
//   └───────┬────────┘
//           │ pending_mask == 0
//           ▼
//   ┌────────────────┐
//   │ DONE           │
//   │                │
//   │ Hold results   │
//   └───────┬────────┘
//           │ Core UPDATE
//           ▼
//          IDLE
//
// Mask relationship
// -----------------------------------------------------------------------------
// instruction_mask
//     = lanes participating when the memory instruction begins
//
// pending_mask
//     = lanes that have not completed the current memory instruction
//
// memory_request_mask
//     = request presented to the Memory Backend
//
// During WAITING:
//
// pending_mask        <= pending_mask & ~memory_done_mask
// memory_request_mask  = pending_mask
//
// Example:
//
// instruction_mask    = 4'b1111
// memory_done_mask    = 4'b0101
// next pending_mask   = 4'b1010
//
// Lanes 0 and 2 completed. Lanes 1 and 3 remain pending.
//



// ============================================================================
// TinyGPU Wave Load/Store Unit
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// One wave owns one Wave LSU.
//
// A memory instruction is shared by the whole wave, while every active lane
// provides its own address and store data.
//
// LDR:
//
//     lane address = rs[lane]
//     returned data is saved into lsu_out[lane]
//
// STR:
//
//     lane address    = rs[lane]
//     lane write data = rt[lane]
//
// Architectural hierarchy
// -----------------------------------------------------------------------------
//
// Per-lane Register Files
//           |
//           | rs[lane], rt[lane]
//           v
//        Wave LSU
//           |
//           | memory_request_mask
//           | memory_address[lane]
//           | memory_write_data[lane]
//           v
//     Memory Backend
//           |
//           | ce, we, addr, wdata, rdata
//           v
//    Single-Port SRAM Bank(s)
//
// Current baseline configuration
// -----------------------------------------------------------------------------
//
// LANES_PER_WAVE = 4
// NUM_BANKS      = 1, implemented by the Memory Backend
//
// Because there is only one bank, the backend completes at most one lane
// request per cycle.
//
// Future banked configuration
// -----------------------------------------------------------------------------
//
// The same Wave LSU interface supports multiple banks.
//
// For four banks with word-addressed 8-bit data:
//
//     bank_id  = address[1:0]
//     bank_row = address[ADDR_BITS-1:2]
//
// A four-bank backend may complete up to four lane requests per cycle,
// provided that they access different banks.
//
// Same-bank accesses are bank conflicts and must be serialized.
//
// Execution mask
// -----------------------------------------------------------------------------
//
// exec_mask indicates which lanes participate in the current instruction.
//
// Current baseline:
//
//     exec_mask[lane] = lane < thread_count
//
// Future divergence implementation:
//
//     exec_mask becomes the wave's architectural EXEC mask.
//
// Lanes whose exec_mask bit is zero must not generate memory requests.
//
// Request-mask protocol
// -----------------------------------------------------------------------------
//
// memory_request_mask[lane] == 1:
//
//     The lane still has an outstanding memory request.
//
// memory_done_mask[lane] == 1:
//
//     The backend completed that lane's memory transaction.
//
// For a load, memory_read_data[lane] is valid when the corresponding
// memory_done_mask bit is asserted.
//
// The Wave LSU keeps request bits asserted until the corresponding done bits
// are received.
//
// This mask-based interface allows:
//
// - Single-bank serialization
// - Multiple-bank parallel accesses
// - Bank-conflict handling
// - Future lane coalescing
// - Future EXEC-mask support
//
// It replaces the original per-lane valid/ready interface.
//
// LSU state encoding
// -----------------------------------------------------------------------------
//
// State         Value   Meaning
// ------------  ------  -------------------------------------------------------
// IDLE          2'b00   No memory instruction is active
// PREPARE       2'b01   Wait for synchronous register-file read results
// WAITING       2'b10   One or more lane requests remain outstanding
// DONE          2'b11   All active lanes completed; wait for Core UPDATE
//
// Core-state behavior
// -----------------------------------------------------------------------------
//
// Core REQUEST:
//
//     Register files synchronously update rs[lane] and rt[lane].
//     Wave LSU changes from IDLE to PREPARE.
//
// PREPARE:
//
//     Wave LSU captures the updated rs/rt values.
//     pending_mask is initialized from exec_mask.
//     Wave LSU changes to WAITING.
//
// WAITING:
//
//     memory_request_mask is generated from pending_mask.
//
//     Each completion clears the corresponding pending bit:
//
//         pending_mask <= pending_mask & ~memory_done_mask
//
//     Load data is captured for every completed load lane.
//
//     When every pending bit is cleared, the LSU changes to DONE.
//
// Core UPDATE:
//
//     register files write lsu_out[lane] into rd for an LDR.
//     Wave LSU returns to IDLE.
//
// Memory operation type
// -----------------------------------------------------------------------------
//
// All active lanes execute the same instruction:
//
//     memory_write = 0 for LDR
//     memory_write = 1 for STR
//
// Therefore memory_write is shared by the whole wave.
//
// Reset behavior
// -----------------------------------------------------------------------------
//
// rst_n is an asynchronous active-low reset.
//
// On reset:
//
//     lsu_state           = IDLE
//     pending_mask        = 0
//     memory_request_mask = 0
//     memory_write        = 0
//     all address/data registers are cleared
//     all lsu_out values are cleared
//
// Notes
// -----------------------------------------------------------------------------
//
// - This module does not decide which bank services each lane.
// - This module does not arbitrate between lanes.
// - Bank selection and conflict handling belong to the Memory Backend.
// - The SRAM macro/model does not contain valid/ready signals.
// ============================================================================

module wave_lsu #(
    parameter int DATA_BITS      = 8,
    parameter int ADDR_BITS      = 8,
    parameter int LANES_PER_WAVE = 4
) (
    input  logic clk,
    input  logic rst_n,

    // Current Core execution state
    input  logic [2:0] core_state,

    // Active lanes for the current instruction
    input  logic [LANES_PER_WAVE-1:0] exec_mask,

    // Decoded memory controls
    input  logic decoded_mem_read_enable,
    input  logic decoded_mem_write_enable,

    // Per-lane register-file operands
    input  logic [DATA_BITS-1:0] rs [LANES_PER_WAVE-1:0],
    input  logic [DATA_BITS-1:0] rt [LANES_PER_WAVE-1:0],

    // Vector request interface to the Memory Backend
    output logic [LANES_PER_WAVE-1:0] memory_request_mask,
    output logic                      memory_write,

    output logic [ADDR_BITS-1:0]
        memory_address [LANES_PER_WAVE-1:0],

    output logic [DATA_BITS-1:0]
        memory_write_data [LANES_PER_WAVE-1:0],

    // Vector completion interface from the Memory Backend
    input  logic [LANES_PER_WAVE-1:0] memory_done_mask,

    input  logic [DATA_BITS-1:0]
        memory_read_data [LANES_PER_WAVE-1:0],

    // Load results returned to the per-lane register files
    output logic [DATA_BITS-1:0]
        lsu_out [LANES_PER_WAVE-1:0],

    // Wave-level LSU status
    output logic [1:0] lsu_state
);

// ============================================================================
// Local parameters
// ============================================================================

// Core state encoding
localparam logic [2:0] CORE_STATE_REQUEST = 3'b011;
localparam logic [2:0] CORE_STATE_UPDATE  = 3'b110;

// Wave LSU state encoding
localparam logic [1:0] LSU_STATE_IDLE    = 2'b00;
localparam logic [1:0] LSU_STATE_PREPARE = 2'b01;
localparam logic [1:0] LSU_STATE_WAITING = 2'b10;
localparam logic [1:0] LSU_STATE_DONE    = 2'b11;

// Memory operation
localparam logic MEM_READ  = 1'b0;
localparam logic MEM_WRITE = 1'b1;

// ============================================================================
// Internal state
// ============================================================================

// Lanes that have not completed the current memory instruction
logic [LANES_PER_WAVE-1:0] pending_mask;

// Indicates whether the current operation is LDR or STR
//logic operation_is_write;

// Latched instruction execution mask
logic [LANES_PER_WAVE-1:0] instruction_mask;

// 由你实现
logic [1:0] lsu_state_next;

assign memory_request_mask = pending_mask ;

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)
		lsu_state <= '0;
	else
		lsu_state <= lsu_state_next;
end


always_comb begin
	case (lsu_state)
		LSU_STATE_IDLE: begin
			if (core_state==CORE_STATE_REQUEST&&(decoded_mem_read_enable||decoded_mem_write_enable))
				lsu_state_next = LSU_STATE_PREPARE;
			else
				lsu_state_next = LSU_STATE_IDLE;
		end
		LSU_STATE_PREPARE: begin
			lsu_state_next = LSU_STATE_WAITING;
		end
		LSU_STATE_WAITING: begin
			if (pending_mask == '0)
				lsu_state_next = LSU_STATE_DONE;
			else
				lsu_state_next = LSU_STATE_WAITING;
		end
		LSU_STATE_DONE: begin
			if(core_state == CORE_STATE_UPDATE)
				lsu_state_next = LSU_STATE_IDLE;
			else 
				lsu_state_next = LSU_STATE_DONE;
		end
		default: lsu_state_next = LSU_STATE_IDLE;
	endcase
end

/*always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		memory_address <= '0;
		memory_write_data <= '0;
		memory_write <= '0;
	end
	else if (lsu_state == LSU_STATE_PREPARE)begin
		memory_address <= rs;
		if(decoded_mem_write_enable)begin
			memory_write_data <= rt;
			memory_write <= MEM_WRITE;
		end
		else if (decoded_mem_read_enable)
			memory_write <= MEM_READ;
	end
end*/


always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        memory_write <= MEM_READ;

        for (int lane = 0; lane < LANES_PER_WAVE; lane = lane + 1) begin
            memory_address[lane]    <= '0;
            memory_write_data[lane] <= '0;
        end
    end
    else if (lsu_state == LSU_STATE_PREPARE) begin
        memory_write <= decoded_mem_write_enable;

        for (int lane = 0; lane < LANES_PER_WAVE; lane = lane + 1) begin
            memory_address[lane] <= ADDR_BITS'(rs[lane]);

            if (decoded_mem_write_enable)
                memory_write_data[lane] <= rt[lane];
        end
    end
end


always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)
		instruction_mask <= '0;
	else if (core_state==CORE_STATE_REQUEST&&(decoded_mem_read_enable||decoded_mem_write_enable))
		instruction_mask <= exec_mask;
end

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)
		pending_mask <= '0;
	else if (lsu_state == LSU_STATE_PREPARE)
		pending_mask <= instruction_mask;
	else if (lsu_state == LSU_STATE_WAITING)
		pending_mask <= pending_mask & ~memory_done_mask;
end


integer i;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (i = 0; i < LANES_PER_WAVE; i = i + 1)
            lsu_out[i] <= '0;
    end
    else if (lsu_state == LSU_STATE_WAITING && !memory_write) begin
        for (i = 0; i < LANES_PER_WAVE; i = i + 1) begin
            if (pending_mask[i] && memory_done_mask[i])
                lsu_out[i] <= memory_read_data[i];
        end
    end
end

endmodule

`default_nettype wire