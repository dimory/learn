`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU M3 Wave Memory Unit
// ============================================================================
//
// Purpose
// -----------------------------------------------------------------------------
// Execute scalar/global/LDS memory instructions through a Wave-level command
// interface. Track outstanding commands until their completion notification.
//
// Microarchitecture
// -----------------------------------------------------------------------------
// - One sending slot captures a command and its architectural commit descriptor.
// - A shared Tag table tracks outstanding commands from all resident Waves.
// - Each Tag saves Wave ID, destination, active mask, dependency kind,
//   sequence number and original instruction information.
// - Responses enter a FIFO and recover their metadata through transaction_id.
// - Loads produce RF writeback packets. Stores complete through backend ack.
// - Request sending, response handling and completion notification operate
//   concurrently.
//
// Sending state machine
// -----------------------------------------------------------------------------
// IDLE:
//   Accept an instruction. Reserve a Tag for an active command.
//   An inactive vector instruction proceeds directly to COMMIT.
//
// REQUEST:
//   Hold the saved command until the memory backend accepts it.
//
// COMMIT:
//   Hold the acceptance commit until Writeback/Commit consumes it.
//   Return to IDLE without waiting for the memory response.
//
// Event ownership
// -----------------------------------------------------------------------------
// - issue_fire reserves a Tag but does not increment dependency counters.
// - mem_req_fire marks the Tag sent and generates dependency issue, amount=1.
// - A Load response must finish RF writeback before becoming complete.
// - A Store response represents a completed-write acknowledgement.
// - LOAD/STORE/DS notify in per-Wave, per-kind issue order.
// - KM completion notification may occur out of order.
// - A Tag is released on its dependency completion notification edge.
//
// Masks and backpressure
// -----------------------------------------------------------------------------
// - Addresses, Store data and active mask are captured at instruction acceptance.
// - Load writeback uses the saved mask, independently of later EXEC changes.
// - SMEM uses lane 0 and executes regardless of EXEC.
// - An inactive vector instruction generates no backend request or counter event.
// - Request, commit and result payloads remain stable while stalled.
//
// Configuration
// -----------------------------------------------------------------------------
// - Default: 16 shared Tags and a four-entry response FIFO.
// - Supported Tag count: 1..31 for the current amount=1 admission model.
// - Physical transaction splitting/coalescing belongs to the later backend.
// ============================================================================

module wave_memory_unit #(
    parameter int NUM_WAVE_CONTEXTS = 4,
    parameter int NUM_MEMORY_TAGS   = 16,
    parameter int RETURN_FIFO_DEPTH = 4,

    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1,

    parameter int TAG_BITS =
        (NUM_MEMORY_TAGS > 1) ? $clog2(NUM_MEMORY_TAGS) : 1,

    parameter int FIFO_BITS =
        (RETURN_FIFO_DEPTH > 1) ? $clog2(RETURN_FIFO_DEPTH) : 1,

    parameter int FIFO_COUNT_BITS =
        $clog2(RETURN_FIFO_DEPTH + 1)
) (
    input logic clk,
    input logic rst_n,

    // Instruction input from Operand Collector.
    input  logic issue_valid,
    output logic issue_ready,
    input  logic [WAVE_ID_BITS-1:0] issue_wave_id,
    input  gpu_pkg::m3_operand_payload_t issue_payload,
    input  logic [31:0] group_segment_bytes,

    // Saved command sent to the memory backend.
    output logic mem_req_valid,
    input  logic mem_req_ready,
    output logic [WAVE_ID_BITS-1:0] mem_req_wave_id,
    output gpu_pkg::m3_memory_request_t mem_req_payload,

    // Backend response: Load data or Store acknowledgement.
    input  logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input  gpu_pkg::m3_memory_response_t mem_rsp_payload,

    // Request-acceptance PC commit.
    output logic memory_commit_valid,
    input  logic memory_commit_ready,
    output logic [WAVE_ID_BITS-1:0] memory_commit_wave_id,
    output gpu_pkg::m3_commit_t memory_commit_payload,

    // Load result sent to Writeback.
    output logic result_valid,
    input  logic result_ready,
    output logic [WAVE_ID_BITS-1:0] result_wave_id,
    output gpu_pkg::m3_result_t result_payload,

    // Dependency events; each event represents amount=1.
    output logic dependency_issue_valid,
    output logic [WAVE_ID_BITS-1:0] dependency_issue_wave_id,
    output gpu_pkg::dependency_kind_t dependency_issue_kind,

    output logic dependency_complete_valid,
    output logic [WAVE_ID_BITS-1:0] dependency_complete_wave_id,
    output gpu_pkg::dependency_kind_t dependency_complete_kind,

    // Response error information.
    output logic fault_valid,
    output logic [WAVE_ID_BITS-1:0] fault_wave_id,
    output logic [63:0] fault_pc,
    output logic [31:0] fault_instruction,

    // Outstanding Tag visibility.
    output logic [NUM_MEMORY_TAGS-1:0] allocated_mask
);

import gpu_pkg::*;

// Sending-slot state.
localparam logic [1:0] IDLE    = 2'd0;
localparam logic [1:0] REQUEST = 2'd1;
localparam logic [1:0] COMMIT  = 2'd2;

logic [1:0] state;
logic [1:0] next_state;

// Interface handshakes.
logic issue_fire;
logic mem_req_fire;
logic mem_rsp_fire;
logic memory_commit_fire;
logic result_fire;

// Metadata belonging to one outstanding memory command.
typedef struct packed {
    logic allocated;
    logic sent;
    logic rf_done;
    logic is_load;

    logic [WAVE_ID_BITS-1:0] wave_id;
    dependency_kind_t kind;

    operand_kind_t dst_kind;
    logic [9:0] dst_index;
    logic [4:0] dst_count;
    logic [31:0] mask;

    logic [7:0] sequence_id;
    logic [63:0] origin_pc;
    logic [31:0] instruction0;
} tag_t;

tag_t tags [0:NUM_MEMORY_TAGS-1];

// Per-Wave, per-kind allocation and completion sequence numbers.
logic [7:0] next_sequence
    [0:NUM_WAVE_CONTEXTS-1][0:DEPENDENCY_COUNTER_COUNT-1];

logic [7:0] head_sequence
    [0:NUM_WAVE_CONTEXTS-1][0:DEPENDENCY_COUNTER_COUNT-1];

// Incoming command preparation and saved sending slot.
m3_memory_request_t prepared;
m3_memory_request_t command;
m3_commit_t command_commit;

logic [WAVE_ID_BITS-1:0] command_wave;
dependency_kind_t prepared_kind;
logic no_active;

logic [63:0] address;
logic [63:0] offset;

// Tag allocation and response lookup.
logic free_valid;
logic [TAG_BITS-1:0] free_tag;
logic [TAG_BITS-1:0] request_tag;
logic [TAG_BITS-1:0] response_tag;
logic [TAG_BITS-1:0] head_tag;

// Backend response FIFO.
m3_memory_response_t response_fifo [0:RETURN_FIFO_DEPTH-1];

logic [FIFO_BITS-1:0] fifo_read;
logic [FIFO_BITS-1:0] fifo_write;
logic [FIFO_COUNT_BITS-1:0] fifo_count;

logic fifo_push;
logic fifo_pop;

// Completion notification arbitration.
logic complete_valid;
logic [TAG_BITS-1:0] complete_tag;
logic [TAG_BITS-1:0] complete_pointer;

// Independent combinational loop variables.
integer t;
integer lane;
integer p;
integer scan;
integer index;

// Sequential reset/update loop variables.
integer ft;
integer w;
integer k;
integer ff_fifo;

always_comb begin
	free_valid     = 1'b0;
	free_tag       = '0;
	allocated_mask = '0;

end


endmodule

`default_nettype wire