-- simple.vhd - VHDL fixture
library ieee;
use ieee.std_logic_1164.all;

entity simple is
  port (
    clk  : in  std_logic;
    rst  : in  std_logic;
    d    : in  std_logic;
    q    : out std_logic
  );
end entity simple;

architecture rtl of simple is
  signal q_i : std_logic;
begin
  p_reg : process (clk, rst)
  begin
    if rst = '1' then
      q_i <= '0';
    elsif rising_edge(clk) then
      q_i <= d;
    end if;
  end process p_reg;
  q <= q_i;
end architecture rtl;
