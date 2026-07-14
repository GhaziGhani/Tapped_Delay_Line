--------------------------------------------------------------------------------
-- File: uart_tx.vhd (CORRECTED)
--
-- FIXES APPLIED:
--   Issue 3/34: Default CLK_FREQ changed from 250_000_000 to 50_000_000
--               to match the actual system clock frequency. The generic is
--               overridden by the top-level instantiation, but the default
--               should match the system for standalone simulation/testing.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_tx is
    Generic (
        CLK_FREQ : integer := 50_000_000;   -- FIX: Match system clock
        BAUD     : integer := 115_200
    );
    Port (
        CLK      : in  STD_LOGIC;
        RST      : in  STD_LOGIC;
        TX_DATA  : in  STD_LOGIC_VECTOR(7 downto 0);
        TX_START : in  STD_LOGIC;
        TX_OUT   : out STD_LOGIC;
        TX_BUSY  : out STD_LOGIC
    );
end uart_tx;

architecture Behavioral of uart_tx is

    constant CLKS_PER_BIT : integer := CLK_FREQ / BAUD;

    type state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal state     : state_t := IDLE;
    signal bit_timer : integer range 0 to CLKS_PER_BIT-1 := 0;
    signal bit_index : integer range 0 to 7 := 0;
    signal shift_reg : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');

begin

    process(CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                state     <= IDLE;
                TX_OUT    <= '1';
                TX_BUSY   <= '0';
                bit_timer <= 0;
                bit_index <= 0;
            else
                case state is

                    when IDLE =>
                        TX_OUT  <= '1';
                        TX_BUSY <= '0';
                        if TX_START = '1' then
                            shift_reg <= TX_DATA;
                            state     <= START_BIT;
                            bit_timer <= 0;
                            TX_BUSY   <= '1';
                        end if;

                    when START_BIT =>
                        TX_OUT <= '0';
                        if bit_timer = CLKS_PER_BIT - 1 then
                            bit_timer <= 0;
                            bit_index <= 0;
                            state     <= DATA_BITS;
                        else
                            bit_timer <= bit_timer + 1;
                        end if;

                    when DATA_BITS =>
                        TX_OUT <= shift_reg(bit_index);
                        if bit_timer = CLKS_PER_BIT - 1 then
                            bit_timer <= 0;
                            if bit_index = 7 then
                                state <= STOP_BIT;
                            else
                                bit_index <= bit_index + 1;
                            end if;
                        else
                            bit_timer <= bit_timer + 1;
                        end if;

                    when STOP_BIT =>
                        TX_OUT <= '1';
                        if bit_timer = CLKS_PER_BIT - 1 then
                            bit_timer <= 0;
                            state     <= IDLE;
                            TX_BUSY   <= '0';
                        else
                            bit_timer <= bit_timer + 1;
                        end if;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
