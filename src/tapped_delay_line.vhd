-- File: tapped_delay_line.vhd (CORRECTED)
--
-- FIXES APPLIED:
--   Issue 5:  Output format cleaned up ? tap_total is primary measurement,
--             coarse/fine fields are debug overlay
--   Issue 6:  tap_total widened to TOTAL_WIDTH to prevent truncation
--   Issue 7:  ?? CRITICAL ? Pipeline delay extended from 8 to 12 to account
--             for 3 extra stages in tdc_channel_pulsed (capture_reg +
--             hold_reg + bubble_filter) plus T2b latency
--             T2b latency for 300 taps: clog2(75)=7, total stages=8
--             tdc_channel_pulsed: 3 pipeline stages
--             Total: 8 + 3 = 11 cycles, use 12 for margin
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

use work.cal_lut_pkg.all;

library UNISIM;
use UNISIM.VComponents.all;

entity tapped_delay_line is
  generic (
    TAPS         : integer := 200;
    TAPS_PER_CNT : integer := 200;
    COARSE_WIDTH : integer := 16;
    FINE_WIDTH   : integer := 10;
    TOTAL_WIDTH  : integer := 32;
    USE_NCCC     : boolean := true;
    USE_CAL_LUT  : boolean := false
  );
  port (
    CLK_IN       : in std_logic;
    CLK_PHASE    : in std_logic;
    RST_IN       : in std_logic;
    START_ENABLE : in std_logic;
    HIT_STOP     : in std_logic;
    TOTAL_TIME   : out std_logic_vector(TOTAL_WIDTH - 1 downto 0);
    TIME_VALID   : out std_logic
  );
end tapped_delay_line;

architecture Structural of tapped_delay_line is

  component pulse_launch_v2 is
    port (
      CLK_SYS      : in std_logic;
      CLK_PHASE    : in std_logic;
      RST          : in std_logic;
      START_ENABLE : in std_logic;
      PULSE_SPIKE  : out std_logic;
      LAUNCH_DONE  : out std_logic
    );
  end component;

  component tdc_channel_pulsed is
    generic (TAPS : integer := 240);
    port (
      CLK_SYS     : in std_logic;
      PULSE_SPIKE : in std_logic;
      CLR         : in std_logic;
      CLR_PULSE   : in std_logic;
      THERMO_CODE : out std_logic_vector(TAPS - 1 downto 0)
    );
  end component;

  component T2b is
    generic (
      N : integer := 799;
      M : integer := 10);
    port (
      CLK        : in std_logic;
      thermo_in  : in std_logic_vector(N downto 0);
      binary_out : out std_logic_vector(M - 1 downto 0)
    );
  end component;

  component course_counter is
    generic (WIDTH : integer := 16);
    port (
      CLK   : in std_logic;
      RST   : in std_logic;
      START : in std_logic;
      STOP  : in std_logic;
      COUNT : out std_logic_vector(WIDTH - 1 downto 0);
      DONE  : out std_logic
    );
  end component;

  attribute KEEP              : string;
  attribute CLOCK_BUFFER_TYPE : string;
  signal pulse_spike          : std_logic;
  signal thermo_code          : std_logic_vector(TAPS - 1 downto 0);
  signal thermo_code_nccc     : std_logic_vector(TAPS - 1 downto 0);
  signal fine_bin             : std_logic_vector(FINE_WIDTH - 1 downto 0);
  signal fine_corr            : std_logic_vector(FINE_WIDTH - 1 downto 0);
  signal coarse_count         : std_logic_vector(COARSE_WIDTH - 1 downto 0);
  signal coarse_done          : std_logic;

  ---------------------------------------------------------------------------
  -- FIX Issue 7: Pipeline delay calculation
  --   tdc_channel_pulsed: 3 stages (capture_reg + hold_reg + bubble_filter)
  --   T2b for 300 taps: FULL_GROUPS=75, clog2(75)=7, TOTAL_STAGES=8
  --   Total fine path latency: 3 + 8 = 11 cycles
  --   Use 12-stage delay on coarse_done to ensure fine_bin is stable
  ---------------------------------------------------------------------------
  constant PIPELINE_DEPTH : integer                                       := 12;
  signal coarse_done_d    : std_logic_vector(PIPELINE_DEPTH - 1 downto 0) := (others => '0');
  signal clr_pipe         : std_logic_vector(1 downto 0)                  := (others => '0');
  signal clr_pulse_int    : std_logic                                     := '0';
  signal coarse_rst       : std_logic;
  signal total_time_reg   : std_logic_vector(TOTAL_WIDTH - 1 downto 0) := (others => '0');
  signal start_en_ext     : std_logic := '0';
  signal start_en_d       : std_logic := '0';
  signal start_stretch    : unsigned(2 downto 0) := (others => '0');
  constant START_STRETCH_CYCLES : unsigned(2 downto 0) := to_unsigned(4, 3);

  -- In NCCC mode, skip tap 0 of each CARRY4 block (indices 0, 4, 8, ...).
  function effective_taps_per_cnt(base_taps : integer; use_nccc_mode : boolean) return integer is
  begin
    if use_nccc_mode then
      return base_taps - ((base_taps + 3) / 4);
    end if;
    return base_taps;
  end function;

  constant TAPS_PER_CNT_EFF : integer := effective_taps_per_cnt(TAPS_PER_CNT, USE_NCCC);

  -- Pipeline for coarse_count to match fine path latency
  type coarse_pipe_t is array (0 to PIPELINE_DEPTH - 1) of
  std_logic_vector(COARSE_WIDTH - 1 downto 0);
  signal coarse_pipe : coarse_pipe_t := (others => (others => '0'));

  attribute KEEP of pulse_spike              : signal is "TRUE";
  attribute CLOCK_BUFFER_TYPE of pulse_spike : signal is "NONE";

