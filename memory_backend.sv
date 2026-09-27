`default_nettype none
`timescale 1ns/1ns

// Parameter restrictions
// -----------------------------------------------------------------------------
// - NUM_BANKS must be a power of two.
// - LANES_PER_WAVE must be greater than one.
// - ADDR_BITS must be greater than $clog2(NUM_BANKS).



// ============================================================================
// TinyGPU 4-Bank Wave Memory Backend
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// The backend accepts per-lane memory requests from one Wave LSU.
//
// Each active lane provides:
// - One outstanding-request bit
// - One memory address
// - One store-data value
//
// The backend maps each address to one of four independent single-port SRAM
// banks. Different banks may operate concurrently. Requests targeting the
// same bank are serialized.
//
// Current configuration
// -----------------------------------------------------------------------------
//
// DATA_BITS      = 8
// ADDR_BITS      = 8
// LANES_PER_WAVE = 4
// NUM_BANKS      = 4
//
// The four banks form one logical 256 x 8 memory:
//
// Bank 0 : 64 x 8
// Bank 1 : 64 x 8
// Bank 2 : 64 x 8
// Bank 3 : 64 x 8
//
// Microarchitecture
// -----------------------------------------------------------------------------
//                       4-Bank Memory Backend
// ┌─────────────────────────────────────────────────────────────────────┐
// │                                                                     │
// │  From Wave LSU                                                      │
// │                                                                     │
// │  memory_request_mask[3:0]                                           │
// │  memory_address[0:3]                                                │
// │  memory_write_data[0:3]                                             │
// │  memory_write                                                       │
// │             │                                                       │
// │             ▼                                                       │
// │  ┌──────────────────────────┐                                       │
// │  │ Per-Lane Address Decode  │                                       │
// │  │                          │                                       │
// │  │ bank_id  = address[1:0]  │                                       │
// │  │ bank_row = address[7:2]  │                                       │
// │  └─────────────┬────────────┘                                       │
// │                │                                                    │
// │                ▼                                                    │
// │  ┌──────────────────────────┐                                       │
// │  │ Per-Bank Request Matrix  │                                       │
// │  │                          │                                       │
// │  │ request[bank][lane]      │                                       │
// │  └─────────────┬────────────┘                                       │
// │                │                                                    │
// │        ┌───────┼────────┬────────┬────────┐                         │
// │        ▼       ▼        ▼        ▼                                  │
// │  ┌─────────┐┌─────────┐┌─────────┐┌─────────┐                       │
// │  │ Bank 0  ││ Bank 1  ││ Bank 2  ││ Bank 3  │                       │
// │  │ Arbiter ││ Arbiter ││ Arbiter ││ Arbiter │                       │
// │  │ + FSM   ││ + FSM   ││ + FSM   ││ + FSM   │                       │
// │  └────┬────┘└────┬────┘└────┬────┘└────┬────┘                       │
// │       │          │          │          │                            │
// │       ▼          ▼          ▼          ▼                            │
// │  ┌─────────┐┌─────────┐┌─────────┐┌─────────┐                       │
// │  │ SRAM 0  ││ SRAM 1  ││ SRAM 2  ││ SRAM 3  │                       │
// │  │ 64 x 8  ││ 64 x 8  ││ 64 x 8  ││ 64 x 8  │                       │
// │  └────┬────┘└────┬────┘└────┬────┘└────┬────┘                       │
// │       │ rdata    │ rdata    │ rdata    │ rdata                      │
// │       └──────────┴─────┬────┴──────────┘                            │
// │                        ▼                                            │
// │           ┌──────────────────────────┐                              │
// │           │ Completion Routing       │                              │
// │           │                          │                              │
// │           │ saved lane ID            │                              │
// │           │        ↓                 │                              │
// │           │ memory_read_data[lane]   │                              │
// │           │ memory_done_mask[lane]   │                              │
// │           └────────────┬─────────────┘                              │
// │                        │                                            │
// │                        ▼                                            │
// │                    To Wave LSU                                      │
// │                                                                     │
// └─────────────────────────────────────────────────────────────────────┘
//
// Address mapping
// -----------------------------------------------------------------------------
//
// For four banks:
//
// bank_id  = memory_address[lane][1:0]
// bank_row = memory_address[lane][7:2]
//
// Global address   Bank   Row
// --------------   ----   ---
// 8'h20              0     8
// 8'h21              1     8
// 8'h22              2     8
// 8'h23              3     8
// 8'h24              0     9
//
// Per-bank request matrix
// -----------------------------------------------------------------------------
//
// bank_request[bank][lane] is asserted when:
//
// 1. memory_request_mask[lane] is asserted
// 2. memory_address[lane] maps to that bank
//
// Example:
//
// Lane      Address      Bank
// --------  -----------  ----
// lane 0    8'h20        0
// lane 1    8'h21        1
// lane 2    8'h24        0
// lane 3    8'h23        3
//
// Resulting request matrix:
//
// Bank      lane0  lane1  lane2  lane3
// --------  -----  -----  -----  -----
// bank 0      1      0      1      0
// bank 1      0      1      0      0
// bank 2      0      0      0      0
// bank 3      0      0      0      1
//
// Arbitration
// -----------------------------------------------------------------------------
//
// Each bank owns one independent fixed-priority arbiter.
//
// Priority:
//
// lane 0 > lane 1 > lane 2 > lane 3
//
// Arbitration outputs:
//
// grant_valid[bank]   : at least one eligible lane requests this bank
// grant_lane_id[bank] : selected lane number
//
// Address decoding and arbitration are combinational.
//
// The selected request is registered only when:
// - the bank is in BANK_IDLE;
// - grant_valid for that bank is asserted.
//
// Bank conflicts
// -----------------------------------------------------------------------------
//
// Addresses                  Behavior
// -------------------------  -----------------------------------------------
// 20, 21, 22, 23             Four banks access concurrently
// 20, 24, 22, 23             Lane requests to Bank 0 are serialized
// 20, 24, 28, 2C             All requests are serialized by Bank 0
//
// Memory operation
// -----------------------------------------------------------------------------
//
// All lanes belong to the same wave instruction.
//
// memory_write = 1'b0 : LDR
// memory_write = 1'b1 : STR
//
// One instruction cannot contain a mixture of LDR and STR operations.
//
// Per-bank saved transaction
// -----------------------------------------------------------------------------
//
// After arbitration, each bank stores:
//
// inflight_lane_id[bank] : lane owning the transaction
// inflight_addr[bank]    : row address inside the selected SRAM bank
// inflight_wdata[bank]   : store data
// inflight_write[bank]   : load/store operation type
//
// The saved lane ID is used to route completion and read data back to the
// correct lane.
//
// Per-bank state machine
// -----------------------------------------------------------------------------
//
// Each SRAM bank owns one independent state machine.
//
// State               Meaning
// ------------------  ---------------------------------------------------------
// BANK_IDLE           Arbitrate and capture a new lane request
// BANK_ISSUE          Drive the saved transaction into the SRAM bank
// BANK_READ_CAPTURE   Capture synchronous SRAM read data
// BANK_COMPLETE       Report completion to the saved lane
//
// State transition diagram
// -----------------------------------------------------------------------------
//
//                         no request
//                    ┌─────────────────┐
//                    │                 │
//                    ▼                 │
//             ┌───────────────┐        │
//             │ BANK_IDLE     │────────┘
//             │               │
//             │ Decode address│
//             │ Arbitrate lane│
//             └───────┬───────┘
//                     │ grant_valid
//                     │
//                     │ Save lane ID, address,
//                     │ write data and operation
//                     ▼
//             ┌───────────────┐
//             │ BANK_ISSUE    │
//             │               │
//             │ sram_ce = 1   │
//             │ sram_we = op  │
//             │ drive addr    │
//             │ drive wdata   │
//             └───┬───────┬───┘
//                 │       │
//             STR │       │ LDR
//                 │       ▼
//                 │  ┌───────────────────┐
//                 │  │ BANK_READ_CAPTURE │
//                 │  │                   │
//                 │  │ Capture rdata and │
//                 │  │ route it using    │
//                 │  │ saved lane ID     │
//                 │  └─────────┬─────────┘
//                 │            │
//                 └──────┬─────┘
//                        ▼
//             ┌───────────────────┐
//             │ BANK_COMPLETE     │
//             │                   │
//             │ Assert done for   │
//             │ saved lane ID     │
//             └─────────┬─────────┘
//                       │
//                       ▼
//                  BANK_IDLE
//
// State transition table
// -----------------------------------------------------------------------------
//
// Current state        Condition                 Next state
// ------------------   ------------------------  -------------------------------
// BANK_IDLE            grant_valid == 1          BANK_ISSUE
// BANK_IDLE            grant_valid == 0          BANK_IDLE
// BANK_ISSUE           inflight_write == 1       BANK_COMPLETE
// BANK_ISSUE           inflight_write == 0       BANK_READ_CAPTURE
// BANK_READ_CAPTURE    unconditional              BANK_COMPLETE
// BANK_COMPLETE        unconditional              BANK_IDLE
//
// State output table
// -----------------------------------------------------------------------------
//
// State               sram_ce  sram_we             memory_done_mask
// ------------------  -------  ------------------  ----------------------------
// BANK_IDLE              0       0                 0
// BANK_ISSUE             1       inflight_write    0
// BANK_READ_CAPTURE      0       0                 0
// BANK_COMPLETE          0       0                 saved lane bit asserted
//
// SRAM timing
// -----------------------------------------------------------------------------
//
// sram_ce  sram_we   Operation at rising edge
// -------  -------   ----------------------------------------------------------
//    0        X      No access
//    1        0      Read sram_addr; rdata updates after the edge
//    1        1      Write sram_wdata into sram_addr
//
// LDR timing
// -----------------------------------------------------------------------------
//
// Cycle       Bank state           Operation
// ----------  -------------------  ---------------------------------------------
// C0          BANK_IDLE            Select and save one lane request
// C1          BANK_ISSUE           SRAM samples the read address
// C2          BANK_READ_CAPTURE    Capture returned SRAM data
// C3          BANK_COMPLETE        Assert the selected lane's done bit
// C4          BANK_IDLE            Select next conflicting lane, if any
//
// STR timing
// -----------------------------------------------------------------------------
//
// Cycle       Bank state           Operation
// ----------  -------------------  ---------------------------------------------
// C0          BANK_IDLE            Select and save one lane request
// C1          BANK_ISSUE           SRAM samples address and write data
// C2          BANK_COMPLETE        Assert the selected lane's done bit
// C3          BANK_IDLE            Select next conflicting lane, if any
//
// Completion interface
// -----------------------------------------------------------------------------
//
// memory_done_mask may contain several asserted bits when different banks
// complete in the same cycle.
//
// For LDR:
//
// memory_read_data[lane] is valid when memory_done_mask[lane] is asserted.
//
// For STR:
//
// memory_done_mask[lane] means that SRAM has sampled the write transaction.
//
// Wave LSU clears completed lanes using:
//
// pending_mask = pending_mask & ~memory_done_mask
//
// Reset behavior
// -----------------------------------------------------------------------------
//
// rst_n is an asynchronous active-low reset.
//
// Reset places every bank in BANK_IDLE and clears:
// - all saved transaction information;
// - memory_done_mask;
// - memory_read_data.
//
// Reset does not clear SRAM contents.
//
// Future pipeline upgrade
// -----------------------------------------------------------------------------
//
// The external interface remains unchanged when the backend is pipelined.
//
// A pipelined implementation will replace the blocking per-bank FSM with:
// - per-bank issue pipeline;
// - accepted_mask;
// - return-valid pipeline;
// - return lane-ID tags.
//
// Multi-wave arbitration, global-memory coalescing and non-blocking loads are
// separate future upgrades.
// ============================================================================

