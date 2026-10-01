`default_nettype none
`timescale 1ns/1ns
//输出信号	下游需要它做什么
//alloc_start_pc	知道这个 Wave 从哪条指令开始执行
//alloc_initial_exec	知道哪些 Lane 有效
//alloc_workgroup_id	知道这个 Wave 属于哪个 Workgroup
//alloc_wave_index	知道它是 Workgroup 内的第几个 Wave
//alloc_waves_in_workgroup	知道所属 Workgroup 总共有几个 Wave
//alloc_global_thread_base	知道这个 Wave 的 Lane0 对应哪个全局线程


// ============================================================================
// TinyGPU M2 Wave Dispatcher
// ============================================================================
//
// Function
// -----------------------------------------------------------------------------
// This module accepts one one-dimensional Kernel launch and converts its
// thread range into a sequence of Workgroup/Wave32 descriptors.
//
// Each descriptor is allocated into one FREE entry of wave_context_table by a
// valid/ready handshake. The Dispatcher may continue generating descriptors as
// completed Waves are retired and Context entries become FREE again.
//
// The Dispatcher counts completed Waves and produces one done pulse only after
// every Wave belonging to the active Kernel has been allocated and retired.
//
// This module does not select a resident Wave for execution and does not store
// runtime PC, EXEC, VCC, SCC, M0 or dependency-counter state.
//
// Microarchitecture
// -----------------------------------------------------------------------------
//
//                         TinyGPU M2 Wave Dispatcher
// ┌──────────────────────────────────────────────────────────────────────────┐
// │                                                                          │
// │  start, start_pc, thread_count                                           │
// │                  │                                                       │
// │                  ▼                                                       │
// │  ┌───────────────────────────────┐                                       │
// │  │ Kernel Context Registers      │                                       │
// │  │ saved_start_pc                │                                       │
// │  │ saved_thread_count            │                                       │
// │  └───────────────┬───────────────┘                                       │
// │                  │                                                       │
// │                  ▼                                                       │
// │  ┌───────────────────────────────┐                                       │
// │  │ Dispatch Cursors              │                                       │
// │  │ workgroup_cursor              │                                       │
// │  │ wave_cursor                   │                                       │
// │  └───────────────┬───────────────┘                                       │
// │                  │                                                       │
// │                  ▼                                                       │
// │  ┌───────────────────────────────┐                                       │
// │  │ Descriptor Calculation        │                                       │
// │  │ workgroup metadata            │                                       │
// │  │ global_thread_base            │                                       │
// │  │ active lanes -> initial EXEC  │                                       │
// │  └───────────────┬───────────────┘                                       │
// │                  │                                                       │
// │     alloc_valid  │ descriptor                            alloc_ready     │
// │                  ├───────────────────────────────────────────►           │
// │                  │                                                       │
// │                  ▼                                                       │
// │             alloc_fire                                                   │
// │                  │                                                       │
// │                  ▼                                                       │
// │  ┌───────────────────────────────┐       wave_completed                  │
// │  │ Dispatch/Completion Counters  │◄──────────────────────────            │
// │  │ waves_dispatched              │                                       │
// │  │ waves_completed               │──── busy, done                        │
// │  └───────────────────────────────┘                                       │
// │                                                                          │
// └──────────────────────────────────────────────────────────────────────────┘
//
// Kernel launch interface
// -----------------------------------------------------------------------------
//
// Signal          Meaning
// --------------  ------------------------------------------------------------
// start           One-cycle Kernel launch pulse; accepted only in IDLE.
// start_pc        Byte address of the first Kernel instruction.
// thread_count    Total number of threads in the one-dimensional Kernel.
// busy            One Kernel is currently owned by the Dispatcher.
// done            One-cycle pulse after all Waves have been safely retired.
//
// start_pc and thread_count are captured when start is accepted. External
// launch inputs may change after that edge without changing the active Kernel.
// A start pulse received while the Dispatcher is not IDLE is ignored.
//
// Thread-count-zero behavior
// -----------------------------------------------------------------------------
//
// If start is accepted with thread_count == 0:
//
// - no Wave descriptor is generated;
// - no Context entry is allocated;
// - the Dispatcher enters DONE and produces one done pulse.
//
// Workgroup and Wave decomposition
// -----------------------------------------------------------------------------
//
// M2 uses a fixed one-dimensional Workgroup size and logical Wave32.
//
//     total_workgroups = ceil(thread_count / THREADS_PER_WORKGROUP)
//
// For Workgroup G:
//
//     workgroup_thread_base = G * THREADS_PER_WORKGROUP
//
//     valid_threads_in_workgroup =
//         min(THREADS_PER_WORKGROUP,
//             thread_count - workgroup_thread_base)
//
//     waves_in_workgroup =
//         ceil(valid_threads_in_workgroup / WAVE_SIZE)
//
// For Wave W inside Workgroup G:
//
//     global_thread_base =
//         workgroup_thread_base + W * WAVE_SIZE
//
//     active_lanes =
//         min(WAVE_SIZE, valid_threads_in_workgroup - wave_thread_offset)
//
// The implementation must keep Workgroup boundaries. A partial Wave at the end
// of one Workgroup is not merged with threads from the following Workgroup.
//
// Descriptor example
// -----------------------------------------------------------------------------
//
// THREADS_PER_WORKGROUP = 64, WAVE_SIZE = 32, thread_count = 70
//
// Descriptor   workgroup_id   wave_index   global_base   initial EXEC[31:0]
// -----------  -------------  -----------  ------------  --------------------
// Wave 0       0              0            0             32'hffff_ffff
// Wave 1       0              1            32            32'hffff_ffff
// Wave 2       1              0            64            32'h0000_003f
//
// Initial EXEC generation
// -----------------------------------------------------------------------------
//
// Lane 0 is stored in alloc_initial_exec[0]. For every logical lane:
//
//     alloc_initial_exec[lane] = (lane < active_lanes)
//
// M2 uses Wave32, so EXEC[31:0] contains the active-lane mask. EXEC[63:32]
// remains zero in the default 64-bit architectural representation.
//
// Allocation handshake
// -----------------------------------------------------------------------------
//
//     alloc_fire = alloc_valid && alloc_ready
//
// alloc_valid is asserted while RUN has a descriptor that has not yet been
// allocated. alloc_ready is supplied by wave_context_table.
//
// The following outputs form one descriptor and must remain stable whenever
// alloc_valid == 1 and alloc_ready == 0:
//
// - alloc_start_pc
// - alloc_initial_exec
// - alloc_workgroup_id
// - alloc_wave_index
// - alloc_waves_in_workgroup
// - alloc_global_thread_base
//
// Descriptor stability follows from advancing the Workgroup/Wave cursors only
// on alloc_fire.
//
// Cursor update rules
// -----------------------------------------------------------------------------
//
// Accepted descriptor                         Cursor action
// ------------------------------------------  --------------------------------
// Not the last Wave in its Workgroup          wave_cursor += 1
// Last Wave in WG, but not last in Kernel      workgroup_cursor += 1;
//                                             wave_cursor = 0
// Last Wave in the Kernel                      dispatch_finished = 1
//
// dispatch_finished prevents another descriptor from being generated while
// previously allocated Waves are still running or waiting for retirement.
//
// Completion tracking
// -----------------------------------------------------------------------------
//
// wave_completed is a one-cycle pulse from wave_retire_controller. It means
// one DONE Wave has reached zero outstanding dependencies and its Context entry
// has been released.
//
// A completion is accepted only while RUN and only when:
//
//     waves_completed < waves_dispatched
//
// This prevents an idle or stale completion pulse from corrupting the count.
// The wave_id is not required here because the Dispatcher counts completed
// Waves; the Context Table and Dependency Tracker handle identity and release.
//
// Kernel completion
// -----------------------------------------------------------------------------
//
// The Kernel completes when:
//
// - dispatch_finished is already set;
// - an accepted wave_completed pulse retires the final outstanding Wave;
// - after accepting that pulse, waves_completed equals waves_dispatched.
//
// The state then enters DISPATCH_DONE for one cycle. done is asserted only in
// DISPATCH_DONE, after which the Dispatcher returns to DISPATCH_IDLE.
//
// FSM states
// -----------------------------------------------------------------------------
//
// State             Operation
// ----------------  ----------------------------------------------------------
// DISPATCH_IDLE     Wait for a Kernel start pulse.
// DISPATCH_RUN      Generate descriptors and count safely retired Waves.
// DISPATCH_DONE     Assert done for one cycle, then return to IDLE.
//
// FSM transitions
// -----------------------------------------------------------------------------
//
// Current state    Condition                                      Next state
// ---------------  ---------------------------------------------  -------------
// IDLE             start && thread_count != 0                     RUN
// IDLE             start && thread_count == 0                     DONE
// IDLE             otherwise                                      IDLE
// RUN              final accepted completion                      DONE
// RUN              otherwise                                      RUN
// DONE             unconditional                                  IDLE
//
// Same-cycle events
// -----------------------------------------------------------------------------
//
// alloc_fire and wave_completed may occur in the same cycle. They update the
// dispatched and completed counters independently. The final newly allocated
// Wave cannot also retire on its allocation edge, so Kernel completion is
// detected from a completion after dispatch_finished has been registered.
//
// Reset behavior
// -----------------------------------------------------------------------------
//
// rst_n is an asynchronous active-low reset.
//
// On reset:
//
// - dispatcher_state      = DISPATCH_IDLE
// - saved launch context  = 0
// - both cursors           = 0
// - dispatch_finished     = 0
// - dispatch counters     = 0
//
// Module summary and future upgrades
// -----------------------------------------------------------------------------
//
// This module converts one Kernel launch into stable Wave32 allocation
// descriptors and detects Kernel completion from safe Wave retirement. Future
// milestones can replace the single active Kernel registers with a dispatch
// queue, add 2D/3D Workgroup coordinates, resource admission, several CUs/WGPs
// and multiple concurrent Kernels without changing the Context lifecycle.
// ============================================================================

