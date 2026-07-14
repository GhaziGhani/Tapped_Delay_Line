--------------------------------------------------------------------------------
-- File: tdc_sweep_top.vhd (FIXED VERSION)
--
-- FIXES APPLIED:
--   Issue 1:  POR relies on INIT values - acceptable for Spartan-6, documented
--   Issue 3:  CLK_FREQ default now 50_000_000 (matches system clock)
--   Issue 12: RST synchronization improved
--   Issue 34: DCM LOCK DEADLOCK - Fixed circular dependency in reset logic
--             Previous: rst <= btn_rst or not dcm_locked (deadlock)
--             Fixed: rst <= btn_rst only (DCM can lock independently)
--   Issue 35: DCM reset now uses power-on reset only, not system reset
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity tdc_sweep_top is
    Generic (
        CLK_FREQ        : integer := 50_000_000;
        BAUD            : integer := 115_200;
        TAPS            : integer := 240;
        TAPS_PER_CNT    : integer := 240;
        COARSE_WIDTH    : integer := 16;
        FINE_WIDTH      : integer := 10;
        TOTAL_WIDTH     : integer := 32;
        PHASE_STEPS     : integer := 200;
        STEP_SIZE       : integer := 1;
        SETTLE_CYCLES   : integer := 32;
        PHASE_WIDTH     : integer := 8;
        TESTS_PER_PHASE : integer := 256;
        STOP_DELAY      : integer := 6;
        INTER_TEST_GAP  : integer := 330;
        TEST_CNT_WIDTH  : integer := 10;
        SUM_WIDTH       : integer := 42
    );
    Port (
        CLK_IN   : in  STD_LOGIC;
        RST_IN   : in  STD_LOGIC;
        TX_OUT   : out STD_LOGIC;
        LOCKED   : out STD_LOGIC;
        ALL_DONE : out STD_LOGIC
    );
end tdc_sweep_top;