module memory_backend #(
    parameter int DATA_BITS      = 8,
    parameter int ADDR_BITS      = 8,
    parameter int LANES_PER_WAVE = 4,
    parameter int NUM_BANKS      = 4,
    parameter int BANK_ADDR_BITS = ADDR_BITS - $clog2(NUM_BANKS)
) (
    input  logic clk,
    input  logic rst_n,

    // Requests from Wave LSU
    input  logic [LANES_PER_WAVE-1:0] memory_request_mask,
    input  logic                      memory_write,

    input  logic [ADDR_BITS-1:0]
        memory_address [LANES_PER_WAVE-1:0],

    input  logic [DATA_BITS-1:0]
        memory_write_data [LANES_PER_WAVE-1:0],

    // Completions returned to Wave LSU
    output logic [LANES_PER_WAVE-1:0] memory_done_mask,

    output logic [DATA_BITS-1:0]
        memory_read_data [LANES_PER_WAVE-1:0],

    // Independent single-port SRAM-bank interfaces
    output logic [NUM_BANKS-1:0] sram_ce,
    output logic [NUM_BANKS-1:0] sram_we,

    output logic [BANK_ADDR_BITS-1:0]
        sram_addr [NUM_BANKS-1:0],

    output logic [DATA_BITS-1:0]
        sram_wdata [NUM_BANKS-1:0],

    input  logic [DATA_BITS-1:0]
        sram_rdata [NUM_BANKS-1:0]
);

