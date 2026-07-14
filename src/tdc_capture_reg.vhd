-- File: tdc_capture_reg.vhd (CORRECTED)
--
-- No functional changes needed. Single authoritative copy.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity tdc_capture_reg is
    Generic (
        WIDTH : integer := 240
    );
    Port (
        CLK     : in  STD_LOGIC;
        CLR     : in  STD_LOGIC;
        DIN     : in  STD_LOGIC_VECTOR(WIDTH-1 downto 0);
        DOUT    : out STD_LOGIC_VECTOR(WIDTH-1 downto 0);
        ANY_HIT : out STD_LOGIC
    );
end tdc_capture_reg;

architecture Behavioral of tdc_capture_reg is
    signal data_reg   : STD_LOGIC_VECTOR(WIDTH-1 downto 0) := (others => '0');
    signal detect_reg : STD_LOGIC := '0';

    attribute KEEP : string;
    attribute KEEP of data_reg   : signal is "TRUE";
    attribute KEEP of detect_reg : signal is "TRUE";
begin
    process(CLK)
        variable or_reduce : STD_LOGIC;
    begin
        if rising_edge(CLK) then
            if CLR = '1' then
                data_reg   <= (others => '0');
                detect_reg <= '0';
            else
                data_reg <= DIN;

                or_reduce := '0';
                for i in 0 to WIDTH-1 loop
                    or_reduce := or_reduce or DIN(i);
                end loop;
                detect_reg <= or_reduce;
            end if;
        end if;
    end process;

    DOUT    <= data_reg;
    ANY_HIT <= detect_reg;
end Behavioral;
