`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Wave Scheduler
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// The Scheduler controls one Wave through the complete instruction lifecycle.
// All active lanes share core_state and the byte-addressed current_pc.
//
// Microarchitecture
// -----------------------------------------------------------------------------
//
//                          Wave Scheduler
// ┌──────────────────────────────────────────────────────────────────────┐
// │                                                                      │
// │  start, start_pc, lane_valid_mask                                    │
// │                 │                                                    │
// │                 ▼                                                    │
// │  ┌────────────────────────────┐                                      │
// │  │ Wave Context Registers     │                                      │
// │  │                            │                                      │
// │  │ current_pc                 │                                      │
// │  │ exec_mask                  │                                      │
// │  └─────────────┬──────────────┘                                      │
// │                │                                                     │
// │                ▼                                                     │
// │  ┌────────────────────────────┐                                      │
// │  │ Instruction Lifecycle FSM  │◄──── fetch_done                      │
// │  │                            │◄──── lsu_state                       │
// │  │ IDLE    FETCH   DECODE     │◄──── decoded_ret                     │
// │  │ REQUEST WAIT    EXECUTE    │                                      │
// │  │ UPDATE  DONE               │                                      │
// │  └─────────────┬──────────────┘                                      │
// │                │                                                     │
// │                ▼                                                     │
// │  ┌────────────────────────────┐                                      │
// │  │ Next-PC Selection          │◄──── next_pc[lane]                   │
// │  │                            │◄──── exec_mask                       │
// │  │ lowest active lane         │                                      │
// │  │ divergence comparison      │                                      │
// │  └─────────────┬──────────────┘                                      │
// │                │                                                     │
// │                ├──────────────► current_pc                           │
// │                └──────────────► divergence_detected                  │
// │                                                                      │
// └──────────────────────────────────────────────────────────────────────┘
//
// Instruction lifecycle
// -----------------------------------------------------------------------------
//
// IDLE
//   -> FETCH
//   -> DECODE
//   -> REQUEST
//   -> WAIT
//   -> EXECUTE
//   -> UPDATE
//   -> FETCH
//
// A RET instruction changes UPDATE -> DONE.
//
// Core-state behavior
// -----------------------------------------------------------------------------
//
// State      Operation
// ---------  ------------------------------------------------------------------
// IDLE       Wait for a new Wave launch
// FETCH      Wait for the Instruction Fetcher
// DECODE     Allow the Decoder to register fields and control signals
// REQUEST    Allow Register Files and the Wave LSU to capture operands
// WAIT       Wait for the Wave LSU when the instruction accesses memory
// EXECUTE    Allow per-lane ALUs and PC units to calculate results
// UPDATE     Commit results and update the shared current_pc
// DONE       Report Wave completion
//
// State transition table
// -----------------------------------------------------------------------------
//
// Current state   Condition                                  Next state
// --------------  -----------------------------------------  -------------------
// IDLE            start == 1                                 FETCH
// IDLE            start == 0                                 IDLE
// FETCH           fetch_done == 1                            DECODE
// FETCH           fetch_done == 0                            FETCH
// DECODE          unconditional                              REQUEST
// REQUEST         unconditional                              WAIT
// WAIT            non-memory instruction                     EXECUTE
// WAIT            memory instruction and LSU_STATE_DONE      EXECUTE
// WAIT            memory instruction and LSU not done        WAIT
// EXECUTE         unconditional                              UPDATE
// UPDATE          decoded_ret == 1                           DONE
// UPDATE          decoded_ret == 0                           FETCH
// DONE            start == 0                                 IDLE
// DONE            start == 1                                 DONE
//
// Wave launch
// -----------------------------------------------------------------------------
// When a Wave starts:
//
// current_pc = start_pc
// exec_mask  = lane_valid_mask
//
// lane_valid_mask identifies lanes occupied by valid threads. The baseline
// holds exec_mask unchanged for the whole Wave. A later divergence design may
// change exec_mask while lane_valid_mask remains the Wave occupancy mask.
//
// WAIT behavior
// -----------------------------------------------------------------------------
// A non-memory instruction passes through WAIT without waiting for the LSU.
// LDR and STR remain in WAIT until lsu_state == LSU_STATE_DONE.
//
// The Scheduler observes only the Wave-level LSU state. Per-lane pending bits
// remain inside wave_lsu.
//
// Shared next-PC selection
// -----------------------------------------------------------------------------
// Every enabled lane calculates one candidate next_pc.
//
// The baseline selects the lowest-numbered active lane as the shared PC source.
// This supports a partial Wave without depending on the last physical lane.
//
// All other active-lane next_pc values are compared with selected_next_pc.
// divergence_detected is asserted if any active lane differs.
//
// The baseline reports divergence but still follows selected_next_pc. A later
// implementation will replace this policy with EXEC-mask splitting, path
// scheduling and reconvergence.
//
// Byte-addressed PC
// -----------------------------------------------------------------------------
// current_pc, start_pc and next_pc are byte addresses.
//
// For the current 16-bit ISA, normal sequential PCs are:
//
// 8'h00 -> 8'h02 -> 8'h04 -> 8'h06
//
// The per-lane PC units calculate the increment. The Scheduler only commits
// selected_next_pc during UPDATE.
//
// Done behavior
// -----------------------------------------------------------------------------
// done is asserted in CORE_STATE_DONE.
// DONE is held while start remains asserted. After start is deasserted, the
// Scheduler returns to IDLE and may accept another Wave launch.
//
// Reset behavior
// -----------------------------------------------------------------------------
// rst_n is an asynchronous active-low reset.
//
// On reset:
//
// core_state          = CORE_STATE_IDLE
// current_pc          = 0
// exec_mask           = 0
// done                = 0
// divergence_detected = 0
//
// Future upgrades
// -----------------------------------------------------------------------------
// The Wave Context can later add wave_id, saved execution masks, divergence
// stack state, outstanding-memory counters, scoreboard state and barrier state.
// ============================================================================

module scheduler #(
    parameter int PC_BITS        = 8,
    parameter int LANES_PER_WAVE = 4
) (
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic                      start,
    input  logic [PC_BITS-1:0]        start_pc,
    input  logic [LANES_PER_WAVE-1:0] lane_valid_mask,

    input  logic                      fetch_done,
    input  logic [1:0]                lsu_state,

    input  logic                      decoded_mem_read_enable,
    input  logic                      decoded_mem_write_enable,
    input  logic                      decoded_ret,

    input  logic [PC_BITS-1:0]
        next_pc [LANES_PER_WAVE-1:0],

    output logic [2:0]                core_state,
    output logic [PC_BITS-1:0]        current_pc,
    output logic [LANES_PER_WAVE-1:0] exec_mask,

    output logic                      done,
    output logic                      divergence_detected
);

localparam logic [2:0] CORE_STATE_IDLE    = 3'b000;
localparam logic [2:0] CORE_STATE_FETCH   = 3'b001;
localparam logic [2:0] CORE_STATE_DECODE  = 3'b010;
localparam logic [2:0] CORE_STATE_REQUEST = 3'b011;
localparam logic [2:0] CORE_STATE_WAIT    = 3'b100;
localparam logic [2:0] CORE_STATE_EXECUTE = 3'b101;
localparam logic [2:0] CORE_STATE_UPDATE  = 3'b110;
localparam logic [2:0] CORE_STATE_DONE    = 3'b111;

localparam logic [1:0] LSU_STATE_IDLE     = 2'b00;
localparam logic [1:0] LSU_STATE_PREPARE  = 2'b01;
localparam logic [1:0] LSU_STATE_WAITING  = 2'b10;
localparam logic [1:0] LSU_STATE_DONE     = 2'b11;

logic [2:0] core_state_next;

//logic [PC_BITS-1:0] current_pc_next;

//logic [LANES_PER_WAVE-1:0] exec_mask_next;

logic [PC_BITS-1:0] selected_next_pc;
logic               selected_next_pc_valid;
logic               next_pc_diverged;

integer lane;

assign done = core_state == CORE_STATE_DONE;

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		exec_mask <= '0;
	end
	else if(start&&(core_state == CORE_STATE_IDLE))begin
		exec_mask <= lane_valid_mask;
	end
end
always_comb begin
	next_pc_diverged = '0;
	selected_next_pc = '0;
	selected_next_pc_valid = '0;

	for ( lane = 0 ; lane < LANES_PER_WAVE; lane = lane + 1) begin
		if (core_state == CORE_STATE_UPDATE)begin
			if(exec_mask[lane]&& !selected_next_pc_valid)begin
				selected_next_pc = next_pc[lane];
				selected_next_pc_valid = 1'b1;
			end	
			else if ((next_pc[lane] != selected_next_pc)&& selected_next_pc_valid && exec_mask[lane] )begin
				next_pc_diverged = 1'b1;
			end
		end	
	end

end

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		divergence_detected <= '0;
	end
	else if (core_state == CORE_STATE_IDLE && start)
		divergence_detected <= '0;
	else if (core_state == CORE_STATE_UPDATE) begin
		divergence_detected <= next_pc_diverged;
	end
end


always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		current_pc <= '0;
	end
	else if ((core_state == CORE_STATE_IDLE)&& start)
		current_pc <= start_pc;
	else if((core_state == CORE_STATE_UPDATE)&&selected_next_pc_valid &&  !decoded_ret)
		current_pc <= selected_next_pc;	
end

always_ff @ ( posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		core_state <= '0;
	end
	else begin
		core_state <= core_state_next;
	end
end

always_comb begin
	core_state_next = '0;
	case (core_state)
		CORE_STATE_IDLE : begin
			core_state_next = (start) ? CORE_STATE_FETCH : CORE_STATE_IDLE;
		end
		CORE_STATE_FETCH : begin 
			core_state_next = (fetch_done) ? CORE_STATE_DECODE : CORE_STATE_FETCH;
		end
		CORE_STATE_DECODE : begin
			core_state_next = CORE_STATE_REQUEST;
		end
		CORE_STATE_REQUEST : begin
			core_state_next = CORE_STATE_WAIT;
		end
		CORE_STATE_WAIT : begin 
			core_state_next = (~(decoded_mem_read_enable | decoded_mem_write_enable)) ? 
			CORE_STATE_EXECUTE : (lsu_state == LSU_STATE_DONE) ? CORE_STATE_EXECUTE : CORE_STATE_WAIT;	
		end
		CORE_STATE_EXECUTE : begin
			core_state_next = CORE_STATE_UPDATE;
		end
		CORE_STATE_UPDATE : begin
			core_state_next = decoded_ret ? CORE_STATE_DONE : CORE_STATE_FETCH;
		end
		CORE_STATE_DONE :begin
			core_state_next = start ? CORE_STATE_DONE : CORE_STATE_IDLE;
		end
		default : begin
			core_state_next = CORE_STATE_IDLE;
		end
	endcase

end





// 由你实现

endmodule

`default_nettype wire
