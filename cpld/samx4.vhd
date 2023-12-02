-- SAMx4

-- (C) 2023 Ciaran Anscomb
--
-- Released under the Creative Commons Attribution-ShareAlike 4.0
-- International License (CC BY-SA 4.0).  Full text in the LICENSE file.

-- TODO: Of course, test with 41256 DRAMs and see if we really do get 256K :)

-- Intended to provide the functionality of the SN74LS783 Synchronous Address
-- Multiplexer.

-- Primary reference is of course the SN74LS783/MC6883 data sheet.

-- Research into how SAM VDG mode transitions affect addressing and the various
-- associated "glitches" by Stewart Orchard.

-- While we're here, also add the minor extras required to behave like Stewart
-- Orchard's 256K Banker Board.  Doing it as part of the SAM probably lifts
-- some of the restrictions too.
--
-- https://gitlab.com/sorchard001/dragon-256k-banker-board

-- Interleaves access to memory between VDG and MPU, refreshing DRAM in place
-- of VDG access in bursts of eight rows following the falling edge of HS#.
-- Refreshes eight rows in about 2ms.

-- Supports SLOW, ADDRESS-DEPENDENT and FAST MPU rates.

-- Supports both 32K and 64K RAM map types.

-- Supports the page bit in 32K map type.

-- Extra registers in $FF3x allow selection between four banks of 64K for both
-- the lower and upper 32K of RAM as per the Banker Board.