// ============================================================================
// Local parameters
// ============================================================================

localparam int BANK_SEL_BITS = $clog2(NUM_BANKS);
localparam int LANE_ID_BITS  = $clog2(LANES_PER_WAVE);

// Memory-operation encoding
localparam logic MEM_READ  = 1'b0;
localparam logic MEM_WRITE = 1'b1;

// Per-bank state encoding
localparam logic [1:0] BANK_IDLE         = 2'b00;
localparam logic [1:0] BANK_ISSUE        = 2'b01;
localparam logic [1:0] BANK_READ_CAPTURE = 2'b10;
localparam logic [1:0] BANK_COMPLETE     = 2'b11;

// 由你实现
// bank_request[bank][lane]
logic [LANES_PER_WAVE-1:0]
    bank_request [NUM_BANKS-1:0];

// Arbitration result for every bank
logic [NUM_BANKS-1:0] grant_valid;

logic [LANE_ID_BITS-1:0]
    grant_lane_id [NUM_BANKS-1:0];

// Independent state for every bank
logic [1:0]
    bank_state [NUM_BANKS-1:0];

logic [1:0]
    bank_state_next [NUM_BANKS-1:0];
	
	
	
logic [LANE_ID_BITS-1:0]
    inflight_lane_id [NUM_BANKS-1:0];

