library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity led_on is
    Port (
        LED : out STD_LOGIC
    );
end led_on;

architecture Behavioral of led_on is
begin
    LED <= '1';  -- Turn LED ON
end Behavioral;