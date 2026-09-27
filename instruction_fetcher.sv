`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Synchronous Instruction Fetcher
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// The Instruction Fetcher retrieves one instruction from synchronous
// instruction SRAM.
//
// All lanes in the current Wave share:
//
// - current_pc
// - instruction
// - decoder
//
// Therefore, only one Instruction Fetcher is required for each Wave Core.
//
// Microarchitecture
// -----------------------------------------------------------------------------
//
//                         Instruction Fetcher
// ┌──────────────────────────────────────────────────────────────────────┐
// │                                                                      │
// │  From Scheduler                                                      │
// │                                                                      │
// │  core_state                                                          │
// │  current_pc                                                          │
// │      │                                                               │
// │      ▼                                                               │
// │  ┌───────────────────┐                                               │
// │  │ Fetch Control FSM │                                               │
// │  │                   │                                               │
// │  │ IDLE              │                                               │
// │  │ ISSUE             │                                               │
// │  │ CAPTURE           │                                               │
// │  │ DONE              │                                               │
// │  └─────────┬─────────┘                                               │
// │            │                                                         │
// │            │ imem_ce                                                 │
// │            │ imem_addr                                               │
// │            ▼                                                         │
// │  ┌───────────────────┐                                               │
// │  │ Instruction SRAM  │                                               │
// │  │                   │                                               │
// │  │ synchronous read  │                                               │
// │  └─────────┬─────────┘                                               │
// │            │ imem_rdata                                              │
// │            ▼                                                         │
// │  ┌───────────────────┐                                               │
// │  │ Instruction Reg   │                                               │
// │  └─────────┬─────────┘                                               │
// │            │                                                         │
// │            ├──────────────► instruction                              │
// │            └──────────────► fetch_done                               │
// │                                                                      │
// └──────────────────────────────────────────────────────────────────────┘
//
// Instruction memory organization
// -----------------------------------------------------------------------------
//
// Each SRAM word contains one complete instruction.
//
// Default organization:
//
// PC width            = 8 bits
// SRAM address width  = 7 bits
// Instruction width   = 16 bits
// Instruction depth   = 128 instructions
//
// current_pc is a byte address.
//
// Therefore:
//
//     imem_addr = current_pc >> $clog2(INSTRUCTION_BYTES)
//
// With 16-bit instructions, the PC sequence is 0, 2, 4, 6 and the
// corresponding SRAM row sequence is 0, 1, 2, 3.
//
// Interface
// -----------------------------------------------------------------------------
//
// Signal        Direction   Description
// ------------ ----------- ---------------------------------------------------
// clk           input       Core clock
// rst_n         input       Asynchronous active-low reset
// core_state    input       Current Wave Core execution state
// current_pc    input       Byte-addressed PC of the instruction being fetched
// imem_ce       output      Instruction SRAM read enable
// imem_addr     output      Instruction SRAM word address
// imem_rdata    input       Registered instruction SRAM read data
// instruction   output      Captured instruction
// fetch_done    output      Current instruction is available
// fetch_state   output      Fetcher FSM state for debug
//
// Core-state interaction
// -----------------------------------------------------------------------------
//
// Core state    Fetcher behavior
// ------------ ---------------------------------------------------------------
// FETCH         Start or continue fetching current_pc
// DECODE        Release FETCH_DONE and return to FETCH_IDLE
// Other         Hold the captured instruction
//
// Core-state encoding used by this module
// -----------------------------------------------------------------------------
//
// CORE_STATE_FETCH  = 3'b001
// CORE_STATE_DECODE = 3'b010
//
// Fetcher states
// -----------------------------------------------------------------------------
//
// State           Meaning
// --------------- ------------------------------------------------------------
// FETCH_IDLE      Wait for core_state == FETCH
// FETCH_ISSUE     Assert imem_ce and drive the translated SRAM row address
// FETCH_CAPTURE   Capture the synchronous SRAM return data
// FETCH_DONE      Hold instruction and assert fetch_done
//
// State transition diagram
// -----------------------------------------------------------------------------
//
//                        core_state != FETCH
//                    ┌────────────────────────┐
//                    │                        │
//                    ▼                        │
//             ┌──────────────┐                │
//             │ FETCH_IDLE   │────────────────┘
//             └──────┬───────┘
//                    │ core_state == FETCH
//                    │ save current_pc
//                    ▼
//             ┌──────────────┐
//             │ FETCH_ISSUE  │
//             │              │
//             │ imem_ce = 1  │
//             │ drive address│
//             └──────┬───────┘
//                    │ unconditional
//                    ▼
//             ┌───────────────┐
//             │ FETCH_CAPTURE │
//             │               │
//             │ capture       │
//             │ imem_rdata    │
//             └───────┬───────┘
//                     │ unconditional
//                     ▼
//             ┌──────────────┐
//             │ FETCH_DONE   │
//             │              │
//             │ fetch_done=1 │
//             └──────┬───────┘
//                    │ core_state == DECODE
//                    ▼
//               FETCH_IDLE
//
// State transition table
// -----------------------------------------------------------------------------
//
// Current state    Condition                    Next state
// --------------- ---------------------------- --------------------------------
// FETCH_IDLE       core_state == FETCH          FETCH_ISSUE
// FETCH_IDLE       core_state != FETCH          FETCH_IDLE
// FETCH_ISSUE      unconditional                FETCH_CAPTURE
// FETCH_CAPTURE    unconditional                FETCH_DONE
// FETCH_DONE       core_state == DECODE         FETCH_IDLE
// FETCH_DONE       otherwise                    FETCH_DONE
//
// Output table
// -----------------------------------------------------------------------------
//
// State           imem_ce   imem_addr derived from saved_pc   fetch_done
// --------------  --------  -------------------------------   ----------
// FETCH_IDLE      0         saved_pc >> PC_LSB_BITS           0
// FETCH_ISSUE     1         saved_pc >> PC_LSB_BITS           0
// FETCH_CAPTURE   0         saved_pc >> PC_LSB_BITS           0
// FETCH_DONE      0         saved_pc >> PC_LSB_BITS           1
//
// Synchronous SRAM timing
// -----------------------------------------------------------------------------
//
// Cycle       Fetch state       Operation
// ----------  ----------------  -----------------------------------------------
// C0          FETCH_IDLE        Detect FETCH and save current_pc
// C1          FETCH_ISSUE       SRAM samples translated imem_addr at rising edge
// C2          FETCH_CAPTURE     Capture stable imem_rdata
// C3          FETCH_DONE        instruction is valid; fetch_done is asserted
//
// At the C1 rising edge:
//
//     imem_rdata <= memory[imem_addr]
//
// The Fetcher cannot capture that new value using the same rising edge because
// both the SRAM and Fetcher use nonblocking assignments.
//
// FETCH_CAPTURE provides the additional edge needed to safely capture rdata.
//
// Reset behavior
// -----------------------------------------------------------------------------
//
// rst_n is an asynchronous active-low reset.
//
// On reset:
//
// fetch_state      = FETCH_IDLE
// fetch_state_next = combinational
// saved_pc         = 0
// instruction      = 0
// imem_ce          = 0
// imem_addr        = 0
// fetch_done       = 0
//
// Future upgrades
// -----------------------------------------------------------------------------
//
// The Scheduler depends only on fetch_done, not on the SRAM latency.
//
// A later implementation may replace the SRAM with:
//
// - Instruction cache
// - Multi-cycle memory
// - Valid/ready request interface
// - Instruction prefetch buffer
// - Multiple Wave fetch requests
//
// The internal Fetcher FSM can change while the Scheduler-facing behavior
// remains:
//
//     request current_pc
//     wait for fetch_done
//     consume instruction
// ============================================================================

module instruction_fetcher #(
    parameter int PC_BITS           = 8,
    parameter int INSTRUCTION_BITS  = 16,
    parameter int INSTRUCTION_BYTES = INSTRUCTION_BITS / 8,
    parameter int IMEM_ADDR_BITS =
        PC_BITS - $clog2(INSTRUCTION_BYTES)
) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic [2:0]                  core_state,
    input  logic [PC_BITS-1:0]          current_pc,

    output logic                        imem_ce,
    output logic [IMEM_ADDR_BITS-1:0]   imem_addr,
    input  logic [INSTRUCTION_BITS-1:0] imem_rdata,

    output logic [INSTRUCTION_BITS-1:0] instruction,
    output logic                        fetch_done,
    output logic [1:0]                  fetch_state
);

localparam logic [2:0] CORE_STATE_FETCH  = 3'b001;
localparam logic [2:0] CORE_STATE_DECODE = 3'b010;

localparam logic [1:0] FETCH_IDLE    = 2'b00;
localparam logic [1:0] FETCH_ISSUE   = 2'b01;
localparam logic [1:0] FETCH_CAPTURE = 2'b10;
localparam logic [1:0] FETCH_DONE    = 2'b11;

localparam int PC_LSB_BITS = $clog2(INSTRUCTION_BYTES);

logic [1:0] fetch_state_next;
logic [PC_BITS-1:0] saved_pc;

assign imem_addr = saved_pc[PC_BITS-1:PC_LSB_BITS];

always_ff @( posedge clk or negedge rst_n) begin
	if (!rst_n)
		fetch_state <= '0;
	else
		fetch_state <= fetch_state_next;
end

always_comb begin
	fetch_state_next = '0;
	case(fetch_state)
		FETCH_IDLE : begin
			fetch_state_next = (core_state == CORE_STATE_FETCH) ? FETCH_ISSUE : FETCH_IDLE;
		end
		FETCH_ISSUE: begin
			fetch_state_next = FETCH_CAPTURE;
		end
		FETCH_CAPTURE: begin
			fetch_state_next = FETCH_DONE;
		end
		FETCH_DONE: begin 
			fetch_state_next = (core_state == CORE_STATE_DECODE) ? FETCH_IDLE : FETCH_DONE;
		end
		default: begin
			fetch_state_next = FETCH_IDLE;
		end
	endcase
end

always_ff @( posedge clk or negedge rst_n) begin
	if (!rst_n)
		saved_pc <= '0;
	else if ((core_state == CORE_STATE_FETCH) && (fetch_state == FETCH_IDLE))
		saved_pc <= current_pc;
end

always_comb begin
	imem_ce = '0;
	fetch_done = '0;
	if( fetch_state == FETCH_ISSUE)begin
		imem_ce = 1'b1;
	end
	else if (fetch_state == FETCH_DONE)begin
		fetch_done = 1'b1;
	end
end

always_ff @( posedge clk or negedge rst_n)begin
	if (!rst_n)
		instruction <= '0;
	else if (fetch_state == FETCH_CAPTURE)
		instruction <= imem_rdata;
end


// 由你实现

endmodule

`default_nettype wire

`default_nettype wire