module wave_dispatcher #(
    parameter int THREAD_COUNT_BITS = gpu_pkg::CDNA_THREAD_COUNT_BITS,
    parameter int PC_BITS = gpu_pkg::CDNA_PC_BITS,
    parameter int EXEC_BITS = gpu_pkg::CDNA_EXEC_BITS,
    parameter int WAVE_SIZE = gpu_pkg::CDNA_WAVE_SIZE,
    parameter int THREADS_PER_WORKGROUP =
        gpu_pkg::CDNA_THREADS_PER_WORKGROUP,
    parameter int WORKGROUP_ID_BITS = gpu_pkg::CDNA_WORKGROUP_ID_BITS,
    parameter int WG_WAVE_ID_BITS = gpu_pkg::CDNA_WORKGROUP_WAVE_ID_BITS,
    parameter int WG_WAVE_COUNT_BITS =
        gpu_pkg::CDNA_WORKGROUP_WAVE_COUNT_BITS,
    parameter int GLOBAL_THREAD_ID_BITS =
        gpu_pkg::CDNA_GLOBAL_THREAD_ID_BITS
) (
    input  logic                              clk,
    input  logic                              rst_n,

    // One-dimensional Kernel launch
    input  logic                              start,
    input  logic [PC_BITS-1:0]                start_pc,
    input  logic [THREAD_COUNT_BITS-1:0]      thread_count,

    // Safe Wave retirement notification
    input  logic                              wave_completed,

    // Kernel status
    output logic                              busy,
    output logic                              done,

    // Wave descriptor allocation into wave_context_table
    output logic                              alloc_valid,
    input  logic                              alloc_ready,
    output logic [PC_BITS-1:0]                alloc_start_pc,
    output logic [EXEC_BITS-1:0]              alloc_initial_exec,
    output logic [WORKGROUP_ID_BITS-1:0]      alloc_workgroup_id,
    output logic [WG_WAVE_ID_BITS-1:0]        alloc_wave_index,
    output logic [WG_WAVE_COUNT_BITS-1:0]     alloc_waves_in_workgroup,
    output logic [GLOBAL_THREAD_ID_BITS-1:0]  alloc_global_thread_base
);

