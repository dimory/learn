`default_nettype none
`timescale 1ns/1ns

// ============================================================================
// M3 F06: Wave32 vector register file with four lane banks.
//
// Microarchitecture:
// - Each VGPR contains one 32-bit DWORD per logical lane.
// - Four independent lane banks, each with synchronous 2R1W access.
// - bank = lane % 4; beat = lane / 4.
// - Eight beats cover all 32 lanes of one VGPR.
// - Bank row = (wave_id * NUM_VGPRS + register_index) * 8 + beat.
// - Two read ports have independent Wave IDs and register indices.
// - Both read ports share read_beat.
// - Each read port returns four DWORDs packed into 128 bits.
// - Bank b occupies read_data[b*32 +: 32].
//
// Bank data layout:
// - bank_data[bank][row] stores one 32-bit lane DWORD.
// - For a fixed Wave w and VGPR r:
//     base_row = (w * NUM_VGPRS + r) * BEATS_PER_VGPR
//     row      = base_row + beat
//
//                      bank_data[bank][row]
//                   bank0     bank1     bank2     bank3
//                 --------------------------------------
//   base_row + 0    lane0     lane1     lane2     lane3
//   base_row + 1    lane4     lane5     lane6     lane7
//   base_row + 2    lane8     lane9     lane10    lane11
//   base_row + 3    lane12    lane13    lane14    lane15
//   base_row + 4    lane16    lane17    lane18    lane19
//   base_row + 5    lane20    lane21    lane22    lane23
//   base_row + 6    lane24    lane25    lane26    lane27
//   base_row + 7    lane28    lane29    lane30    lane31
//
// - All lane data above belongs to the same Wave w and VGPR r.
// - Each VGPR occupies eight rows in each of the four banks.
// - Within each port, all four banks use the same row address.
//
// Default row allocation in each bank:
// NUM_WAVE_CONTEXTS = 4; NUM_VGPRS = 64; BEATS_PER_VGPR = 8.
//
//   Wave       Row range       VGPR allocation
//   ---------------------------------------------------
//   Wave0      0    .. 511     v0 .. v63, 8 rows per VGPR
//   Wave1      512  .. 1023    v0 .. v63, 8 rows per VGPR
//   Wave2      1024 .. 1535    v0 .. v63, 8 rows per VGPR
//   Wave3      1536 .. 2047    v0 .. v63, 8 rows per VGPR
//
// Packed read_data / write_data layout for beat t:
//
//   Bit range     Bank       Logical lane
//   --------------------------------------------
//   [31:0]        bank0      4*t + 0
//   [63:32]       bank1      4*t + 1
//   [95:64]       bank2      4*t + 2
//   [127:96]      bank3      4*t + 3
//
// Write behavior:
// - One write port updates four lanes of one VGPR beat.
// - write_mask[b] enables the write to bank b.
// - Unselected banks preserve their previous data.
// - Initializer and execution writeback share the physical write port;
//   their arbitration is performed outside this module.
//
// Timing and initialization:
// - Enabled reads update read_data after the sampling clock edge.
// - The Collector captures the returned data at the following edge.
// - Disabled read ports hold their previous output values.
// - There is no write-to-read bypass; same-row RTL reads return old data.
// - Data arrays and read output registers have no reset.
// - Architectural initialization is performed through the write port.
// ============================================================================

module wave_vgpr_file #(
    parameter int NUM_WAVE_CONTEXTS = 4,
    parameter int NUM_VGPRS = 64,
    parameter int WAVE_ID_BITS =
        (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1
) (
    input logic clk,

    // Two independent read ports with a shared beat.
    input logic [1:0] read_enable,
    input logic [WAVE_ID_BITS-1:0] read_wave0,
    input logic [WAVE_ID_BITS-1:0] read_wave1,
    input logic [9:0] read_index0,
    input logic [9:0] read_index1,
    input logic [2:0] read_beat,
    output logic [127:0] read_data0,
    output logic [127:0] read_data1,

    // One masked write port.
    input logic write_enable,
    input logic [WAVE_ID_BITS-1:0] write_wave_id,
    input logic [9:0] write_index,
    input logic [2:0] write_beat,
    input logic [3:0] write_mask,
    input logic [127:0] write_data
);

localparam int NUM_BANKS = 4;
localparam int BEATS_PER_VGPR = 8;
localparam int BANK_DEPTH =
    NUM_WAVE_CONTEXTS * NUM_VGPRS * BEATS_PER_VGPR;

// Each bank stores one DWORD per row.
logic [31:0] bank_data [0:NUM_BANKS-1][0:BANK_DEPTH-1];

// Combinational row addresses.
integer read_row0;
integer read_row1;
integer write_row;

genvar bank;

assign read_row0 = (read_wave0 * NUM_VGPRS + read_index0) * BEATS_PER_VGPR + read_beat; //wave base address + vgpr index address + beat address.    each vgpr include 8 beat address.
assign read_row1 = (read_wave1 * NUM_VGPRS + read_index1) * BEATS_PER_VGPR + read_beat;
assign write_row = (write_wave_id * NUM_VGPRS + write_index) * BEATS_PER_VGPR + write_beat;
// Add address mapping and generated bank logic here.

generate
    for (bank = 0; bank < NUM_BANKS; bank = bank + 1) begin : g_bank
        always_ff @(posedge clk) begin

			if(read_enable[0])
				read_data0[bank*32 +: 32] <= bank_data[bank][read_row0];
			if(read_enable[1])
				read_data1[bank*32 +: 32] <= bank_data[bank][read_row1];
			if (write_enable && write_mask[bank])
				bank_data[bank][write_row] <=  write_data[bank*32 +: 32];
        end
    end
endgenerate

endmodule

`default_nettype wire