-- File: tapped_delay_line.vhd
--
-- Fine/coarse integration for slave-mode TDC. The fine-path latency model
-- is computed from the active channel and T2b implementations so coarse/fine
-- alignment stays consistent when encoder internals change.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

-- use work.cal_lut_pkg.all;

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
    USE_DIRECT_EDGE_FINE : boolean := false;
    USE_CAL_LUT  : boolean := false
  );
  port (
    CLK_IN       : in std_logic;
    RST_IN       : in std_logic;
    START_ENABLE : in std_logic;
    HIT_STOP     : in std_logic;
    CALIB_ENABLE : in std_logic;
    CALIB_CLK    : in std_logic;
    TOTAL_TIME   : out std_logic_vector(TOTAL_WIDTH - 1 downto 0);
    TIME_VALID   : out std_logic
  );
end tapped_delay_line;

architecture Structural of tapped_delay_line is

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

  component tdc_ringosc is
    generic (
      g_LENGTH : positive
    );
    port (
      en_i  : in std_logic;
      clk_o : out std_logic
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
  signal pulse_spike          : std_logic;
  signal stop_spike           : std_logic;
  signal ro_clk               : std_logic;
  signal thermo_code          : std_logic_vector(TAPS - 1 downto 0);
  signal thermo_code_stop     : std_logic_vector(TAPS - 1 downto 0);
  signal thermo_code_nccc     : std_logic_vector(TAPS - 1 downto 0);
  signal thermo_code_stop_nccc : std_logic_vector(TAPS - 1 downto 0);
  signal fine_bin             : std_logic_vector(FINE_WIDTH - 1 downto 0);
  signal fine_bin_stop        : std_logic_vector(FINE_WIDTH - 1 downto 0);
  signal fine_bin_t2b         : std_logic_vector(FINE_WIDTH - 1 downto 0);
  signal fine_bin_stop_t2b    : std_logic_vector(FINE_WIDTH - 1 downto 0);
  signal fine_corr            : std_logic_vector(FINE_WIDTH - 1 downto 0);
  signal fine_stop_corr       : std_logic_vector(FINE_WIDTH - 1 downto 0);
  signal coarse_count         : std_logic_vector(COARSE_WIDTH - 1 downto 0);
  signal coarse_done          : std_logic;

  function clog2(val : integer) return integer is
    variable result : integer := 0;
    variable v      : integer := val - 1;
  begin
    if val <= 1 then
      return 1;
    end if;

    while v > 0 loop
      result := result + 1;
      v      := v / 2;
    end loop;

    return result;
  end function;

  function select_fine_cycles(
    use_direct    : boolean;
    channel_cycles: integer;
    direct_extra  : integer;
    tree_cycles   : integer
  ) return integer is
  begin
    if use_direct then
      return channel_cycles + direct_extra;
    end if;
    return channel_cycles + tree_cycles;
  end function;

  function bool_to_std(value : boolean) return std_logic is
  begin
    if value then
      return '1';
    end if;
    return '0';
  end function;

  constant T2B_GROUPS            : integer := (TAPS / 4) + ((TAPS mod 4 + 3) / 4);
  -- Use CALIB_CLK as calibration stimulus (wired to external async pulse at top level).
  -- Set to true to revert calibration stimulus to the local ring oscillator.
  constant USE_RINGOSC_CAL_SOURCE : boolean := false;
  constant USE_RINGOSC_HIT_SOURCE : boolean := false;
  constant RINGOSC_STAT_MODE      : std_logic := bool_to_std(USE_RINGOSC_HIT_SOURCE);
  constant RO_LENGTH           : integer := 15;
  constant T2B_TREE_STAGES     : integer := 1 + clog2(T2B_GROUPS);
  constant CHANNEL_PIPE_CYCLES : integer := 2; -- async-set taps + 2-stage SYS snapshot
  constant DIRECT_EDGE_CYCLES  : integer := 1;
  constant TREE_T2B_CYCLES     : integer := T2B_TREE_STAGES;
  constant FINE_PATH_CYCLES    : integer := select_fine_cycles(
    USE_DIRECT_EDGE_FINE,
    CHANNEL_PIPE_CYCLES,
    DIRECT_EDGE_CYCLES,
    TREE_T2B_CYCLES
  );
  constant PIPELINE_DEPTH      : integer := FINE_PATH_CYCLES + 1;

  signal coarse_done_d    : std_logic_vector(PIPELINE_DEPTH - 1 downto 0) := (others => '0');
  signal clr_pipe         : std_logic_vector(1 downto 0)                  := (others => '0');
  signal clr_pulse_int    : std_logic                                     := '0';
  signal coarse_rst       : std_logic;
  signal total_time_reg   : std_logic_vector(TOTAL_WIDTH - 1 downto 0) := (others => '0');

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
  signal histogram_mode_active : std_logic;
  signal pulse_meta            : std_logic := '0';
  signal pulse_sync            : std_logic := '0';
  signal pulse_sync_d          : std_logic := '0';
  signal pulse_event           : std_logic := '0';

  attribute KEEP of pulse_spike : signal is "TRUE";
  attribute KEEP of stop_spike  : signal is "TRUE";
  attribute KEEP of ro_clk      : signal is "TRUE";

begin

  coarse_rst <= RST_IN or clr_pulse_int;
  histogram_mode_active <= '1' when (CALIB_ENABLE = '1' or RINGOSC_STAT_MODE = '1') else '0';

  U_RINGOSC : tdc_ringosc
  generic map (
    g_LENGTH => RO_LENGTH
  )
  port map (
    en_i  => not RST_IN,
    clk_o => ro_clk
  );

  -- Normal mode uses external launch/stop.
  -- Calibration mode can use either ring-oscillator or CALIB_CLK stimulus.
  pulse_spike <= ro_clk when (CALIB_ENABLE = '1' and USE_RINGOSC_CAL_SOURCE) else
                 CALIB_CLK when CALIB_ENABLE = '1' else
                 ro_clk when USE_RINGOSC_HIT_SOURCE else
                 START_ENABLE;
  stop_spike  <= '0' when CALIB_ENABLE = '1' else '0' when USE_RINGOSC_HIT_SOURCE else HIT_STOP;

  ---------------------------------------------------------------------------
  -- Fine measurement paths (start/stop) with symmetric processing.
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

  U_TDC_STOP : tdc_channel_pulsed
  generic map(TAPS => TAPS)
  port map
  (
    CLK_SYS     => CLK_IN,
    PULSE_SPIKE => stop_spike,
    CLR         => RST_IN,
    CLR_PULSE   => clr_pulse_int,
    THERMO_CODE => thermo_code_stop
  );

  GEN_NCCC_MASK : for i in 0 to TAPS - 1 generate
  begin
    thermo_code_nccc(i) <= '0' when (USE_NCCC and (i mod 4 = 0)) else thermo_code(i);
  end generate GEN_NCCC_MASK;

  GEN_NCCC_MASK_STOP : for i in 0 to TAPS - 1 generate
  begin
    thermo_code_stop_nccc(i) <= '0' when (USE_NCCC and (i mod 4 = 0)) else thermo_code_stop(i);
  end generate GEN_NCCC_MASK_STOP;

  GEN_FINE_T2B : if not USE_DIRECT_EDGE_FINE generate
  begin
    U_T2B_FINE_START : T2b
    generic map(N => TAPS - 1, M => FINE_WIDTH)
    port map
    (
      CLK        => CLK_IN,
      thermo_in  => thermo_code_nccc,
      binary_out => fine_bin_t2b
    );

    U_T2B_FINE_STOP : T2b
    generic map(N => TAPS - 1, M => FINE_WIDTH)
    port map
    (
      CLK        => CLK_IN,
      thermo_in  => thermo_code_stop_nccc,
      binary_out => fine_bin_stop_t2b
    );

    fine_bin      <= fine_bin_t2b;
    fine_bin_stop <= fine_bin_stop_t2b;
  end generate GEN_FINE_T2B;

  GEN_FINE_DIRECT_EDGE : if USE_DIRECT_EDGE_FINE generate
  begin
    -- Direct edge extraction: encode the furthest reached tap on both paths.
    process (thermo_code_nccc)
      variable edge_pos_v : integer range 0 to TAPS;
    begin
      edge_pos_v := 0;
      for i in TAPS - 1 downto 0 loop
        if thermo_code_nccc(i) = '1' then
          edge_pos_v := i + 1;
          exit;
        end if;
      end loop;

      fine_bin <= std_logic_vector(to_unsigned(edge_pos_v, FINE_WIDTH));
    end process;

    process (thermo_code_stop_nccc)
      variable edge_pos_v : integer range 0 to TAPS;
    begin
      edge_pos_v := 0;
      for i in TAPS - 1 downto 0 loop
        if thermo_code_stop_nccc(i) = '1' then
          edge_pos_v := i + 1;
          exit;
        end if;
      end loop;

      fine_bin_stop <= std_logic_vector(to_unsigned(edge_pos_v, FINE_WIDTH));
    end process;
  end generate GEN_FINE_DIRECT_EDGE;

  -- Optional LUT-based fine-code correction. The LUT is generated from
  -- measured calibration data and compiled into cal_lut_pkg.vhd.
  process (fine_bin)
    variable idx_v      : integer;
    variable lut_word_v : unsigned(9 downto 0);
  begin
    idx_v      := to_integer(unsigned(fine_bin));
    lut_word_v := unsigned(fine_bin);

    if false then
      if false then
        lut_word_v := (others => '0');
      end if;
    end if;

    fine_corr <= std_logic_vector(resize(lut_word_v, FINE_WIDTH));
  end process;

  process (fine_bin_stop)
    variable idx_v      : integer;
    variable lut_word_v : unsigned(9 downto 0);
  begin
    idx_v      := to_integer(unsigned(fine_bin_stop));
    lut_word_v := unsigned(fine_bin_stop);

    if false then
      if false then
        lut_word_v := (others => '0');
      end if;
    end if;

    fine_stop_corr <= std_logic_vector(resize(lut_word_v, FINE_WIDTH));
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
    START => START_ENABLE,
    STOP  => HIT_STOP,
    COUNT => coarse_count,
    DONE  => coarse_done
  );

  ---------------------------------------------------------------------------
  -- Output assembly with matched pipeline delays
  --
  -- Statistical mode:
  --   Continuous fine-code publication from ring-oscillator launches.
  -- Deterministic mode:
  --   Both coarse and fine paths are aligned to PIPELINE_DEPTH.
  --
  -- Combined measurement model:
  --   total = coarse*TAPS_PER_CNT_EFF + (fine_stop - fine_start)
  --
  -- Packet format:
  --   [31:26] = coarse_count[5:0]    (debug)
  --   [25:16] = fine_delta[9:0]      (two's-complement debug)
  --   [15:0]  = combined_total[15:0] (primary measurement)
  ---------------------------------------------------------------------------
  process (CLK_IN)
    variable coarse_delayed : std_logic_vector(COARSE_WIDTH - 1 downto 0);
    variable coarse_term_v  : unsigned(TOTAL_WIDTH downto 0);
    variable fine_delta_v   : signed(FINE_WIDTH downto 0);
    variable fine_delta_dbg_v : std_logic_vector(FINE_WIDTH - 1 downto 0);
    variable total_ext_v    : signed(TOTAL_WIDTH + 1 downto 0);
    variable total_combined_v : std_logic_vector(TOTAL_WIDTH - 1 downto 0);
    variable packed_v       : std_logic_vector(21 + FINE_WIDTH downto 0);
  begin
    if rising_edge(CLK_IN) then
      if RST_IN = '1' then
        coarse_done_d  <= (others => '0');
        clr_pipe       <= (others => '0');
        clr_pulse_int  <= '0';
        total_time_reg <= (others => '0');
        TIME_VALID     <= '0';
        pulse_meta     <= '0';
        pulse_sync     <= '0';
        pulse_sync_d   <= '0';
        pulse_event    <= '0';
        for i in 0 to PIPELINE_DEPTH - 1 loop
          coarse_pipe(i) <= (others => '0');
        end loop;
      else
        -- Synchronize async pulse source and detect rising edges in CLK_IN domain.
        pulse_meta   <= pulse_spike;
        pulse_sync   <= pulse_meta;
        pulse_sync_d <= pulse_sync;
        pulse_event  <= pulse_sync and not pulse_sync_d;

        if histogram_mode_active = '1' then
          -- Statistical histogram mode: publish one sample per detected pulse.
          coarse_done_d <= (others => '0');
          clr_pipe      <= (others => '0');
          clr_pulse_int <= '0';

          if pulse_event = '1' then
            packed_v := (others => '0');
            packed_v(25 downto 16) := fine_corr;
            packed_v(15 downto 0)  := std_logic_vector(resize(unsigned(fine_corr), 16));
            total_time_reg <= std_logic_vector(resize(unsigned(packed_v), TOTAL_WIDTH));
            TIME_VALID <= '1';
          else
            TIME_VALID <= '0';
          end if;
        else
          -- Shift coarse_done through pipeline
          coarse_done_d <= coarse_done_d(PIPELINE_DEPTH - 2 downto 0) & coarse_done;

          -- Shift coarse_count through matching pipeline.
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

            -- Symmetric fine-delta and combined total with saturation.
            fine_delta_v := signed('0' & fine_stop_corr) - signed('0' & fine_corr);
            fine_delta_dbg_v := std_logic_vector(resize(fine_delta_v, FINE_WIDTH));

            coarse_term_v := resize(
              unsigned(coarse_delayed) * to_unsigned(TAPS_PER_CNT_EFF, COARSE_WIDTH),
              TOTAL_WIDTH + 1
            );
            total_ext_v := signed('0' & coarse_term_v) + resize(fine_delta_v, TOTAL_WIDTH + 2);

            if total_ext_v(total_ext_v'high) = '1' then
              total_combined_v := (others => '0');
            elsif total_ext_v(TOTAL_WIDTH) = '1' then
              total_combined_v := (others => '1');
            else
              total_combined_v := std_logic_vector(unsigned(total_ext_v(TOTAL_WIDTH - 1 downto 0)));
            end if;

            -- Pack output: coarse debug + fine delta debug + combined result.
            packed_v := coarse_delayed(5 downto 0)
              & fine_delta_dbg_v
              & total_combined_v(15 downto 0);
            total_time_reg <= std_logic_vector(resize(unsigned(packed_v), TOTAL_WIDTH));
            TIME_VALID <= '1';
          end if;
        end if;
      end if;
    end if;
  end process;

  TOTAL_TIME <= total_time_reg;

end Structural;
