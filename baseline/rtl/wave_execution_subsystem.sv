`default_nettype none
`timescale 1ns/1ns
// ============================================================================
// TinyGPU M3 Wave Execution Subsystem (T01)
// ============================================================================
// Function
// -----------------------------------------------------------------------------
// Structural integration of Fetch/Decode, per-Wave slots, Scoreboard, operand
// collection, SALU/VALU/Control/Memory, Register Init and Writeback/Commit.
// This wrapper owns no architectural state and does not execute instructions.
//
// Microarchitecture and ownership
// -----------------------------------------------------------------------------
// selected Context -> Fetch -> Decode -> per-Wave slot -> operand Collector.
// Collector's SEND packet is demultiplexed to exactly one of four units:
//   unit 0 SALU, unit 1 VALU, unit 2 Control, unit 3 Memory.
// Only collector_valid & collector_ready reserves Scoreboard destinations.
// Result sources 0 SALU / 1 VALU / 2 Load / 3 Init share the RF write ports.
// Writeback serializes whole results and performs final busy-clear/commit.
// Control and Memory-accept descriptors share the architectural commit arbiter.
// Init owns launch snapshots and the sticky first-fault record. Memory owns
// outstanding Tags, return FIFO and ordered dependency-completion events.
//
// Interfaces and timing
// -----------------------------------------------------------------------------
// Wave IDs are resident-slot sidebands, retained with their matching packets.
// SGPR/VGPR reads are synchronous; Collector supplies their request/capture
// phases. RF writes take effect on the rising edge and have no ready signal.
// imem uses tagged DWORD channels; data memory uses whole-Wave tagged commands.
// Each accepted backend command emits one issue event; final completion emits
// one complete event. Load return writes do not advance PC a second time.
// Commit and Wait-arm are same-edge events. Wait satisfied is feedback only
// for the committed Wave's next state, never a qualification of commit valid.
//
// Reset and fault
// -----------------------------------------------------------------------------
// rst_n passes directly to control storage. RF data/read outputs have no reset.
// Fault blocks new frontend admission/Collector selection. Owned operations and
// legal memory responses drain. The backend must flush ownership with reset.
// M3_VERIFICATION exposes pressure probes only; production ties them to zero.
// ============================================================================
module wave_execution_subsystem #(
    parameter int NUM_WAVE_CONTEXTS=4,NUM_SGPRS=32,NUM_VGPRS=64,
    parameter int NUM_MEMORY_TAGS=16,RETURN_FIFO_DEPTH=4,MAX_GROUP_SEGMENT_BYTES=4096,
    parameter int WAVE_ID_BITS=(NUM_WAVE_CONTEXTS>1)?$clog2(NUM_WAVE_CONTEXTS):1
) (
    input logic clk,rst_n,
    input logic selected_valid,
    output logic selected_ready,
    input logic [WAVE_ID_BITS-1:0] selected_wave_id,
    input gpu_pkg::m3_context_t selected_context,
    input logic alloc_fire,release_valid,
    input logic [WAVE_ID_BITS-1:0] alloc_wave_id,release_wave_id,
    input logic [4:0] alloc_wave_index,
    input logic launch_candidate,
    input logic [63:0] launch_start_pc,
    input logic [5:0] user_sgpr_count,
    input logic [1023:0] user_sgpr_data,
    input logic [24:0] dispatch_index,
    input logic [31:0] group_segment_bytes,
    output logic launch_config_legal,
    output logic [24:0] saved_dispatch_index,
    output logic [NUM_WAVE_CONTEXTS-1:0] rf_initialized_mask,
    output logic fault_valid,
    output logic [WAVE_ID_BITS-1:0] fault_wave_id,
    output gpu_pkg::m3_fault_t fault_code,
    output logic [63:0] fault_pc,
    output logic [31:0] fault_instruction,
    output logic imem_req_valid,
    input logic imem_req_ready,
    output logic [WAVE_ID_BITS-1:0] imem_req_wave_id,
    output logic [1:0] imem_req_word_index,
    output logic [63:0] imem_req_address,
    input logic imem_rsp_valid,
    output logic imem_rsp_ready,
    input logic [WAVE_ID_BITS-1:0] imem_rsp_wave_id,
    input logic [1:0] imem_rsp_word_index,
    input logic [31:0] imem_rsp_data,
    input logic imem_rsp_error,
    output logic mem_req_valid,
    input logic mem_req_ready,
    output logic [WAVE_ID_BITS-1:0] mem_req_wave_id,
    output gpu_pkg::m3_memory_request_t mem_req_payload,
    input logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input gpu_pkg::m3_memory_response_t mem_rsp_payload,
    output logic commit_valid,
    output logic [WAVE_ID_BITS-1:0] commit_wave_id,
    output gpu_pkg::m3_commit_t commit_payload,
    output gpu_pkg::wave_context_state_t commit_next_state,
    output logic dependency_issue_valid,dependency_complete_valid,
    output logic [WAVE_ID_BITS-1:0] dependency_issue_wave_id,dependency_complete_wave_id,
    output gpu_pkg::dependency_kind_t dependency_issue_kind,dependency_complete_kind,
    output logic wait_arm_valid,
    output gpu_pkg::m3_wait_spec_t wait_spec,
    input logic wait_arm_satisfied
);
    import gpu_pkg::*;
    logic fetch_valid,fetch_ready,decoded_valid,decoded_ready,buffer_ready;
    logic fetch_selected_ready;
    assign selected_ready = fetch_selected_ready && !fault_valid;
    logic [WAVE_ID_BITS-1:0] fetch_wave,decoded_wave;
    m3_fetch_payload_t fetch_payload;
    m3_decoded_payload_t decoded_payload,slots[0:NUM_WAVE_CONTEXTS-1];
    logic [NUM_WAVE_CONTEXTS-1:0] slot_valid,pop_mask,eligible_mask;
    logic [NUM_SGPRS-1:0] sgpr_busy[0:NUM_WAVE_CONTEXTS-1];
    logic [NUM_VGPRS-1:0] vgpr_busy[0:NUM_WAVE_CONTEXTS-1];
    logic collector_valid,collector_ready,execute_issue_fire;
    logic [WAVE_ID_BITS-1:0] collector_wave,rf_read_wave;
    logic [1:0] collector_unit,sgpr_read_enable,vgpr_read_enable;
    logic [3:0] unit_ready,result_valid,result_ready;
    logic [9:0] rf_read_index0,rf_read_index1;
    logic [2:0] rf_read_beat;
    logic [31:0] sgpr_read_data0,sgpr_read_data1;
    logic [127:0] vgpr_read_data0,vgpr_read_data1;
    m3_operand_payload_t collector_payload;
    logic [WAVE_ID_BITS-1:0] result_wave_ids[0:3];
    m3_result_t result_payloads[0:3];
    logic control_valid,control_ready,memory_commit_valid,memory_commit_ready;
    logic [WAVE_ID_BITS-1:0] control_wave,memory_commit_wave;
    m3_commit_t control_payload,memory_commit_payload;
    logic sgpr_write_enable,vgpr_write_enable,clear_valid;
    logic [WAVE_ID_BITS-1:0] rf_write_wave,clear_wave;
    logic [9:0] rf_write_index,clear_index;
    logic [2:0] rf_write_beat;
    logic [4:0] clear_count;
    operand_kind_t clear_kind;
    logic [31:0] sgpr_write_data;
    logic [3:0] vgpr_write_mask;
    logic [127:0] vgpr_write_data;
    logic decode_fault_valid,memory_fault_valid;
    logic [WAVE_ID_BITS-1:0] memory_fault_wave;
    logic [63:0] memory_fault_pc;
    logic [31:0] memory_fault_instruction,saved_group_segment_bytes;
    logic [5:0] saved_user_sgpr_count;
    logic [1023:0] saved_user_sgpr_data;
    logic [NUM_MEMORY_TAGS-1:0] allocated_tags;
