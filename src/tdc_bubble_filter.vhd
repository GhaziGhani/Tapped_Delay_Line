-- File: tdc_bubble_filter.vhd (CORRECTED)
--
-- FIXES APPLIED:
--   Issue 33: Boundary condition at i=WIDTH-1 already fixed — right='0'
--             (pulse propagates upward from index 0; beyond last tap = '0')
--             No additional changes needed.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity tdc_bubble_filter is
    Generic (
        WIDTH : integer := 240
    );
    Port (
        CLK  : in  STD_LOGIC;
        CLR  : in  STD_LOGIC;
        DIN  : in  STD_LOGIC_VECTOR(WIDTH-1 downto 0);
        DOUT : out STD_LOGIC_VECTOR(WIDTH-1 downto 0)
    );
end tdc_bubble_filter;

architecture Behavioral of tdc_bubble_filter is
    signal filtered : STD_LOGIC_VECTOR(WIDTH-1 downto 0) := (others => '0');
begin
    process(CLK)
        variable left   : STD_LOGIC;
        variable center : STD_LOGIC;
        variable right  : STD_LOGIC;
    begin
        if rising_edge(CLK) then
            if CLR = '1' then
                filtered <= (others => '0');
            else
                for i in 0 to WIDTH-1 loop
                    if i = 0 then
                        left := '0';
                    else
                        left := DIN(i-1);
                    end if;

                    center := DIN(i);

                    if i = WIDTH-1 then
                        right := '0';    -- Beyond chain = no pulse
                    else
                        right := DIN(i+1);
                    end if;

                    -- Majority vote: 2-of-3
                    filtered(i) <= (left and center)
                                or (center and right)
                                or (left and right);
                end loop;
            end if;
        end if;
    end process;

    DOUT <= filtered;
end Behavioral;
