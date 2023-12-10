-- (C) 2023 Ciaran Anscomb
--
-- Released under the Creative Commons Attribution-ShareAlike 4.0
-- International License (CC BY-SA 4.0).  Full text in the LICENSE file.

library ieee;
use ieee.std_logic_1164.all;

entity div3 is
	port (
		     clk : in std_logic;
		     q : out std_logic;
		     rst : in std_logic
	     );
end;

architecture rtl of div3 is

	signal d0 : std_logic;
	signal q0 : std_logic := '0';
	signal q1 : std_logic := '0';
	signal q2 : std_logic := '0';

begin

	d0 <= q0 nor q1;

	process (clk, rst)
	begin
		if rst = '1' then
			q0 <= '0';
			q1 <= '0';
		elsif rising_edge(clk) then
			q0 <= d0;
			q1 <= q0;
		end if;
	end process;

	process (clk, rst)
	begin
		if rst = '1' then
			q2 <= '0';
		elsif falling_edge(clk) then
			q2 <= q1;
		end if;
	end process;

	q <= q2 or q1;

end rtl;