logic [BANK_ADDR_BITS-1:0]
    inflight_addr [NUM_BANKS-1:0];

logic [DATA_BITS-1:0]
    inflight_wdata [NUM_BANKS-1:0];

logic [NUM_BANKS-1:0]
    inflight_write;

//integer bank;
//integer lane;

always_comb begin
	for (int bank = 0 ; bank< NUM_BANKS ; bank=bank +1)begin
		bank_request[bank] = '0;
	end
	for (int bank = 0 ; bank< NUM_BANKS ; bank=bank +1)begin
		for (int lane = 0; lane < LANES_PER_WAVE ; lane = lane+1)begin
			if(memory_request_mask[lane] && (memory_address[lane][BANK_SEL_BITS-1:0] ==bank))
				bank_request[bank][lane] = 1'b1;
		end
	end
end

always_comb begin
	grant_valid = '0;
	for (int bank = 0 ; bank < NUM_BANKS ; bank = bank + 1)begin
		grant_lane_id[bank] = '0;
	end
	for (int bank = 0 ; bank< NUM_BANKS ; bank=bank +1)begin
		for (int lane = 0; lane < LANES_PER_WAVE ; lane = lane+1 ) begin
			if(!grant_valid[bank] && bank_request[bank][lane] ) begin
				grant_valid[bank]= 1'b1;
				grant_lane_id[bank] =lane; 
			end
		end
	end


