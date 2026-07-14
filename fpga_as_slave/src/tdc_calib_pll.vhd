--------------------------------------------------------------------------------
-- File: tdc_calib_pll.vhd
--
-- Internal calibration clock source for startup histogram acquisition.
-- This version uses DCM clock generation (not ring oscillator). The LOCKED
-- signal is intentionally not used for control; calibration runs free.
--
-- Strategy:
-- 1) Use CLKFX with a slight ratio offset (32/31) to keep calibration clock
--    asynchronous relative to SYS clock.
-- 2) Apply a small fixed phase shift for fine skew margin.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

library UNISIM;
use UNISIM.VComponents.all;

entity tdc_calib_pll is
    Port (
        CLK_IN     : in  STD_LOGIC;
        RST_IN     : in  STD_LOGIC;
        CLK_CAL    : out STD_LOGIC;
        LOCKED_OUT : out STD_LOGIC
    );
end tdc_calib_pll;

architecture Behavioral of tdc_calib_pll is
    -- 50 MHz * (6/5) = 60 MHz (non-integer-related to 50 MHz)
    constant CAL_CLK_MULTIPLY : integer := 6;
    constant CAL_CLK_DIVIDE   : integer := 5;
    constant CAL_PHASE_SHIFT  : integer := 8;

    signal dcm_clk0_raw   : STD_LOGIC;
    signal dcm_clk0_buf   : STD_LOGIC;
    signal dcm_clkfx_raw  : STD_LOGIC;
begin

    -- CLK_IN is expected to be already buffered at top level.

    U_DCM_CAL : DCM_SP
    generic map (
        CLKIN_PERIOD          => 20.0,
        CLK_FEEDBACK          => "1X",
        CLKOUT_PHASE_SHIFT    => "FIXED",
        PHASE_SHIFT           => CAL_PHASE_SHIFT,
        DESKEW_ADJUST         => "SYSTEM_SYNCHRONOUS",
        DFS_FREQUENCY_MODE    => "LOW",
        DLL_FREQUENCY_MODE    => "LOW",
        DUTY_CYCLE_CORRECTION => TRUE,
        CLKDV_DIVIDE          => 2.0,
        CLKFX_DIVIDE          => CAL_CLK_DIVIDE,
        CLKFX_MULTIPLY        => CAL_CLK_MULTIPLY,
        DSS_MODE              => "NONE",
        FACTORY_JF            => X"C080",
        STARTUP_WAIT          => FALSE
    )
    port map (
        CLKIN    => CLK_IN,
        CLKFB    => dcm_clk0_buf,
        RST      => RST_IN,
        PSEN     => '0',
        PSINCDEC => '0',
        PSCLK    => '0',
        PSDONE   => open,
        CLK0     => dcm_clk0_raw,
        CLK90    => open,
        CLK180   => open,
        CLK270   => open,
        CLK2X    => open,
        CLK2X180 => open,
        CLKDV    => open,
        CLKFX    => dcm_clkfx_raw,
        CLKFX180 => open,
        LOCKED   => open,
        STATUS   => open
    );

    U_BUFG_FB : BUFG
    port map (
        I => dcm_clk0_raw,
        O => dcm_clk0_buf
    );

    -- Calibration source is used as async pulse/data (not a global clock tree
    -- clock), so avoid BUFG here to prevent non-clock BUFG load violations.
    CLK_CAL    <= dcm_clkfx_raw;
    LOCKED_OUT <= '0';

end Behavioral;
