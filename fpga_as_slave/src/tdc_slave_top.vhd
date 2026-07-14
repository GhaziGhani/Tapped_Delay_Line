library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity tdc_slave_top is
    Generic (
        CLK_FREQ     : integer := 50_000_000;
        BAUD         : integer := 115_200;
        TAPS         : integer := 200;
        TOTAL_WIDTH  : integer := 32;
        STOP_DELAY   : integer := 3;
        HIST_BINS    : integer := 256;
        CAL_SAMPLES  : integer := 32768
    );
    Port (
        CLK_IN       : in  STD_LOGIC;
        EXT_CAL_CLK  : in  STD_LOGIC;
        RST_IN       : in  STD_LOGIC;
        RX           : in  STD_LOGIC;
        TX           : out STD_LOGIC;
        led          : out STD_LOGIC_VECTOR(3 downto 0)
    );
end tdc_slave_top;

architecture Behavioral of tdc_slave_top is

    function clog2(n : positive) return natural is
        variable v : natural := n - 1;
        variable r : natural := 0;
    begin
        while v > 0 loop
            v := v / 2;
            r := r + 1;
        end loop;
        return r;
    end function;

    constant HIST_ADDR_WIDTH : integer := clog2(HIST_BINS);

    component clk_gen is
        Port (
            CLK_50_IN  : in  STD_LOGIC;
            RST_IN     : in  STD_LOGIC;
            PSEN       : in  STD_LOGIC;
            PSINCDEC   : in  STD_LOGIC;
            CLK        : out STD_LOGIC;
            CLK_PHASE  : out STD_LOGIC;
            CLK_PHASE_90  : out STD_LOGIC;
            CLK_PHASE_180 : out STD_LOGIC;
            CLK_PHASE_270 : out STD_LOGIC;
            DCM_LOCKED : out STD_LOGIC;
            PSDONE     : out STD_LOGIC
        );
    end component;

    component tdc_calib_pll is
        Port (
            CLK_IN     : in  STD_LOGIC;
            RST_IN     : in  STD_LOGIC;
            CLK_CAL    : out STD_LOGIC;
            LOCKED_OUT : out STD_LOGIC
        );
    end component;

    component tapped_delay_line is
        Generic (
            TAPS         : integer := 200;
            TAPS_PER_CNT : integer := 200;
            COARSE_WIDTH : integer := 16;
            FINE_WIDTH   : integer := 10;
            TOTAL_WIDTH  : integer := 32;
            USE_NCCC     : boolean := true;
            USE_DIRECT_EDGE_FINE : boolean := false;
            USE_CAL_LUT  : boolean := false
        );
        Port (
            CLK_IN       : in  STD_LOGIC;
            RST_IN       : in  STD_LOGIC;
            START_ENABLE : in  STD_LOGIC;
            HIT_STOP     : in  STD_LOGIC;
            CALIB_ENABLE : in  STD_LOGIC;
            CALIB_CLK    : in  STD_LOGIC;
            TOTAL_TIME   : out STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
            TIME_VALID   : out STD_LOGIC
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

    component bram_histogrammer is
        Generic (
            ADDR_WIDTH : integer := 8;
            DATA_WIDTH : integer := 32
        );
        Port (
            clk         : in  STD_LOGIC;
            reset       : in  STD_LOGIC;
            clear_start : in  STD_LOGIC;
            clear_busy  : out STD_LOGIC;
            hit_valid   : in  STD_LOGIC;
            hit_bin     : in  STD_LOGIC_VECTOR(ADDR_WIDTH-1 downto 0);
            hit_ready   : out STD_LOGIC;
            hit_accepted: out STD_LOGIC;
            read_addr   : in  STD_LOGIC_VECTOR(ADDR_WIDTH-1 downto 0);
            read_data   : out STD_LOGIC_VECTOR(DATA_WIDTH-1 downto 0)
        );
    end component;

    -- Clocks and Resets
    signal sys_clk       : STD_LOGIC;
    signal dcm_locked    : STD_LOGIC;
    signal sys_rst       : STD_LOGIC;
    signal calib_clk     : STD_LOGIC;
    signal calib_clk_sel : STD_LOGIC;

    -- TDC channel
    signal start_enable : STD_LOGIC := '0';
    signal hit_stop     : STD_LOGIC := '0';
    signal calib_enable : STD_LOGIC := '0';
    signal total_time   : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
    signal time_valid   : STD_LOGIC;

    -- Histogram BRAM path
    signal hist_clear_start : STD_LOGIC := '0';
    signal hist_clear_busy  : STD_LOGIC;
    signal hist_hit_valid   : STD_LOGIC := '0';
    signal hist_hit_ready   : STD_LOGIC;
    signal hist_hit_accepted: STD_LOGIC;
    signal hist_hit_bin     : STD_LOGIC_VECTOR(HIST_ADDR_WIDTH-1 downto 0);
    signal hist_read_addr   : STD_LOGIC_VECTOR(HIST_ADDR_WIDTH-1 downto 0) := (others => '0');
    signal hist_read_data   : STD_LOGIC_VECTOR(31 downto 0);

    -- UART
    signal tx_start   : STD_LOGIC := '0';
    signal tx_data    : STD_LOGIC_VECTOR(7 downto 0) := (others => '0');
    signal tx_busy    : STD_LOGIC;
    signal tx_ready   : STD_LOGIC;

    -- FSM state
    type state_t is (
        CLEAR_BRAM_START,
        CLEAR_BRAM_WAIT,
        ACQUIRE_HITS,
        TX_SYNC_0,
        TX_SYNC_1,
        TX_TYPE,
        TX_VERSION,
        TX_BINS_LSB,
        TX_BINS_MSB,
        TX_LOAD_BIN,
        TX_BIN_B0,
        TX_BIN_B1,
        TX_BIN_B2,
        TX_BIN_B3,
        TX_END_0,
        TX_END_1,
        DONE
    );
    signal state : state_t := CLEAR_BRAM_START;

    signal sample_count  : integer range 0 to CAL_SAMPLES := 0;
    signal stream_bin_idx : integer range 0 to HIST_BINS - 1 := 0;
    signal resend_wait_cnt : integer range 0 to CLK_FREQ := 0;

    signal rst_active_high : STD_LOGIC;
    signal led_reg         : STD_LOGIC_VECTOR(3 downto 0) := "0001";

    constant FRAME_SYNC_0    : STD_LOGIC_VECTOR(7 downto 0) := x"A5";
    constant FRAME_SYNC_1    : STD_LOGIC_VECTOR(7 downto 0) := x"5A";
    constant FRAME_TYPE_CAL  : STD_LOGIC_VECTOR(7 downto 0) := x"C1";
    constant FRAME_VERSION   : STD_LOGIC_VECTOR(7 downto 0) := x"01";
    constant FRAME_END_0     : STD_LOGIC_VECTOR(7 downto 0) := x"55";
    constant FRAME_END_1     : STD_LOGIC_VECTOR(7 downto 0) := x"AA";
    constant BINS_LSB        : STD_LOGIC_VECTOR(7 downto 0) := std_logic_vector(to_unsigned(HIST_BINS mod 256, 8));
    constant BINS_MSB        : STD_LOGIC_VECTOR(7 downto 0) := std_logic_vector(to_unsigned(HIST_BINS / 256, 8));
    constant RESEND_WAIT_CYCLES : integer := CLK_FREQ / 5;
    constant USE_EXTERNAL_CAL_SOURCE : boolean := true;

begin
    rst_active_high <= not RST_IN;
    sys_rst <= rst_active_high or not dcm_locked;
    led <= led_reg;
    -- Guard against advancing two TX states before uart_tx consumes TX_START.
    -- tx_start is registered, so hold tx_ready low for one cycle after strobing.
    tx_ready <= (not tx_busy) and (not tx_start);
    hist_hit_bin <= total_time(HIST_ADDR_WIDTH - 1 downto 0);
    calib_clk_sel <= EXT_CAL_CLK when USE_EXTERNAL_CAL_SOURCE else calib_clk;

    -- RX is currently unused in startup-stream mode.
    -- Kept as a top-level port to preserve constraints and future command mode.
    

    inst_clk_gen: clk_gen
        port map (
            CLK_50_IN  => CLK_IN,
            RST_IN     => rst_active_high,
            PSEN       => '0',
            PSINCDEC   => '0',
            CLK        => sys_clk,
            CLK_PHASE  => open,
            CLK_PHASE_90  => open,
            CLK_PHASE_180 => open,
            CLK_PHASE_270 => open,
            DCM_LOCKED => dcm_locked,
            PSDONE     => open
        );

    inst_calib_pll: tdc_calib_pll
        port map (
            CLK_IN     => sys_clk,
            RST_IN     => rst_active_high,
            CLK_CAL    => calib_clk,
            LOCKED_OUT => open
        );

    inst_tapped_line: tapped_delay_line
        generic map (
            TAPS => TAPS, TAPS_PER_CNT => TAPS,
            COARSE_WIDTH => 16, FINE_WIDTH => 10, TOTAL_WIDTH => TOTAL_WIDTH,
            USE_NCCC => true, USE_DIRECT_EDGE_FINE => false, USE_CAL_LUT => false
        )
        port map (
            CLK_IN       => sys_clk,
            RST_IN       => sys_rst,
            START_ENABLE => start_enable,
            HIT_STOP     => hit_stop,
            CALIB_ENABLE => calib_enable,
            CALIB_CLK    => calib_clk_sel,
            TOTAL_TIME   => total_time,
            TIME_VALID   => time_valid
        );

    inst_tx: uart_tx
        generic map ( CLK_FREQ => CLK_FREQ, BAUD => BAUD )
        port map (
            CLK      => sys_clk,
            RST      => sys_rst,
            TX_DATA  => tx_data,
            TX_START => tx_start,
            TX_OUT   => TX,
            TX_BUSY  => tx_busy
        );

    inst_histogram: bram_histogrammer
        generic map (
            ADDR_WIDTH => HIST_ADDR_WIDTH,
            DATA_WIDTH => 32
        )
        port map (
            clk         => sys_clk,
            reset       => sys_rst,
            clear_start => hist_clear_start,
            clear_busy  => hist_clear_busy,
            hit_valid   => hist_hit_valid,
            hit_bin     => hist_hit_bin,
            hit_ready   => hist_hit_ready,
            hit_accepted=> hist_hit_accepted,
            read_addr   => hist_read_addr,
            read_data   => hist_read_data
        );

    process(sys_clk)
    begin
        if rising_edge(sys_clk) then
            if sys_rst = '1' then
                state <= CLEAR_BRAM_START;
                start_enable <= '0';
                hit_stop <= '0';
                calib_enable <= '0';
                tx_start <= '0';
                hist_clear_start <= '0';
                hist_hit_valid <= '0';
                led_reg <= "0001";
                sample_count <= 0;
                stream_bin_idx <= 0;
                resend_wait_cnt <= 0;
                hist_read_addr <= (others => '0');
            else
                -- Defaults
                start_enable <= '0';
                hit_stop <= '0';
                calib_enable <= '0';
                tx_start <= '0';
                hist_clear_start <= '0';
                hist_hit_valid <= '0';
                resend_wait_cnt <= 0;

                case state is
                    when CLEAR_BRAM_START =>
                        hist_clear_start <= '1';
                        sample_count <= 0;
                        stream_bin_idx <= 0;
                        hist_read_addr <= (others => '0');
                        led_reg <= "0001";
                        state <= CLEAR_BRAM_WAIT;

                    when CLEAR_BRAM_WAIT =>
                        led_reg <= "0001";
                        if hist_clear_busy = '1' then
                            state <= ACQUIRE_HITS;
                        else
                            state <= CLEAR_BRAM_WAIT;
                        end if;

                    when ACQUIRE_HITS =>
                        calib_enable <= '1';
                        led_reg <= "0010";
                        if sample_count = CAL_SAMPLES then
                            stream_bin_idx <= 0;
                            hist_read_addr <= (others => '0');
                            state <= TX_SYNC_0;
                        else
                            if not (sample_count = CAL_SAMPLES - 1 and hist_hit_accepted = '1') then
                                if time_valid = '1' and hist_hit_ready = '1' then
                                    hist_hit_valid <= '1';
                                end if;
                            end if;

                            if hist_hit_accepted = '1' and sample_count < CAL_SAMPLES then
                                sample_count <= sample_count + 1;
                            end if;
                        end if;

                    when TX_SYNC_0 =>
                        led_reg <= "0100";
                        if tx_ready = '1' then
                            tx_start <= '1';
                            tx_data <= FRAME_SYNC_0;
                            state <= TX_SYNC_1;
                        end if;

                    when TX_SYNC_1 =>
                        if tx_ready = '1' then
                            tx_start <= '1';
                            tx_data <= FRAME_SYNC_1;
                            state <= TX_TYPE;
                        end if;

                    when TX_TYPE =>
                        if tx_ready = '1' then
                            tx_start <= '1';
                            tx_data <= FRAME_TYPE_CAL;
                            state <= TX_VERSION;
                        end if;

                    when TX_VERSION =>
                        if tx_ready = '1' then
                            tx_start <= '1';
                            tx_data <= FRAME_VERSION;
                            state <= TX_BINS_LSB;
                        end if;

                    when TX_BINS_LSB =>
                        if tx_ready = '1' then
                            tx_start <= '1';
                            tx_data <= BINS_LSB;
                            state <= TX_BINS_MSB;
                        end if;

                    when TX_BINS_MSB =>
                        if tx_ready = '1' then
                            tx_start <= '1';
                            tx_data <= BINS_MSB;
                            hist_read_addr <= (others => '0');
                            state <= TX_LOAD_BIN;
                        end if;

                    when TX_LOAD_BIN =>
                        state <= TX_BIN_B0;

                    when TX_BIN_B0 =>
                        if tx_ready = '1' then
                            tx_start <= '1';
                            tx_data <= hist_read_data(7 downto 0);
                            state <= TX_BIN_B1;
                        end if;

                    when TX_BIN_B1 =>
                        if tx_ready = '1' then
                            tx_start <= '1';
                            tx_data <= hist_read_data(15 downto 8);
                            state <= TX_BIN_B2;
                        end if;

                    when TX_BIN_B2 =>
                        if tx_ready = '1' then
                            tx_start <= '1';
                            tx_data <= hist_read_data(23 downto 16);
                            state <= TX_BIN_B3;
                        end if;

                    when TX_BIN_B3 =>
                        if tx_ready = '1' then
                            tx_start <= '1';
                            tx_data <= hist_read_data(31 downto 24);
                            if stream_bin_idx = HIST_BINS - 1 then
                                state <= TX_END_0;
                            else
                                stream_bin_idx <= stream_bin_idx + 1;
                                hist_read_addr <= std_logic_vector(to_unsigned(stream_bin_idx + 1, HIST_ADDR_WIDTH));
                                state <= TX_LOAD_BIN;
                            end if;
                        end if;

                    when TX_END_0 =>
                        if tx_ready = '1' then
                            tx_start <= '1';
                            tx_data <= FRAME_END_0;
                            state <= TX_END_1;
                        end if;

                    when TX_END_1 =>
                        if tx_ready = '1' then
                            tx_start <= '1';
                            tx_data <= FRAME_END_1;
                            led_reg <= "1111";
                            state <= DONE;
                        end if;

                    when DONE =>
                        led_reg <= "1111";
                        if resend_wait_cnt = RESEND_WAIT_CYCLES then
                            resend_wait_cnt <= 0;
                            stream_bin_idx <= 0;
                            hist_read_addr <= (others => '0');
                            state <= TX_SYNC_0;
                        else
                            resend_wait_cnt <= resend_wait_cnt + 1;
                        end if;

                    when others =>
                        state <= DONE;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
