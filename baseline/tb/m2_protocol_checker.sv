`timescale 1ns/1ns
// Simulation-only protocol assertions, using constructs supported by VCS2016
// and Icarus. Strict checks can be disabled for explicitly labelled negative
// stimuli; lifecycle, retirement and stall checks always remain enabled.
module m2_protocol_checker #(
    parameter integer N=4,
    parameter integer W=(N>1)?$clog2(N):1,
    parameter integer PAYLOAD_BITS=1
) (
    input logic clk, rst_n, strict_events,
    input logic selected_valid, selected_ready,
    input logic [W-1:0] selected_wave_id,
    input logic [PAYLOAD_BITS-1:0] selected_payload,
    input logic alloc_fire, schedule_fire, retire_fire,
    input logic [W-1:0] alloc_wave_id, retire_wave_id,
    input logic commit_valid,
    input logic [W-1:0] commit_wave_id,
    input gpu_pkg::wave_context_state_t commit_next_state,
    input logic wait_arm_valid,
    input logic [W-1:0] wait_arm_wave_id,
    input logic [N-1:0] free_mask, resident_mask, ready_mask, issued_mask,
    input logic [N-1:0] waitcnt_mask, barrier_mask, done_mask,
    input logic [N-1:0] wait_satisfied_mask, wait_wakeup_mask,
    input logic [N-1:0] all_counters_zero_mask, wait_active,
    input logic done
);
    import gpu_pkg::*;
    logic stalled, previous_done;
    logic [W-1:0] stalled_id;
    logic [PAYLOAD_BITS-1:0] stalled_payload;
    integer i, state_bits;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stalled=0; previous_done=0; stalled_id=0; stalled_payload=0;
        end
        else begin
            if ((^{free_mask,resident_mask,ready_mask,issued_mask,
                waitcnt_mask,barrier_mask,done_mask,alloc_fire,schedule_fire,retire_fire,done}) === 1'bx)
                $fatal(1,"M2 assertion: unknown control/mask");
            if (resident_mask !== ~free_mask)
                $fatal(1,"M2 assertion: residency differs from allocated entries");
            for(i=0;i<N;i=i+1) begin
                state_bits=int'(free_mask[i])+int'(ready_mask[i])+int'(issued_mask[i])+
                           int'(waitcnt_mask[i])+int'(barrier_mask[i])+int'(done_mask[i]);
                if(state_bits!=1) $fatal(1,"M2 assertion: state masks do not partition entries");
                if((free_mask[i]||done_mask[i]) && wait_active[i])
                    $fatal(1,"M2 assertion: FREE/DONE owns an active Wait");
            end
            if(wait_wakeup_mask !== (waitcnt_mask & wait_satisfied_mask))
                $fatal(1,"M2 assertion: wakeup qualification mismatch");
            if(alloc_fire && (alloc_wave_id>=N || !free_mask[alloc_wave_id]))
                $fatal(1,"M2 assertion: allocation into occupied entry");
            if(schedule_fire && (selected_wave_id>=N || !ready_mask[selected_wave_id]))
                $fatal(1,"M2 assertion: issue of non-READY entry");
            if(retire_fire && (retire_wave_id>=N || !done_mask[retire_wave_id] ||
                !all_counters_zero_mask[retire_wave_id] || wait_active[retire_wave_id]))
                $fatal(1,"M2 assertion: unsafe retirement");
            if(strict_events && commit_valid) begin
                if(commit_wave_id>=N || !issued_mask[commit_wave_id])
                    $fatal(1,"M2 assertion: commit of non-ISSUED entry");
                if(commit_next_state!=WAVE_STATE_READY && commit_next_state!=WAVE_STATE_WAITCNT &&
                   commit_next_state!=WAVE_STATE_BARRIER && commit_next_state!=WAVE_STATE_DONE)
                    $fatal(1,"M2 assertion: illegal commit result state");
            end
            if(strict_events && wait_arm_valid &&
               (!commit_valid || wait_arm_wave_id!=commit_wave_id ||
                wait_arm_wave_id>=N || !issued_mask[wait_arm_wave_id]))
                $fatal(1,"M2 assertion: Wait arm is not aligned with commit");
            if(stalled && (!selected_valid || selected_wave_id!==stalled_id ||
                           selected_payload!==stalled_payload))
                $fatal(1,"M2 assertion: stalled launch payload changed");
            if(done && previous_done) $fatal(1,"M2 assertion: Kernel done exceeds one cycle");
            previous_done=done;
            stalled=selected_valid && !selected_ready;
            stalled_id=selected_wave_id; stalled_payload=selected_payload;
        end
    end
endmodule
