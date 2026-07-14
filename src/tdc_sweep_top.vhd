--------------------------------------------------------------------------------
-- File: tdc_sweep_top.vhd (FIXED VERSION v2)
--
-- FIXES APPLIED:
--   Issue 1:  POR relies on INIT values - acceptable for Spartan-6, documented
--   Issue 3:  CLK_FREQ default now 50_000_000 (matches system clock)
--   Issue 12: RST synchronization improved
--   Issue 34: DCM LOCK DEADLOCK - Fixed circular dependency in reset logic
--   Issue 35: DCM reset now uses power-on reset only, not system reset
--   Issue 36: POST-PAR FIX - POR now uses 'clk' which comes from
--             IBUFG???BUFG (always valid, no DCM dependency). The BUFG
--             output is available immediately after GSR deasserts (~100ns).
--             POR shift register clears within 3 clk cycles after GSR.
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
        TAPS            : integer := 200;
        TAPS_PER_CNT    : integer := 200;
        USE_NCCC        : boolean := true;
        USE_CAL_LUT     : boolean := false;
        COARSE_WIDTH    : integer := 16;
        FINE_WIDTH      : integer := 10;
        TOTAL_WIDTH     : integer := 32;
        PHASE_STEPS     : integer := 200;
        STEP_SIZE       : integer := 1;
        SETTLE_CYCLES   : integer := 32;
        PHASE_WIDTH     : integer := 8;
        TESTS_PER_PHASE : integer := 256;
        STOP_DELAY      : integer := 3;
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
    end component;

    component tapped_delay_line is
        Generic (
            TAPS         : integer := 200;
            TAPS_PER_CNT : integer := 200;
            USE_NCCC     : boolean := true;
            USE_CAL_LUT  : boolean := false;
            COARSE_WIDTH : integer := 16;
            FINE_WIDTH   : integer := 10;
            TOTAL_WIDTH  : integer := 32
        );
        Port (
            CLK_IN       : in  STD_LOGIC;
            CLK_PHASE    : in  STD_LOGIC;
            RST_IN       : in  STD_LOGIC;
            START_ENABLE : in  STD_LOGIC;
            HIT_STOP     : in  STD_LOGIC;
            TOTAL_TIME   : out STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
            TIME_VALID   : out STD_LOGIC
        );
    end component;

    component stats_collector is
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
    end component;

    component uart_packetiser is
        Generic (
            TOTAL_WIDTH    : integer := 32;
            PHASE_WIDTH    : integer := 8;
            TEST_CNT_WIDTH : integer := 10;
            SUM_WIDTH      : integer := 42
        );
        Port (
            CLK          : in  STD_LOGIC;
            RST          : in  STD_LOGIC;
            PHASE_IN     : in  STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
            MIN_IN       : in  STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
            MAX_IN       : in  STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
            SUM_IN       : in  STD_LOGIC_VECTOR(SUM_WIDTH-1 downto 0);
            COUNT_IN     : in  STD_LOGIC_VECTOR(TEST_CNT_WIDTH-1 downto 0);
            RESULT_VALID : in  STD_LOGIC;
            TX_DATA      : out STD_LOGIC_VECTOR(7 downto 0);
            TX_START     : out STD_LOGIC;
            TX_BUSY      : in  STD_LOGIC;
            PACK_DONE    : out STD_LOGIC;
            PACK_BUSY    : out STD_LOGIC
        );
    end component;

    component uart_tx is
        Generic (
            CLK_FREQ : integer := 50_000_000;
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
    end component;

    ---------------------------------------------------------------------------
    -- Clocking signals
    ---------------------------------------------------------------------------
    signal clk_in_buf : STD_LOGIC;    -- Top-level IBUFG output
    signal clk        : STD_LOGIC;    -- IBUFG ??? BUFG (always valid)
    signal clk_phase  : STD_LOGIC;    -- DCM CLK0 ??? BUFG (valid after lock)
    signal dcm_locked : STD_LOGIC;

    ---------------------------------------------------------------------------
    -- Reset domain signals
    --
    -- BOOT SEQUENCE (post-PAR timing simulation):
    --   t=0ns:      GSR asserted by glbl.v, all FFs held in INIT state
    --   t~100ns:    GSR deasserts, FFs release
    --               por_sr INIT="111" ??? starts shifting '0' in on clk edges
    --               clk is valid (IBUFG???BUFG, no DCM dependency)
    --   t~160ns:    por_sr = "000", por deasserts
    --   t~160ns:    dcm_rst deasserts, DCM begins locking
    --   t~5us:      DCM locks, dcm_locked = '1'
    --   t~5.2us:    rst_sr shifts out all '1's, rst deasserts
    --               System begins operation
    ---------------------------------------------------------------------------
signal por_sr : STD_LOGIC_VECTOR(15 downto 0) := X"FFFF";
    signal por             : STD_LOGIC;
    signal dcm_rst         : STD_LOGIC;
    signal btn_rst         : STD_LOGIC;
    signal btn_rst_sync_sr : STD_LOGIC_VECTOR(2 downto 0) := "111";
    signal btn_rst_sync    : STD_LOGIC;
    signal rst_in_clean    : STD_LOGIC;
    signal hw_rst          : STD_LOGIC;
    signal rst_sr          : STD_LOGIC_VECTOR(7 downto 0) := "11111111";
    signal rst             : STD_LOGIC;

    ---------------------------------------------------------------------------
    -- Sweep control
    ---------------------------------------------------------------------------
    signal sweep_next   : STD_LOGIC;
    signal sweep_done   : STD_LOGIC;
    signal sweep_phase  : STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
    signal sweep_finish : STD_LOGIC;

    -- Phase sweep DCM control
    signal psen_int     : STD_LOGIC;
    signal psen_safe    : STD_LOGIC;
    signal psincdec_int : STD_LOGIC;
    signal psdone_int   : STD_LOGIC;

    -- TDC measurement
    signal start_enable   : STD_LOGIC;
    signal hit_stop_int   : STD_LOGIC;
    signal total_time_int : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
    signal time_valid     : STD_LOGIC;

    -- Statistics
    signal stat_data_int  : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
    signal stat_we_int    : STD_LOGIC;
    signal stat_phase_int : STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
    signal stat_last_int  : STD_LOGIC;

    -- Stats ??? UART path
    signal phase_out_int    : STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
    signal min_out_int      : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
    signal max_out_int      : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
    signal sum_out_int      : STD_LOGIC_VECTOR(SUM_WIDTH-1 downto 0);
    signal count_out_int    : STD_LOGIC_VECTOR(TEST_CNT_WIDTH-1 downto 0);
    signal result_valid_int : STD_LOGIC;

    signal uart_tx_data_int  : STD_LOGIC_VECTOR(7 downto 0);
    signal uart_tx_start_int : STD_LOGIC;
    signal uart_tx_busy_int  : STD_LOGIC;

begin

    ---------------------------------------------------------------------------
    -- 0. Top-level input buffer
    --    CLK_IN pin is buffered once here and fanned out to:
    --      a) clk_gen input
    --      b) POR generator clock
    ---------------------------------------------------------------------------
    U_IBUFG_TOP : IBUFG
    port map (
        I => CLK_IN,
        O => clk_in_buf
    );

    ---------------------------------------------------------------------------
    -- 1. Input sanitization
    --    Treat X/U/Z on RST_IN as deasserted (not pressed)
    --    Button is active-high on the board, active-low internally
    ---------------------------------------------------------------------------
    rst_in_clean <= '1' when RST_IN = '1' else '0';
    btn_rst      <= not rst_in_clean;

    ---------------------------------------------------------------------------
    -- 2. Power-On Reset (POR)
    --
    --    por_sr is initialized to "111" by FPGA configuration (INIT values).
    --    After GSR deasserts (~100ns in post-PAR sim), the shift register
    --    begins shifting in '0' on each rising_edge(clk).
    --
    --    CRITICAL: 'clk' comes from IBUFG???BUFG inside clk_gen.
    --    This path has NO DCM dependency ??? the BUFG output is valid
    --    as soon as the input clock is running and GSR deasserts.
    --    There is NO circular dependency.
    --
    --    Timeline:
    --      Cycle 1 after GSR: por_sr = "110"
    --      Cycle 2 after GSR: por_sr = "100"
    --      Cycle 3 after GSR: por_sr = "000" ??? por = '0' (deasserted)
    ---------------------------------------------------------------------------
    POR_GEN : process(clk_in_buf)
    begin
        if rising_edge(clk_in_buf) then
            por_sr <= por_sr(14 downto 0) & '0';
        end if;
    end process;
    por <= por_sr(15);

    ---------------------------------------------------------------------------
    -- 3. Button reset synchronizer
    --    Synchronize external button into clk domain (2FF + 1 pipeline)
    --    btn_rst_sync_sr INIT="111" ensures reset is asserted at boot
    --    (same as POR ??? belt and suspenders)
    ---------------------------------------------------------------------------
    BTN_RST_SYNC1 : process(clk_in_buf)
    begin
        if rising_edge(clk_in_buf) then
            btn_rst_sync_sr <= btn_rst_sync_sr(1 downto 0) & btn_rst;
        end if;
    end process;
    btn_rst_sync <= btn_rst_sync_sr(2);

    ---------------------------------------------------------------------------
    -- 4. DCM reset
    --    As requested, DCM reset is controlled only by the button reset.
    ---------------------------------------------------------------------------
    dcm_rst <= btn_rst;

    ---------------------------------------------------------------------------
    -- 5. Clock generation
    --    clk       = IBUFG ??? BUFG (always valid, no DCM dependency)
    --    clk_phase = DCM CLK0 ??? BUFG (valid after DCM locks)
    ---------------------------------------------------------------------------
    U_CLK_GEN : clk_gen
    port map (
        CLK_50_IN  => clk_in_buf,
        RST_IN     => dcm_rst,
        PSEN       => psen_safe,
        PSINCDEC   => psincdec_int,
        CLK        => clk,
        CLK_PHASE  => clk_phase,
        DCM_LOCKED => dcm_locked,
        PSDONE     => psdone_int
    );
    LOCKED <= dcm_locked;

    -- Gate PSEN: only allow phase shifts once DCM is locked and stable
    psen_safe <= psen_int and dcm_locked;

    ---------------------------------------------------------------------------
    -- 6. System reset synchronizer
    --    System stays in reset until:
    --      a) Button is released (btn_rst_sync = '0')
    --      b) DCM is locked (dcm_locked = '1')
    --    The shift register ensures clean deassert (8 cycles of '0' input)
    --
    --    rst_sr INIT="11111111" keeps system in reset at boot.
    --    Input to shift register: btn_rst_sync OR (NOT dcm_locked)
    --      - btn_rst_sync='1' while button pressed ??? rst stays asserted
    --      - dcm_locked='0' while DCM unlocked ??? rst stays asserted
    --      - Both clear ??? '0' shifts in ??? after 8 cycles rst deasserts
    --
    --    NO CIRCULAR DEPENDENCY because:
    --      clk = IBUFG???BUFG (always valid, drives this process)
    --      dcm_rst = por OR btn_rst (does NOT use dcm_locked)
    --      This process READS dcm_locked but does NOT feed back to DCM
    ---------------------------------------------------------------------------
    RST_SYNC : process(clk)
    begin
        if rising_edge(clk) then
            rst_sr <= rst_sr(6 downto 0) & (btn_rst_sync or not dcm_locked);
        end if;
    end process;
    rst <= rst_sr(7);

    ---------------------------------------------------------------------------
    -- 7. TDC measurement core
    ---------------------------------------------------------------------------
    U_TDC : tapped_delay_line
    generic map (
        TAPS         => TAPS,
        TAPS_PER_CNT => TAPS_PER_CNT,
        USE_NCCC     => USE_NCCC,
        USE_CAL_LUT  => USE_CAL_LUT,
        COARSE_WIDTH => COARSE_WIDTH,
        FINE_WIDTH   => FINE_WIDTH,
        TOTAL_WIDTH  => TOTAL_WIDTH
    )
    port map (
        CLK_IN       => clk,
        CLK_PHASE    => clk_phase,
        RST_IN       => rst,
        START_ENABLE => start_enable,
        HIT_STOP     => hit_stop_int,
        TOTAL_TIME   => total_time_int,
        TIME_VALID   => time_valid
    );

    ---------------------------------------------------------------------------
    -- 8. Phase sweep controller
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
    -- 9. Sweep engine
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
    -- 10. Statistics collection
    ---------------------------------------------------------------------------
    U_STATS : stats_collector
    generic map (
        TOTAL_WIDTH    => TOTAL_WIDTH,
        PHASE_WIDTH    => PHASE_WIDTH,
        TEST_CNT_WIDTH => TEST_CNT_WIDTH,
        SUM_WIDTH      => SUM_WIDTH
    )
    port map (
        CLK          => clk,
        RST          => rst,
        STAT_DATA    => stat_data_int,
        STAT_WE      => stat_we_int,
        STAT_PHASE   => stat_phase_int,
        STAT_LAST    => stat_last_int,
        PHASE_OUT    => phase_out_int,
        MIN_OUT      => min_out_int,
        MAX_OUT      => max_out_int,
        SUM_OUT      => sum_out_int,
        COUNT_OUT    => count_out_int,
        RESULT_VALID => result_valid_int
    );

    ---------------------------------------------------------------------------
    -- 11. UART packetiser
    ---------------------------------------------------------------------------
    U_UART_PACKETISER : uart_packetiser
    generic map (
        TOTAL_WIDTH    => TOTAL_WIDTH,
        PHASE_WIDTH    => PHASE_WIDTH,
        TEST_CNT_WIDTH => TEST_CNT_WIDTH,
        SUM_WIDTH      => SUM_WIDTH
    )
    port map (
        CLK          => clk,
        RST          => rst,
        PHASE_IN     => phase_out_int,
        MIN_IN       => min_out_int,
        MAX_IN       => max_out_int,
        SUM_IN       => sum_out_int,
        COUNT_IN     => count_out_int,
        RESULT_VALID => result_valid_int,
        TX_DATA      => uart_tx_data_int,
        TX_START     => uart_tx_start_int,
        TX_BUSY      => uart_tx_busy_int,
        PACK_DONE    => open,
        PACK_BUSY    => open
    );

    ---------------------------------------------------------------------------
    -- 12. UART transmitter
    ---------------------------------------------------------------------------
    U_UART_TX : uart_tx
    generic map (
        CLK_FREQ => CLK_FREQ,
        BAUD     => BAUD
    )
    port map (
        CLK      => clk,
        RST      => rst,
        TX_DATA  => uart_tx_data_int,
        TX_START => uart_tx_start_int,
        TX_OUT   => TX_OUT,
        TX_BUSY  => uart_tx_busy_int
    );

end Structural;