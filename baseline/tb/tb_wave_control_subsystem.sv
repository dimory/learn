`timescale 1ns/1ns
// Whole-subsystem M2 stage test, not a single-module unit test.
// Integer reference model: dispatch descriptors, lifecycle, Round-Robin,
// architectural context, seven counters, saved Waits and Kernel completion.
// Synthetic events replace the future Wave-tagged execution/backend path.
`ifndef M2_NUM_CONTEXTS
`define M2_NUM_CONTEXTS 4
`endif
`ifndef M2_WG_THREADS
`define M2_WG_THREADS 64
`endif
module tb_wave_control_subsystem;
    import gpu_pkg::*;
    parameter integer N=`M2_NUM_CONTEXTS;
    parameter integer P=`M2_WG_THREADS;
    localparam integer NUM_WAVE_CONTEXTS=N;
    localparam integer WAVE_ID_BITS=(N>1)?$clog2(N):1;
    localparam integer PC_BITS=CDNA_PC_BITS;
    localparam integer THREAD_COUNT_BITS=CDNA_THREAD_COUNT_BITS;
    localparam integer EXEC_BITS=CDNA_EXEC_BITS, VCC_BITS=CDNA_VCC_BITS;
    localparam integer DATA_BITS=CDNA_DATA_BITS;
    localparam integer WORKGROUP_ID_BITS=CDNA_WORKGROUP_ID_BITS;
    localparam integer WG_WAVE_ID_BITS=CDNA_WORKGROUP_WAVE_ID_BITS;
    localparam integer WG_WAVE_COUNT_BITS=CDNA_WORKGROUP_WAVE_COUNT_BITS;
    localparam integer GLOBAL_THREAD_ID_BITS=CDNA_GLOBAL_THREAD_ID_BITS;
    logic clk;
    logic rst_n;
    logic start;
    logic [PC_BITS-1:0] start_pc;
    logic [THREAD_COUNT_BITS-1:0] thread_count;
    logic busy;
    logic done;
    logic selected_valid;
    logic selected_ready;
    logic [WAVE_ID_BITS-1:0] selected_wave_id;
    logic selected_context_valid;
    gpu_pkg::wave_context_state_t selected_state;
    logic [PC_BITS-1:0] selected_pc;
    logic [EXEC_BITS-1:0] selected_exec;
    logic [VCC_BITS-1:0] selected_vcc;
    logic selected_scc;
    logic [DATA_BITS-1:0] selected_m0;
    logic [WORKGROUP_ID_BITS-1:0] selected_workgroup_id;
    logic [WG_WAVE_ID_BITS-1:0] selected_wave_index;
    logic [WG_WAVE_COUNT_BITS-1:0] selected_waves_in_workgroup;
    logic [GLOBAL_THREAD_ID_BITS-1:0] selected_global_thread_base;
    logic commit_valid;
    logic [WAVE_ID_BITS-1:0] commit_wave_id;
    gpu_pkg::wave_context_state_t commit_next_state;
    logic commit_pc_write_enable;
    logic [PC_BITS-1:0] commit_pc;
    logic commit_exec_write_enable;
    logic [EXEC_BITS-1:0] commit_exec;
    logic commit_vcc_write_enable;
    logic [VCC_BITS-1:0] commit_vcc;
    logic commit_scc_write_enable;
    logic commit_scc;
    logic commit_m0_write_enable;
    logic [DATA_BITS-1:0] commit_m0;
    logic dependency_issue_valid;
    logic [WAVE_ID_BITS-1:0] dependency_issue_wave_id;
    gpu_pkg::dependency_kind_t dependency_issue_kind;
    logic [gpu_pkg::DEPENDENCY_AMOUNT_BITS-1:0] dependency_issue_amount;
    logic dependency_complete_valid;
    logic [WAVE_ID_BITS-1:0] dependency_complete_wave_id;
    gpu_pkg::dependency_kind_t dependency_complete_kind;
    logic [gpu_pkg::DEPENDENCY_AMOUNT_BITS-1:0] dependency_complete_amount;
    logic wait_arm_valid;
    logic [WAVE_ID_BITS-1:0] wait_arm_wave_id;
    logic [gpu_pkg::DEPENDENCY_COUNTER_COUNT-1:0] wait_counter_mask;
    logic [gpu_pkg::CDNA_LOAD_COUNTER_BITS-1:0] wait_load_threshold;
    logic [gpu_pkg::CDNA_STORE_COUNTER_BITS-1:0] wait_store_threshold;
    logic [gpu_pkg::CDNA_DS_COUNTER_BITS-1:0] wait_ds_threshold;
    logic [gpu_pkg::CDNA_KM_COUNTER_BITS-1:0] wait_km_threshold;
    logic [gpu_pkg::CDNA_ASYNC_COUNTER_BITS-1:0] wait_async_threshold;
    logic [gpu_pkg::CDNA_TENSOR_COUNTER_BITS-1:0] wait_tensor_threshold;
    logic [gpu_pkg::CDNA_X_COUNTER_BITS-1:0] wait_x_threshold;
    logic wait_arm_satisfied;
    logic [NUM_WAVE_CONTEXTS-1:0] barrier_release_mask;
    logic [NUM_WAVE_CONTEXTS-1:0] free_mask;
    logic [NUM_WAVE_CONTEXTS-1:0] resident_mask;
    logic [NUM_WAVE_CONTEXTS-1:0] ready_mask;
    logic [NUM_WAVE_CONTEXTS-1:0] issued_mask;
    logic [NUM_WAVE_CONTEXTS-1:0] waitcnt_mask;
    logic [NUM_WAVE_CONTEXTS-1:0] barrier_mask;
    logic [NUM_WAVE_CONTEXTS-1:0] done_mask;
    logic [NUM_WAVE_CONTEXTS-1:0] wait_satisfied_mask;
    logic [NUM_WAVE_CONTEXTS-1:0] wait_wakeup_mask;
    logic [NUM_WAVE_CONTEXTS-1:0] all_counters_zero_mask;
    logic alloc_fire;
    logic [WAVE_ID_BITS-1:0] alloc_wave_id;
    logic schedule_fire;
    logic retire_fire;
    logic [WAVE_ID_BITS-1:0] retire_wave_id;

    wave_control_subsystem #(.NUM_WAVE_CONTEXTS(N), .THREADS_PER_WORKGROUP(P)) dut (.*);
    logic strict_events=1;
    logic commit_is_wait=0;
    logic deposit_load_snapshot=0;
`ifndef M2_IVERILOG
    // VCS2016 test-only deposit: no second procedural driver of always_ff.
    // Static generated indices avoid variable hierarchical path selection.
    genvar deposit_index;
    generate
        for(deposit_index=0;deposit_index<N;deposit_index=deposit_index+1) begin : snapshot_deposit
            always @(posedge deposit_load_snapshot)
                $deposit(dut.u_dependency_tracker.load_count[deposit_index],6'd0);
        end
    endgenerate
`endif
    wave_context_state_t requested_next_state=WAVE_STATE_READY;
    assign commit_next_state=commit_is_wait ?
        (wait_arm_satisfied ? WAVE_STATE_READY : WAVE_STATE_WAITCNT) : requested_next_state;
    localparam integer PAYLOAD_BITS=PC_BITS+EXEC_BITS+VCC_BITS+1+DATA_BITS+
        WORKGROUP_ID_BITS+WG_WAVE_ID_BITS+WG_WAVE_COUNT_BITS+GLOBAL_THREAD_ID_BITS;
    wire [PAYLOAD_BITS-1:0] launch_payload={selected_pc,selected_exec,selected_vcc,
        selected_scc,selected_m0,selected_workgroup_id,selected_wave_index,
        selected_waves_in_workgroup,selected_global_thread_base};
    m2_protocol_checker #(.N(N),.W(WAVE_ID_BITS),.PAYLOAD_BITS(PAYLOAD_BITS)) checker_inst (
        .clk(clk),.rst_n(rst_n),.strict_events(strict_events),
        .selected_valid(selected_valid),.selected_ready(selected_ready),
        .selected_wave_id(selected_wave_id),.selected_payload(launch_payload),
        .alloc_fire(alloc_fire),.schedule_fire(schedule_fire),.retire_fire(retire_fire),
        .alloc_wave_id(alloc_wave_id),.retire_wave_id(retire_wave_id),
        .commit_valid(commit_valid),.commit_wave_id(commit_wave_id),.commit_next_state(commit_next_state),
        .wait_arm_valid(wait_arm_valid),.wait_arm_wave_id(wait_arm_wave_id),
        .free_mask(free_mask),.resident_mask(resident_mask),.ready_mask(ready_mask),
        .issued_mask(issued_mask),.waitcnt_mask(waitcnt_mask),.barrier_mask(barrier_mask),.done_mask(done_mask),
        .wait_satisfied_mask(wait_satisfied_mask),.wait_wakeup_mask(wait_wakeup_mask),
        .all_counters_zero_mask(all_counters_zero_mask),.wait_active(dut.u_dependency_tracker.wait_active),.done(done)
    );
    initial begin clk=0; forever #5 clk=~clk; end
    integer state_ref[0:N-1], count_ref[0:N-1][0:6];
    integer threshold_ref[0:N-1][0:6], program_ref[0:N-1], ordinal_ref[0:N-1];
    logic active_ref[0:N-1];
    logic [6:0] wait_mask_ref[0:N-1];
    logic [PC_BITS-1:0] pc_ref[0:N-1];
    logic [EXEC_BITS-1:0] exec_ref[0:N-1];
    logic [VCC_BITS-1:0] vcc_ref[0:N-1];
    logic scc_ref[0:N-1];
    logic [DATA_BITS-1:0] m0_ref[0:N-1];
    integer wg_ref[0:N-1], wi_ref[0:N-1], wc_ref[0:N-1], base_ref[0:N-1];
    integer kernel_ref=0, pointer_ref=0, locked_id_ref=0;
    logic locked_ref=0, finished_ref=0;
    integer threads_ref=0, next_wg_ref=0, next_wave_ref=0;
    integer dispatched_ref=0, completed_ref=0;
    logic [PC_BITS-1:0] launch_pc_ref=0;
    integer cycles=0, checks=0, cases=0;
    integer cov_stall=0, cov_full=0, cov_wait=0, cov_barrier=0, cov_done_pending=0;
    integer cov_reuse=0, cov_concurrent=0, cov_net=0, cov_multiwake=0, cov_nonblocking=0;
    logic used_entry[0:N-1];
    integer seed=32'h10032026, random_unused;
    integer i,j,k,a,step_index;
    string case_name="initial";
    logic [N-1:0] f_ref,r_ref,is_ref,wt_ref,b_ref,d_ref,z_ref,sat_ref;

    function automatic integer limit_of(input integer kind);
        limit_of=(kind==DEP_KM)?31:63;
    endfunction
    function automatic integer actual_count(input integer id,input integer kind);
        case(kind)
            DEP_LOAD:actual_count=dut.u_dependency_tracker.load_count[id];
            DEP_STORE:actual_count=dut.u_dependency_tracker.store_count[id];
            DEP_DS:actual_count=dut.u_dependency_tracker.ds_count[id];
            DEP_KM:actual_count=dut.u_dependency_tracker.km_count[id];
            DEP_ASYNC:actual_count=dut.u_dependency_tracker.async_count[id];
            DEP_TENSOR:actual_count=dut.u_dependency_tracker.tensor_count[id];
            default:actual_count=dut.u_dependency_tracker.x_count[id];
        endcase
    endfunction
    function automatic integer threshold_input(input integer kind);
        case(kind)
            DEP_LOAD:threshold_input=wait_load_threshold;
            DEP_STORE:threshold_input=wait_store_threshold;
            DEP_DS:threshold_input=wait_ds_threshold;
            DEP_KM:threshold_input=wait_km_threshold;
            DEP_ASYNC:threshold_input=wait_async_threshold;
            DEP_TENSOR:threshold_input=wait_tensor_threshold;
            default:threshold_input=wait_x_threshold;
        endcase
    endfunction
    function automatic integer actual_threshold(input integer id,input integer kind);
        case(kind)
            DEP_LOAD:actual_threshold=dut.u_dependency_tracker.saved_wait_load_threshold[id];
            DEP_STORE:actual_threshold=dut.u_dependency_tracker.saved_wait_store_threshold[id];
            DEP_DS:actual_threshold=dut.u_dependency_tracker.saved_wait_ds_threshold[id];
            DEP_KM:actual_threshold=dut.u_dependency_tracker.saved_wait_km_threshold[id];
            DEP_ASYNC:actual_threshold=dut.u_dependency_tracker.saved_wait_async_threshold[id];
            DEP_TENSOR:actual_threshold=dut.u_dependency_tracker.saved_wait_tensor_threshold[id];
            default:actual_threshold=dut.u_dependency_tracker.saved_wait_x_threshold[id];
        endcase
    endfunction
    function automatic logic resident_ref(input integer id);
        resident_ref=0;
        if(id<N) resident_ref=(state_ref[id]!=WAVE_STATE_FREE);
    endfunction
    function automatic logic arm_satisfied_ref;
        integer kind;
        begin
            arm_satisfied_ref=0;
            if(wait_arm_valid && resident_ref(wait_arm_wave_id)) begin
                arm_satisfied_ref=1;
                for(kind=0;kind<7;kind=kind+1)
                    if(wait_counter_mask[kind] && count_ref[wait_arm_wave_id][kind]>threshold_input(kind))
                        arm_satisfied_ref=0;
            end
        end
    endfunction
    function automatic integer waves_for(input integer threads);
        waves_for=(threads/P)*((P+31)/32)+((threads%P)+31)/32;
    endfunction

    task automatic inputs_idle;
        begin
            start=0; selected_ready=0; commit_valid=0; commit_is_wait=0;
            commit_wave_id=0; requested_next_state=WAVE_STATE_READY;
            commit_pc_write_enable=0; commit_exec_write_enable=0; commit_vcc_write_enable=0;
            commit_scc_write_enable=0; commit_m0_write_enable=0;
            commit_pc=0; commit_exec=0; commit_vcc=0; commit_scc=0; commit_m0=0;
            dependency_issue_valid=0; dependency_complete_valid=0;
            dependency_issue_wave_id=0; dependency_complete_wave_id=0;
            dependency_issue_kind=0; dependency_complete_kind=0;
            dependency_issue_amount=0; dependency_complete_amount=0;
            wait_arm_valid=0; wait_arm_wave_id=0; wait_counter_mask=0;
            wait_load_threshold=0; wait_store_threshold=0; wait_ds_threshold=0;
            wait_km_threshold=0; wait_async_threshold=0; wait_tensor_threshold=0; wait_x_threshold=0;
            barrier_release_mask=0; strict_events=1;
        end
    endtask
    task automatic clear_entry(input integer id);
        begin
            state_ref[id]=WAVE_STATE_FREE;
            pc_ref[id]=0; exec_ref[id]=0; vcc_ref[id]=0; scc_ref[id]=0; m0_ref[id]=0;
            wg_ref[id]=0; wi_ref[id]=0; wc_ref[id]=0; base_ref[id]=0; program_ref[id]=0;
        end
    endtask
    task automatic reset_model;
        integer id,kind;
        begin
            kernel_ref=0; pointer_ref=0; locked_ref=0; locked_id_ref=0;
            finished_ref=0; threads_ref=0; next_wg_ref=0; next_wave_ref=0;
            dispatched_ref=0; completed_ref=0; launch_pc_ref=0;
            for(id=0;id<N;id=id+1) begin
                clear_entry(id); active_ref[id]=0; wait_mask_ref[id]=0;
                for(kind=0;kind<7;kind=kind+1) begin count_ref[id][kind]=0; threshold_ref[id][kind]=0; end
            end
        end
    endtask
    task automatic check_state;
        integer id,kind,expected_select,expected_release,expected_free,scan;
        integer wg_threads,wg_waves,base,lanes;
        logic [EXEC_BITS-1:0] initial_mask;
        logic expected_valid;
        begin
            f_ref=0;r_ref=0;is_ref=0;wt_ref=0;b_ref=0;d_ref=0;z_ref='1;sat_ref=0;
            expected_release=-1; expected_free=-1;
            for(id=0;id<N;id=id+1) begin
                case(state_ref[id])
                    WAVE_STATE_FREE:f_ref[id]=1;
                    WAVE_STATE_READY:r_ref[id]=1;
                    WAVE_STATE_ISSUED:is_ref[id]=1;
                    WAVE_STATE_WAITCNT:wt_ref[id]=1;
                    WAVE_STATE_BARRIER:b_ref[id]=1;
                    WAVE_STATE_DONE:d_ref[id]=1;
                    default:$fatal(1,"Reference state invalid");
                endcase
                sat_ref[id]=active_ref[id];
                for(kind=0;kind<7;kind=kind+1) begin
                    if(count_ref[id][kind]!=0) z_ref[id]=0;
                    if(wait_mask_ref[id][kind] && count_ref[id][kind]>threshold_ref[id][kind]) sat_ref[id]=0;
                    if(actual_count(id,kind)!==count_ref[id][kind])
                        $fatal(1,"%s cycle=%0d wave=%0d kind=%0d count expected=%0d got=%0d",case_name,cycles,id,kind,count_ref[id][kind],actual_count(id,kind));
                    if(actual_threshold(id,kind)!==threshold_ref[id][kind]) $fatal(1,"Saved Wait threshold mismatch");
                    checks=checks+2;
                end
                if(dut.u_dependency_tracker.wait_active[id]!==active_ref[id] ||
                   dut.u_dependency_tracker.saved_wait_counter_mask[id]!==wait_mask_ref[id]) $fatal(1,"Saved Wait state mismatch");
                if(dut.u_context_table.context_state[id]!==3'(state_ref[id]) ||
                   dut.u_context_table.context_pc[id]!==pc_ref[id] ||
                   dut.u_context_table.context_exec[id]!==exec_ref[id] ||
                   dut.u_context_table.context_vcc[id]!==vcc_ref[id] ||
                   dut.u_context_table.context_scc[id]!==scc_ref[id] ||
                   dut.u_context_table.context_m0[id]!==m0_ref[id]) $fatal(1,"%s Context mismatch wave=%0d",case_name,id);
                if(expected_free<0 && f_ref[id]) expected_free=id;
                if(expected_release<0 && d_ref[id] && z_ref[id]) expected_release=id;
            end
            if({free_mask,ready_mask,issued_mask,waitcnt_mask,barrier_mask,done_mask}!==
               {f_ref,r_ref,is_ref,wt_ref,b_ref,d_ref}) $fatal(1,"%s state-mask mismatch cycle=%0d",case_name,cycles);
            if(resident_mask!==~f_ref || all_counters_zero_mask!==z_ref || wait_satisfied_mask!==sat_ref ||
               wait_wakeup_mask!==(wt_ref & sat_ref)) $fatal(1,"%s dependency/wakeup mask mismatch",case_name);
            if(wait_arm_satisfied!==arm_satisfied_ref()) $fatal(1,"Incoming Wait query mismatch");
            if(busy!==(kernel_ref==1) || done!==(kernel_ref==2)) $fatal(1,"%s Kernel status mismatch cycle=%0d",case_name,cycles);
            if(dut.u_dispatcher.waves_dispatched!==33'(dispatched_ref) ||
               dut.u_dispatcher.waves_completed!==33'(completed_ref)) $fatal(1,"Kernel accounting mismatch");
            if(dut.alloc_valid!==((kernel_ref==1)&&!finished_ref) || dut.alloc_ready!==(expected_free>=0))
                $fatal(1,"Dispatcher allocation flow mismatch");
            if(expected_free<0) expected_free=0;
            if(alloc_wave_id!==WAVE_ID_BITS'(expected_free)) $fatal(1,"FREE allocator priority mismatch");
            if(dut.alloc_valid) begin
                wg_threads=threads_ref-next_wg_ref*P;
                if(wg_threads>P) wg_threads=P;
                wg_waves=(wg_threads+31)/32;
                base=next_wg_ref*P+next_wave_ref*32;
                lanes=wg_threads-next_wave_ref*32;
                if(lanes>32) lanes=32;
                initial_mask=0;
                for(scan=0;scan<32;scan=scan+1) if(scan<lanes) initial_mask[scan]=1;
                if(dut.alloc_start_pc!==launch_pc_ref || dut.alloc_initial_exec!==initial_mask ||
                   dut.alloc_workgroup_id!==WORKGROUP_ID_BITS'(next_wg_ref) ||
                   dut.alloc_wave_index!==WG_WAVE_ID_BITS'(next_wave_ref) ||
                   dut.alloc_waves_in_workgroup!==WG_WAVE_COUNT_BITS'(wg_waves) ||
                   dut.alloc_global_thread_base!==GLOBAL_THREAD_ID_BITS'(base))
                    $fatal(1,"%s descriptor mismatch WG=%0d wave=%0d base=%0d",case_name,next_wg_ref,next_wave_ref,base);
            end
            expected_select=-1;
            if(locked_ref) expected_select=locked_id_ref;
            else for(scan=0;scan<N;scan=scan+1) begin
                id=(pointer_ref+scan)%N;
                if(expected_select<0 && r_ref[id]) expected_select=id;
            end
            expected_valid=(expected_select>=0);
            if(expected_select<0) expected_select=0;
            if(selected_valid!==expected_valid || selected_wave_id!==WAVE_ID_BITS'(expected_select))
                $fatal(1,"%s RR selection mismatch cycle=%0d",case_name,cycles);
            id=expected_select;
            if(selected_context_valid!==(state_ref[id]!=WAVE_STATE_FREE) ||
               selected_state!==3'(state_ref[id]) || selected_pc!==pc_ref[id] || selected_exec!==exec_ref[id] ||
               selected_vcc!==vcc_ref[id] || selected_scc!==scc_ref[id] || selected_m0!==m0_ref[id] ||
               selected_workgroup_id!==WORKGROUP_ID_BITS'(wg_ref[id]) ||
               selected_wave_index!==WG_WAVE_ID_BITS'(wi_ref[id]) ||
               selected_waves_in_workgroup!==WG_WAVE_COUNT_BITS'(wc_ref[id]) ||
               selected_global_thread_base!==GLOBAL_THREAD_ID_BITS'(base_ref[id])) $fatal(1,"Selected Context payload mismatch");
            if(retire_fire!==(expected_release>=0)) $fatal(1,"Safe-retirement validity mismatch");
            if(expected_release<0) expected_release=0;
            if(retire_wave_id!==WAVE_ID_BITS'(expected_release) || dut.wave_completed!==retire_fire)
                $fatal(1,"Retirement identity/completion wiring mismatch");
            checks=checks+20;
        end
    endtask
    task automatic tick;
        integer id,kind,net,wg_threads,wg_waves,lanes,old_allocated;
        logic issue_ok,complete_ok,arm_ok,arm_good;
        logic [N-1:0] wake_before;
        wave_context_state_t commit_result;
        begin
            #1; check_state();
            issue_ok=dependency_issue_valid && resident_ref(dependency_issue_wave_id) && dependency_issue_kind<7 && dependency_issue_amount!=0;
            complete_ok=dependency_complete_valid && resident_ref(dependency_complete_wave_id) && dependency_complete_kind<7 && dependency_complete_amount!=0;
            arm_ok=wait_arm_valid && resident_ref(wait_arm_wave_id); arm_good=arm_satisfied_ref();
            wake_before=wait_wakeup_mask; commit_result=commit_next_state; old_allocated=dispatched_ref;
            if(selected_valid && !selected_ready) cov_stall=cov_stall+1;
            if(dut.alloc_valid && !dut.alloc_ready) cov_full=cov_full+1;
            if((alloc_fire && retire_fire)||(schedule_fire && commit_valid)) cov_concurrent=cov_concurrent+1;
            if(issue_ok && complete_ok && dependency_issue_wave_id==dependency_complete_wave_id && dependency_issue_kind==dependency_complete_kind) cov_net=cov_net+1;
            if($countones(wake_before)>1) cov_multiwake=cov_multiwake+1;
            for(id=0;id<N;id=id+1) begin
                if(state_ref[id]==WAVE_STATE_WAITCNT) cov_wait=cov_wait+1;
                if(state_ref[id]==WAVE_STATE_BARRIER) cov_barrier=cov_barrier+1;
                if(state_ref[id]==WAVE_STATE_DONE && !all_counters_zero_mask[id]) cov_done_pending=cov_done_pending+1;
                if(state_ref[id]==WAVE_STATE_READY && !all_counters_zero_mask[id]) cov_nonblocking=cov_nonblocking+1;
            end
            @(posedge clk);
            if(kernel_ref==0 && start) begin
                kernel_ref=(thread_count==0)?2:1; threads_ref=thread_count; launch_pc_ref=start_pc;
                next_wg_ref=0;next_wave_ref=0;finished_ref=0;dispatched_ref=0;completed_ref=0;
            end
            else if(kernel_ref==2) kernel_ref=0;
            else if(kernel_ref==1 && finished_ref && retire_fire && completed_ref+1==dispatched_ref) kernel_ref=2;
            if(schedule_fire) begin pointer_ref=(int'(selected_wave_id)+1)%N; locked_ref=0; end
            else if(selected_valid && !selected_ready) begin locked_ref=1;locked_id_ref=selected_wave_id; end
            for(id=0;id<N;id=id+1) begin
                if(arm_ok && wait_arm_wave_id==id) begin
                    active_ref[id]=!arm_good;wait_mask_ref[id]=wait_counter_mask;
                    for(kind=0;kind<7;kind=kind+1) threshold_ref[id][kind]=threshold_input(kind);
                end
                else if(wake_before[id]) active_ref[id]=0;
                for(kind=0;kind<7;kind=kind+1) begin
                    if((retire_fire && retire_wave_id==id)||(alloc_fire && alloc_wave_id==id)) count_ref[id][kind]=0;
                    else begin
                        net=count_ref[id][kind];
                        if(issue_ok && dependency_issue_wave_id==id && dependency_issue_kind==kind) net=net+dependency_issue_amount;
                        if(complete_ok && dependency_complete_wave_id==id && dependency_complete_kind==kind) net=net-dependency_complete_amount;
                        if(net>=0 && net<=limit_of(kind)) count_ref[id][kind]=net;
                        else if(strict_events) $fatal(1,"Stimulus violates counter capacity");
                    end
                end
                if(retire_fire && retire_wave_id==id) clear_entry(id);
                else if(alloc_fire && alloc_wave_id==id) begin
                    if(used_entry[id]) cov_reuse=cov_reuse+1;
                    used_entry[id]=1; state_ref[id]=WAVE_STATE_READY;pc_ref[id]=launch_pc_ref;
                    wg_threads=threads_ref-next_wg_ref*P;if(wg_threads>P) wg_threads=P;
                    lanes=wg_threads-next_wave_ref*32;if(lanes>32) lanes=32;
                    exec_ref[id]=0;for(kind=0;kind<32;kind=kind+1) if(kind<lanes) exec_ref[id][kind]=1;
                    vcc_ref[id]=0;scc_ref[id]=0;m0_ref[id]=0;
                    wg_ref[id]=next_wg_ref;wi_ref[id]=next_wave_ref;wc_ref[id]=(wg_threads+31)/32;
                    base_ref[id]=next_wg_ref*P+next_wave_ref*32;ordinal_ref[id]=old_allocated;program_ref[id]=0;
                end
                else if(commit_valid && commit_wave_id==id && state_ref[id]==WAVE_STATE_ISSUED) begin
                    state_ref[id]=commit_result;program_ref[id]=program_ref[id]+1;
                    if(commit_pc_write_enable) pc_ref[id]=commit_pc;
                    if(commit_exec_write_enable) exec_ref[id]=commit_exec;
                    if(commit_vcc_write_enable) vcc_ref[id]=commit_vcc;
                    if(commit_scc_write_enable) scc_ref[id]=commit_scc;
                    if(commit_m0_write_enable) m0_ref[id]=commit_m0;
                end
                else if((wake_before[id] && state_ref[id]==WAVE_STATE_WAITCNT)||
                        (barrier_release_mask[id] && state_ref[id]==WAVE_STATE_BARRIER)) state_ref[id]=WAVE_STATE_READY;
                else if(schedule_fire && selected_wave_id==id && state_ref[id]==WAVE_STATE_READY) state_ref[id]=WAVE_STATE_ISSUED;
            end
            if(alloc_fire) begin
                wg_threads=threads_ref-next_wg_ref*P;if(wg_threads>P) wg_threads=P;
                wg_waves=(wg_threads+31)/32;
                lanes=wg_threads-next_wave_ref*32;if(lanes>32) lanes=32;
                if(next_wg_ref*P+next_wave_ref*32+lanes>=threads_ref) finished_ref=1;
                else if(next_wave_ref+1==wg_waves) begin next_wg_ref=next_wg_ref+1;next_wave_ref=0;end
                else next_wave_ref=next_wave_ref+1;
                dispatched_ref=dispatched_ref+1;
            end
            if(retire_fire) completed_ref=completed_ref+1;
            cycles=cycles+1;
            #1;check_state();
            @(negedge clk);
        end
    endtask
    task automatic reset_system;
        begin
            inputs_idle(); rst_n=0;reset_model();
            #2;check_state();
            @(negedge clk);rst_n=1;tick();
        end
    endtask
    task automatic launch(input integer threads);
        begin
            if(kernel_ref!=0) $fatal(1,"Launch helper needs IDLE");
            inputs_idle();start=1;thread_count=threads;start_pc=64'h1000+cycles*4;tick();
            inputs_idle();start_pc=64'hdead0000;thread_count=17;
        end
    endtask
    task automatic accept_wave(output integer id);
        integer timeout_cycles;
        begin
            inputs_idle();timeout_cycles=0;
            #1;
            while(!selected_valid && timeout_cycles<100) begin tick();timeout_cycles=timeout_cycles+1;end
            if(!selected_valid) $fatal(1,"No schedulable Wave");
            id=selected_wave_id;selected_ready=1;tick();inputs_idle();
        end
    endtask
    task automatic prepare_commit(input integer id,input wave_context_state_t result_state);
        begin
            inputs_idle();commit_valid=1;commit_wave_id=id;requested_next_state=result_state;
            commit_pc_write_enable=1;commit_pc=pc_ref[id]+4;
            commit_vcc_write_enable=1;commit_vcc=64'habcdef00+ordinal_ref[id];
            commit_scc_write_enable=1;commit_scc=!scc_ref[id];
            commit_m0_write_enable=1;commit_m0=32'h8000+ordinal_ref[id];
            commit_exec_write_enable=1;commit_exec=exec_ref[id]^64'h1;
        end
    endtask
    task automatic complete_counter(input integer id,input integer kind,input integer amount);
        begin
            inputs_idle();dependency_complete_valid=1;dependency_complete_wave_id=id;
            dependency_complete_kind=kind;dependency_complete_amount=amount;tick();inputs_idle();
        end
    endtask
    task automatic random_step;
        integer id,kind,offset,chosen;
        begin
            inputs_idle();
            offset=$urandom_range(0,N-1); chosen=-1;
            for(id=0;id<N;id=id+1)
                if(chosen<0 && state_ref[(id+offset)%N]==WAVE_STATE_ISSUED) chosen=(id+offset)%N;
            if(chosen>=0 && $urandom_range(0,3)!=0) begin
                id=chosen;kind=ordinal_ref[id]%7;prepare_commit(id,WAVE_STATE_READY);
                case(program_ref[id])
                    0:begin dependency_issue_valid=1;dependency_issue_wave_id=id;
                            dependency_issue_kind=kind;dependency_issue_amount=3;end
                    1:if((ordinal_ref[id]%2)==0) begin
                        commit_is_wait=1;wait_arm_valid=1;wait_arm_wave_id=id;wait_counter_mask=7'(1<<kind);
                    end
                    2:if((ordinal_ref[id]%3)==0) requested_next_state=WAVE_STATE_BARRIER;
                    default:requested_next_state=WAVE_STATE_DONE;
                endcase
            end
            selected_ready=($urandom_range(0,4)!=0);
            barrier_release_mask=barrier_mask & N'($urandom);
            if((cycles%3)==0) begin
                chosen=-1;offset=$urandom_range(0,N*7-1);
                for(id=0;id<N*7;id=id+1) begin
                    kind=(id+offset)%(N*7);
                    if(chosen<0 && count_ref[kind/7][kind%7]>0) chosen=kind;
                end
                if(chosen>=0) begin
                    dependency_complete_valid=1;dependency_complete_wave_id=chosen/7;
                    dependency_complete_kind=chosen%7;dependency_complete_amount=1;
                end
            end
            tick();
        end
    endtask
    task automatic finish_random;
        integer timeout_cycles;
        begin
            timeout_cycles=0;
            while(kernel_ref!=2 && timeout_cycles<20000) begin random_step();timeout_cycles=timeout_cycles+1;end
            if(kernel_ref!=2) $fatal(1,"%s Kernel timeout N=%0d P=%0d",case_name,N,P);
            if(dispatched_ref!=waves_for(threads_ref) || completed_ref!=dispatched_ref || resident_mask!='0)
                $fatal(1,"Kernel completion totals/residency mismatch");
            inputs_idle();tick();
        end
    endtask
    task automatic pass_case(input string name);
        begin cases=cases+1;$display("[PASS] M2 %s N=%0d WG=%0d",name,N,P);end
    endtask
    initial begin
        rst_n=1;start_pc=0;thread_count=0;
        random_unused=$urandom(seed);
        for(i=0;i<N;i=i+1) used_entry[i]=0;
        reset_model();reset_system();
        case_name="zero_thread";
        launch(0);
        if(!done || alloc_fire || resident_mask!='0) $fatal(1,"Zero-thread launch failed");
        inputs_idle();tick();pass_case(case_name);

        case_name="dispatch_edges_and_random_lifecycle";
        for(j=0;j<8;j=j+1) begin
            case(j)
                0:a=1;1:a=31;2:a=32;3:a=33;4:a=64;5:a=70;6:a=129;default:a=257;
            endcase
            launch(a);
            // Hold execution to fill the table and lock a launch selection.
            for(step_index=0;step_index<N+6;step_index=step_index+1) begin
                inputs_idle();
                if(step_index==2) begin start=1;start_pc=64'hbad00000;thread_count=0;end
                tick(); // Busy-time launch is ignored, descriptor remains stable.
            end
            finish_random();
        end
        pass_case(case_name);

        case_name="all_counter_bounds_wait_and_safe_retire";
        launch(1);
        for(k=0;k<7;k=k+1) begin
            accept_wave(a);
            // Explicit negative underflow test, with no architectural commit.
            dependency_complete_valid=1;dependency_complete_wave_id=a;
            dependency_complete_kind=k;dependency_complete_amount=1;strict_events=0;tick();
            prepare_commit(a,WAVE_STATE_READY);
            dependency_issue_valid=1;dependency_issue_wave_id=a;
            dependency_issue_kind=k;dependency_issue_amount=limit_of(k);tick();
            accept_wave(a);prepare_commit(a,WAVE_STATE_READY);
            dependency_issue_valid=1;dependency_issue_wave_id=a;
            dependency_issue_kind=k;dependency_issue_amount=63;
            dependency_complete_valid=1;dependency_complete_wave_id=a;
            dependency_complete_kind=k;dependency_complete_amount=63;tick();
            accept_wave(a);prepare_commit(a,WAVE_STATE_READY);
            dependency_issue_valid=1;dependency_issue_wave_id=a;
            dependency_issue_kind=k;dependency_issue_amount=1;strict_events=0;tick();
        end
        accept_wave(a);prepare_commit(a,WAVE_STATE_READY);
        commit_is_wait=1;wait_arm_valid=1;wait_arm_wave_id=a;wait_counter_mask=0;tick();
        if(state_ref[a]!=WAVE_STATE_READY || dut.u_dependency_tracker.wait_active[a]) $fatal(1,"Empty Wait should be immediate");
        accept_wave(a);prepare_commit(a,WAVE_STATE_READY);
        commit_is_wait=1;wait_arm_valid=1;wait_arm_wave_id=a;wait_counter_mask='1;wait_load_threshold=2;tick();
        if(state_ref[a]!=WAVE_STATE_WAITCNT) $fatal(1,"Multi-class Wait did not sleep");
        complete_counter(a,DEP_LOAD,61);
        for(k=1;k<7;k=k+1) complete_counter(a,k,limit_of(k));
        inputs_idle();tick(); // Accept wakeup after the final comparison changed.
        if(state_ref[a]!=WAVE_STATE_READY || all_counters_zero_mask[a]) $fatal(1,"Nonzero threshold/wakeup failed");
        accept_wave(a);prepare_commit(a,WAVE_STATE_DONE);tick();
        for(k=0;k<5;k=k+1) begin inputs_idle();tick();if(retire_fire) $fatal(1,"Retired with outstanding Load");end
        complete_counter(a,DEP_LOAD,2);finish_random();pass_case(case_name);

        case_name="completion_and_wait_arm_same_edge";
        launch(1);accept_wave(a);prepare_commit(a,WAVE_STATE_READY);
        dependency_issue_valid=1;dependency_issue_wave_id=a;dependency_issue_kind=DEP_DS;dependency_issue_amount=1;tick();
        accept_wave(a);prepare_commit(a,WAVE_STATE_READY);
        commit_is_wait=1;wait_arm_valid=1;wait_arm_wave_id=a;wait_counter_mask=7'(1<<DEP_DS);
        dependency_complete_valid=1;dependency_complete_wave_id=a;dependency_complete_kind=DEP_DS;dependency_complete_amount=1;tick();
        if(state_ref[a]!=WAVE_STATE_WAITCNT || !dut.u_dependency_tracker.wait_active[a] || !wait_satisfied_mask[a])
            $fatal(1,"Completion/arm must use registered pre-edge counts");
        inputs_idle();tick();finish_random();pass_case(case_name);

        if(N>1) begin
            case_name="multi_hot_wakeup_snapshot";
            launch(P*N);
            for(i=0;i<N;i=i+1) begin
                accept_wave(a);prepare_commit(a,WAVE_STATE_READY);
                dependency_issue_valid=1;dependency_issue_wave_id=a;dependency_issue_kind=DEP_LOAD;dependency_issue_amount=1;tick();
                // With RR, the just-committed Wave need not be the next selected.
                // Park every context after one Load, using the global reference.
            end
            for(i=0;i<N;i=i+1) begin
                accept_wave(a);prepare_commit(a,WAVE_STATE_READY);
                commit_is_wait=1;wait_arm_valid=1;wait_arm_wave_id=a;wait_counter_mask=1;tick();
            end
            inputs_idle();
            // Single completion port ordinarily wakes one Wave per edge.
            // A verification-only snapshot models simultaneous backend returns
            // to exercise the multi-hot acknowledgement wiring, without adding
            // any production bypass or extra completion port.
            for(i=0;i<N;i=i+1) begin
`ifdef M2_IVERILOG
                // Icarus 12 cannot $deposit into vpiMemoryWord targets.
                // This fallback is excluded from the final VCS compile.
                dut.u_dependency_tracker.load_count[i]=0;
`endif
                count_ref[i][DEP_LOAD]=0;
            end
            deposit_load_snapshot=1;
            #1;
            deposit_load_snapshot=0;
            if(wait_wakeup_mask!=='1) $fatal(1,"Multi-hot wake mask missing");
            tick();finish_random();pass_case(case_name);
        end

        case_name="invalid_events_ignored";
        inputs_idle();strict_events=0;commit_valid=1;commit_wave_id=0;
        dependency_issue_valid=1;dependency_issue_amount=1;
        dependency_complete_valid=1;dependency_complete_amount=1;
        wait_arm_valid=1;wait_arm_wave_id=0;tick(); // FREE entry, all ignored.
        if((1<<WAVE_ID_BITS)>N) begin
            inputs_idle();strict_events=0;commit_valid=1;commit_wave_id=N;
            dependency_issue_valid=1;dependency_issue_wave_id=N;dependency_issue_amount=1;
            dependency_complete_valid=1;dependency_complete_wave_id=N;dependency_complete_amount=1;
            wait_arm_valid=1;wait_arm_wave_id=N;tick();
        end
        launch(1);accept_wave(a);prepare_commit(a,WAVE_STATE_READY);
        dependency_issue_valid=1;dependency_issue_wave_id=a;dependency_issue_kind=7;dependency_issue_amount=1;
        dependency_complete_valid=1;dependency_complete_wave_id=a;dependency_complete_kind=7;dependency_complete_amount=1;
        strict_events=0;tick();
        inputs_idle();strict_events=0;dependency_issue_valid=1;dependency_issue_wave_id=a;dependency_issue_amount=0;
        dependency_complete_valid=1;dependency_complete_wave_id=a;dependency_complete_amount=0;tick();
        finish_random();pass_case(case_name);

        case_name="asynchronous_reset_discards_stalled_launch";
        launch(P*N);
        for(i=0;i<N+3;i=i+1) begin inputs_idle();tick();end
        if(!dut.u_scheduler.locked || !selected_valid) $fatal(1,"Reset test did not lock a launch");
        reset_system();launch(1);finish_random();pass_case(case_name);

        case_name="asynchronous_reset_aborts_active_kernel";
        launch(P*N);accept_wave(a);prepare_commit(a,WAVE_STATE_READY);
        dependency_issue_valid=1;dependency_issue_wave_id=a;dependency_issue_kind=DEP_LOAD;dependency_issue_amount=2;tick();
        // Find and issue the original Wave again without committing others.
        for(i=0;i<N;i=i+1) begin
            accept_wave(j);
            if(j==a) begin
                prepare_commit(a,WAVE_STATE_READY);commit_is_wait=1;wait_arm_valid=1;
                wait_arm_wave_id=a;wait_counter_mask=1;tick();
                i=N;
            end
        end
        if(state_ref[a]!=WAVE_STATE_WAITCNT) $fatal(1,"Reset test did not create an active Wait");
        reset_system();launch(33);finish_random();pass_case(case_name);

        case_name="workgroup_id_crosses_65535";
        launch(65536*P+1);
        // Fast-forward an already-completed prefix. Only the boundary tail is
        // simulated; lifecycle/counters of the tail still use the full top.
        $deposit(dut.u_dispatcher.workgroup_cursor,WORKGROUP_ID_BITS'(65535));
        $deposit(dut.u_dispatcher.wave_cursor,0);
        $deposit(dut.u_dispatcher.waves_dispatched,33'(65535*((P+31)/32)));
        $deposit(dut.u_dispatcher.waves_completed,33'(65535*((P+31)/32)));
        next_wg_ref=65535;next_wave_ref=0;
        dispatched_ref=65535*((P+31)/32);completed_ref=dispatched_ref;
        finish_random();pass_case(case_name);

        if(!cov_stall || !cov_full || !cov_wait || !cov_barrier || !cov_done_pending ||
           !cov_reuse || !cov_net || !cov_nonblocking)
            $fatal(1,"Missing M2 scenario coverage");
        if(N>1 && !cov_concurrent) $fatal(1,"Missing independent-entry concurrency coverage");
        if(N>1 && !cov_multiwake) $fatal(1,"Missing multi-hot wake coverage");
        $display("M2 COVERAGE stalls=%0d full=%0d wait=%0d barrier=%0d pending_done=%0d reuse=%0d concurrent=%0d net=%0d multiwake=%0d nonblocking=%0d",
            cov_stall,cov_full,cov_wait,cov_barrier,cov_done_pending,cov_reuse,cov_concurrent,cov_net,cov_multiwake,cov_nonblocking);
        $display("TinyGPU M2: ALL %0d SCENARIO GROUPS PASSED N=%0d WG=%0d cycles=%0d checks=%0d",cases,N,P,cycles,checks);
        $finish;
    end
    initial begin #1000000;$fatal(1,"M2 whole-subsystem timeout");end
`ifdef FSDB
    initial begin
        $fsdbDumpfile("waves/tinygpu_m2.fsdb");
        $fsdbDumpvars(0,tb_wave_control_subsystem);
        $fsdbDumpMDA();
    end
`endif
    initial if($test$plusargs("VCD")) begin
        $dumpfile("waves/tinygpu_m2.vcd");$dumpvars(0,tb_wave_control_subsystem);
    end
endmodule