-- Timing outputs occur synchronous with the clock (who'd have thought?), but
-- S[2..0] changes as soon as A[15..13], RnW or map type changes.  Z[8..0] may
-- change during an MPU access in FAST rate, but it should have settled before
-- RAS# fall.

-- Important to operation is the "Address Delay Time" as documented in Figure
-- 1 of the MC6809E datasheet.  The next address from the MPU should be
-- available 3 (2.8) oscillator periods after E falls during a slow cycle or
-- 2 (1.44) periods during a fast cycle.  This means that in address-dependent
-- MPU rate, the decision must be taken at T0 and T8 whether to return from
-- fast to slow cycles.

-- As noted by Stewart Orchard, the transition from slow to actually-fast rate
-- can occur at TA, shortening the slow cycle slightly to allow enough time
-- between falling E and rising Q.

-- Also noted by Stewart is that fast cycles are permitted for the
-- address-dependent rate in map type 1, despite the note on page 16 of the
-- data sheet.

-- Known behaviour changes:

-- The memory type setting is ignored.  Only 256K mode is supported, which is
-- identical to 64K mode with an extra row and column presented.  Note that
-- this makes it unsuitable to replace the SAM in a Dragon 32 with two banks of
-- 16K.  Possible future expansion.

-- Size M1 M0   Src     R/C      Z8  Z7  Z6  Z5  Z4  Z3  Z2  Z1  Z0
-- ----------------------------------------------------------------
-- 256K  X  X   MPU     ROW     A16  A7  A6  A5  A4  A3  A2  A1  A0
--                      COL     A17 A15 A14 A13 A12 A11 A10  A9  A8
--              VDG     ROW       *  B7  B6  B5  B4  B3  B2  B1  B0
--                      COL       * B15 B14 B13 B12 B11 B10  B9  B8
--              REF     ROW       L  C7  C6  C5  C4  C3  C2  C1  C0
--                      COL**     L  C7  C6  C5  C4  C3  C2  C1  C0
-- ----------------------------------------------------------------

-- * VDG ROW and COLUMN are either 0 or as per selected 32K bank
-- ** CAS# is not strobed during refresh cycles

-- One line can optionally be uncommented to yield some valid video accesses in
-- fast mode.  The display is noisy, but it's better than nothing!  It breaks
-- DRAM refresh testing, though.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.all;

entity samx4 is
	port (
		     -- No OscIn pin: if a crystal is to be used, the circuit
		     -- to present it as a nice square clock should be
		     -- external.
		     OscOut : in std_logic;
		     E : out std_logic;
		     Q : out std_logic;

		     A : in std_logic_vector(15 downto 0);
		     RnW : in std_logic;
		     S : out std_logic_vector(2 downto 0);
		     Z : out std_logic_vector(8 downto 0);
		     nRAS0 : out std_logic;
		     nCAS : out std_logic;
		     nWE : out std_logic;

		     -- VClk being held low for 8 cycles of OscOut implies
		     -- external reset.
		     VClk : out std_logic;  -- 100Ω to nRST
		     nRST : in std_logic;
		     DA0 : in std_logic;  -- 10K pullup, probably not needed
		     nHS : in std_logic
	     );
end;

architecture rtl of samx4 is

	-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
	-- -- Registers

	-- V: VDG addressing mode
	-- Mode		Division	Bits cleared on HS#
	-- V2 V1 V0	X   Y
	--  0  0  0     1  12           B1-B4
	--  0  0  1     3   1           B1-B3
	--  0  1  0     1   3           B1-B4
	--  0  1  1     2   1           B1-B3
	--  1  0  0     1   2           B1-B4
	--  1  0  1     1   1           B1-B3
	--  1  1  0     1   1           B1-B4
	--  1  1  1     1   1           None (DMA MODE)
	signal V : std_logic_vector(2 downto 0) := (others => '0');

	-- F: VDG address offset (multiples of 512 bytes)
	signal F : std_logic_vector(6 downto 0) := (others => '0');

	-- P1: Page bit.  Selects which 32K page from the current bank selected
	-- for region 0 ($0000-$7FFF) is mapped to that region.
	signal P1 : std_logic := '0';

	-- R: MPU rate.
	signal R : std_logic_vector(1 downto 0) := (others => '0');

	-- M: Memory type.  IGNORED for now.
	--signal M : std_logic_vector(1 downto 0) := (others => '0');

	-- TY: Map type.  0 selects 32K RAM, 32K ROM.  1 selects 64K RAM.
	signal TY : std_logic := '0';

	-- 256K related registers

	-- Bank select.  Which of four banks of 64K is mapped for use in the
	-- lower and higher regions of address space.
	type bank_array is array (1 downto 0) of std_logic_vector(1 downto 0);
	constant INIT_BANK : bank_array := (
		"00", "00"
	);
	signal bank : bank_array := INIT_BANK;

	type video_bank is (VB_L32, VB_0);
	signal vbank : video_bank := VB_L32;

	-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
	-- -- Address decoding

	signal is_FFxx : boolean;
	signal is_IO0 : boolean;
	signal is_IO1 : boolean;
	signal is_IO2 : boolean;
	signal is_FF3x : boolean;
	signal is_FFCx : boolean;
	signal is_FFEx : boolean;
	signal is_RAM : boolean;
	signal is_RAM_or_IO0 : boolean;  -- used in AD rate mode

	-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
	-- -- Timing

	-- Reference time
	type time_ref is (T0, T1, T2, T3, T4, T5, T6, T7, T8, T9, TA, TB, TC, TD, TE, TF);
	signal BOSC : std_logic := '0';
	signal T : time_ref := TF;
	signal fast_cycle : boolean := false;

	signal want_refresh : std_logic := '0';
	signal mpu_rate_slow : boolean := false;
	signal mpu_rate_ad_slow : boolean := false;
	signal mpu_rate_ad_fast : boolean := false;
	signal mpu_rate_fast : boolean := false;

	-- Internal port signals
	signal E_i : std_logic := '0';
	signal Q_i : std_logic := '0';

	-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
	-- -- Address multiplexer

	type addr_type is (MPU, VDG, REF);
	signal z_source : addr_type := MPU;
	type row_or_col is (ROW, COL);
	signal z_mux : row_or_col := ROW;

	-- B: Video address counter
	signal B : std_logic_vector(15 downto 1) := (others => '0');

	-- C: 9-bit refresh counter.  The 41256 actually only needs 8-bits (one
	-- row gets translated internally to a column), but it can't hurt.
	signal C : std_logic_vector(7 downto 0) := (others => '0');

	-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
	-- -- Reset

	signal VClk_BOSC_div2_d : std_logic;
	signal VClk_BOSC_div2_q : std_logic := '0';
	signal VClk_BOSC_div4_d : std_logic;
	signal VClk_BOSC_div4_q : std_logic := '0';
	signal IER : std_logic := '0';
	signal HR : std_logic;  -- Horizontal Reset
	signal DA0_nq : std_logic := '0';
	signal IER_or_VP : std_logic := '0';  -- Vertical Pre-load

	-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
	-- -- VDG

	-- Synchronisation

	signal vdg_da0_window : boolean := false;
	signal vdg_start : boolean := false;
	signal vdg_sync_error : boolean := false;

	-- Glitching
	--
	-- Delaying video mode changes for 3 E cycles (Vbuf2 -> 1 -> 0 -> V)
	-- seems to be necessary to line up with divider outputs at the right
	-- time.  Then comparison to Vprev provides the "glitching".

	signal Vbuf2 : std_logic_vector(2 downto 0) := (others => '0');
	signal Vbuf1 : std_logic_vector(2 downto 0) := (others => '0');
	signal Vbuf0 : std_logic_vector(2 downto 0) := (others => '0');
	signal Vprev : std_logic_vector(2 downto 1) := (others => '0');

	-- Counters, dividers

	signal is_DMA       : boolean;

	signal use_xgnd     : std_logic;
	signal use_xdiv3    : std_logic;
	signal use_xdiv2    : std_logic;
	signal use_xdiv1    : std_logic;
	signal xdiv3_out    : std_logic := '0';
	signal xdiv2_out    : std_logic := '0';
	signal clock_b4     : std_logic := '0';

	signal use_ygnd     : std_logic;
	signal use_yb4      : std_logic;
	signal use_ydiv12   : std_logic;
	signal use_ydiv3    : std_logic;
	signal use_ydiv2    : std_logic;
	signal use_ydiv1    : std_logic;
	signal ydiv12_out   : std_logic := '0';
	signal ydiv3_out    : std_logic := '0';
	signal ydiv2_out    : std_logic := '0';
	signal clock_b5     : std_logic := '0';

begin

	-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
	-- -- Address decoding

	is_FFxx <= A(15 downto 8) = "11111111";
	is_IO0  <= is_FFxx and A(7 downto 5) = "000";   -- ALSO FF1x
	is_IO1  <= is_FFxx and A(7 downto 4) = "0010";  -- ONLY FF2x
	is_FF3x <= is_FFxx and A(7 downto 4) = "0011";  -- ONLY FF3x
	is_IO2  <= is_FFxx and A(7 downto 5) = "010";   -- ALSO FF5x
	is_FFCx <= is_FFxx and A(7 downto 5) = "110";   -- ALSO FFDx
	is_FFEx <= is_FFxx and A(7 downto 5) = "111";   -- ALSO FFFx

	process (is_FFxx, is_IO0, is_IO1, is_IO2, is_FFEx, TY, RnW, A(15 downto 13))
	begin
		if is_IO0 then
			S <= "100";
			is_RAM <= false;
		elsif is_IO1 then
			S <= "101";
			is_RAM <= false;
		elsif is_IO2 then
			S <= "110";
			is_RAM <= false;
		elsif is_FFEx then
			S <= "010";
			is_RAM <= false;
		elsif is_FFxx then
			S <= "111";
			is_RAM <= false;
		else
			if TY = '0' or RnW = '0' then
				-- Map Type 0 or write in Map Type 1
				case A(15 downto 13) is
					when "100" =>
						S <= "001";  -- ROM0 (TY=0) or RAM (TY=1)
						is_RAM <= TY = '1';
					when "101" =>
						S <= "010";  -- ROM1 (TY=0) or RAM (TY=1)
						is_RAM <= TY = '1';
					when "110" =>
						S <= "011";  -- ROM2 (TY=0) or RAM (TY=1)
						is_RAM <= TY = '1';
					when "111" =>
						S <= "011";  -- ROM2 (TY=0) or RAM (TY=1)
						is_RAM <= TY = '1';
					when others =>
						-- RAM
						if RnW = '1' then
							S <= "000";
						else
							S <= "111";
						end if;
						is_RAM <= true;
				end case;
			else
				-- Read in Map Type 1
				S <= "000";
				is_RAM <= true;
			end if;
		end if;
	end process;

	is_RAM_or_IO0 <= is_RAM or is_IO0;
	mpu_rate_slow <= R = "00";
	mpu_rate_ad_slow <= R = "01" and is_RAM_or_IO0;
	mpu_rate_ad_fast <= R = "01" and not is_RAM_or_IO0;
	mpu_rate_fast <= R(1) = '1';

	-- -- Register writes

	process (IER, E_i, RnW, is_FFxx, is_FF3x, is_FFCx)
	begin
		if IER = '1' then
			Vbuf2 <= (others => '0');
			F <= (others => '0');
			P1 <= '0';
			R <= (others => '0');
			-- M <= (others => '0');
			TY <= '0';
			bank <= INIT_BANK;
			vbank <= VB_L32;
		elsif rising_edge(E_i) then
			if is_FFCx and RnW = '0' then
				-- SAM registers
				case A(4 downto 1) is
					when "0000" => Vbuf2(0) <= A(0);
					when "0001" => Vbuf2(1) <= A(0);
					when "0010" => Vbuf2(2) <= A(0);
					when "0011" => F(0) <= A(0);
					when "0100" => F(1) <= A(0);
					when "0101" => F(2) <= A(0);
					when "0110" => F(3) <= A(0);
					when "0111" => F(4) <= A(0);
					when "1000" => F(5) <= A(0);
					when "1001" => F(6) <= A(0);
					when "1010" => P1 <= A(0);
					when "1011" => R(0) <= A(0);
					when "1100" => R(1) <= A(0);
					-- when "1101" => M(0) <= A(0);
					-- when "1110" => M(1) <= A(0);
					when "1111" => TY <= A(0);
					when others => null;
				end case;
			elsif is_FF3x and RnW = '0' then
				-- 256K banker board registers
				case A(3 downto 2) is
					when "00" => bank(0) <= A(1 downto 0);
					when "01" => bank(1) <= A(1 downto 0);
					when "10" =>
						case A(1 downto 0) is
							when "00" => vbank <= VB_L32;
							when "01" => vbank <= VB_0;
							when others => null;
						end case;
					when others => null;
				end case;
			end if;
		end if;
	end process;

	-- Delay video mode changes for three cycles (falling edge of E): for
	-- some reason this seems to be necessary to reproduce certain observed
	-- timing behaviour.
	--
	-- Another possibility would be to special-case setting V to be on the
	-- falling edge and only use a two-stage pipeline here, but I'll keep
	-- it simple for now.
	--
	-- TODO: not tested with fast mode.  This may be more accurately
	-- clocked within the main state machine at a specific point rather
	-- then off 'E'.

	process (E_i)
	begin
		if falling_edge(E_i) then
			V <= Vbuf0;
			Vbuf0 <= Vbuf1;
			Vbuf1 <= Vbuf2;
		end if;
	end process;

	-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
	-- -- Timing

	-- Buffered Oscillator - used for all internal timing references
	BOSC <= OscOut;

	-- Buffered outputs
	E <= E_i when IER = '0' else '0';
	Q <= Q_i when IER = '0' else '0';

	-- Pass through RnW to RAM (on nWE) when E high (MPU cycle) only for
	-- RAM accesses.
	nWE <= RnW when E_i = '1' and is_RAM else '1';

	-- Refresh timing: HS# going low enables a burst of 8 refresh cycles,
	-- continuing for multiples of 8 if held low longer than that.

	process (nHS, C(2))
	begin
		if nHS = '0' then
			want_refresh <= '1';
		elsif falling_edge(C(2)) then
			want_refresh <= '0';
		end if;
	end process;

	-- ROW vs COLUMN
	z_mux <= ROW when T = TF or T = T0 or T = T1 or
		 T = T7 or T = T8 or T = T9 else COL;

	-- RAS#
	nRAS0 <= '0' when T = T1 or T = T2 or T = T3 or T = T4 or T = T5 or
		 T = T9 or T = TA or T = TB or T = TC or T = TD else '1';

	-- VDG DA0 transition window open for these states
	vdg_da0_window <= true when T = TA or T = TB else false;

	-- Restart VDG, if stopped
	vdg_start <= true when T = TB else false;

	-- This is the main state machine, advanced by BOSC falling edge.  It
	-- schedules things (broadly) as specified in the SAM datasheet.
	-- Remember that the NEW state set at each clock transition is what you
	-- should use when cross-referencing with the data sheet.

	process (BOSC)
	begin
		if falling_edge(BOSC) then

			case T is

				when TF =>
					T <= T0;

					-- CAS# rise
					nCAS <= '1';

					if fast_cycle then
						if mpu_rate_slow or mpu_rate_ad_slow then
							fast_cycle <= false;
						else
							-- Q rise
							Q_i <= '1';
							if mpu_rate_fast
							-- uncomment for (some)
							-- video in fast mode
							-- (breaks refresh
							-- test):
							--and is_RAM
							then
								-- MPU address to RAM
								z_source <= MPU;
							end if;
						end if;
					end if;

				when T0 =>
					T <= T1;
					-- RAS# falls (done elsewhere)

				when T1 =>
					T <= T2;

					if not fast_cycle then
						if mpu_rate_fast or mpu_rate_ad_fast then
							fast_cycle <= true;
						end if;
					else
						-- E rise
						E_i <= '1';
					end if;

				when T2 =>
					T <= T3;

					-- CAS# fall if NOT refreshing
					if z_source /= REF then
						nCAS <= '0';
					end if;

					if not fast_cycle then
						-- Q rise
						Q_i <= '1';
					end if;

				when T3 =>
					T <= T4;

					if fast_cycle then
						-- Q fall
						Q_i <= '0';
					end if;

				when T4 =>
					T <= T5;

				when T5 =>
					T <= T6;
					-- RAS# rises (done elsewhere)

					if fast_cycle then
						-- E fall
						E_i <= '0';
					end if;

				when T6 =>
					T <= T7;

					if z_source = REF then
						-- increment refresh row
						C <= std_logic_vector(unsigned(C)+1);
					end if;

					if not fast_cycle then
						-- E rise
						E_i <= '1';
					end if;

				when T7 =>
					T <= T8;

					-- CAS# rise
					nCAS <= '1';

					-- MPU address to RAM (could have done this at T7)
					z_source <= MPU;

					if fast_cycle then
						if mpu_rate_slow or mpu_rate_ad_slow then
							fast_cycle <= false;
						else
							-- Q rise
							Q_i <= '1';
						end if;
					end if;

				when T8 =>
					T <= T9;
					-- RAS# falls (done elsewhere)

				when T9 =>
					T <= TA;

					if not fast_cycle then
						if mpu_rate_fast then
							fast_cycle <= true;
						end if;
					else
						-- E rise
						E_i <= '1';
					end if;

				when TA =>
					T <= TB;

					-- CAS# fall
					nCAS <= '0';

					if not fast_cycle then
						-- Q fall
						Q_i <= '0';
					end if;

				when TB =>
					T <= TC;

					if fast_cycle then
						-- Q fall
						Q_i <= '0';
					end if;

				when TC =>
					T <= TD;

				when TD =>
					T <= TE;
					-- RAS# rises (done elsewhere)

					if fast_cycle then
						-- E fall
						E_i <= '0';
					end if;

				when TE =>
					T <= TF;

					if not fast_cycle then
						-- E fall
						E_i <= '0';
					end if;

					-- Overridden at T0 if FAST
					if want_refresh = '0' and IER = '0' then
						-- VDG address to RAM
						z_source <= VDG;
					else
						-- REFRESH row to RAM
						z_source <= REF;
					end if;

			end case;
		end if;
	end process;

	-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
	-- -- Address multiplexer

	process (z_mux, z_source, A, B, DA0, vbank, bank, C, TY, P1)
	begin
		if z_mux = ROW then
			case z_source is
				when MPU =>
					Z(8) <= bank(to_integer(unsigned'('0'&A(15))))(0);
					Z(7 downto 0) <= A(7 downto 0);
				when VDG =>
					if vbank = VB_L32 then
						Z(8) <= bank(0)(0);
					else
						Z(8) <= '0';
					end if;
					Z(7 downto 0) <= B(7 downto 1) & DA0;
				when REF =>
					Z(8) <= '0';
					Z(7 downto 0) <= C(7 downto 0);
			end case;
		else
			case z_source is
				when MPU =>
					Z(8) <= bank(to_integer(unsigned'('0'&A(15))))(1);
					if TY = '0' then
						Z(7) <= P1;
					else
						Z(7) <= A(15);
					end if;
					Z(6 downto 0) <= A(14 downto 8);
				when VDG =>
					if vbank = VB_L32 then
						Z(8) <= bank(0)(1);
					else
						Z(8) <= '0';
					end if;
					Z(7 downto 0) <= B(15 downto 8);
				when REF =>
					Z(8) <= '0';
					Z(7 downto 0) <= C(7 downto 0);
			end case;
		end if;
	end process;

	-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
	-- -- Reset

	VClk_BOSC_div2_d <= '0' when not vdg_sync_error and BOSC = '1' else '1';

	VClk_BOSC_div2 : entity div2
	port map (
			 clk => VClk_BOSC_div2_d,
			 q => VClk_BOSC_div2_q,
			 rst => IER
		 );

	VClk_BOSC_div4_d <= not VClk_BOSC_div2_q;

	VClk_BOSC_div4 : entity div2
	port map (
			 clk => VClk_BOSC_div4_d,
			 q => VClk_BOSC_div4_q,
			 rst => '0'
		 );

	VClk <= not VClk_BOSC_div4_q;

	IER <= '1' when nRST = '0' and VClk_BOSC_div2_q = '0' and VClk_BOSC_div4_q = '0' else '0';

	-- Horizontal Reset (HR)

	HR <= IER or not nHS;

	-- Vertical Pre-load (VP)

	process (HR)
	begin
		if falling_edge(HR) then
			DA0_nq <= not DA0;
		end if;
	end process;

	IER_or_VP <= IER or (HR nor DA0_nq);

	-- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --
	-- -- VDG

	-- Synchronisation & clock

	process (DA0, vdg_start)
	begin
		if vdg_start then
			vdg_sync_error <= false;
		elsif rising_edge(DA0) then
			if not vdg_da0_window then
				vdg_sync_error <= true;
			end if;
		end if;
	end process;

	-- VDG address modifier

	--  Mode        Division    Bits cleared
	--  V2 V1 V0    X   Y       by HS# (low)
	--  ---------------------------------------
	--   0  0  0    1   12      B1-B4
	--   0  0  1    3    1      B1-B3
	--  ---------------------------------------
	--   0  1  0    1    3      B1-B4
	--   0  1  1    2    1      B1-B3
	--  ---------------------------------------
	--   1  0  0    1    2      B1-B4
	--   1  0  1    1    1      B1-B3
	--  ---------------------------------------
	--   1  1  0    1    1      B1-B4
	--   1  1  1    1    1      None (DMA MODE)

	-- Furthermore, a real SAM "glitches" on certain mode changes, behaving
	-- like the following:
	--
	-- B5 input briefly becomes 0 when switching between Y÷12 and Y÷3, that
	-- is V2 = V0 = 0 and V1 changing.
	--
	-- B5 input briefly becomes B4 when switching between Y÷12 and Y÷2,
	-- that is V1 = V0 = 0 and V2 changing.
	--
	-- B4 input briefly becomes 0 when switching between X÷3 and X÷2, that
	-- is V2 = 0, V0 = 1 and V1 changing.
	--
	-- There are other glitches, but they produce unreliable results, so
	-- I'm not aiming to reproduce them here.

	use_ygnd   <= '1' when V(2) = '0' and V(0) = '0' and Vprev(1) /= V(1) else '0';
	use_yb4    <= '1' when V(1) = '0' and V(0) = '0' and Vprev(2) /= V(2) else '0';
	use_xgnd   <= '1' when V(2) = '0' and V(0) = '1' and Vprev(1) /= V(1) else '0';

	use_ydiv12 <= '1' when use_ygnd = '0' and use_yb4 = '0' and V = "000" else '0';
	use_ydiv3  <= '1' when use_ygnd = '0' and V = "010" else '0';
	use_ydiv2  <= '1' when use_yb4 = '0' and V = "100" else '0';
	use_ydiv1  <= '1' when use_yb4 = '1' or V(2 downto 1) = "11" or V(0) = '1' else '0';

	use_xdiv3  <= '1' when use_xgnd = '0' and V = "001" else '0';
	use_xdiv2  <= '1' when use_xgnd = '0' and V = "011" else '0';
	use_xdiv1  <= '1' when use_xgnd = '1' or V(2) = '1' or V(0) = '0' else '0';

	is_DMA     <= V = "111";

	-- Provides pulse where V /= Vprev, to "glitch" B4/B5 clock inputs.
	process (BOSC)
	begin
		if rising_edge(BOSC) then
			Vprev(2) <= V(2);
			Vprev(1) <= V(1);
			clock_b5 <= (use_ydiv12 and ydiv12_out) or (use_ydiv3 and ydiv3_out) or (use_ydiv2 and ydiv2_out) or (use_ydiv1 and B(4));
			clock_b4 <= (use_xdiv3 and xdiv3_out) or (use_xdiv2 and xdiv2_out) or (use_xdiv1 and B(3));
		end if;
	end process;

	-- VDG X dividers - B3 ÷ X -> B4

	xdiv3 : entity div3
	port map (
			 clk => B(3),
			 q => xdiv3_out,
			 rst => IER_or_VP
		 );

	xdiv2 : entity div2
	port map (
			 clk => B(3),
			 q => xdiv2_out,
			 rst => IER_or_VP
		 );

	-- B3..1 clocked by DA0 falling edge
	--
	-- B4 clocked by B3 or X divider outputs

	process (DA0, clock_b4, IER_or_VP, HR, V(0), is_DMA)
	begin
		if IER_or_VP = '1' then
			B(4 downto 1) <= (others => '0');
		elsif HR = '1' and not is_DMA then
			B(3 downto 1) <= (others => '0');
			if V(0) = '0' then
				B(4) <= '0';
			end if;
		else
			if falling_edge(DA0) then
				B(3 downto 1) <= std_logic_vector(unsigned(B(3 downto 1)) + 1);
			end if;
			if falling_edge(clock_b4) then
				B(4) <= not B(4);
			end if;
		end if;
	end process;

	-- VDG Y dividers - B4 ÷ Y -> B15..5

	ydiv12 : entity div4
	port map (
			 clk => ydiv3_out,
			 q => ydiv12_out,
			 rst => IER_or_VP
		 );

	ydiv3 : entity div3
	port map (
			 clk => B(4),
			 q => ydiv3_out,
			 rst => IER_or_VP
		 );

	ydiv2 : entity div2
	port map (
			 clk => B(4),
			 q => ydiv2_out,
			 rst => IER_or_VP
		 );

	-- B15..5 clocked by B4 or Y divider outputs

	process (clock_b5, IER_or_VP, F)
	begin
		if IER_or_VP = '1' then
			B(15 downto 9) <= F;  -- loaded from SAM register
			B(8 downto 5) <= (others => '0');
		elsif falling_edge(clock_b5) then
			B(15 downto 5) <= std_logic_vector(unsigned(B(15 downto 5))+1);
		end if;
	end process;

end rtl;
