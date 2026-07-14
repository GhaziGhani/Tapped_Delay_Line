--------------------------------------------------------------------------------
-- File: clk_gen.vhd
--
-- Clock buffer wrapper used by the slave top-level.
-- The previous dynamic phase-shifter (DCM + PSEN/PSINCDEC) path was removed.
-- Interface signals are kept for compatibility, but phase outputs are tied low.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity clk_gen is
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
end clk_gen;

architecture Behavioral of clk_gen is
    signal clk_ibufg   : STD_LOGIC;
    signal clk_in_bufg : STD_LOGIC;
begin

    -- Step 1: Input buffer
    U_IBUFG : IBUFG
    port map (
        I => CLK_50_IN,
        O => clk_ibufg
    );

    -- Step 2: Global clock buffer for system clock
    U_BUFG_FIXED : BUFG
    port map (
        I => clk_ibufg,
        O => clk_in_bufg
    );

    -- Phase-shifter logic removed: keep interface stable for existing users.
    -- PSEN/PSINCDEC are intentionally ignored.
    CLK           <= clk_in_bufg;
    CLK_PHASE     <= '0';
    CLK_PHASE_90  <= '0';
    CLK_PHASE_180 <= '0';
    CLK_PHASE_270 <= '0';
    DCM_LOCKED    <= not RST_IN;
    PSDONE        <= '0';

end Behavioral;