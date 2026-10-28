// counter.v - parameterised up counter (test fixture)
module counter #(
  parameter integer WIDTH = 8,
  parameter [WIDTH-1:0] INIT = 0
) (
  input  wire             clk,
  input  wire             rst_n,
  input  wire             en,
  output reg  [WIDTH-1:0] q,
  output wire             wrap
);

  wire [WIDTH-1:0] q_nxt;
  reg              wrap_r;
  localparam [WIDTH-1:0] MAXV = {WIDTH{1'b1}};

  assign q_nxt = q + 1'b1;
  assign wrap  = wrap_r;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      q      <= INIT;
      wrap_r <= 1'b0;
    end else if (en) begin
      q      <= q_nxt;
      wrap_r <= (q == MAXV);
    end
  end

  function [WIDTH-1:0] next_val;
    input [WIDTH-1:0] v;
    begin
      next_val = v + 1'b1;
    end
  endfunction

endmodule