end

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		for (int bank = 0 ; bank < NUM_BANKS ; bank = bank+1 )begin
			bank_state[bank] <= '0;
		end
	end
	else begin
		for (int bank = 0 ; bank < NUM_BANKS ; bank = bank+1 )begin
			bank_state[bank] <= bank_state_next[bank];
		end	
	end
end

always_comb begin
		for (int bank = 0 ; bank < NUM_BANKS ; bank = bank+1 )begin
			case (bank_state[bank])
				BANK_IDLE: begin
					if (grant_valid[bank])
						bank_state_next[bank] = BANK_ISSUE;
					else 
						bank_state_next[bank] = BANK_IDLE;				
				end
				BANK_ISSUE: begin
					bank_state_next[bank] = inflight_write[bank] ? BANK_COMPLETE : BANK_READ_CAPTURE;
				end
				BANK_READ_CAPTURE: begin
					bank_state_next[bank] = BANK_COMPLETE;
				end
				BANK_COMPLETE: begin
					bank_state_next[bank] = BANK_IDLE;
				end
				default: bank_state_next[bank] = BANK_IDLE;
				endcase
		end	
end

always_ff @(posedge clk or negedge rst_n) begin
	if(!rst_n)begin
		for (int bank = 0 ; bank < NUM_BANKS ; bank = bank+1 )begin
			inflight_lane_id[bank] <= '0;
			inflight_addr[bank]	   <= '0;
			inflight_wdata[bank]   <= '0;
			inflight_write[bank]   <= '0;
		end
	end
	else begin
		for (int bank = 0 ; bank < NUM_BANKS ; bank = bank+1 )begin
			if (bank_state[bank] == BANK_IDLE && grant_valid[bank] )begin
				inflight_lane_id[bank] <= grant_lane_id[bank];
				inflight_write[bank]   <= memory_write;
				inflight_addr[bank]    <= memory_address[grant_lane_id[bank]][ADDR_BITS-1:BANK_SEL_BITS];
				if(memory_write)
					inflight_wdata[bank] <= memory_write_data[grant_lane_id[bank]];
			end
		end
	end
end

always_comb begin
	for (int bank = 0 ; bank < NUM_BANKS ; bank = bank+1 )begin
		sram_ce[bank]	= '0;
		sram_we[bank] 	= '0;
		sram_addr[bank] = '0;
		sram_wdata[bank]= '0;
		
	end
	memory_done_mask= '0;
	for (int bank = 0 ; bank < NUM_BANKS ; bank = bank+1 )begin
		if (bank_state[bank] == BANK_ISSUE)begin
			sram_ce[bank] = 1'b1;
			sram_addr[bank] = inflight_addr[bank];
			if(inflight_write[bank])begin
				sram_we[bank] = 1'b1;
				sram_wdata[bank] = inflight_wdata[bank];
			end
			else begin
				sram_we[bank] = 0;
			end
		end
		else if (bank_state[bank] == BANK_COMPLETE)begin
			memory_done_mask[inflight_lane_id[bank]] = 1'b1;
		end
		
	end	
end

always_ff @(posedge clk or negedge rst_n) begin
	if(!rst_n)begin
        for (int lane = 0; lane < LANES_PER_WAVE; lane = lane + 1) begin
            memory_read_data[lane] <= '0;
		end
	end
	else begin
		for (int bank = 0 ; bank < NUM_BANKS ; bank = bank+1 )begin
			if(bank_state[bank] == BANK_READ_CAPTURE)begin	
				memory_read_data[inflight_lane_id[bank]] <= sram_rdata[bank];
			end
		end
	end
end


endmodule

`default_nettype wire