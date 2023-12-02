-- (C) 2023 Ciaran Anscomb
--
-- Released under the Creative Commons Attribution-ShareAlike 4.0
-- International License (CC BY-SA 4.0).  Full text in the LICENSE file.

library ieee;
use ieee.std_logic_1164.all;
use work.all;

entity div4 is
	port (
		     clk : in std_logic;
		     q : out std_logic;
		     rst : in std_logic
	     );
end;

architecture rtl of div4 is

	signal q0 : std_logic := '0';

begin

	div2_0 : entity div2
	port map (
			 clk => clk,
			 q => q0,
			 rst => rst
		 );

	div2_1 : entity div2
	port map (
			 clk => q0,
			 q => q,
			 rst => rst
		 );

end rtl;