`ifdef M3_VERIFICATION
    logic verification_decode_stall=1'b0;
    logic [3:0] verification_issue_stall='0;
`else
    wire verification_decode_stall=1'b0;
    wire [3:0] verification_issue_stall='0;
`endif

    wave_instruction_fetcher #(.WAVE_ID_BITS(WAVE_ID_BITS),
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS)) u_fetch (
        .clk(clk),
        .rst_n(rst_n),
        .selected_valid(selected_valid && !fault_valid),
        .selected_ready(fetch_selected_ready),
        .selected_wave_id(selected_wave_id),
        .selected_context(selected_context),
        .imem_req_valid(imem_req_valid),
        .imem_req_ready(imem_req_ready),
        .imem_req_wave_id(imem_req_wave_id),
        .imem_req_word_index(imem_req_word_index),
        .imem_req_address(imem_req_address),
        .imem_rsp_valid(imem_rsp_valid),
        .imem_rsp_ready(imem_rsp_ready),
        .imem_rsp_wave_id(imem_rsp_wave_id),
        .imem_rsp_word_index(imem_rsp_word_index),
        .imem_rsp_data(imem_rsp_data),
        .imem_rsp_error(imem_rsp_error),
        .out_valid(fetch_valid),
        .out_ready(fetch_ready),
        .out_wave_id(fetch_wave),
        .out_payload(fetch_payload));
    cdna_decoder #(.NUM_SGPRS(NUM_SGPRS),
        .NUM_VGPRS(NUM_VGPRS),
        .WAVE_ID_BITS(WAVE_ID_BITS)) u_decoder (
        .in_valid(fetch_valid),
        .in_ready(fetch_ready),
        .in_wave_id(fetch_wave),
        .in_payload(fetch_payload),
        .out_valid(decoded_valid),
        .out_ready(decoded_ready),
        .out_wave_id(decoded_wave),
        .out_payload(decoded_payload));
    assign decoded_ready=!verification_decode_stall && ((decoded_payload.fault!=M3_FAULT_NONE)?1'b1:buffer_ready);
    assign decode_fault_valid=decoded_valid && decoded_ready && decoded_payload.fault!=M3_FAULT_NONE;
    wave_instruction_buffer #(.WAVE_ID_BITS(WAVE_ID_BITS),
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS)) u_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .in_valid(decoded_valid && !verification_decode_stall && decoded_payload.fault==M3_FAULT_NONE),
        .in_ready(buffer_ready),
        .in_wave_id(decoded_wave),
        .in_payload(decoded_payload),
        .pop_mask(pop_mask),
        .slot_valid(slot_valid),
        .slots(slots));
    assign execute_issue_fire=collector_valid && collector_ready;
    wave_scoreboard #(.WAVE_ID_BITS(WAVE_ID_BITS),
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS),
        .NUM_SGPRS(NUM_SGPRS),
        .NUM_VGPRS(NUM_VGPRS)) u_scoreboard (
        .clk(clk),
        .rst_n(rst_n),
        .slots(slots),
        .eligible_mask(eligible_mask),
        .sgpr_busy(sgpr_busy),
        .vgpr_busy(vgpr_busy),
        .issue_fire(execute_issue_fire),
        .issue_wave_id(collector_wave),
        .issue_uop(collector_payload.decoded.uop),
        .issue_exec(collector_payload.decoded.context_data.exec_mask[31:0]),
        .clear_valid(clear_valid),
        .clear_wave_id(clear_wave),
        .clear_kind(clear_kind),
        .clear_index(clear_index),
        .clear_count(clear_count),
        .release_valid(release_valid),
        .release_wave_id(release_wave_id));
    assign collector_ready=unit_ready[collector_unit] && !verification_issue_stall[collector_unit];
    wave_operand_collector #(.WAVE_ID_BITS(WAVE_ID_BITS),
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS)) u_collector (
        .clk(clk),
        .rst_n(rst_n),
        .halt(fault_valid),
        .slot_valid(slot_valid),
        .eligible_mask(eligible_mask),
        .slots(slots),
        .unit_ready(unit_ready),
        .pop_mask(pop_mask),
        .sgpr_read_enable(sgpr_read_enable),
        .vgpr_read_enable(vgpr_read_enable),
        .rf_read_wave_id(rf_read_wave),
        .rf_read_index0(rf_read_index0),
        .rf_read_index1(rf_read_index1),
        .rf_read_beat(rf_read_beat),
        .sgpr_read_data0(sgpr_read_data0),
        .sgpr_read_data1(sgpr_read_data1),
        .vgpr_read_data0(vgpr_read_data0),
        .vgpr_read_data1(vgpr_read_data1),
        .out_valid(collector_valid),
        .out_ready(collector_ready),
        .out_wave_id(collector_wave),
        .out_unit(collector_unit),
        .out_payload(collector_payload));
    wave_sgpr_file #(.WAVE_ID_BITS(WAVE_ID_BITS),
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS),
        .NUM_SGPRS(NUM_SGPRS)) u_sgpr (
        .clk(clk),
        .read_enable(sgpr_read_enable),
        .read_wave0(rf_read_wave),
        .read_wave1(rf_read_wave),
        .read_index0(rf_read_index0),
        .read_index1(rf_read_index1),
        .read_data0(sgpr_read_data0),
        .read_data1(sgpr_read_data1),
        .write_enable(sgpr_write_enable),
        .write_wave_id(rf_write_wave),
        .write_index(rf_write_index),
        .write_data(sgpr_write_data));
    wave_vgpr_file #(.WAVE_ID_BITS(WAVE_ID_BITS),
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS),
        .NUM_VGPRS(NUM_VGPRS)) u_vgpr (
        .clk(clk),
        .read_enable(vgpr_read_enable),
        .read_wave0(rf_read_wave),
        .read_wave1(rf_read_wave),
        .read_index0(rf_read_index0),
        .read_index1(rf_read_index1),
        .read_beat(rf_read_beat),
        .read_data0(vgpr_read_data0),
        .read_data1(vgpr_read_data1),
        .write_enable(vgpr_write_enable),
        .write_wave_id(rf_write_wave),
        .write_index(rf_write_index),
        .write_beat(rf_write_beat),
        .write_mask(vgpr_write_mask),
        .write_data(vgpr_write_data));
    wave_salu #(.WAVE_ID_BITS(WAVE_ID_BITS)) u_salu (.clk(clk),
        .rst_n(rst_n),
        .issue_valid(collector_valid && collector_unit==0 && !verification_issue_stall[0]),
        .issue_ready(unit_ready[0]),
        .issue_wave_id(collector_wave),
        .issue_payload(collector_payload),
        .result_valid(result_valid[0]),
        .result_ready(result_ready[0]),
        .result_wave_id(result_wave_ids[0]),
        .result_payload(result_payloads[0]));
    wave_valu #(.WAVE_ID_BITS(WAVE_ID_BITS)) u_valu (.clk(clk),
        .rst_n(rst_n),
        .issue_valid(collector_valid && collector_unit==1 && !verification_issue_stall[1]),
        .issue_ready(unit_ready[1]),
        .issue_wave_id(collector_wave),
        .issue_payload(collector_payload),
        .result_valid(result_valid[1]),
        .result_ready(result_ready[1]),
        .result_wave_id(result_wave_ids[1]),
        .result_payload(result_payloads[1]));
    wave_control_unit #(.WAVE_ID_BITS(WAVE_ID_BITS)) u_control (.clk(clk),
        .rst_n(rst_n),
        .issue_valid(collector_valid && collector_unit==2 && !verification_issue_stall[2]),
        .issue_ready(unit_ready[2]),
        .issue_wave_id(collector_wave),
        .issue_payload(collector_payload),
        .commit_valid(control_valid),
        .commit_ready(control_ready),
        .commit_wave_id(control_wave),
        .commit_payload(control_payload));
    wave_memory_unit #(.WAVE_ID_BITS(WAVE_ID_BITS),
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS),
        .NUM_MEMORY_TAGS(NUM_MEMORY_TAGS),
        .RETURN_FIFO_DEPTH(RETURN_FIFO_DEPTH)) u_memory (
        .clk(clk),
        .rst_n(rst_n),
        .issue_valid(collector_valid && collector_unit==3 && !verification_issue_stall[3]),
        .issue_ready(unit_ready[3]),
        .issue_wave_id(collector_wave),
        .issue_payload(collector_payload),
        .group_segment_bytes(saved_group_segment_bytes),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_wave_id(mem_req_wave_id),
        .mem_req_payload(mem_req_payload),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_payload(mem_rsp_payload),
        .memory_commit_valid(memory_commit_valid),
        .memory_commit_ready(memory_commit_ready),
        .memory_commit_wave_id(memory_commit_wave),
        .memory_commit_payload(memory_commit_payload),
        .result_valid(result_valid[2]),
        .result_ready(result_ready[2]),
        .result_wave_id(result_wave_ids[2]),
        .result_payload(result_payloads[2]),
        .dependency_issue_valid(dependency_issue_valid),
        .dependency_issue_wave_id(dependency_issue_wave_id),
        .dependency_issue_kind(dependency_issue_kind),
        .dependency_complete_valid(dependency_complete_valid),
        .dependency_complete_wave_id(dependency_complete_wave_id),
        .dependency_complete_kind(dependency_complete_kind),
        .fault_valid(memory_fault_valid),
        .fault_wave_id(memory_fault_wave),
        .fault_pc(memory_fault_pc),
        .fault_instruction(memory_fault_instruction),
        .allocated_mask(allocated_tags));
    wave_register_init #(.WAVE_ID_BITS(WAVE_ID_BITS),
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS),
        .NUM_SGPRS(NUM_SGPRS),
        .MAX_GROUP_SEGMENT_BYTES(MAX_GROUP_SEGMENT_BYTES)) u_init (
        .clk(clk),
        .rst_n(rst_n),
        .alloc_fire(alloc_fire),
        .alloc_wave_id(alloc_wave_id),
        .alloc_wave_index(alloc_wave_index),
        .release_valid(release_valid),
        .release_wave_id(release_wave_id),
        .user_sgpr_count(user_sgpr_count),
        .user_sgpr_data(user_sgpr_data),
        .launch_candidate(launch_candidate),
        .launch_start_pc(launch_start_pc),
        .launch_dispatch_index(dispatch_index),
        .launch_group_segment_bytes(group_segment_bytes),
        .launch_config_legal(launch_config_legal),
        .saved_user_sgpr_count(saved_user_sgpr_count),
        .saved_user_sgpr_data(saved_user_sgpr_data),
        .saved_dispatch_index(saved_dispatch_index),
        .saved_group_segment_bytes(saved_group_segment_bytes),
        .decode_fault_valid(decode_fault_valid),
        .decode_fault_wave_id(decoded_wave),
        .decode_fault_code(decoded_payload.fault),
        .decode_fault_pc(decoded_payload.context_data.pc),
        .decode_fault_instruction(decoded_payload.instruction[31:0]),
        .memory_fault_valid(memory_fault_valid),
        .memory_fault_wave_id(memory_fault_wave),
        .memory_fault_pc(memory_fault_pc),
        .memory_fault_instruction(memory_fault_instruction),
        .fault_valid(fault_valid),
        .fault_wave_id(fault_wave_id),
        .fault_code(fault_code),
        .fault_pc(fault_pc),
        .fault_instruction(fault_instruction),
        .rf_initialized_mask(rf_initialized_mask),
        .result_valid(result_valid[3]),
        .result_ready(result_ready[3]),
        .result_wave_id(result_wave_ids[3]),
        .result_payload(result_payloads[3]));
    wave_writeback_commit #(.WAVE_ID_BITS(WAVE_ID_BITS)) u_writeback (
        .clk(clk),
        .rst_n(rst_n),
        .result_valid(result_valid),
        .result_ready(result_ready),
        .result_wave_ids(result_wave_ids),
        .result_payloads(result_payloads),
        .control_valid(control_valid),
        .control_ready(control_ready),
        .control_wave_id(control_wave),
        .control_payload(control_payload),
        .memory_commit_valid(memory_commit_valid),
        .memory_commit_ready(memory_commit_ready),
        .memory_commit_wave_id(memory_commit_wave),
        .memory_commit_payload(memory_commit_payload),
        .sgpr_write_enable(sgpr_write_enable),
        .vgpr_write_enable(vgpr_write_enable),
        .rf_write_wave_id(rf_write_wave),
        .rf_write_index(rf_write_index),
        .rf_write_beat(rf_write_beat),
        .sgpr_write_data(sgpr_write_data),
        .vgpr_write_mask(vgpr_write_mask),
        .vgpr_write_data(vgpr_write_data),
        .clear_valid(clear_valid),
        .clear_wave_id(clear_wave),
        .clear_kind(clear_kind),
        .clear_index(clear_index),
        .clear_count(clear_count),
        .commit_valid(commit_valid),
        .commit_wave_id(commit_wave_id),
        .commit_payload(commit_payload),
        .commit_next_state(commit_next_state),
        .wait_arm_valid(wait_arm_valid),
        .wait_spec(wait_spec),
        .wait_arm_satisfied(wait_arm_satisfied));
endmodule
`default_nettype wire
