library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity tdc_ringosc is
    generic (
        g_LENGTH : positive := 15
    );
    port (
        en_i  : in  std_logic;
        clk_o : out std_logic
    );
end entity;

architecture rtl of tdc_ringosc is
    component LUT1
        generic (
            INIT : bit_vector := X"0"
        );
        port (
            O  : out std_logic;
            I0 : in  std_logic
        );
    end component;

    component LUT2
        generic (
            INIT : bit_vector := X"0"
        );
        port (
            O  : out std_logic;
            I0 : in  std_logic;
            I1 : in  std_logic
        );
    end component;

    signal s : std_logic_vector(g_LENGTH downto 0);
    attribute KEEP : string;
    attribute KEEP of s : signal is "TRUE";
begin
    g_luts : for i in 0 to g_LENGTH - 1 generate
        g_firstlut : if i = 0 generate
            cmp_LUT : LUT2
            generic map (
                INIT => "0100"
            )
            port map (
                I0 => s(i),
                I1 => en_i,
                O  => s(i + 1)
            );
        end generate;

        g_nextlut : if i > 0 generate
            cmp_LUT : LUT1
            generic map (
                INIT => "01"
            )
            port map (
                I0 => s(i),
                O  => s(i + 1)
            );
        end generate;
    end generate;

    s(0) <= s(g_LENGTH);
    clk_o <= s(g_LENGTH);
end architecture;
