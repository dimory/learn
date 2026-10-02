`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU M2 Wave Control Subsystem
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// Structural integration of the five M2 control modules: Dispatcher, Context
// Table, Scheduler, Dependency Tracker and Retire Controller. This module owns
// no registers, counters, lifecycle state or instruction execution logic.
//
// Microarchitecture and event wiring
// -----------------------------------------------------------------------------
// alloc_fire = Dispatcher alloc_valid & Context Table alloc_ready.
// The table selects alloc_wave_id; the same handshake initializes the Tracker.
// schedule_fire = Scheduler selected_valid & execution-port selected_ready.
// The Scheduler ID also selects the Context Table's combinational read port.
// wait_wakeup_mask = waitcnt_mask & wait_satisfied_mask. Both the Context Table
// and Tracker consume this mask, changing WAITCNT to READY and clearing active
// Wait state on the same edge.
// Retire Controller selects one DONE entry with all seven counters zero.
// Its release goes to the table and Tracker; its completion goes to Dispatcher.
//
// Execution and backend interfaces
// -----------------------------------------------------------------------------
// selected_valid/ready and selected_* form the Wave launch interface. Payload
// is consumed only with selected_valid=1; selected_context_valid reports raw
// Context residency and does not create another handshake.
// commit_* is produced by the Wave-tagged execution path. It owns next-state
// selection and architectural write enables. M2 tests supply synthetic events.
// For a Wait commit, the producer supplies wait_arm_valid and the matching ID
// on the same edge as commit_valid, and chooses commit_next_state as READY when
// wait_arm_satisfied=1, otherwise WAITCNT. Wait arm valid must not depend on
// wait_arm_satisfied. This wrapper neither decodes nor generates commits.
// Backend request acceptance supplies dependency_issue_* independently of
// schedule_fire. Completion uses the Wave ID retained by the original request.
// barrier_release_mask is external in M2; the Workgroup controller arrives in M5.
//
// Timing and reset
// -----------------------------------------------------------------------------
// Scalar events are levels sampled once per rising edge. Consecutive asserted
// edges represent consecutive events. Release has no backpressure port.
// Child storage has asynchronous active-low reset. This wrapper passes rst_n
// through and adds no combinational reset gates. The system suppresses external
// events during reset. Allocation does not bypass a same-edge retirement.
//
// Observation ports and verification
// -----------------------------------------------------------------------------
// State masks, handshake events and retirement identity are exposed to the M2
// checker. They are wires from the child modules, without duplicated state.
// All Wave IDs identify resident Context slots, not Workgroup-local indices.
// Counter widths/kinds and lifecycle encodings are defined by gpu_pkg.
// Compile gpu_pkg.sv before the five child modules and this integration module.
// ============================================================================
module wave_control_subsystem #(
    parameter int NUM_WAVE_CONTEXTS = gpu_pkg::CDNA_NUM_RESIDENT_WAVES,
    parameter int THREAD_COUNT_BITS = gpu_pkg::CDNA_THREAD_COUNT_BITS,
    parameter int PC_BITS = gpu_pkg::CDNA_PC_BITS,
    parameter int EXEC_BITS = gpu_pkg::CDNA_EXEC_BITS,
    parameter int VCC_BITS = gpu_pkg::CDNA_VCC_BITS,
    parameter int DATA_BITS = gpu_pkg::CDNA_DATA_BITS,
    parameter int WAVE_SIZE = gpu_pkg::CDNA_WAVE_SIZE,
    parameter int THREADS_PER_WORKGROUP = gpu_pkg::CDNA_THREADS_PER_WORKGROUP,
    parameter int WORKGROUP_ID_BITS = gpu_pkg::CDNA_WORKGROUP_ID_BITS,
    parameter int WG_WAVE_ID_BITS = gpu_pkg::CDNA_WORKGROUP_WAVE_ID_BITS,
    parameter int WG_WAVE_COUNT_BITS = gpu_pkg::CDNA_WORKGROUP_WAVE_COUNT_BITS,
    parameter int GLOBAL_THREAD_ID_BITS = gpu_pkg::CDNA_GLOBAL_THREAD_ID_BITS,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    input logic clk,
    input logic rst_n,

    // Kernel launch, accepted by Dispatcher while idle.
    input logic start,
    input logic [PC_BITS-1:0] start_pc,
    input logic [THREAD_COUNT_BITS-1:0] thread_count,
    output logic busy,
    output logic done,

    // Wave launch to the execution path.
    output logic selected_valid,
    input logic selected_ready,
    output logic [WAVE_ID_BITS-1:0] selected_wave_id,
    output logic selected_context_valid,
    output gpu_pkg::wave_context_state_t selected_state,
    output logic [PC_BITS-1:0] selected_pc,
    output logic [EXEC_BITS-1:0] selected_exec,
    output logic [VCC_BITS-1:0] selected_vcc,
    output logic selected_scc,
    output logic [DATA_BITS-1:0] selected_m0,
    output logic [WORKGROUP_ID_BITS-1:0] selected_workgroup_id,
    output logic [WG_WAVE_ID_BITS-1:0] selected_wave_index,
    output logic [WG_WAVE_COUNT_BITS-1:0] selected_waves_in_workgroup,
    output logic [GLOBAL_THREAD_ID_BITS-1:0] selected_global_thread_base,

    // Architectural commit from execution; one event per edge.
    input logic commit_valid,
    input logic [WAVE_ID_BITS-1:0] commit_wave_id,
    input gpu_pkg::wave_context_state_t commit_next_state,
    input logic commit_pc_write_enable,
    input logic [PC_BITS-1:0] commit_pc,
    input logic commit_exec_write_enable,
    input logic [EXEC_BITS-1:0] commit_exec,
    input logic commit_vcc_write_enable,
    input logic [VCC_BITS-1:0] commit_vcc,
    input logic commit_scc_write_enable,
    input logic commit_scc,
    input logic commit_m0_write_enable,
    input logic [DATA_BITS-1:0] commit_m0,

    // Accepted backend work and asynchronous completion.
    input logic dependency_issue_valid,
    input logic [WAVE_ID_BITS-1:0] dependency_issue_wave_id,
    input gpu_pkg::dependency_kind_t dependency_issue_kind,
    input logic [gpu_pkg::DEPENDENCY_AMOUNT_BITS-1:0] dependency_issue_amount,
    input logic dependency_complete_valid,
    input logic [WAVE_ID_BITS-1:0] dependency_complete_wave_id,
    input gpu_pkg::dependency_kind_t dependency_complete_kind,
    input logic [gpu_pkg::DEPENDENCY_AMOUNT_BITS-1:0] dependency_complete_amount,

    // Wait query/configuration, concurrent with the corresponding Wait commit.
    input logic wait_arm_valid,
    input logic [WAVE_ID_BITS-1:0] wait_arm_wave_id,
    input logic [gpu_pkg::DEPENDENCY_COUNTER_COUNT-1:0] wait_counter_mask,
    input logic [gpu_pkg::CDNA_LOAD_COUNTER_BITS-1:0] wait_load_threshold,
    input logic [gpu_pkg::CDNA_STORE_COUNTER_BITS-1:0] wait_store_threshold,
    input logic [gpu_pkg::CDNA_DS_COUNTER_BITS-1:0] wait_ds_threshold,
    input logic [gpu_pkg::CDNA_KM_COUNTER_BITS-1:0] wait_km_threshold,
    input logic [gpu_pkg::CDNA_ASYNC_COUNTER_BITS-1:0] wait_async_threshold,
    input logic [gpu_pkg::CDNA_TENSOR_COUNTER_BITS-1:0] wait_tensor_threshold,
    input logic [gpu_pkg::CDNA_X_COUNTER_BITS-1:0] wait_x_threshold,
    output logic wait_arm_satisfied,

    // M2 Barrier placeholder, later driven by the Barrier Controller.
    input logic [NUM_WAVE_CONTEXTS-1:0] barrier_release_mask,

    // Observation ports for stage verification and later system integration.
    output logic [NUM_WAVE_CONTEXTS-1:0] free_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0] resident_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0] ready_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0] issued_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0] waitcnt_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0] barrier_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0] done_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0] wait_satisfied_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0] wait_wakeup_mask,
    output logic [NUM_WAVE_CONTEXTS-1:0] all_counters_zero_mask,
    output logic alloc_fire,
    output logic [WAVE_ID_BITS-1:0] alloc_wave_id,
    output logic schedule_fire,
    output logic retire_fire,
    output logic [WAVE_ID_BITS-1:0] retire_wave_id
);
    logic alloc_valid;
    logic alloc_ready;
    logic [PC_BITS-1:0] alloc_start_pc;
    logic [EXEC_BITS-1:0] alloc_initial_exec;
    logic [WORKGROUP_ID_BITS-1:0] alloc_workgroup_id;
    logic [WG_WAVE_ID_BITS-1:0] alloc_wave_index;
    logic [WG_WAVE_COUNT_BITS-1:0] alloc_waves_in_workgroup;
    logic [GLOBAL_THREAD_ID_BITS-1:0] alloc_global_thread_base;
    logic wave_completed;

    assign alloc_fire = alloc_valid && alloc_ready;
    assign schedule_fire = selected_valid && selected_ready;
    assign wait_wakeup_mask = waitcnt_mask & wait_satisfied_mask;

    wave_dispatcher #(
        .THREAD_COUNT_BITS(THREAD_COUNT_BITS), .PC_BITS(PC_BITS),
        .EXEC_BITS(EXEC_BITS), .WAVE_SIZE(WAVE_SIZE),
        .THREADS_PER_WORKGROUP(THREADS_PER_WORKGROUP),
        .WORKGROUP_ID_BITS(WORKGROUP_ID_BITS), .WG_WAVE_ID_BITS(WG_WAVE_ID_BITS),
        .WG_WAVE_COUNT_BITS(WG_WAVE_COUNT_BITS),
        .GLOBAL_THREAD_ID_BITS(GLOBAL_THREAD_ID_BITS)
    ) u_dispatcher (
        .clk(clk), .rst_n(rst_n), .start(start), .start_pc(start_pc),
        .thread_count(thread_count), .busy(busy), .done(done),
        .wave_completed(wave_completed),
        .alloc_valid(alloc_valid), .alloc_ready(alloc_ready),
        .alloc_start_pc(alloc_start_pc), .alloc_initial_exec(alloc_initial_exec),
        .alloc_workgroup_id(alloc_workgroup_id), .alloc_wave_index(alloc_wave_index),
        .alloc_waves_in_workgroup(alloc_waves_in_workgroup),
        .alloc_global_thread_base(alloc_global_thread_base)
    );

    wave_context_table #(
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS), .WAVE_ID_BITS(WAVE_ID_BITS),
        .PC_BITS(PC_BITS), .EXEC_BITS(EXEC_BITS), .VCC_BITS(VCC_BITS),
        .DATA_BITS(DATA_BITS), .WORKGROUP_ID_BITS(WORKGROUP_ID_BITS),
        .WG_WAVE_ID_BITS(WG_WAVE_ID_BITS), .WG_WAVE_COUNT_BITS(WG_WAVE_COUNT_BITS),
        .GLOBAL_THREAD_ID_BITS(GLOBAL_THREAD_ID_BITS)
    ) u_context_table (
        .clk(clk), .rst_n(rst_n),
        .alloc_valid(alloc_valid), .alloc_ready(alloc_ready), .alloc_wave_id(alloc_wave_id),
        .alloc_start_pc(alloc_start_pc), .alloc_initial_exec(alloc_initial_exec),
        .alloc_workgroup_id(alloc_workgroup_id), .alloc_wave_index(alloc_wave_index),
        .alloc_waves_in_workgroup(alloc_waves_in_workgroup),
        .alloc_global_thread_base(alloc_global_thread_base),
        .issue_valid(schedule_fire), .issue_wave_id(selected_wave_id),
        .commit_valid(commit_valid), .commit_wave_id(commit_wave_id),
        .commit_next_state(commit_next_state),
        .commit_pc_write_enable(commit_pc_write_enable), .commit_pc(commit_pc),
        .commit_exec_write_enable(commit_exec_write_enable), .commit_exec(commit_exec),
        .commit_vcc_write_enable(commit_vcc_write_enable), .commit_vcc(commit_vcc),
        .commit_scc_write_enable(commit_scc_write_enable), .commit_scc(commit_scc),
        .commit_m0_write_enable(commit_m0_write_enable), .commit_m0(commit_m0),
        .wait_wakeup_mask(wait_wakeup_mask), .barrier_release_mask(barrier_release_mask),
        .release_valid(retire_fire), .release_wave_id(retire_wave_id),
        .read_wave_id(selected_wave_id), .read_valid(selected_context_valid),
        .read_state(selected_state), .read_pc(selected_pc), .read_exec(selected_exec),
        .read_vcc(selected_vcc), .read_scc(selected_scc), .read_m0(selected_m0),
        .read_workgroup_id(selected_workgroup_id), .read_wave_index(selected_wave_index),
        .read_waves_in_workgroup(selected_waves_in_workgroup),
        .read_global_thread_base(selected_global_thread_base),
        .free_mask(free_mask), .resident_mask(resident_mask), .ready_mask(ready_mask),
        .issued_mask(issued_mask), .waitcnt_mask(waitcnt_mask),
        .barrier_mask(barrier_mask), .done_mask(done_mask)
    );

    wave_scheduler #(
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS), .WAVE_ID_BITS(WAVE_ID_BITS)
    ) u_scheduler (
        .clk(clk), .rst_n(rst_n), .ready_mask(ready_mask),
        .selected_valid(selected_valid), .selected_ready(selected_ready),
        .selected_wave_id(selected_wave_id)
    );

    wave_dependency_tracker #(
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS), .WAVE_ID_BITS(WAVE_ID_BITS)
    ) u_dependency_tracker (
        .clk(clk), .rst_n(rst_n), .resident_mask(resident_mask),
        .alloc_fire(alloc_fire), .alloc_wave_id(alloc_wave_id),
        .release_valid(retire_fire), .release_wave_id(retire_wave_id),
        .dependency_issue_valid(dependency_issue_valid),
        .dependency_issue_wave_id(dependency_issue_wave_id),
        .dependency_issue_kind(dependency_issue_kind),
        .dependency_issue_amount(dependency_issue_amount),
        .dependency_complete_valid(dependency_complete_valid),
        .dependency_complete_wave_id(dependency_complete_wave_id),
        .dependency_complete_kind(dependency_complete_kind),
        .dependency_complete_amount(dependency_complete_amount),
        .wait_arm_valid(wait_arm_valid), .wait_arm_wave_id(wait_arm_wave_id),
        .wait_counter_mask(wait_counter_mask),
        .wait_load_threshold(wait_load_threshold), .wait_store_threshold(wait_store_threshold),
        .wait_ds_threshold(wait_ds_threshold), .wait_km_threshold(wait_km_threshold),
        .wait_async_threshold(wait_async_threshold), .wait_tensor_threshold(wait_tensor_threshold),
        .wait_x_threshold(wait_x_threshold), .wait_arm_satisfied(wait_arm_satisfied),
        .wait_wakeup_mask(wait_wakeup_mask), .wait_satisfied_mask(wait_satisfied_mask),
        .all_counters_zero_mask(all_counters_zero_mask)
    );

    wave_retire_controller #(
        .NUM_WAVE_CONTEXTS(NUM_WAVE_CONTEXTS), .WAVE_ID_BITS(WAVE_ID_BITS)
    ) u_retire_controller (
        .done_mask(done_mask), .all_counters_zero_mask(all_counters_zero_mask),
        .release_valid(retire_fire), .release_wave_id(retire_wave_id),
        .wave_completed(wave_completed)
    );
endmodule

`default_nettype wire