// ============================================================================
// Local parameters
// ============================================================================

localparam logic [1:0] DISPATCH_IDLE = 2'b00;
localparam logic [1:0] DISPATCH_RUN  = 2'b01;
localparam logic [1:0] DISPATCH_DONE = 2'b10;

localparam int EVENT_COUNT_BITS = THREAD_COUNT_BITS + 1;
localparam int CALC_BITS        = THREAD_COUNT_BITS + 1;

localparam logic [CALC_BITS-1:0] WAVE_SIZE_EXTENDED = WAVE_SIZE;
localparam logic [CALC_BITS-1:0] THREADS_PER_WORKGROUP_EXTENDED =
    THREADS_PER_WORKGROUP;

// ============================================================================
// Kernel state and dispatch cursors
// ============================================================================

logic [1:0]                         dispatcher_state;
logic [1:0]                         dispatcher_state_next;
logic [PC_BITS-1:0]                 saved_start_pc;
logic [THREAD_COUNT_BITS-1:0]       saved_thread_count;

logic [WORKGROUP_ID_BITS-1:0]       workgroup_cursor;
logic [WG_WAVE_ID_BITS-1:0]         wave_cursor;
logic                               dispatch_finished;

logic [EVENT_COUNT_BITS-1:0]        waves_dispatched;
logic [EVENT_COUNT_BITS-1:0]        waves_completed;

