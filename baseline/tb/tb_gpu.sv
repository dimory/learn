`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// TinyGPU Baseline Self-Checking Verification Environment
// ============================================================================
//
// Verification scope
// -----------------------------------------------------------------------------
// This testbench is intentionally separate from rtl/gpu_top.sv. It performs
// simulation-only SRAM initialization, kernel launch, timeout handling, result
// checking and optional FSDB dumping.
//
// Tests
// -----------------------------------------------------------------------------
//
// Name             Main coverage
// ---------------  -----------------------------------------------------------
// mat_add          8 threads, two Blocks, LDR/ADD/STR, all four banks
partial_block      6 threads, second Block lane_valid_mask == 4'b0011
mat_mul          2x2 matrix multiply and byte-addressed backward branch
divergence         Per-lane next_pc mismatch and Lane-0 baseline policy
bank_conflict      Four Lane loads serialized through the same SRAM bank
zero_thread        Dispatcher zero-thread launch completion
all                Run every test above in one simulation
//
// Memory initialization
// -----------------------------------------------------------------------------
// SRAM arrays have no reset. This testbench loads them hierarchically before
// releasing rst_n. Hierarchical access is verification-only and is not present
// in the synthesizable top.
//
// Logical data address mapping:
//
//     bank = address[1:0]
//     row  = address[7:2]
//
// VCS/Verdi
// -----------------------------------------------------------------------------
// Define FSDB during compilation to enable wave dumping:
//
//     +define+FSDB
//
// Select one test at runtime with +TEST=<name>. With no plusarg, all tests run.
// ============================================================================

module tb_gpu;

localparam int DATA_BITS         = 8;
localparam int ADDR_BITS         = 8;
localparam int PC_BITS           = 8;
localparam int INSTRUCTION_BITS  = 16;
localparam int LANES_PER_WAVE    = 4;
localparam int THREADS_PER_BLOCK = 4;
localparam int THREAD_COUNT_BITS = 8;
localparam int NUM_BANKS         = 4;
localparam int IMEM_DEPTH        = 128;
localparam int BANK_DEPTH        = 64;
localparam int MAX_KERNEL_CYCLES = 20000;

logic                         clk;
logic                         rst_n;
logic                         start;
logic [PC_BITS-1:0]           start_pc;
logic [THREAD_COUNT_BITS-1:0] thread_count;
logic                         busy;
logic                         done;
logic                         divergence_detected;

integer failure_count;
integer test_count;
logic   saw_divergence;
string  selected_test;

gpu_top #(
    .DATA_BITS         (DATA_BITS),
    .ADDR_BITS         (ADDR_BITS),
    .PC_BITS           (PC_BITS),
    .INSTRUCTION_BITS  (INSTRUCTION_BITS),
    .LANES_PER_WAVE    (LANES_PER_WAVE),
    .THREADS_PER_BLOCK (THREADS_PER_BLOCK),
    .THREAD_COUNT_BITS (THREAD_COUNT_BITS),
    .NUM_BANKS         (NUM_BANKS)
) dut (
    .clk                 (clk),
    .rst_n               (rst_n),
    .start               (start),
    .start_pc            (start_pc),
    .thread_count        (thread_count),
    .busy                (busy),
    .done                (done),
    .divergence_detected (divergence_detected)
);

initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
end

`ifdef FSDB
initial begin
    $fsdbDumpfile("waves/tinygpu_baseline.fsdb");
    $fsdbDumpvars(0, tb_gpu);
    $fsdbDumpMDA();
