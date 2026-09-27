// Microarchitecture
// -----------------------------------------------------------------------------
//                         Instruction Decoder
// ┌────────────────────────────────────────────────────────────────────┐
// │                                                                    │
// │                    instruction[15:0]                               │
// │                            │                                       │
// │                            ▼                                       │
// │              ┌─────────────────────────┐                           │
// │              │ Instruction Field Split │                           │
// │              │                         │                           │
// │              │ opcode    = [15:12]     │                           │
// │              │ rd        = [11:8]      │                           │
// │              │ rs        = [7:4]       │                           │
// │              │ rt        = [3:0]       │                           │
// │              │ nzp_mask  = [11:9]      │                           │
// │              │ immediate = [7:0]       │                           │
// │              └────────────┬────────────┘                           │
// │                           │                                        │
// │              ┌────────────┴────────────┐                           │
// │              │                         │                           │
// │              ▼                         ▼                           │
// │   ┌────────────────────┐    ┌────────────────────────┐             │
// │   │ Decoded Fields     │    │ Opcode Control Decode  │             │
// │   │                    │    │                        │             │
// │   │ rd / rs / rt       │    │ Register write enable  │             │
// │   │ NZP mask           │    │ Register input MUX     │             │
// │   │ immediate          │    │ ALU operation          │             │
// │   └─────────┬──────────┘    │ Memory read/write      │             │
// │             │               │ NZP/PC control         │             │
// │             │               │ RET control            │             │
// │             │               └───────────┬────────────┘             │
// │             │                           │                          │
// │             └──────────────┬────────────┘                          │
// │                            ▼                                       │
// │              ┌─────────────────────────┐                           │
// │              │ Registered Decoder      │                           │
// │              │ Outputs                 │                           │
// │              │                         │                           │
// │              │ Updated only when:      │                           │
// │              │ core_state == DECODE    │                           │
// │              └────────────┬────────────┘                           │
// │                           │                                        │
// │                           ▼                                        │
// │               decoded_* control signals                            │
// │                                                                    │
// └────────────────────────────────────────────────────────────────────┘
//





// ============================================================================
// TinyGPU Instruction Decoder
// ============================================================================
//
// Instruction format
// -----------------------------------------------------------------------------
// instruction[15:12] : opcode
// instruction[11:8]  : rd
// instruction[7:4]   : rs
// instruction[3:0]   : rt
// instruction[11:9]  : NZP branch mask
// instruction[7:0]   : immediate / absolute branch target
//
// Decoder behavior
// -----------------------------------------------------------------------------
// 1. Decoder registers are updated only when core_state == DECODE.
// 2. All control signals are cleared before decoding each new instruction.
// 3. Decoded fields and controls remain unchanged outside the DECODE stage.
// 4. rst_n is an asynchronous active-low reset.
//
// ============================================================================
// decoded_reg_input_mux
// ============================================================================
//
// Value   Register writeback source
// -----   --------------------------------------------------
// 2'b00   ALU output
// 2'b01   LSU load output
// 2'b10   Immediate value
// 2'b11   Reserved
//
// ============================================================================
// decoded_alu_arithmetic_mux
// ============================================================================
//
// Value   ALU arithmetic operation
// -----   --------------------------------------------------
// 2'b00   ADD
// 2'b01   SUB
// 2'b10   MUL
// 2'b11   DIV
//
// ============================================================================
// decoded_alu_output_mux
// ============================================================================
//
// Value   ALU output type
// -----   --------------------------------------------------
// 1'b0    Arithmetic result selected by alu_arithmetic_mux
// 1'b1    CMP result encoded as {N, Z, P}
//
// ============================================================================
// decoded_pc_mux
// ============================================================================
//
// Value   Next-PC selection
// -----   --------------------------------------------------
// 1'b0    Sequential PC: current_pc + 1
// 1'b1    Conditional branch using saved NZP and decoded_nzp
//
// ============================================================================
// Enable/control signals
// ============================================================================
//
// Signal                            Meaning when asserted
// --------------------------------  -------------------------------------------
// decoded_reg_write_enable          Write selected data into Register[rd]
// decoded_mem_read_enable           Start an LSU/SRAM read operation
// decoded_mem_write_enable          Start an LSU/SRAM write operation
// decoded_nzp_write_enable          Update saved NZP with the CMP result
// decoded_ret                       Finish execution of the current block/wave
//
// ============================================================================
// Opcode control table
// ============================================================================
//
//                                    reg_   alu_   alu_   mem_  mem_  nzp_  pc_
// Opcode  Instruction  reg_write     input  arith  output read  write write mux  ret
// ------  -----------  ------------  -----  -----  ------ ----  ----- ----- ---  ---
// 4'h0    NOP          0             00     00     0      0     0     0     0    0
// 4'h1    BRNZP        0             00     00     0      0     0     0     1    0
// 4'h2    CMP          0             00     00     1      0     0     1     0    0
// 4'h3    ADD          1             00     00     0      0     0     0     0    0
// 4'h4    SUB          1             00     01     0      0     0     0     0    0
// 4'h5    MUL          1             00     10     0      0     0     0     0    0
// 4'h6    DIV          1             00     11     0      0     0     0     0    0
// 4'h7    LDR          1             01     00     0      1     0     0     0    0
// 4'h8    STR          0             00     00     0      0     1     0     0    0
// 4'h9    CONST        1             10     00     0      0     0     0     0    0
// 4'hF    RET          0             00     00     0      0     0     0     0    1
//
// Notes
// -----------------------------------------------------------------------------
// - MUX values shown as 0 for unused paths are default/reset values.
// - BRNZP uses instruction[11:9] as its NZP mask.
// - BRNZP uses instruction[7:0] as an absolute target PC.
// - CMP reads rs and rt but does not write a general-purpose register.
// - LDR uses Register[rs] as the memory address and writes data to Register[rd].
// - STR uses Register[rs] as the memory address and Register[rt] as write data.
// - CONST writes instruction[7:0] directly to Register[rd].
// - DIV requires Register[rt] to be non-zero.
// ============================================================================




