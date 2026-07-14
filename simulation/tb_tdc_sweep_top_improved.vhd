library ieee;
use ieee.std_logic_1164.all;
use std.env.all;

entity tb_tdc_sweep_top_improved is
end entity;

architecture sim of tb_tdc_sweep_top_improved is
  signal clk_in   : std_logic := '0';
  signal rst_in   : std_logic := '1';  -- Start with reset active
  signal tx_out   : std_logic;
  signal locked   : std_logic;
  signal all_done : std_logic;
  
  -- Simulation control
  constant CLK_PERIOD : time := 20 ns;  -- 50 MHz clock
  constant SIM_TIMEOUT : time := 50 ms;  -- Extended timeout
  constant RESET_PULSE : time := 100 ns; -- Reset pulse width
  
  -- UART monitoring
  type uart_state_type is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
  signal uart_state : uart_state_type := IDLE;
  signal uart_bit_count : integer range 0 to 7 := 0;
  signal uart_data_reg : std_logic_vector(7 downto 0) := (others => '0');
  signal uart_byte_count : integer := 0;
  
  -- Debug counters
  signal cycle_count : integer := 0;
  signal locked_count : integer := 0;
  
begin
  -- Clock generation
  clk_in <= not clk_in after CLK_PERIOD/2;
  
  -- Cycle counter
  process(clk_in)
  begin
    if rising_edge(clk_in) then
      if rst_in = '0' then
        cycle_count <= cycle_count + 1;
      else
        cycle_count <= 0;
      end if;
    end if;
  end process;
  
  -- PLL lock monitoring
  process(clk_in)
  begin
    if rising_edge(clk_in) then
      if locked = '1' then
        locked_count <= locked_count + 1;
      end if;
    end if;
  end process;
  
  -- UART receiver for monitoring TX output
  process(clk_in)
    variable bit_timer : integer := 0;
    constant BIT_PERIODS : integer := 434;  -- 50MHz / 115200 baud
  begin
    if rising_edge(clk_in) then
      if rst_in = '0' then
        case uart_state is
          when IDLE =>
            if tx_out = '0' then  -- Start bit detected
              uart_state <= START_BIT;
              bit_timer := BIT_PERIODS / 2;  -- Sample in middle of bit
              uart_bit_count <= 0;
              uart_data_reg <= (others => '0');
            end if;
            
          when START_BIT =>
            if bit_timer > 0 then
              bit_timer := bit_timer - 1;
            else
              if tx_out = '0' then  -- Verify start bit
                uart_state <= DATA_BITS;
                bit_timer := BIT_PERIODS;
              else
                uart_state <= IDLE;  -- False start
              end if;
            end if;
            
          when DATA_BITS =>
            if bit_timer > 0 then
              bit_timer := bit_timer - 1;
            else
              uart_data_reg <= tx_out & uart_data_reg(7 downto 1);
              if uart_bit_count = 7 then
                uart_state <= STOP_BIT;
                bit_timer := BIT_PERIODS;
              else
                uart_bit_count <= uart_bit_count + 1;
                bit_timer := BIT_PERIODS;
              end if;
            end if;
            
          when STOP_BIT =>
            if bit_timer > 0 then
              bit_timer := bit_timer - 1;
            else
              if tx_out = '1' then  -- Stop bit detected
                uart_byte_count <= uart_byte_count + 1;
                report "UART Byte received: 0x" & to_hstring(uart_data_reg) & 
                       " ('" & to_character(character'val(to_integer(unsigned(uart_data_reg)))) & "') at " & 
                       time'image(now) severity note;
              end if;
              uart_state <= IDLE;
            end if;
        end case;
      else
        uart_state <= IDLE;
        uart_bit_count <= 0;
        uart_data_reg <= (others => '0');
      end if;
    end if;
  end process;
  
  -- DUT instantiation
  uut : entity work.tdc_sweep_top
    generic map(
      CLK_FREQ        => 50_000_000,
      BAUD            => 115_200,
      TAPS            => 240,
      TAPS_PER_CNT    => 240,
      COARSE_WIDTH    => 16,
      FINE_WIDTH      => 10,
      TOTAL_WIDTH     => 32,
      PHASE_STEPS     => 200,
      STEP_SIZE       => 1,
      SETTLE_CYCLES   => 2,
      PHASE_WIDTH     => 8,
      TESTS_PER_PHASE => 4,
      STOP_DELAY      => 2,
      INTER_TEST_GAP  => 8,
      TEST_CNT_WIDTH  => 3,
      SUM_WIDTH       => 24
    )
    port map
    (
      CLK_IN   => clk_in,
      RST_IN   => rst_in,
      TX_OUT   => tx_out,
      LOCKED   => locked,
      ALL_DONE => all_done
    );

  -- Improved stimulus process
  stimulus : process
  begin
    report "=== Starting Improved TDC Simulation ===" severity note;
    report "Clock period: " & time'image(CLK_PERIOD) severity note;
    report "Simulation timeout: " & time'image(SIM_TIMEOUT) severity note;
    
    -- Start with system in reset
    rst_in <= '1';
    wait for RESET_PULSE;
    
    -- Release reset and wait for PLL to lock
    report "Releasing reset..." severity note;
    rst_in <= '0';
    
    -- Wait for PLL lock with timeout
    wait until locked = '1' for 1 us;
    if locked = '1' then
      report "PLL locked at " & time'image(now) severity note;
    else
      report "PLL failed to lock within 1us" severity error;
    end if;
    
    -- Monitor for early completion (this should NOT happen)
    wait for 1 us;
    if all_done = '1' then
      report "ERROR: ALL_DONE asserted too early at " & time'image(now) severity error;
    end if;
    
    -- Wait for normal completion or timeout
    report "Waiting for TDC sweep completion..." severity note;
    wait until all_done = '1' for SIM_TIMEOUT;
    
    if all_done = '1' then
      report "TDC sweep completed at " & time'image(now) severity note;
      report "Total cycles: " & integer'image(cycle_count) severity note;
      report "UART bytes received: " & integer'image(uart_byte_count) severity note;
      report "PLL locked cycles: " & integer'image(locked_count) severity note;
    else
      report "TDC sweep timed out after " & time'image(SIM_TIMEOUT) severity warning;
    end if;
    
    -- Allow some time for final UART transmission
    wait for 100 us;
    
    -- Final status report
    report "=== Simulation Summary ===" severity note;
    report "Final ALL_DONE: " & std_logic'image(all_done) severity note;
    report "Final LOCKED: " & std_logic'image(locked) severity note;
    report "Total simulation time: " & time'image(now) severity note;
    report "Total clock cycles: " & integer'image(cycle_count) severity note;
    report "UART bytes transmitted: " & integer'image(uart_byte_count) severity note;
    
    if uart_byte_count = 0 then
      report "WARNING: No UART data detected - possible measurement issue" severity warning;
    end if;
    
    if all_done = '1' and uart_byte_count > 0 then
      report "SUCCESS: TDC simulation completed with data output" severity note;
    else
      report "FAILURE: TDC simulation did not complete properly" severity error;
    end if;
    
    wait for 1 us;
    stop;
    wait;
  end process;
  
  -- Debug monitoring process
  debug_monitor : process
    variable last_all_done : std_logic := '0';
    variable last_locked : std_logic := '0';
  begin
    wait until clk_in'event and clk_in = '1';
    
    -- Monitor ALL_DONE changes
    if all_done /= last_all_done then
      if all_done = '1' then
        report "ALL_DONE asserted at cycle " & integer'image(cycle_count) & 
               " (" & time'image(now) & ")" severity note;
      else
        report "ALL_DONE deasserted at cycle " & integer'image(cycle_count) & 
               " (" & time'image(now) & ")" severity note;
      end if;
      last_all_done := all_done;
    end if;
    
    -- Monitor LOCKED changes
    if locked /= last_locked then
      if locked = '1' then
        report "PLL locked at cycle " & integer'image(cycle_count) & 
               " (" & time'image(now) & ")" severity note;
      else
        report "PLL unlocked at cycle " & integer'image(cycle_count) & 
               " (" & time'image(now) & ")" severity warning;
      end if;
      last_locked := locked;
    end if;
  end process;
  
end architecture;