end
`endif

task automatic clear_instruction_memory;
    integer word_index;
    begin
        for (word_index = 0;
             word_index < IMEM_DEPTH;
             word_index = word_index + 1) begin
            dut.u_instruction_sram.memory[word_index] = 16'h0000;
        end
    end
endtask

task automatic clear_data_memory;
    integer row;
    begin
        for (row = 0; row < BANK_DEPTH; row = row + 1) begin
            dut.u_memory_subsystem.gen_sram_bank[0].u_sram.memory[row] = '0;
            dut.u_memory_subsystem.gen_sram_bank[1].u_sram.memory[row] = '0;
            dut.u_memory_subsystem.gen_sram_bank[2].u_sram.memory[row] = '0;
            dut.u_memory_subsystem.gen_sram_bank[3].u_sram.memory[row] = '0;
        end
    end
endtask

task automatic write_data_word(
    input integer address,
    input logic [DATA_BITS-1:0] value
);
    integer row;
    begin
        row = address >> 2;
        case (address & 3)
            0: dut.u_memory_subsystem.gen_sram_bank[0].u_sram.memory[row] = value;
            1: dut.u_memory_subsystem.gen_sram_bank[1].u_sram.memory[row] = value;
            2: dut.u_memory_subsystem.gen_sram_bank[2].u_sram.memory[row] = value;
            3: dut.u_memory_subsystem.gen_sram_bank[3].u_sram.memory[row] = value;
        endcase
    end
endtask

function automatic [DATA_BITS-1:0] read_data_word(input integer address);
    integer row;
    begin
        row = address >> 2;
        case (address & 3)
            0: read_data_word =
                dut.u_memory_subsystem.gen_sram_bank[0].u_sram.memory[row];
            1: read_data_word =
                dut.u_memory_subsystem.gen_sram_bank[1].u_sram.memory[row];
            2: read_data_word =
                dut.u_memory_subsystem.gen_sram_bank[2].u_sram.memory[row];
            3: read_data_word =
                dut.u_memory_subsystem.gen_sram_bank[3].u_sram.memory[row];
            default: read_data_word = 'x;
        endcase
    end
endfunction

task automatic prepare_test(input string program_file);
    begin
        start        = 1'b0;
        start_pc     = '0;
        thread_count = '0;
        rst_n        = 1'b0;

        clear_instruction_memory();
        clear_data_memory();

        if (program_file != "") begin
            $readmemh(program_file, dut.u_instruction_sram.memory);
        end

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
    end
endtask

task automatic launch_kernel(input integer number_of_threads);
    begin
        @(negedge clk);
        start_pc     = 8'h00;
        thread_count = number_of_threads[THREAD_COUNT_BITS-1:0];
        start        = 1'b1;

        @(negedge clk);
        start = 1'b0;
    end
endtask

task automatic wait_for_kernel_done;
    integer cycle_count;
    begin
        cycle_count    = 0;
        saw_divergence = 1'b0;

        while ((done !== 1'b1) &&
               (cycle_count < MAX_KERNEL_CYCLES)) begin
            @(posedge clk);
            #1;
            if (divergence_detected === 1'b1)
                saw_divergence = 1'b1;
            cycle_count = cycle_count + 1;
        end

        if (done !== 1'b1) begin
            failure_count = failure_count + 1;
            $display("[FAIL] Kernel timeout after %0d cycles", cycle_count);
        end
        else begin
            $display("[INFO] Kernel completed in %0d cycles", cycle_count);
        end

        @(posedge clk);
        #1;
    end
endtask

task automatic expect_data(
    input integer address,
    input logic [DATA_BITS-1:0] expected,
    input string label_text
);
    logic [DATA_BITS-1:0] actual;
    begin
        actual = read_data_word(address);
        if (actual !== expected) begin
            failure_count = failure_count + 1;
            $display("[FAIL] %s address=%0d expected=0x%02h actual=0x%02h",
                     label_text, address, expected, actual);
        end
    end
endtask

task automatic report_case(input string case_name, input integer failures_before);
    begin
        test_count = test_count + 1;
        if (failure_count == failures_before)
            $display("[PASS] %s", case_name);
        else
            $display("[FAIL] %s (%0d new failures)",
                     case_name, failure_count - failures_before);
    end
endtask

task automatic run_mat_add;
    integer i;
    integer failures_before;
    begin
        failures_before = failure_count;
        $display("\n[TEST] mat_add");
        prepare_test("patterns/mat_add.hex");

        for (i = 0; i < 8; i = i + 1) begin
            write_data_word(i,     i[7:0]);
            write_data_word(8 + i, i[7:0]);
            write_data_word(16 + i, 8'ha5);
        end

        launch_kernel(8);
        wait_for_kernel_done();

        for (i = 0; i < 8; i = i + 1)
            expect_data(16 + i, (2 * i), "mat_add C[i]");

        report_case("mat_add", failures_before);
    end
endtask

task automatic run_partial_block;
    integer i;
    integer failures_before;
    begin
        failures_before = failure_count;
        $display("\n[TEST] partial_block");
        prepare_test("patterns/mat_add.hex");

        for (i = 0; i < 8; i = i + 1) begin
            write_data_word(i,      i[7:0]);
            write_data_word(8 + i,  i[7:0]);
            write_data_word(16 + i, 8'ha5);
        end

        launch_kernel(6);
        wait_for_kernel_done();

        for (i = 0; i < 6; i = i + 1)
            expect_data(16 + i, (2 * i), "partial valid lane");

        expect_data(22, 8'ha5, "partial invalid lane 2");
        expect_data(23, 8'ha5, "partial invalid lane 3");

        report_case("partial_block", failures_before);
    end
endtask

task automatic run_mat_mul;
    integer failures_before;
    begin
        failures_before = failure_count;
        $display("\n[TEST] mat_mul");
        prepare_test("patterns/mat_mul.hex");

        write_data_word(0, 8'd1);
        write_data_word(1, 8'd2);
        write_data_word(2, 8'd3);
        write_data_word(3, 8'd4);
        write_data_word(4, 8'd1);
        write_data_word(5, 8'd2);
        write_data_word(6, 8'd3);
        write_data_word(7, 8'd4);

        launch_kernel(4);
        wait_for_kernel_done();

        expect_data(8,  8'd7,  "mat_mul C[0][0]");
        expect_data(9,  8'd10, "mat_mul C[0][1]");
        expect_data(10, 8'd15, "mat_mul C[1][0]");
        expect_data(11, 8'd22, "mat_mul C[1][1]");

        report_case("mat_mul", failures_before);
    end
endtask

task automatic run_divergence;
    integer i;
    integer failures_before;
    begin
        failures_before = failure_count;
        $display("\n[TEST] divergence");
        prepare_test("patterns/divergence.hex");

        for (i = 32; i < 36; i = i + 1)
            write_data_word(i, 8'h00);

        launch_kernel(4);
        wait_for_kernel_done();

        if (saw_divergence !== 1'b1) begin
            failure_count = failure_count + 1;
            $display("[FAIL] divergence indication was never observed");
        end

        for (i = 32; i < 36; i = i + 1)
            expect_data(i, 8'h11, "divergence Lane-0 path");

        report_case("divergence", failures_before);
    end
endtask

task automatic run_bank_conflict;
    integer failures_before;
    begin
        failures_before = failure_count;
        $display("\n[TEST] bank_conflict");
        prepare_test("patterns/bank_conflict.hex");

        write_data_word(0,  8'd10);
        write_data_word(4,  8'd20);
        write_data_word(8,  8'd30);
        write_data_word(12, 8'd40);

        launch_kernel(4);
        wait_for_kernel_done();

        expect_data(64, 8'd10, "bank_conflict lane0");
        expect_data(65, 8'd20, "bank_conflict lane1");
        expect_data(66, 8'd30, "bank_conflict lane2");
        expect_data(67, 8'd40, "bank_conflict lane3");

        report_case("bank_conflict", failures_before);
    end
endtask

task automatic run_zero_thread;
    integer failures_before;
    begin
        failures_before = failure_count;
        $display("\n[TEST] zero_thread");
        prepare_test("");
        launch_kernel(0);
        wait_for_kernel_done();
        report_case("zero_thread", failures_before);
    end
endtask

initial begin
    rst_n           = 1'b0;
    start           = 1'b0;
    start_pc        = '0;
    thread_count    = '0;
    failure_count   = 0;
    test_count      = 0;
    saw_divergence  = 1'b0;

    if (!$value$plusargs("TEST=%s", selected_test))
        selected_test = "all";

    if ((selected_test == "all") || (selected_test == "mat_add"))
        run_mat_add();

    if ((selected_test == "all") || (selected_test == "partial_block"))
        run_partial_block();

    if ((selected_test == "all") || (selected_test == "mat_mul"))
        run_mat_mul();

    if ((selected_test == "all") || (selected_test == "divergence"))
        run_divergence();

    if ((selected_test == "all") || (selected_test == "bank_conflict"))
        run_bank_conflict();

    if ((selected_test == "all") || (selected_test == "zero_thread"))
        run_zero_thread();

    if (test_count == 0) begin
        failure_count = failure_count + 1;
        $display("[FAIL] Unknown TEST selection: %s", selected_test);
    end

    if (failure_count == 0) begin
        $display("\n========================================");
        $display("TinyGPU baseline: ALL %0d TESTS PASSED", test_count);
        $display("========================================");
    end
    else begin
        $display("\n========================================");
        $display("TinyGPU baseline: %0d FAILURE(S)", failure_count);
        $display("========================================");
    end

    $finish;
end

endmodule

`default_nettype wire
