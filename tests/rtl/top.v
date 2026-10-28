// top.v - instantiates counter (test fixture)
`include "defs.vh"
module top (
  input  wire       clk,
  input  wire       rst_n,
  output wire [7:0] count,
  output wire       done
);

  wire en = 1'b1;

  counter #(
    .WIDTH (8),
    .INIT  (`TOP_INIT)
  ) u_counter (
    .clk   (clk),
    .rst_n (rst_n),
    .en    (en),
    .q     (count),
    .wrap  (done)
  );

endmodule
