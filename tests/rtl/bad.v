// bad.v - intentionally broken RTL for the diagnostic test
module bad (
  input  wire       clk,
  input  wire [3:0] a,
  output reg  [3:0] y
);

  always @(posedge clk) begin
    if (a == 4'd1) begin
      y <= undeclared_signal;   // undeclared identifier
    end                          // <- the outer begin is never closed

endmodule