begin

  coarse_rst <= RST_IN or clr_pulse_int;

  -- Stretch START_ENABLE so CDC sampling in pulse_launch_v2 does not miss
  -- narrow single-cycle requests when crossing into CLK_PHASE domain.
  process (CLK_IN)
  begin
    if rising_edge(CLK_IN) then
      if RST_IN = '1' then
        start_en_d    <= '0';
        start_stretch <= (others => '0');
      else
        start_en_d <= START_ENABLE;
        if (START_ENABLE = '1') and (start_en_d = '0') then
          start_stretch <= START_STRETCH_CYCLES;
        elsif start_stretch /= 0 then
          start_stretch <= start_stretch - 1;
        end if;
      end if;
    end if;
  end process;

  start_en_ext <= '1' when (START_ENABLE = '1' or start_stretch /= 0) else '0';

  ---------------------------------------------------------------------------
  -- Pulse launch
  ---------------------------------------------------------------------------
  U_PULSE_LAUNCH : pulse_launch_v2
  port map
  (
    CLK_SYS      => CLK_IN,
    CLK_PHASE    => CLK_PHASE,
    RST          => RST_IN,
    START_ENABLE => start_en_ext,
    PULSE_SPIKE  => pulse_spike,
    LAUNCH_DONE  => open
  );

  ---------------------------------------------------------------------------
  -- Fine measurement path (3 pipeline stages + T2b stages)
  ---------------------------------------------------------------------------
  U_TDC_FINE : tdc_channel_pulsed
  generic map(TAPS => TAPS)
  port map
  (
    CLK_SYS     => CLK_IN,
    PULSE_SPIKE => pulse_spike,
    CLR         => RST_IN,
    CLR_PULSE   => clr_pulse_int,
    THERMO_CODE => thermo_code
  );

  GEN_NCCC_MASK : for i in 0 to TAPS - 1 generate
  begin
    thermo_code_nccc(i) <= '0' when (USE_NCCC and (i mod 4 = 0)) else thermo_code(i);
  end generate GEN_NCCC_MASK;

  U_T2B_FINE : T2b
  generic map(N => TAPS - 1, M => FINE_WIDTH)
  port map
  (
    CLK        => CLK_IN,
    thermo_in  => thermo_code_nccc,
    binary_out => fine_bin
  );

  -- Optional LUT-based fine-code correction. The LUT is generated from
  -- measured calibration data and compiled into cal_lut_pkg.vhd.
  process (fine_bin)
    variable idx_v      : integer;
    variable lut_word_v : unsigned(CAL_LUT_WIDTH - 1 downto 0);
  begin
    idx_v      := to_integer(unsigned(fine_bin));
    lut_word_v := resize(unsigned(fine_bin), CAL_LUT_WIDTH);

    if USE_CAL_LUT then
      if idx_v < CAL_LUT_DEPTH then
        lut_word_v := CAL_FINE_LUT(idx_v);
      end if;
    end if;

    fine_corr <= std_logic_vector(resize(lut_word_v, FINE_WIDTH));
  end process;

  ---------------------------------------------------------------------------
  -- Coarse timing path
  ---------------------------------------------------------------------------
  U_COARSE : course_counter
  generic map(WIDTH => COARSE_WIDTH)
  port map
  (
    CLK   => CLK_IN,
    RST   => coarse_rst,
    START => start_en_ext,
    STOP  => HIT_STOP,
    COUNT => coarse_count,
    DONE  => coarse_done
  );

  ---------------------------------------------------------------------------
  -- Output assembly with matched pipeline delays
  --
  -- FIX Issue 7: Both coarse_done and coarse_count are delayed by
  --   PIPELINE_DEPTH cycles to match the fine measurement path latency.
  --
  -- Packet format:
  --   [31:26] = coarse_count[5:0]   (6 bits, debug)
  --   [25:16] = fine_bin[9:0]       (10 bits, debug)
  --   [15:0]  = tap-domain total    (16 bits, primary measurement)
  ---------------------------------------------------------------------------
  process (CLK_IN)
    variable tap_total_v    : unsigned(TOTAL_WIDTH - 1 downto 0);
    variable coarse_delayed : std_logic_vector(COARSE_WIDTH - 1 downto 0);
    variable packed_v       : std_logic_vector(21 + FINE_WIDTH downto 0);
  begin
    if rising_edge(CLK_IN) then
      if RST_IN = '1' then
        coarse_done_d  <= (others => '0');
        clr_pipe       <= (others => '0');
        clr_pulse_int  <= '0';
        total_time_reg <= (others => '0');
        TIME_VALID     <= '0';
        for i in 0 to PIPELINE_DEPTH - 1 loop
          coarse_pipe(i) <= (others => '0');
        end loop;
      else
        -- Shift coarse_done through pipeline
        coarse_done_d <= coarse_done_d(PIPELINE_DEPTH - 2 downto 0) & coarse_done;

        -- Shift coarse_count through matching pipeline
        coarse_pipe(0) <= coarse_count;
        for i in 1 to PIPELINE_DEPTH - 1 loop
          coarse_pipe(i) <= coarse_pipe(i - 1);
        end loop;

        -- Clear logic uses end of pipeline
        clr_pipe      <= clr_pipe(0) & coarse_done_d(PIPELINE_DEPTH - 1);
        clr_pulse_int <= coarse_done_d(PIPELINE_DEPTH - 1) or clr_pipe(1);

        TIME_VALID <= '0';

        if coarse_done_d(PIPELINE_DEPTH - 1) = '1' then
          -- Use delayed coarse count that matches fine path
          coarse_delayed := coarse_pipe(PIPELINE_DEPTH - 1);

          -- Compute total in tap domain (full width)
          tap_total_v := resize(
            unsigned(coarse_delayed) *
            to_unsigned(TAPS_PER_CNT_EFF, COARSE_WIDTH),
            TOTAL_WIDTH
            ) + resize(unsigned(fine_corr), TOTAL_WIDTH);

          -- Pack output: debug fields + primary measurement
          packed_v := coarse_delayed(5 downto 0)
            & fine_bin(FINE_WIDTH - 1 downto 0)
            & std_logic_vector(tap_total_v(15 downto 0));
          total_time_reg <= std_logic_vector(resize(unsigned(packed_v), TOTAL_WIDTH));
          TIME_VALID <= '1';
        end if;
      end if;
    end if;
  end process;

  TOTAL_TIME <= total_time_reg;

end Structural;
