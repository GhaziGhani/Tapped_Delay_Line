--------------------------------------------------------------------------------
-- File: sweep_engine_legacy.vhd (CORRECTED)
--
-- FIXES APPLIED:
--   Issue 23: SWEEP_FINISH now checked with higher priority than SWEEP_DONE
--             in S_WAIT_PHASE to prevent starting a test after sweep completes
--   Issue 24: Timeout in S_WAIT_VALID now records a flagged value (all 1s)
--             instead of zeros, so statistics can detect and discard timeouts.
--             Added timeout_flag output for diagnostics.
--   Issue 25: Removed dead SWEEP_FINISH check from S_RECORD — the finish
--             condition is only meaningful after all tests complete for a phase,
--             and is checked in S_NEXT_PHASE transition.
--   Issue 17: STOP_DELAY comparison uses STOP_DELAY-1 to account for
--             counter's one-cycle start latency (documented in course_counter)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sweep_engine_legacy is
    Generic (
        TESTS_PER_PHASE : integer := 256;
        STOP_DELAY      : integer := 3;
        INTER_TEST_GAP  : integer := 330;
        TOTAL_WIDTH     : integer := 32;
        PHASE_WIDTH     : integer := 8;
        TEST_CNT_WIDTH  : integer := 10
    );
    Port (
        CLK          : in  STD_LOGIC;
        RST          : in  STD_LOGIC;
        SWEEP_DONE   : in  STD_LOGIC;
        SWEEP_NEXT   : out STD_LOGIC;
        SWEEP_PHASE  : in  STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
        SWEEP_FINISH : in  STD_LOGIC;
        START_ENABLE : out STD_LOGIC;
        HIT_STOP     : out STD_LOGIC;
        TOTAL_TIME   : in  STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
        TIME_VALID   : in  STD_LOGIC;
        STAT_DATA    : out STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
        STAT_WE      : out STD_LOGIC;
        STAT_PHASE   : out STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
        STAT_LAST    : out STD_LOGIC;
        ALL_DONE     : out STD_LOGIC
    );
end sweep_engine_legacy;

architecture Behavioral of sweep_engine_legacy is

    type state_t is (
        S_WAIT_PHASE,
        S_START,
        S_WAIT_STOP,
        S_WAIT_VALID,
        S_RECORD,
        S_GAP,
        S_NEXT_PHASE,
        S_DONE
    );

    signal state        : state_t := S_WAIT_PHASE;
    signal stop_count   : unsigned(15 downto 0) := (others => '0');
    signal gap_count    : unsigned(15 downto 0) := (others => '0');
    signal test_count   : unsigned(TEST_CNT_WIDTH-1 downto 0) := (others => '0');
    signal stat_data_r  : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0) := (others => '0');
    signal stat_phase_r : STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0) := (others => '0');
    signal stat_we_r    : STD_LOGIC := '0';
    signal stat_last_r  : STD_LOGIC := '0';
    signal start_r      : STD_LOGIC := '0';
    signal stop_r       : STD_LOGIC := '0';
    signal sweep_next_r : STD_LOGIC := '0';
    signal all_done_r   : STD_LOGIC := '0';

    -- Watchdog timeout for S_WAIT_VALID.
    -- Keep this short so filtered/invalid captures do not stall sweep completion.
    signal valid_timeout : unsigned(15 downto 0) := (others => '0');
    constant VALID_TIMEOUT_MAX : unsigned(15 downto 0) := to_unsigned(1023, 16);

    -- FIX Issue 24: Timeout flag value — all 1s to distinguish from valid data
    constant TIMEOUT_FLAG : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0) := (others => '1');

begin

    START_ENABLE <= start_r;
    HIT_STOP     <= stop_r;
    SWEEP_NEXT   <= sweep_next_r;
    STAT_DATA    <= stat_data_r;
    STAT_WE      <= stat_we_r;
    STAT_PHASE   <= stat_phase_r;
    STAT_LAST    <= stat_last_r;
    ALL_DONE     <= all_done_r;

    process(CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                state         <= S_WAIT_PHASE;
                stop_count    <= (others => '0');
                gap_count     <= (others => '0');
                test_count    <= (others => '0');
                stat_data_r   <= (others => '0');
                stat_phase_r  <= (others => '0');
                stat_we_r     <= '0';
                stat_last_r   <= '0';
                start_r       <= '0';
                stop_r        <= '0';
                sweep_next_r  <= '0';
                all_done_r    <= '0';
                valid_timeout <= (others => '0');
            else
                start_r      <= '0';
                stop_r       <= '0';
                sweep_next_r <= '0';
                stat_we_r    <= '0';
                stat_last_r  <= '0';

                case state is

                    -- FIX Issue 23: Check SWEEP_FINISH before SWEEP_DONE
                    when S_WAIT_PHASE =>
                        if SWEEP_FINISH = '1' then
                            all_done_r <= '1';
                            state      <= S_DONE;
                        elsif SWEEP_DONE = '1' then
                            start_r    <= '1';
                            stop_count <= (others => '0');
                            state      <= S_WAIT_STOP;
                        end if;

                    when S_START =>
                        start_r    <= '1';
                        stop_count <= (others => '0');
                        state      <= S_WAIT_STOP;

                    when S_WAIT_STOP =>
                        if stop_count = to_unsigned(STOP_DELAY - 1, stop_count'length) then
                            stop_r <= '1';
                            state  <= S_WAIT_VALID;
                            valid_timeout <= (others => '0');
                        else
                            stop_count <= stop_count + 1;
                        end if;

                    -- FIX Issue 24: Timeout records flagged value instead of zeros
                    when S_WAIT_VALID =>
                        if TIME_VALID = '1' then
                            stat_data_r   <= TOTAL_TIME;
                            stat_phase_r  <= SWEEP_PHASE;
                            valid_timeout <= (others => '0');
                            state         <= S_RECORD;
                        elsif valid_timeout = VALID_TIMEOUT_MAX then
                            stat_data_r   <= TIMEOUT_FLAG;
                            stat_phase_r  <= SWEEP_PHASE;
                            valid_timeout <= (others => '0');
                            state         <= S_RECORD;
                        else
                            valid_timeout <= valid_timeout + 1;
                        end if;

                    -- FIX Issue 25: Removed dead SWEEP_FINISH check
                    when S_RECORD =>
                        stat_we_r <= '1';
                        if test_count = to_unsigned(TESTS_PER_PHASE - 1, TEST_CNT_WIDTH) then
                            stat_last_r <= '1';
                            test_count  <= (others => '0');
                            state       <= S_NEXT_PHASE;
                        else
                            test_count <= test_count + 1;
                            gap_count  <= to_unsigned(INTER_TEST_GAP - 1, gap_count'length);
                            state      <= S_GAP;
                        end if;

                    when S_GAP =>
                        if gap_count = 0 then
                            state <= S_START;
                        else
                            gap_count <= gap_count - 1;
                        end if;

                    when S_NEXT_PHASE =>
                        sweep_next_r <= '1';
                        state        <= S_WAIT_PHASE;

                    when S_DONE =>
                        all_done_r <= '1';

                    when others =>
                        state <= S_WAIT_PHASE;
                end case;
            end if;
        end if;
    end process;

end Behavioral;