// ============================================================================
// Descriptor calculation signals
// ============================================================================

logic [CALC_BITS-1:0]               saved_thread_count_extended;
logic [CALC_BITS-1:0]               workgroup_cursor_extended;
logic [CALC_BITS-1:0]               wave_cursor_extended;

logic [CALC_BITS-1:0]               workgroup_thread_base;
logic [CALC_BITS-1:0]               kernel_threads_at_workgroup;
logic [CALC_BITS-1:0]               valid_threads_in_workgroup;
logic [CALC_BITS-1:0]               waves_in_workgroup_extended;

logic [CALC_BITS-1:0]               wave_thread_offset;
logic [CALC_BITS-1:0]               global_thread_base_extended;
logic [CALC_BITS-1:0]               kernel_threads_at_wave;
logic [CALC_BITS-1:0]               active_lanes_extended;

logic [EXEC_BITS-1:0]               initial_exec_comb;

logic                               last_wave_in_workgroup;
logic                               last_wave_in_kernel;

// ============================================================================
// Event signals
// ============================================================================

logic                               alloc_fire;
logic                               wave_completed_accepted;
logic                               final_completion;

integer lane_comb;

// 由你实现
assign saved_thread_count_extended = saved_thread_count;  //总线程数
assign workgroup_cursor_extended = workgroup_cursor; //第几个workgroup
assign wave_cursor_extended = wave_cursor; //第几个wave

assign workgroup_thread_base = 
			workgroup_cursor_extended * THREADS_PER_WORKGROUP_EXTENDED; //每个workgroup的线程起始
assign kernel_threads_at_workgroup =
			(saved_thread_count_extended > workgroup_thread_base ) ?
			(saved_thread_count_extended - workgroup_thread_base) : '0;//当前kernel剩多少thread没处理（包括现在正在dispatch的worgroup）
assign valid_threads_in_workgroup = 
			(kernel_threads_at_workgroup > THREADS_PER_WORKGROUP_EXTENDED) ?
			THREADS_PER_WORKGROUP_EXTENDED : kernel_threads_at_workgroup;//当前workgroup需要多少valid thread
