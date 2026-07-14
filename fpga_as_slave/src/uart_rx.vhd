library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_rx is
    Generic (
        CLK_FREQ : integer := 50_000_000;
        BAUD     : integer := 115_200
    );
    Port (
        clk      : in  STD_LOGIC;
        reset    : in  STD_LOGIC;
        rx       : in  STD_LOGIC;
        data     : out STD_LOGIC_VECTOR (7 downto 0);
        valid    : out STD_LOGIC
    );
end uart_rx;

architecture Behavioral of uart_rx is
    constant CLKS_PER_BIT : integer := CLK_FREQ / BAUD;
    
    type state_type is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal state : state_type := IDLE;
    
    signal clk_cnt  : integer range 0 to CLKS_PER_BIT-1 := 0;
    signal bit_cnt  : integer range 0 to 7 := 0;
    signal rx_reg   : std_logic_vector(7 downto 0) := (others => '0');
    signal rx_sync  : std_logic_vector(1 downto 0) := "11";
begin

    -- CDC for RX pin
    process(clk)
    begin
        if rising_edge(clk) then
            rx_sync <= rx_sync(0) & rx;
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state <= IDLE;
                valid <= '0';
                clk_cnt <= 0;
                bit_cnt <= 0;
            else
                valid <= '0'; -- Default clear valid
                
                case state is
                    when IDLE =>
                        clk_cnt <= 0;
                        bit_cnt <= 0;
                        if rx_sync(1) = '0' then -- Falling edge (start bit)
                            state <= START_BIT;
                        end if;
                        
                    when START_BIT =>
                        if clk_cnt = (CLKS_PER_BIT - 1) / 2 then
                            if rx_sync(1) = '0' then
                                clk_cnt <= 0;
                                state <= DATA_BITS;
                            else
                                state <= IDLE;
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;
                        
                    when DATA_BITS =>
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            rx_reg(bit_cnt) <= rx_sync(1);
                            if bit_cnt = 7 then
                                state <= STOP_BIT;
                            else
                                bit_cnt <= bit_cnt + 1;
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;
                        
                    when STOP_BIT =>
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            valid <= '1';
                            data <= rx_reg;
                            state <= IDLE;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;
                        
                end case;
            end if;
        end if;
    end process;

end Behavioral;
