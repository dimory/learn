`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// M3 F05: Per-Wave scalar register file.
//
// Microarchitecture:
// - NUM_SGPRS independent 32-bit registers per resident Wave.
// - One flattened data array with NUM_WAVE_CONTEXTS * NUM_SGPRS rows.
// - Row address = wave_id * NUM_SGPRS + register_index.
// - Two independent synchronous read ports and one synchronous write port.
// - Each read port has its own enable, Wave ID and register index.
// - Initializer and execution writeback share the single physical write port;
//   their arbitration is performed outside this module.
//
// Timing:
// - Enabled reads sample their addresses at clock edge N.
// - read_data is updated after edge N; the Collector captures it at edge N+1.
// - Disabled read ports hold their previous output values.
// - Enabled writes update one selected row at the clock edge.
// - There is no write-to-read bypass.
// - RTL reads return the old value for a same-row read and write at one edge.
//
// Initialization:
// - The data array and read output registers have no reset.
// - Architectural initialization is performed by wave_register_init.
// - Read outputs are usable only after a valid read request.
// ============================================================================

module wave_sgpr_file #(
    parameter int NUM_WAVE_CONTEXTS = 4,
    parameter int NUM_SGPRS = 32,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    input logic clk,

    // Two independent read ports.
    input logic [1:0] read_enable,
    input logic [WAVE_ID_BITS-1:0] read_wave0,
    input logic [WAVE_ID_BITS-1:0] read_wave1,
    input logic [9:0] read_index0,
    input logic [9:0] read_index1,
    output logic [31:0] read_data0,
    output logic [31:0] read_data1,

    // One shared write port.
    input logic write_enable,
    input logic [WAVE_ID_BITS-1:0] write_wave_id,
    input logic [9:0] write_index,
    input logic [31:0] write_data
);

localparam int RF_DEPTH = NUM_WAVE_CONTEXTS * NUM_SGPRS;

// Architectural register storage.
logic [31:0] data [0:RF_DEPTH-1];

// Combinational row addresses.
integer read_row0;
integer read_row1;
integer write_row;

assign read_row0 = read_wave0 * NUM_SGPRS + read_index0;
assign read_row1 = read_wave1 * NUM_SGPRS + read_index1;
assign write_row = write_wave_id * NUM_SGPRS + write_index;

always_ff @(posedge clk )begin
	if(read_enable[0])	
		read_data0 <= data[read_row0];
	if(read_enable[1])
		read_data1 <= data[read_row1];
	if(write_enable)
		data[write_row] <= write_data;
end

endmodule

`default_nettype wire