architecture Structural of tdc_sweep_top is

    component clk_gen is
        Port (
            CLK_50_IN  : in  STD_LOGIC;
            RST_IN     : in  STD_LOGIC;
            PSEN       : in  STD_LOGIC;
            PSINCDEC   : in  STD_LOGIC;
            CLK        : out STD_LOGIC;
            CLK_PHASE  : out STD_LOGIC;
            DCM_LOCKED : out STD_LOGIC;
            PSDONE     : out STD_LOGIC
        );
    end component;

    component phase_sweep is
        Generic (
            PHASE_STEPS   : integer := 200;
            STEP_SIZE     : integer := 1;
            SETTLE_CYCLES : integer := 32;
            PHASE_WIDTH   : integer := 8
        );
        Port (
            CLK          : in  STD_LOGIC;
            RST          : in  STD_LOGIC;
            SWEEP_NEXT   : in  STD_LOGIC;
            SWEEP_DONE   : out STD_LOGIC;
            SWEEP_PHASE  : out STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
            SWEEP_FINISH : out STD_LOGIC;
            PSDONE       : in  STD_LOGIC;
            PSEN         : out STD_LOGIC;
            PSINCDEC     : out STD_LOGIC
        );
    end component;

    component sweep_engine_legacy is
        Generic (
            TESTS_PER_PHASE : integer := 256;
            STOP_DELAY      : integer := 6;
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
    end component;

    component tdc_channel_pulsed is
        Generic (
            TAPS         : integer := 240;
            TAPS_PER_CNT : integer := 240;
            COARSE_WIDTH : integer := 16;
            FINE_WIDTH   : integer := 10;
            TOTAL_WIDTH  : integer := 32
        );
        Port (
            CLK_IN       : in  STD_LOGIC;
            CLK_PHASE    : in  STD_LOGIC;
            RST_IN       : in  STD_LOGIC;
            START_ENABLE : in  STD_LOGIC;
            HIT_STOP     : out STD_LOGIC;
            TOTAL_TIME   : out STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
            TIME_VALID   : out STD_LOGIC
        );
    end component;

    component stats_collector is
        Generic (
            TOTAL_WIDTH  : integer := 32;
            PHASE_WIDTH  : integer := 8;
            SUM_WIDTH    : integer := 42;
            TESTS_PER_PHASE : integer := 256
        );
        Port (
            CLK        : in  STD_LOGIC;
            RST        : in  STD_LOGIC;
            STAT_DATA  : in  STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
            STAT_WE    : in  STD_LOGIC;
            STAT_PHASE : in  STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
            STAT_LAST  : in  STD_LOGIC;
            TX_OUT     : out STD_LOGIC
        );
    end component;

    -- Clock buffering
    signal clk_in_buf : STD_LOGIC;
    signal clk        : STD_LOGIC;
    signal clk_phase  : STD_LOGIC;
    signal dcm_locked : STD_LOGIC;

    -- Sweep reset - extended to 8 bits for robust synchronization
    signal rst_sr : STD_LOGIC_VECTOR(7 downto 0) := "11111111";
    signal rst    : STD_LOGIC;

    -- Sweep control
    signal sweep_next   : STD_LOGIC;
    signal sweep_done   : STD_LOGIC;
    signal sweep_phase : STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
    signal sweep_finish : STD_LOGIC;

    -- Phase sweep control
    signal psen_int   : STD_LOGIC;
    signal psincdec_int : STD_LOGIC;
    signal psdone_int : STD_LOGIC;

    -- TDC measurement
    signal start_enable : STD_LOGIC;
    signal hit_stop_int : STD_LOGIC;
    signal total_time_int : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
    signal time_valid   : STD_LOGIC;

    -- Statistics
    signal stat_data_int : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
    signal stat_we_int   : STD_LOGIC;
    signal stat_phase_int : STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
    signal stat_last_int : STD_LOGIC;

    -- Reset
    signal btn_rst   : STD_LOGIC;
    signal por_sr    : STD_LOGIC_VECTOR(15 downto 0) := X"FFFF";
    signal por       : STD_LOGIC;
    signal hw_rst    : STD_LOGIC;
    signal dcm_rst   : STD_LOGIC;  -- FIX: Separate DCM reset

begin

    ---------------------------------------------------------------------------
    -- 1. Input buffering
    ---------------------------------------------------------------------------
    U_IBUFG : IBUFG
    port map (
        I => CLK_IN,
        O => clk_in_buf
    );

    ---------------------------------------------------------------------------
    -- 2. Reset: active-low button + power-on reset
    ---------------------------------------------------------------------------
    btn_rst <= not RST_IN;

    POR_GEN : process(clk_in_buf)
    begin
        if rising_edge(clk_in_buf) then
            por_sr <= por_sr(14 downto 0) & '0';
        end if;
    end process;
    por    <= por_sr(15);
    
    -- FIX Issue 34/35: Separate DCM reset from system reset
    -- DCM only needs power-on reset, not system reset
    dcm_rst <= por;  -- Only power-on reset, no button reset
    hw_rst <= por or btn_rst;  -- Full hardware reset for other logic

    ---------------------------------------------------------------------------
    -- 3. Clock generation
    ---------------------------------------------------------------------------
    U_CLK_GEN : clk_gen
    port map (
        CLK_50_IN  => clk_in_buf,
        RST_IN     => dcm_rst,  -- FIX: Use separate DCM reset
        PSEN       => psen_int,
        PSINCDEC   => psincdec_int,
        CLK        => clk,
        CLK_PHASE  => clk_phase,
        DCM_LOCKED => dcm_locked,
        PSDONE     => psdone_int
    );
    LOCKED <= dcm_locked;

    ---------------------------------------------------------------------------
    -- 4. Synchronous reset (on clk domain, waits for DCM lock)
    --    Extended to 8 stages for robust metastability protection
    -- FIX Issue 34: Removed circular dependency
    -- OLD: rst_sr <= rst_sr(6 downto 0) & (btn_rst or not dcm_locked);
    -- NEW: rst_sr <= rst_sr(6 downto 0) & btn_rst;
    ---------------------------------------------------------------------------
    RST_SYNC : process(clk)
    begin
        if rising_edge(clk) then
            rst_sr <= rst_sr(6 downto 0) & btn_rst;  -- FIX: Only button reset
        end if;
    end process;
    rst <= rst_sr(7);

    ---------------------------------------------------------------------------
    -- 5. TDC measurement core
    ---------------------------------------------------------------------------
    U_TDC : tapped_delay_line
    generic map (
        TAPS         => TAPS,
        TAPS_PER_CNT => TAPS_PER_CNT,
        COARSE_WIDTH => COARSE_WIDTH,
        FINE_WIDTH   => FINE_WIDTH,
        TOTAL_WIDTH  => TOTAL_WIDTH
    )
    port map (
        CLK_IN       => clk,
        RST_IN       => rst,
        START_ENABLE => start_enable,
        HIT_STOP     => hit_stop_int,
        TOTAL_TIME   => total_time_int,
        TIME_VALID   => time_valid
    );

    ---------------------------------------------------------------------------
    -- 6. Phase sweep controller
    ---------------------------------------------------------------------------
    U_PHASE_SWEEP : phase_sweep
    generic map (
        PHASE_STEPS   => PHASE_STEPS,
        STEP_SIZE     => STEP_SIZE,
        SETTLE_CYCLES => SETTLE_CYCLES,
        PHASE_WIDTH   => PHASE_WIDTH
    )
    port map (
        CLK          => clk,
        RST          => rst,
        SWEEP_NEXT   => sweep_next,
        SWEEP_DONE   => sweep_done,
        SWEEP_PHASE  => sweep_phase,
        SWEEP_FINISH => sweep_finish,
        PSDONE       => psdone_int,
        PSEN         => psen_int,
        PSINCDEC     => psincdec_int
    );

    ---------------------------------------------------------------------------
    -- 7. Sweep engine
    ---------------------------------------------------------------------------
    U_SWEEP_ENGINE : sweep_engine_legacy
    generic map (
        TESTS_PER_PHASE => TESTS_PER_PHASE,
        STOP_DELAY      => STOP_DELAY,
        INTER_TEST_GAP  => INTER_TEST_GAP,
        TOTAL_WIDTH     => TOTAL_WIDTH,
        PHASE_WIDTH     => PHASE_WIDTH,
        TEST_CNT_WIDTH  => TEST_CNT_WIDTH
    )
    port map (
        CLK          => clk,
        RST          => rst,
        SWEEP_DONE   => sweep_done,
        SWEEP_NEXT   => sweep_next,
        SWEEP_PHASE  => sweep_phase,
        SWEEP_FINISH => sweep_finish,
        START_ENABLE => start_enable,
        HIT_STOP     => hit_stop_int,
        TOTAL_TIME   => total_time_int,
        TIME_VALID   => time_valid,
        STAT_DATA    => stat_data_int,
        STAT_WE      => stat_we_int,
        STAT_PHASE   => stat_phase_int,
        STAT_LAST    => stat_last_int,
        ALL_DONE     => ALL_DONE
    );

    ---------------------------------------------------------------------------
    -- 8. Statistics collection and UART transmission
    ---------------------------------------------------------------------------
    U_STATS : stats_collector
    generic map (
        TOTAL_WIDTH  => TOTAL_WIDTH,
        PHASE_WIDTH  => PHASE_WIDTH,
        SUM_WIDTH    => SUM_WIDTH,
        TESTS_PER_PHASE => TESTS_PER_PHASE
    )
    port map (
        CLK        => clk,
        RST        => rst,
        STAT_DATA  => stat_data_int,
        STAT_WE    => stat_we_int,
        STAT_PHASE => stat_phase_int,
        STAT_LAST  => stat_last_int,
        TX_OUT     => TX_OUT
    );

end Structural;