module decoder (
    input  logic        clk,
    input  logic        rst_n,

    // Core当前执行阶段
    input  logic [2:0]  core_state,

    // Fetcher取回的16-bit指令
    input  logic [15:0] instruction,

    // 指令字段
    output logic [3:0]  decoded_rd_address,
    output logic [3:0]  decoded_rs_address,
    output logic [3:0]  decoded_rt_address,
    output logic [2:0]  decoded_nzp,
    output logic [7:0]  decoded_immediate,

    // Register File控制
    output logic        decoded_reg_write_enable,
    output logic [1:0]  decoded_reg_input_mux,

    // LSU控制
    output logic        decoded_mem_read_enable,
    output logic        decoded_mem_write_enable,

    // ALU控制
    output logic [1:0]  decoded_alu_arithmetic_mux,
    output logic        decoded_alu_output_mux,

    // PC/NZP控制
    output logic        decoded_nzp_write_enable,
    output logic        decoded_pc_mux,

    // Wave/Core完成控制
    output logic        decoded_ret
);

    // 由你实现
	
	
localparam DECODE = 3'b010;

localparam NOP   = 4'b0000;
localparam BRNZP = 4'b0001;
localparam CMP   = 4'b0010;
localparam ADD   = 4'b0011;
localparam SUB   = 4'b0100;
localparam MUL   = 4'b0101;
localparam DIV   = 4'b0110;
localparam LDR   = 4'b0111;
localparam STR   = 4'b1000;
localparam CONST = 4'b1001;
localparam RET   = 4'b1111;

logic [3:0] opcode;
logic [3:0] rd;
logic [3:0] rs;
logic [3:0] rt;
logic [2:0] nzp_mask;
logic [7:0] immediate ;

assign opcode    = instruction[15:12];
assign rd        = instruction[11:8];
assign rs        = instruction[7:4];
assign rt        = instruction[3:0];
assign nzp_mask  = instruction[11:9];
assign immediate = instruction[7:0];


always_ff @(posedge clk or negedge rst_n)
begin
	if (!rst_n)begin
		decoded_rd_address            <= '0;
		decoded_rs_address            <= '0;
		decoded_rt_address            <= '0;
		decoded_nzp                   <= '0;
		decoded_immediate             <= '0;
		decoded_reg_write_enable	  <= '0;
		decoded_reg_input_mux		  <= '0;
		decoded_mem_read_enable		  <= '0;
		decoded_mem_write_enable	  <= '0;
		decoded_alu_arithmetic_mux	  <= '0;
		decoded_alu_output_mux	      <= '0;
		decoded_nzp_write_enable	  <= '0;
		decoded_pc_mux				  <= '0;
		decoded_ret					  <= '0;
	end
	else if (core_state == DECODE)begin
		begin
				decoded_rd_address            <= rd;
				decoded_rs_address            <= rs;
				decoded_rt_address            <= rt;
				decoded_nzp                   <= nzp_mask;
				decoded_immediate             <= immediate;
				decoded_reg_write_enable	  <= '0;
				decoded_reg_input_mux		  <= '0;
				decoded_mem_read_enable		  <= '0;
				decoded_mem_write_enable	  <= '0;
				decoded_alu_arithmetic_mux	  <= '0;
				decoded_alu_output_mux	      <= '0;
				decoded_nzp_write_enable	  <= '0;
				decoded_pc_mux				  <= '0;
				decoded_ret					  <= '0;
				case(opcode)
					NOP: begin
					end
					BRNZP: begin
						decoded_pc_mux <= 1'b1;
					end
					CMP: begin
						decoded_nzp_write_enable <= 1'b1;
						decoded_alu_output_mux   <= 1'b1;
					end
					ADD: begin
						decoded_reg_write_enable   <= 1'b1;
						decoded_alu_arithmetic_mux <= 2'b00;
						decoded_reg_input_mux      <= 2'b00;
					end
					SUB: begin
						decoded_reg_write_enable   <= 1'b1;
						decoded_alu_arithmetic_mux <= 2'b01;
						decoded_reg_input_mux      <= 2'b00;					
					end
					MUL: begin
						decoded_reg_write_enable   <= 1'b1;
						decoded_alu_arithmetic_mux <= 2'b10;
						decoded_reg_input_mux      <= 2'b00;										
					end
					DIV: begin
						decoded_reg_write_enable   <= 1'b1;
						decoded_alu_arithmetic_mux <= 2'b11;
						decoded_reg_input_mux      <= 2'b00;					
					end
					LDR: begin
						decoded_reg_write_enable <= 1'b1;
						decoded_mem_read_enable  <= 1'b1;
						decoded_reg_input_mux	 <= 2'b01;
					end
					STR: begin
						decoded_mem_write_enable <= 1'b1;					
					end
					CONST: begin 
					 decoded_reg_input_mux 	<= 2'b10;
					 decoded_reg_write_enable <= 1'b1;
					end
					RET : begin
					decoded_ret  <=1'b1;
					end
					default: begin
					end
				endcase
		end
		
	end

end


endmodule
