// Microarchitecture
// -----------------------------------------------------------------------------
//                              Per-Lane ALU
// ┌────────────────────────────────────────────────────────────────────┐
// │                                                                    │
// │   rs ───────────────┐                                              │
// │                     │                                              │
// │                     ▼                                              │
// │              ┌────────────────┐                                    │
// │   rt ───────►│ Arithmetic Unit│                                    │
// │              │                │                                    │
// │              │ 00 : rs + rt   │                                    │
// │              │ 01 : rs - rt   │                                    │
// │              │ 10 : rs * rt   │                                    │
// │              │ 11 : rs / rt   │                                    │
// │              └───────┬────────┘                                    │
// │                      │ arithmetic_result                           │
// │                      │                                             │
// │   rs ───────────────┐│                                             │
// │                     ▼▼                                             │
// │              ┌────────────────┐                                    │
// │   rt ───────►│ Compare Unit   │                                    │
// │              │                │                                    │
// │              │ N = rs < rt    │                                    │
// │              │ Z = rs == rt   │                                    │
// │              │ P = rs > rt    │                                    │
// │              └───────┬────────┘                                    │
// │                      │ {5'b0, N, Z, P}                             │
// │                      │                                             │
// │                      ▼                                             │
// │              ┌────────────────┐                                    │
// │              │ Output MUX     │◄──── decoded_alu_output_mux        │
// │              │                │                                    │
// │              │ 0 : arithmetic │                                    │
// │              │ 1 : CMP result │                                    │
// │              └───────┬────────┘                                    │
// │                      │                                             │
// │                      ▼                                             │
// │              ┌────────────────┐                                    │
// │              │ alu_out_reg    │                                    │
// │              │                │                                    │
// │              │ Load when:     │                                    │
// │              │ enable = 1     │                                    │
// │              │ state = EXECUTE│                                    │
// │              └───────┬────────┘                                    │
// │                      │                                             │
// │                      ▼                                             │
// │                   alu_out                                          │
// │                                                                    │
// └────────────────────────────────────────────────────────────────────┘
//




`default_nettype none
`timescale 1ns/1ns

module alu (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       enable,

    input  logic [2:0] core_state,

    input  logic [1:0] decoded_alu_arithmetic_mux,
    input  logic       decoded_alu_output_mux,

    input  logic [7:0] rs,
    input  logic [7:0] rt,

    output logic [7:0] alu_out
);

localparam EXECUTE = 3'b101;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        alu_out <= '0;
    end
    else if ((core_state == EXECUTE) && enable) begin
        if (decoded_alu_output_mux) begin
            alu_out <= {5'b0, (rs < rt), (rs == rt), (rs > rt)};
        end
        else begin
            case (decoded_alu_arithmetic_mux)
                2'b00: alu_out <= rs + rt;
                2'b01: alu_out <= rs - rt;
                2'b10: alu_out <= rs * rt;
                2'b11: alu_out <= rs / rt;
            endcase
        end
    end
end

endmodule

`default_nettype wire