-- (C) 2023 Ciaran Anscomb
--
-- Released under the Creative Commons Attribution-ShareAlike 4.0
-- International License (CC BY-SA 4.0).  Full text in the LICENSE file.

library ieee;
use ieee.std_logic_1164.all;

entity div2 is
	port (
		     clk : in std_logic;
		     q : out std_logic;
		     rst : in std_logic
	     );
end;

architecture rtl of div2 is

	signal q0 : std_logic := '0';

begin

	process (clk, rst)
	begin
		if rst = '1' then
			q0 <= '0';
		elsif falling_edge(clk) then
			q0 <= not q0;
		end if;
	end process;

	q <= q0;

end rtl;
