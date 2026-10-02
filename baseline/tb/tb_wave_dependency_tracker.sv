`timescale 1ns/1ns
// Single-module self-checking test. No M2 integration or execution backend.
// The reference model uses integer counts and a table-driven Wait model.
// Deliberate invalid-event / arithmetic-bound tests verify ignore / hold behavior.
module tb_wave_dependency_tracker;
    import gpu_pkg::*;
    parameter integer N = 4;
    localparam integer W = (N > 1) ? $clog2(N) : 1;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 1;
    logic [N-1:0] resident_mask = '1;
    logic alloc_fire = 0, release_valid = 0;
    logic [W-1:0] alloc_wave_id = '0, release_wave_id = '0;
    logic dependency_issue_valid = 0, dependency_complete_valid = 0;
    logic [W-1:0] dependency_issue_wave_id = '0, dependency_complete_wave_id = '0;
    dependency_kind_t dependency_issue_kind = DEP_LOAD, dependency_complete_kind = DEP_LOAD;
    logic [DEPENDENCY_AMOUNT_BITS-1:0] dependency_issue_amount = '0, dependency_complete_amount = '0;
    logic wait_arm_valid = 0;
    logic [W-1:0] wait_arm_wave_id = '0;
    logic [DEPENDENCY_COUNTER_COUNT-1:0] wait_counter_mask = '0;
    logic [CDNA_LOAD_COUNTER_BITS-1:0] wait_load_threshold = '0;
    logic [CDNA_STORE_COUNTER_BITS-1:0] wait_store_threshold = '0;
    logic [CDNA_DS_COUNTER_BITS-1:0] wait_ds_threshold = '0;
    logic [CDNA_KM_COUNTER_BITS-1:0] wait_km_threshold = '0;
    logic [CDNA_ASYNC_COUNTER_BITS-1:0] wait_async_threshold = '0;
    logic [CDNA_TENSOR_COUNTER_BITS-1:0] wait_tensor_threshold = '0;
    logic [CDNA_X_COUNTER_BITS-1:0] wait_x_threshold = '0;
    logic wait_arm_satisfied;
    logic [N-1:0] wait_wakeup_mask = '0, wait_satisfied_mask, all_counters_zero_mask;

    wave_dependency_tracker #(.NUM_WAVE_CONTEXTS(N), .WAVE_ID_BITS(W)) dut (.*);

    integer model_count [0:N-1][0:6];
    integer model_threshold [0:N-1][0:6];
    logic [6:0] model_mask [0:N-1];
    logic model_active [0:N-1];
    integer cycles = 0, checks = 0;
    integer underflow_holds = 0, overflow_holds = 0, ignored_events = 0;
    integer i, j, k, trial, wave, kind, amount, capacity;
    integer seed = 32'h1022026, random_value;
    logic [N-1:0] expected_wait, expected_zero;

    function automatic integer limit_of(input integer counter_kind);
        limit_of = (counter_kind == DEP_KM) ? 31 : 63;
    endfunction

    function automatic integer count_of(input integer id, input integer counter_kind);
        case (counter_kind)
            DEP_LOAD: count_of = dut.load_count[id];
            DEP_STORE: count_of = dut.store_count[id];
            DEP_DS: count_of = dut.ds_count[id];
            DEP_KM: count_of = dut.km_count[id];
            DEP_ASYNC: count_of = dut.async_count[id];
            DEP_TENSOR: count_of = dut.tensor_count[id];
            default: count_of = dut.x_count[id];
        endcase
    endfunction

    function automatic integer saved_threshold_of(input integer id, input integer counter_kind);
        case (counter_kind)
            DEP_LOAD: saved_threshold_of = dut.saved_wait_load_threshold[id];
            DEP_STORE: saved_threshold_of = dut.saved_wait_store_threshold[id];
            DEP_DS: saved_threshold_of = dut.saved_wait_ds_threshold[id];
            DEP_KM: saved_threshold_of = dut.saved_wait_km_threshold[id];
            DEP_ASYNC: saved_threshold_of = dut.saved_wait_async_threshold[id];
            DEP_TENSOR: saved_threshold_of = dut.saved_wait_tensor_threshold[id];
            default: saved_threshold_of = dut.saved_wait_x_threshold[id];
        endcase
    endfunction

    function automatic integer threshold_of(input integer counter_kind);
        case (counter_kind)
            DEP_LOAD: threshold_of = wait_load_threshold;
            DEP_STORE: threshold_of = wait_store_threshold;
            DEP_DS: threshold_of = wait_ds_threshold;
            DEP_KM: threshold_of = wait_km_threshold;
            DEP_ASYNC: threshold_of = wait_async_threshold;
            DEP_TENSOR: threshold_of = wait_tensor_threshold;
            default: threshold_of = wait_x_threshold;
        endcase
    endfunction

    task automatic set_threshold(input integer counter_kind, input integer value);
        case (counter_kind)
            DEP_LOAD: wait_load_threshold = value;
            DEP_STORE: wait_store_threshold = value;
            DEP_DS: wait_ds_threshold = value;
            DEP_KM: wait_km_threshold = value;
            DEP_ASYNC: wait_async_threshold = value;
            DEP_TENSOR: wait_tensor_threshold = value;
            default: wait_x_threshold = value;
        endcase
    endtask

    function automatic logic resident_id(input integer id);
        resident_id = 0;
        if (id < N) resident_id = resident_mask[id];
    endfunction

    function automatic logic arm_satisfied_model;
        integer counter_kind;
        begin
            arm_satisfied_model = 0;
            if (wait_arm_valid && resident_id(wait_arm_wave_id)) begin
                arm_satisfied_model = 1;
                for (counter_kind = 0; counter_kind < 7; counter_kind = counter_kind + 1)
                    if (wait_counter_mask[counter_kind] &&
                        model_count[wait_arm_wave_id][counter_kind] > threshold_of(counter_kind))
                        arm_satisfied_model = 0;
            end
        end
    endfunction

    task automatic idle_inputs;
        begin
            alloc_fire = 0; release_valid = 0;
            dependency_issue_valid = 0; dependency_complete_valid = 0;
            dependency_issue_amount = 0; dependency_complete_amount = 0;
            wait_arm_valid = 0; wait_counter_mask = 0; wait_wakeup_mask = 0;
            wait_load_threshold = 0; wait_store_threshold = 0; wait_ds_threshold = 0;
            wait_km_threshold = 0; wait_async_threshold = 0; wait_tensor_threshold = 0;
            wait_x_threshold = 0;
        end
    endtask

    task automatic reset_model;
        integer id, counter_kind;
        begin
            for (id = 0; id < N; id = id + 1) begin
                model_active[id] = 0;
                model_mask[id] = 0;
                for (counter_kind = 0; counter_kind < 7; counter_kind = counter_kind + 1) begin
                    model_count[id][counter_kind] = 0;
                    model_threshold[id][counter_kind] = 0;
                end
            end
        end
    endtask

    task automatic check_state;
        integer id, counter_kind;
        begin
            expected_wait = 0; expected_zero = '1;
            for (id = 0; id < N; id = id + 1) begin
                expected_wait[id] = model_active[id];
                if (dut.wait_active[id] !== model_active[id])
                    $fatal(1, "N=%0d cycle=%0d wave=%0d active mismatch", N, cycles, id);
                if (dut.saved_wait_counter_mask[id] !== model_mask[id])
                    $fatal(1, "N=%0d cycle=%0d wave=%0d saved mask mismatch", N, cycles, id);
                for (counter_kind = 0; counter_kind < 7; counter_kind = counter_kind + 1) begin
                    if (count_of(id, counter_kind) !== model_count[id][counter_kind])
                        $fatal(1, "N=%0d cycle=%0d wave=%0d kind=%0d count expected=%0d got=%0d",
                            N, cycles, id, counter_kind, model_count[id][counter_kind], count_of(id, counter_kind));
                    if (saved_threshold_of(id, counter_kind) !== model_threshold[id][counter_kind])
                        $fatal(1, "N=%0d cycle=%0d wave=%0d kind=%0d saved threshold mismatch", N, cycles, id, counter_kind);
                    if (model_count[id][counter_kind] != 0) expected_zero[id] = 0;
                    if (model_mask[id][counter_kind] &&
                        model_count[id][counter_kind] > model_threshold[id][counter_kind])
                        expected_wait[id] = 0;
                    checks = checks + 2;
                end
                checks = checks + 2;
            end
            if (wait_arm_satisfied !== arm_satisfied_model())
                $fatal(1, "N=%0d cycle=%0d incoming Wait query mismatch", N, cycles);
            if (wait_satisfied_mask !== expected_wait)
                $fatal(1, "N=%0d cycle=%0d stored Wait expected=%b got=%b", N, cycles, expected_wait, wait_satisfied_mask);
            if (all_counters_zero_mask !== expected_zero)
                $fatal(1, "N=%0d cycle=%0d zero mask expected=%b got=%b", N, cycles, expected_zero, all_counters_zero_mask);
            checks = checks + 3;
        end
    endtask

    task automatic tick;
        integer id, counter_kind, net;
        logic issue_legal, complete_legal, arm_legal, arm_good;
        begin
            #1;
            check_state();
            // Wake acknowledgement is an external protocol invariant.
            if (|(wait_wakeup_mask & ~wait_satisfied_mask))
                $fatal(1, "TB protocol: acknowledgement of an unsatisfied Wait");
            issue_legal = dependency_issue_valid && resident_id(dependency_issue_wave_id) &&
                          dependency_issue_kind < 7 && dependency_issue_amount != 0;
            complete_legal = dependency_complete_valid && resident_id(dependency_complete_wave_id) &&
                             dependency_complete_kind < 7 && dependency_complete_amount != 0;
            arm_legal = wait_arm_valid && resident_id(wait_arm_wave_id);
            arm_good = arm_satisfied_model();
            if (dependency_issue_valid && !issue_legal) ignored_events = ignored_events + 1;
            if (dependency_complete_valid && !complete_legal) ignored_events = ignored_events + 1;
            if (wait_arm_valid && !arm_legal) ignored_events = ignored_events + 1;
            @(posedge clk);
            // Save incoming Wait satisfaction BEFORE updating model counts.
            for (id = 0; id < N; id = id + 1) begin
                if (!rst_n) begin
                    model_active[id] = 0; model_mask[id] = 0;
                    for (counter_kind = 0; counter_kind < 7; counter_kind = counter_kind + 1)
                        model_threshold[id][counter_kind] = 0;
                end
                else if (arm_legal && wait_arm_wave_id == id) begin
                    model_active[id] = !arm_good;
                    model_mask[id] = wait_counter_mask;
                    for (counter_kind = 0; counter_kind < 7; counter_kind = counter_kind + 1)
                        model_threshold[id][counter_kind] = threshold_of(counter_kind);
                end
                else if (wait_wakeup_mask[id]) model_active[id] = 0;
                for (counter_kind = 0; counter_kind < 7; counter_kind = counter_kind + 1) begin
                    if (!rst_n || (release_valid && release_wave_id == id) || (alloc_fire && alloc_wave_id == id))
                        model_count[id][counter_kind] = 0;
                    else begin
                        net = model_count[id][counter_kind];
                        if (issue_legal && dependency_issue_wave_id == id && dependency_issue_kind == counter_kind)
                            net = net + dependency_issue_amount;
                        if (complete_legal && dependency_complete_wave_id == id && dependency_complete_kind == counter_kind)
                            net = net - dependency_complete_amount;
                        if (net < 0) underflow_holds = underflow_holds + 1;
                        else if (net > limit_of(counter_kind)) overflow_holds = overflow_holds + 1;
                        else model_count[id][counter_kind] = net;
                    end
                end
            end
            cycles = cycles + 1;
            #1; check_state();
            @(negedge clk);
        end
    endtask

    task automatic issue_one(input integer id, input integer counter_kind, input integer value);
        begin
            idle_inputs(); dependency_issue_valid = 1;
            dependency_issue_wave_id = id; dependency_issue_kind = counter_kind;
            dependency_issue_amount = value; tick();
        end
    endtask

    task automatic complete_one(input integer id, input integer counter_kind, input integer value);
        begin
            idle_inputs(); dependency_complete_valid = 1;
            dependency_complete_wave_id = id; dependency_complete_kind = counter_kind;
            dependency_complete_amount = value; tick();
        end
    endtask

    task automatic acknowledge_all;
        begin
            idle_inputs(); #1; wait_wakeup_mask = wait_satisfied_mask; tick();
        end
    endtask

    task automatic async_reset;
        begin
            idle_inputs();
            #2; rst_n = 0;
            reset_model();
            #1; check_state(); // Observe reset BEFORE the next clock edge.
            @(negedge clk);
            rst_n = 1; tick();
        end
    endtask

    initial begin
        random_value = $urandom(seed);
        reset_model();
        async_reset();

        // All seven counter limits, including KM 31+63-63=31.
        for (k = 0; k < 7; k = k + 1) begin
            issue_one(0, k, limit_of(k));
            dependency_issue_amount = 63;
            dependency_complete_valid = 1; dependency_complete_wave_id = 0;
            dependency_complete_kind = k; dependency_complete_amount = 63;
            tick();
            issue_one(0, k, 1); // Intentional overflow: hold, not wrap.
            complete_one(0, k, limit_of(k));
            complete_one(0, k, 1); // Intentional underflow: hold, not wrap.
        end

        // Direct storage-control tests exercise clearing nonzero counters.
        // These stimuli test reset/release/allocation precedence in isolation;
        // the legal safe-retirement lifecycle is tested at the end separately.
        for (k = 0; k < 7; k = k + 1) issue_one(0, k, 2);
        idle_inputs(); release_valid = 1; release_wave_id = 0;
        dependency_issue_valid = 1; dependency_issue_wave_id = N-1;
        dependency_issue_kind = DEP_X; dependency_issue_amount = 1; tick();
        for (k = 0; k < 7; k = k + 1) issue_one(0, k, 2);
        idle_inputs(); alloc_fire = 1; alloc_wave_id = 0;
        dependency_complete_valid = 1; dependency_complete_wave_id = 0;
        dependency_complete_kind = DEP_LOAD; dependency_complete_amount = 1;
        dependency_issue_valid = 1; dependency_issue_wave_id = N-1;
        dependency_issue_kind = DEP_ASYNC; dependency_issue_amount = 1; tick();
        if (N > 1) begin
            complete_one(N-1, DEP_X, 1);
            complete_one(N-1, DEP_ASYNC, 1);
        end

        // Single-class thresholds 0/1/2/3; saved config survives input changes.
        for (k = 0; k < 7; k = k + 1) begin
            issue_one(0, k, 3);
            idle_inputs(); wait_arm_valid = 1; wait_arm_wave_id = 0;
            wait_counter_mask[k] = 1;
            for (j = 0; j <= 3; j = j + 1) begin
                set_threshold(k, j); #1; check_state();
            end
            set_threshold(k, 2); tick();
            idle_inputs();
            for (j = 0; j < 7; j = j + 1) set_threshold(j, limit_of(j));
            tick(); // Ports changed; stored threshold must remain 2.
            complete_one(0, k, 1); // Stored Wait satisfied at count 2.
            idle_inputs(); tick(); // Satisfaction stays high without ack.
            acknowledge_all();
            complete_one(0, k, 2);
        end

        // Empty mask and unselected nonzero counters are immediately satisfied.
        issue_one(0, DEP_LOAD, 3);
        idle_inputs(); wait_arm_valid = 1; wait_arm_wave_id = 0; tick();
        wait_counter_mask[DEP_STORE] = 1; tick();
        complete_one(0, DEP_LOAD, 3);

        // AND of selected classes: equality passes; one failing class blocks.
        issue_one(0, DEP_LOAD, 3); issue_one(0, DEP_STORE, 1);
        idle_inputs(); wait_arm_valid = 1; wait_arm_wave_id = 0;
        wait_counter_mask = (1 << DEP_LOAD) | (1 << DEP_STORE);
        wait_load_threshold = 2; wait_store_threshold = 1; tick();
        complete_one(0, DEP_LOAD, 1); acknowledge_all();
        complete_one(0, DEP_LOAD, 2); complete_one(0, DEP_STORE, 1);

        // Every context waits independently, then a single mask acknowledges all.
        for (i = 0; i < N; i = i + 1) begin
            issue_one(i, DEP_LOAD, 3);
            idle_inputs(); wait_arm_valid = 1; wait_arm_wave_id = i;
            wait_counter_mask[DEP_LOAD] = 1; wait_load_threshold = (i % 2) + 1; tick();
        end
        for (i = 0; i < N; i = i + 1) complete_one(i, DEP_LOAD, 3);
        if (wait_satisfied_mask !== {N{1'b1}}) $fatal(1, "All-wave satisfaction missing");
        acknowledge_all();

        // Completion and arm on one edge use PRE-edge counts for arm query.
        issue_one(0, DEP_DS, 1);
        idle_inputs(); wait_arm_valid = 1; wait_arm_wave_id = 0;
        wait_counter_mask[DEP_DS] = 1;
        dependency_complete_valid = 1; dependency_complete_wave_id = 0;
        dependency_complete_kind = DEP_DS; dependency_complete_amount = 1; tick();
        if (dut.wait_active[0] !== 1'b1 || wait_satisfied_mask[0] !== 1'b1)
            $fatal(1, "No-bypass completion/arm timing mismatch");
        acknowledge_all();

        // Different Waves and different kinds can update on the same edge.
        issue_one(N-1, DEP_LOAD, 2); issue_one(0, DEP_STORE, 1);
        idle_inputs(); dependency_issue_valid = 1; dependency_issue_wave_id = 0;
        dependency_issue_kind = DEP_ASYNC; dependency_issue_amount = 1;
        dependency_complete_valid = 1; dependency_complete_wave_id = N-1;
        dependency_complete_kind = DEP_LOAD; dependency_complete_amount = 1; tick();
        dependency_issue_wave_id = N-1; dependency_issue_kind = DEP_X; dependency_issue_amount = 2;
        dependency_complete_wave_id = 0; dependency_complete_kind = DEP_STORE; tick();
        complete_one(N-1, DEP_LOAD, 1); complete_one(0, DEP_ASYNC, 1);
        complete_one(N-1, DEP_X, 2);

        // Sustained valid represents one event on each rising edge.
        issue_one(0, DEP_TENSOR, 1); tick(); tick();
        if (model_count[0][DEP_TENSOR] != 3) $fatal(1, "Consecutive issue count mismatch");
        complete_one(0, DEP_TENSOR, 1); tick(); tick();

        // Invalid kinds / zero amounts / nonresident IDs / unused ID encodings.
        issue_one(0, 7, 1); complete_one(0, 7, 1);
        issue_one(0, DEP_LOAD, 0); complete_one(0, DEP_LOAD, 0);
        resident_mask[0] = 0;
        issue_one(0, DEP_LOAD, 1); complete_one(0, DEP_LOAD, 1);
        idle_inputs(); wait_arm_valid = 1; wait_arm_wave_id = 0; tick();
        resident_mask = '1;
        if ((1 << W) > N) begin
            issue_one(N, DEP_LOAD, 1); complete_one(N, DEP_LOAD, 1);
            idle_inputs(); wait_arm_valid = 1; wait_arm_wave_id = N; tick();
        end

        // Reset an active Wait and nonzero counters asynchronously.
        issue_one(0, DEP_KM, 2);
        idle_inputs(); wait_arm_valid = 1; wait_arm_wave_id = 0;
        wait_counter_mask[DEP_KM] = 1; tick(); async_reset();

        // Random legal Wait lifecycle and bounded dependency events.
        for (trial = 0; trial < 4000; trial = trial + 1) begin
            idle_inputs();
            #1;
            for (i = 0; i < N; i = i + 1)
                wait_wakeup_mask[i] = wait_satisfied_mask[i] && $urandom_range(0,1);
            wave = $urandom_range(0,N-1); kind = $urandom_range(0,6);
            capacity = limit_of(kind) - model_count[wave][kind];
            if (!model_active[wave] && capacity > 0 && $urandom_range(0,3) != 0) begin
                dependency_issue_valid = 1; dependency_issue_wave_id = wave;
                dependency_issue_kind = kind;
                dependency_issue_amount = $urandom_range(1, (capacity < 4) ? capacity : 4);
            end
            wave = $urandom_range(0,N-1); kind = $urandom_range(0,6);
            amount = model_count[wave][kind];
            if (amount > 0 && $urandom_range(0,3) != 0) begin
                dependency_complete_valid = 1; dependency_complete_wave_id = wave;
                dependency_complete_kind = kind;
                dependency_complete_amount = $urandom_range(1, (amount < 5) ? amount : 5);
            end
            wave = $urandom_range(0,N-1);
            if (!model_active[wave] && $urandom_range(0,4) == 0) begin
                wait_arm_valid = 1; wait_arm_wave_id = wave;
                wait_counter_mask = $urandom_range(0,127);
                for (j = 0; j < 7; j = j + 1) set_threshold(j, $urandom_range(0,3));
                if (dependency_issue_valid && dependency_issue_wave_id == wave)
                    dependency_issue_valid = 0;
            end
            tick();
        end

        // Drain, wake, then retire/reallocate each context: no active Wait is reused.
        for (i = 0; i < N; i = i + 1)
            for (k = 0; k < 7; k = k + 1)
                if (model_count[i][k] != 0) complete_one(i, k, model_count[i][k]);
        acknowledge_all();
        for (i = 0; i < N; i = i + 1) begin
            if (model_active[i] || !all_counters_zero_mask[i])
                $fatal(1, "TB protocol: unsafe context reuse");
            idle_inputs(); release_valid = 1; release_wave_id = i; tick();
            resident_mask[i] = 0; idle_inputs(); tick();
            alloc_fire = 1; alloc_wave_id = i; tick();
            resident_mask[i] = 1;
            issue_one(i, DEP_LOAD, 1);
            idle_inputs(); wait_arm_valid = 1; wait_arm_wave_id = i;
            wait_counter_mask[DEP_LOAD] = 1; tick();
            complete_one(i, DEP_LOAD, 1); acknowledge_all();
        end
        if (underflow_holds != 7 || overflow_holds != 7)
            $fatal(1, "Expected seven directed underflow and seven overflow cases");
        $display("PASS N=%0d cycles=%0d checks=%0d underflow_holds=%0d overflow_holds=%0d ignored_events=%0d",
                 N, cycles, checks, underflow_holds, overflow_holds, ignored_events);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "Simulation timeout");
    end
endmodule
