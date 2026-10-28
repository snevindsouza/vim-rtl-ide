// pkg.sv - SystemVerilog fixture
package pkg;
  typedef enum logic [1:0] {IDLE, RUN, DONE} state_t;
  localparam int DW = 16;
endpackage

module sv_top (
  input  logic clk,
  input  logic rst_n,
  output logic [pkg::DW-1:0] data
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) data <= '0;
    else        data <= data + 1'b1;
  end
endmodule
