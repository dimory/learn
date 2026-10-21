`default_nettype none
`timescale 1ns/1ns
// ============================================================================
// TinyGPU M3 Multi-Wave Compute Top (T02)
// ============================================================================
// Function
// -----------------------------------------------------------------------------
// Join the existing M2 lifecycle controller and the real M3 execution path.
// The external environment supplies launch descriptors and imem/data responses;
// all normal commit, Wait and dependency events originate in execution RTL.
//
// Launch and initialization
// -----------------------------------------------------------------------------
// A start candidate is accepted only while Dispatcher is idle and not done or
// faulted. Init checks/saves User SGPR, PC, dispatch and LDS configuration.
// Legal start drives Dispatcher. Allocation sends the resident ID and local
// Wave index to Init. Scheduler candidates are ready_mask & initialized & !fault.
// This filter precedes round-robin selection; uninitialized slots cannot lock it.
//
// Context, dependency and retirement wiring
// -----------------------------------------------------------------------------
// Context Table supplies the selected architectural snapshot; saved dispatch
// index supplies TTMP8 metadata. Fetch acceptance performs READY -> ISSUED.
// Writeback's single commit updates PC/special state and READY/WAITCNT/DONE.
// Memory accept/ordered completion drive Tracker with amount=1 independently.
// Wait-arm uses the same commit Wave ID; the seven thresholds are unpacked
// directly from wait_spec. Tracker wakes saved waits after their conditions hold.
// M2 retires only DONE entries whose dependency counters are all zero. Release
// clears Init/Scoreboard ownership. No real Barrier producer exists in M3.
//
// Timing, reset and backend contract
// -----------------------------------------------------------------------------
// All events are sampled at rising edges; valid/payload remain held on stalls.
// The wrapper is combinational wiring only, with no duplicate lifecycle state.
// Reset must flush both this compute block and the external tagged backends.
// RF contents are not reset; programs may read only architecturally defined data.
// busy is Dispatcher progress; done is successful completion suppressed by fault.
// ============================================================================
module wave_compute_top #(
    parameter int NUM_WAVE_CONTEXTS = 4,
    parameter int THREADS_PER_WORKGROUP = 64,
    parameter int NUM_SGPRS = 32,
    parameter int NUM_VGPRS = 64,
    parameter int NUM_MEMORY_TAGS = 16,
    parameter int RETURN_FIFO_DEPTH = 4,
    parameter int MAX_GROUP_SEGMENT_BYTES = 4096,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    input logic clk,
    input logic rst_n,
    input logic start,
    input logic [63:0] start_pc,
    input logic [31:0] thread_count,
    input logic [5:0] launch_user_sgpr_count,
    input logic [1023:0] launch_user_sgpr_data,
    input logic [24:0] launch_dispatch_index,
    input logic [31:0] launch_group_segment_bytes,
    output logic busy,
    output logic done,
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
    input gpu_pkg::m3_memory_response_t mem_rsp_payload
);
    import gpu_pkg::*;
    logic control_busy,control_done,launch_candidate,launch_config_legal;
    logic selected_valid,selected_ready,selected_context_valid;
    logic [WAVE_ID_BITS-1:0] selected_wave_id,commit_wave_id,alloc_wave_id,retire_wave_id;
    wave_context_state_t selected_state,commit_next_state;
    m3_context_t selected_context;
    m3_commit_t commit_payload;
    logic commit_valid,wait_arm_valid,wait_arm_satisfied;
    m3_wait_spec_t wait_spec;
    logic dependency_issue_valid,dependency_complete_valid;
    logic [WAVE_ID_BITS-1:0] dependency_issue_wave_id,dependency_complete_wave_id;
    dependency_kind_t dependency_issue_kind,dependency_complete_kind;
    logic [NUM_WAVE_CONTEXTS-1:0] rf_initialized_mask,schedule_enable_mask;
    logic [NUM_WAVE_CONTEXTS-1:0] free_mask,resident_mask,ready_mask,issued_mask,waitcnt_mask,barrier_mask,done_mask;
    logic [NUM_WAVE_CONTEXTS-1:0] wait_satisfied_mask,wait_wakeup_mask,all_counters_zero_mask;
    logic alloc_fire,schedule_fire,retire_fire;
    logic [31:0] alloc_workgroup_id;
    logic [4:0] alloc_wave_index;
    logic [24:0] saved_dispatch_index;
    assign launch_candidate=start && !control_busy && !control_done && !fault_valid;
    assign busy=control_busy;
    assign done=control_done && !fault_valid;
    assign schedule_enable_mask=rf_initialized_mask & {NUM_WAVE_CONTEXTS{!fault_valid}};
    assign selected_context.dispatch_index=saved_dispatch_index;
    wave_control_subsystem #(.WAVE_ID_BITS(WAVE_ID_BITS),
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS),
        .THREADS_PER_WORKGROUP(THREADS_PER_WORKGROUP)) u_control (
        .clk(clk),
        .rst_n(rst_n),
        .start(start && launch_config_legal && !fault_valid),
        .start_pc(start_pc),
        .thread_count(thread_count),
        .busy(control_busy),
        .done(control_done),
        .selected_valid(selected_valid),
        .selected_ready(selected_ready),
        .schedule_enable_mask(schedule_enable_mask),
        .selected_wave_id(selected_wave_id),
        .selected_context_valid(selected_context_valid),
        .selected_state(selected_state),
        .selected_pc(selected_context.pc),
        .selected_exec(selected_context.exec_mask),
        .selected_vcc(selected_context.vcc),
        .selected_scc(selected_context.scc),
        .selected_m0(selected_context.m0),
        .selected_workgroup_id(selected_context.workgroup_id),
        .selected_wave_index(selected_context.wave_index),
        .selected_waves_in_workgroup(selected_context.waves_in_workgroup),
        .selected_global_thread_base(selected_context.global_thread_base),
        .commit_valid(commit_valid),
        .commit_wave_id(commit_wave_id),
        .commit_next_state(commit_next_state),
        .commit_pc_write_enable(1'b1),
        .commit_pc(commit_payload.next_pc),
        .commit_exec_write_enable(commit_payload.exec_write),
        .commit_exec(commit_payload.exec_data),
        .commit_vcc_write_enable(commit_payload.vcc_write),
        .commit_vcc(commit_payload.vcc_data),
        .commit_scc_write_enable(commit_payload.scc_write),
        .commit_scc(commit_payload.scc_data),
        .commit_m0_write_enable(commit_payload.m0_write),
        .commit_m0(commit_payload.m0_data),
        .dependency_issue_valid(dependency_issue_valid),
        .dependency_issue_wave_id(dependency_issue_wave_id),
        .dependency_issue_kind(dependency_issue_kind),
        .dependency_issue_amount(dependency_amount_t'(1)),
        .dependency_complete_valid(dependency_complete_valid),
        .dependency_complete_wave_id(dependency_complete_wave_id),
        .dependency_complete_kind(dependency_complete_kind),
        .dependency_complete_amount(dependency_amount_t'(1)),
        .wait_arm_valid(wait_arm_valid),
        .wait_arm_wave_id(commit_wave_id),
        .wait_counter_mask(wait_spec.mask),
        .wait_load_threshold(wait_spec.load_threshold),
        .wait_store_threshold(wait_spec.store_threshold),
        .wait_ds_threshold(wait_spec.ds_threshold),
        .wait_km_threshold(wait_spec.km_threshold),
        .wait_async_threshold(wait_spec.async_threshold),
        .wait_tensor_threshold(wait_spec.tensor_threshold),
        .wait_x_threshold(wait_spec.x_threshold),
        .wait_arm_satisfied(wait_arm_satisfied),
        .barrier_release_mask({NUM_WAVE_CONTEXTS{1'b0}}),
        .free_mask(free_mask),
        .resident_mask(resident_mask),
        .ready_mask(ready_mask),
        .issued_mask(issued_mask),
        .waitcnt_mask(waitcnt_mask),
        .barrier_mask(barrier_mask),
        .done_mask(done_mask),
        .wait_satisfied_mask(wait_satisfied_mask),
        .wait_wakeup_mask(wait_wakeup_mask),
        .all_counters_zero_mask(all_counters_zero_mask),
        .alloc_fire(alloc_fire),
        .alloc_wave_id(alloc_wave_id),
        .alloc_workgroup_id_out(alloc_workgroup_id),
        .alloc_wave_index_out(alloc_wave_index),
        .schedule_fire(schedule_fire),
        .retire_fire(retire_fire),
        .retire_wave_id(retire_wave_id));
    wave_execution_subsystem #(.WAVE_ID_BITS(WAVE_ID_BITS),
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS),
        .NUM_SGPRS(NUM_SGPRS),
        .NUM_VGPRS(NUM_VGPRS),
        .NUM_MEMORY_TAGS(NUM_MEMORY_TAGS),
        .RETURN_FIFO_DEPTH(RETURN_FIFO_DEPTH),
        .MAX_GROUP_SEGMENT_BYTES(MAX_GROUP_SEGMENT_BYTES)) u_execution (
        .clk(clk),
        .rst_n(rst_n),
        .selected_valid(selected_valid),
        .selected_ready(selected_ready),
        .selected_wave_id(selected_wave_id),
        .selected_context(selected_context),
        .alloc_fire(alloc_fire),
        .alloc_wave_id(alloc_wave_id),
        .alloc_wave_index(alloc_wave_index),
        .release_valid(retire_fire),
        .release_wave_id(retire_wave_id),
        .launch_candidate(launch_candidate),
        .launch_start_pc(start_pc),
        .user_sgpr_count(launch_user_sgpr_count),
        .user_sgpr_data(launch_user_sgpr_data),
        .dispatch_index(launch_dispatch_index),
        .group_segment_bytes(launch_group_segment_bytes),
        .launch_config_legal(launch_config_legal),
        .saved_dispatch_index(saved_dispatch_index),
        .rf_initialized_mask(rf_initialized_mask),
        .fault_valid(fault_valid),
        .fault_wave_id(fault_wave_id),
        .fault_code(fault_code),
        .fault_pc(fault_pc),
        .fault_instruction(fault_instruction),
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
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_wave_id(mem_req_wave_id),
        .mem_req_payload(mem_req_payload),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_payload(mem_rsp_payload),
        .commit_valid(commit_valid),
        .commit_wave_id(commit_wave_id),
        .commit_payload(commit_payload),
        .commit_next_state(commit_next_state),
        .dependency_issue_valid(dependency_issue_valid),
        .dependency_issue_wave_id(dependency_issue_wave_id),
        .dependency_issue_kind(dependency_issue_kind),
        .dependency_complete_valid(dependency_complete_valid),
        .dependency_complete_wave_id(dependency_complete_wave_id),
        .dependency_complete_kind(dependency_complete_kind),
        .wait_arm_valid(wait_arm_valid),
        .wait_spec(wait_spec),
        .wait_arm_satisfied(wait_arm_satisfied));
endmodule
`default_nettype wire
