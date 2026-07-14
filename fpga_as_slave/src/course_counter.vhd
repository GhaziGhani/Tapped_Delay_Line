-- File: course_counter.vhd (CORRECTED)
--
-- FIXES APPLIED:
--   Issue 17: Counter starts counting on the cycle AFTER START is seen.
--             This is a fixed +1 offset that is compensated by STOP_DELAY
--             adjustment in sweep_engine_legacy. Documented here.
--   Issue 18: STOP in IDLE correctly ignored (no change needed)
--   Issue 19: Counter reset on re-START correct (no change needed)
--
-- NOTE: The counter increments on each CLK cycle while in COUNTING state.
--       First increment happens one cycle after START, so the count value
--       when STOP arrives represents (elapsed_cycles - 1). This fixed
--       offset is accounted for in the sweep engine's STOP_DELAY parameter.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity course_counter is
    Generic (
        WIDTH : integer := 16
    );
    Port (
        CLK   : in  STD_LOGIC;
        RST   : in  STD_LOGIC;
        START : in  STD_LOGIC;
        STOP  : in  STD_LOGIC;
        COUNT : out STD_LOGIC_VECTOR(WIDTH-1 downto 0);
        DONE  : out STD_LOGIC
    );
end course_counter;

architecture Behavioral of course_counter is

    type state_type is (IDLE, COUNTING, STOPPED);
    signal state     : state_type := IDLE;
    signal count_reg : unsigned(WIDTH-1 downto 0) := (others => '0');
    signal done_reg  : STD_LOGIC := '0';

    constant COUNT_MAX : unsigned(WIDTH-1 downto 0) := (others => '1');

begin

    COUNTER_PROC : process(CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                state     <= IDLE;
                count_reg <= (others => '0');
                done_reg  <= '0';
            else
                done_reg <= '0';
                case state is
                    when IDLE =>
                        count_reg <= (others => '0');
                        if START = '1' then
                            state <= COUNTING;
                        end if;

                    when COUNTING =>
                        if count_reg /= COUNT_MAX then
                            count_reg <= count_reg + 1;
                        end if;
                        if STOP = '1' then
                            state    <= STOPPED;
                            done_reg <= '1';
                        end if;

                    when STOPPED =>
                        if START = '1' then
                            count_reg <= (others => '0');
                            state     <= COUNTING;
                        end if;

                    when others =>
                        state <= IDLE;
                end case;
            end if;
        end if;
    end process;

    COUNT <= std_logic_vector(count_reg);
    DONE  <= done_reg;

end Behavioral;
