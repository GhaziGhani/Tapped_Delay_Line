-- File: tdc_hold_reg.vhd (UNCHANGED)
--
-- No bugs found. Freeze-on-first-hit behavior is correct.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity tdc_hold_reg is
    Generic (
        WIDTH : integer := 240
    );
    Port (
        CLK    : in  STD_LOGIC;
        CLR    : in  STD_LOGIC;
        DIN    : in  STD_LOGIC_VECTOR(WIDTH-1 downto 0);
        HIT_IN : in  STD_LOGIC;
        DOUT   : out STD_LOGIC_VECTOR(WIDTH-1 downto 0)
    );
end tdc_hold_reg;

architecture Behavioral of tdc_hold_reg is
    signal held_reg : STD_LOGIC_VECTOR(WIDTH-1 downto 0) := (others => '0');
    signal captured : STD_LOGIC := '0';

    attribute KEEP : string;
    attribute KEEP of held_reg : signal is "TRUE";
    attribute KEEP of captured : signal is "TRUE";
begin
    process(CLK)
    begin
        if rising_edge(CLK) then
            if CLR = '1' then
                held_reg <= (others => '0');
                captured <= '0';
            else
                if captured = '0' and HIT_IN = '1' then
                    held_reg <= DIN;
                    captured <= '1';
                end if;
            end if;
        end if;
    end process;

    DOUT <= held_reg;
end Behavioral;