assign waves_in_workgroup_extended = 
			(valid_threads_in_workgroup + WAVE_SIZE_EXTENDED - 1'b1)/ WAVE_SIZE_EXTENDED; //需要几个wave当前workgroup
assign wave_thread_offset = 
			wave_cursor_extended * WAVE_SIZE_EXTENDED;
assign global_thread_base_extended = 
			workgroup_thread_base + wave_thread_offset;
assign kernel_threads_at_wave = 
			(valid_threads_in_workgroup > wave_thread_offset) ? 
			valid_threads_in_workgroup - wave_thread_offset : '0; //当前workgroup中，还剩多少thread没处理（包含当前dispatch的wave）
assign active_lanes_extended = 
			(kernel_threads_at_wave > WAVE_SIZE_EXTENDED) ?
			WAVE_SIZE_EXTENDED : kernel_threads_at_wave;

always_comb begin
	initial_exec_comb = '0;
	for (lane_comb = 0; 
		 lane_comb < WAVE_SIZE; 
		 lane_comb = lane_comb + 1) begin
		if (lane_comb < active_lanes_extended)
			initial_exec_comb[lane_comb] = 1'b1;
	end
end

assign last_wave_in_workgroup =
    (waves_in_workgroup_extended != '0) &&
    ((wave_cursor_extended + 1'b1) >= waves_in_workgroup_extended);

assign last_wave_in_kernel =
    (active_lanes_extended != '0) &&
    ((global_thread_base_extended + active_lanes_extended)
        >= saved_thread_count_extended);

assign busy = (dispatcher_state == DISPATCH_RUN);
assign done = (dispatcher_state == DISPATCH_DONE);

assign alloc_valid =
    (dispatcher_state == DISPATCH_RUN) &&
    !dispatch_finished;

assign alloc_fire = alloc_valid && alloc_ready;

assign alloc_start_pc           = saved_start_pc;
assign alloc_initial_exec       = initial_exec_comb;
assign alloc_workgroup_id       = workgroup_cursor;
assign alloc_wave_index         = wave_cursor;
assign alloc_waves_in_workgroup =
    waves_in_workgroup_extended[WG_WAVE_COUNT_BITS-1:0];
assign alloc_global_thread_base =
    global_thread_base_extended[GLOBAL_THREAD_ID_BITS-1:0];

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		workgroup_cursor <= '0;
		wave_cursor      <= '0;
		dispatch_finished<= '0;
	end
	else if ((dispatcher_state == DISPATCH_IDLE) && start)begin
		workgroup_cursor <= '0;
		wave_cursor      <= '0;
		dispatch_finished<= '0;	
	end
	else if (alloc_fire)begin
		if(last_wave_in_kernel)
			dispatch_finished <= 1'b1;
		else if (last_wave_in_workgroup)begin
			workgroup_cursor <= workgroup_cursor + 1'b1;
			wave_cursor <= '0;
		end
		else begin
			wave_cursor <= wave_cursor + 1'b1;
		end
	end
end

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)begin
		saved_start_pc <= '0;
		saved_thread_count <= '0;
	end
	else if ((dispatcher_state == DISPATCH_IDLE) && start)begin
			saved_start_pc <= start_pc;
			saved_thread_count <= thread_count;
	end
end

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        dispatcher_state <= DISPATCH_IDLE;
    else
        dispatcher_state <= dispatcher_state_next;
end

always_comb begin
	dispatcher_state_next = DISPATCH_IDLE;
	case (dispatcher_state) 
		DISPATCH_IDLE : begin
			if (start && (|thread_count))
				dispatcher_state_next = DISPATCH_RUN;
			else if (start && !(|thread_count))
				dispatcher_state_next = DISPATCH_DONE;
		end
		DISPATCH_RUN  : begin
			if (final_completion) 
				dispatcher_state_next = DISPATCH_DONE;	
			else 
				dispatcher_state_next = DISPATCH_RUN;
		end
		DISPATCH_DONE : begin
			dispatcher_state_next = DISPATCH_IDLE;
		end
	
	endcase

end

always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)
		waves_dispatched <= '0;
	else if (alloc_fire)
		waves_dispatched <= waves_dispatched + 1'b1;
	else if ((dispatcher_state == DISPATCH_IDLE) && start)
    waves_dispatched <= '0;
end
assign wave_completed_accepted =
    (dispatcher_state == DISPATCH_RUN) &&
    wave_completed &&
    (waves_completed < waves_dispatched);
assign final_completion =
    dispatch_finished &&
    wave_completed_accepted &&
    ((waves_completed + 1'b1) == waves_dispatched);//当前的wave完成后dispatch和complete相等的同时done
always_ff @(posedge clk or negedge rst_n)begin
	if (!rst_n)
		waves_completed <= '0;
	else if (wave_completed_accepted)
		waves_completed <= waves_completed + 1'b1;
	else if ((dispatcher_state == DISPATCH_IDLE) && start)
		waves_completed <= '0;
end

endmodule

`default_nettype wire
