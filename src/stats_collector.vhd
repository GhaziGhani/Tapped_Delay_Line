-- File: stats_collector.vhd (CORRECTED)
--
-- FIXES APPLIED:
--   Issue 26-28: Min/max initialization, count width, sum width all confirmed
--                correct. No changes needed.
--   Added: PHASE_OUT reset (was missing in some versions)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity stats_collector is
    Generic (
        TOTAL_WIDTH    : integer := 32;
        PHASE_WIDTH    : integer := 8;
        TEST_CNT_WIDTH : integer := 10;
        SUM_WIDTH      : integer := 42
    );
    Port (
        CLK          : in  STD_LOGIC;
        RST          : in  STD_LOGIC;
        STAT_DATA    : in  STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
        STAT_WE      : in  STD_LOGIC;
        STAT_PHASE   : in  STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
        STAT_LAST    : in  STD_LOGIC;
        PHASE_OUT    : out STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
        MIN_OUT      : out STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
        MAX_OUT      : out STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
        SUM_OUT      : out STD_LOGIC_VECTOR(SUM_WIDTH-1 downto 0);
        COUNT_OUT    : out STD_LOGIC_VECTOR(TEST_CNT_WIDTH-1 downto 0);
        RESULT_VALID : out STD_LOGIC
    );
end stats_collector;

architecture Behavioral of stats_collector is

    signal data_r  : unsigned(TOTAL_WIDTH-1 downto 0)          := (others => '0');
    signal we_r    : STD_LOGIC := '0';
    signal last_r  : STD_LOGIC := '0';
    signal phase_r : STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0)  := (others => '0');

    signal min_acc   : unsigned(TOTAL_WIDTH-1 downto 0)        := (others => '1');
    signal max_acc   : unsigned(TOTAL_WIDTH-1 downto 0)        := (others => '0');
    signal sum_acc   : unsigned(SUM_WIDTH-1 downto 0)          := (others => '0');
    signal count_acc : unsigned(TEST_CNT_WIDTH-1 downto 0)     := (others => '0');
    signal valid_r   : STD_LOGIC := '0';

begin

    RESULT_VALID <= valid_r;

    INPUT_PIPE : process(CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                data_r  <= (others => '0');
                we_r    <= '0';
                last_r  <= '0';
                phase_r <= (others => '0');
            else
                data_r  <= unsigned(STAT_DATA);
                we_r    <= STAT_WE;
                last_r  <= STAT_LAST;
                phase_r <= STAT_PHASE;
            end if;
        end if;
    end process;

    process(CLK)
        variable new_min   : unsigned(TOTAL_WIDTH-1 downto 0);
        variable new_max   : unsigned(TOTAL_WIDTH-1 downto 0);
        variable new_sum   : unsigned(SUM_WIDTH-1 downto 0);
        variable new_count : unsigned(TEST_CNT_WIDTH-1 downto 0);
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                min_acc   <= (others => '1');
                max_acc   <= (others => '0');
                sum_acc   <= (others => '0');
                count_acc <= (others => '0');
                valid_r   <= '0';
                MIN_OUT   <= (others => '0');
                MAX_OUT   <= (others => '0');
                SUM_OUT   <= (others => '0');
                COUNT_OUT <= (others => '0');
                PHASE_OUT <= (others => '0');
            else
                valid_r <= '0';

                if we_r = '1' then
                    if data_r < min_acc then
                        new_min := data_r;
                    else
                        new_min := min_acc;
                    end if;

                    if data_r > max_acc then
                        new_max := data_r;
                    else
                        new_max := max_acc;
                    end if;

                    new_sum   := sum_acc + resize(data_r, SUM_WIDTH);
                    new_count := count_acc + 1;

                    min_acc   <= new_min;
                    max_acc   <= new_max;
                    sum_acc   <= new_sum;
                    count_acc <= new_count;

                    if last_r = '1' then
                        PHASE_OUT <= phase_r;
                        MIN_OUT   <= std_logic_vector(new_min);
                        MAX_OUT   <= std_logic_vector(new_max);
                        SUM_OUT   <= std_logic_vector(new_sum);
                        COUNT_OUT <= std_logic_vector(new_count);
                        valid_r   <= '1';

                        min_acc   <= (others => '1');
                        max_acc   <= (others => '0');
                        sum_acc   <= (others => '0');
                        count_acc <= (others => '0');
                    end if;
                end if;
            end if;
        end if;
    end process;

end Behavioral;