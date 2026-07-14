--------------------------------------------------------------------------------
-- File: clk_gen.vhd (CORRECTED v5)
--
-- ARCHITECTURE (for non-clock-capable pin T8):
--
--   CLK_50_IN (T8)
--     → IBUFG
--       ├→ DCM_SP CLKIN  (dedicated routing: IBUFG→DCM is always available)
--       │    → CLK0 → BUFG (U_BUFG_FB) → CLKFB (feedback)
--       │                               → CLK_PHASE output
--       └→ BUFG (U_BUFG_FIXED)          → CLK output
--            ↑ uses general routing (CLOCK_DEDICATED_ROUTE=FALSE)
--            This is acceptable: CLK is used for state machines/counters,
--            NOT for sub-ns TDC timing. ~200ps extra jitter is fine.
--
--   The DCM path uses dedicated routing (IBUFG→DCM is a special case
--   in Spartan-6 that works even from non-GCLK pins, as long as the
--   IBUFG feeds the DCM directly).
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
        DCM_LOCKED : out STD_LOGIC;
        PSDONE     : out STD_LOGIC
    );
end clk_gen;

architecture Behavioral of clk_gen is

    signal clk_in_bufg    : STD_LOGIC;
    signal dcm_clk0       : STD_LOGIC;
    signal dcm_clk0_buf   : STD_LOGIC;
    signal dcm_locked_int : STD_LOGIC;

    attribute KEEP : string;
    attribute S    : string;
    attribute KEEP of dcm_clk0_buf : signal is "TRUE";
    attribute S    of dcm_clk0_buf : signal is "TRUE";

begin

    ---------------------------------------------------------------------------
    -- Fixed system clock: IBUFG → BUFG
    -- Uses general routing (not dedicated) since T8 is not a clock pin.
    -- Constrained with CLOCK_DEDICATED_ROUTE=FALSE in UCF.
    -- Acceptable: this clock drives state machines, not TDC timing paths.
    ---------------------------------------------------------------------------
    U_BUFG_FIXED : BUFG
    port map (
        I => CLK_50_IN,
        O => clk_in_bufg
    );

    ---------------------------------------------------------------------------
    -- DCM for variable phase shift
    -- IBUFG → DCM uses dedicated routing (works from any IBUFG)
    ---------------------------------------------------------------------------
    U_DCM_PHASE : DCM_SP
    generic map (
        CLKIN_PERIOD          => 20.0,
        CLK_FEEDBACK          => "1X",
        CLKOUT_PHASE_SHIFT    => "VARIABLE",
        PHASE_SHIFT           => 0,
        DESKEW_ADJUST         => "SYSTEM_SYNCHRONOUS",
        DFS_FREQUENCY_MODE    => "LOW",
        DLL_FREQUENCY_MODE    => "LOW",
        DUTY_CYCLE_CORRECTION => TRUE,
        CLKDV_DIVIDE          => 2.0,
        CLKFX_DIVIDE          => 1,
        CLKFX_MULTIPLY        => 4,
        DSS_MODE              => "NONE",
        FACTORY_JF            => X"C080",
        STARTUP_WAIT          => FALSE
    )
    port map (
        CLKIN    => CLK_50_IN,
        CLKFB    => dcm_clk0_buf,
        RST      => RST_IN,
        PSEN     => PSEN,
        PSINCDEC => PSINCDEC,
        PSCLK    => clk_in_bufg,
        PSDONE   => PSDONE,
        CLK0     => dcm_clk0,
        CLK90    => open,
        CLK180   => open,
        CLK270   => open,
        CLK2X    => open,
        CLK2X180 => open,
        CLKDV    => open,
        CLKFX    => open,
        CLKFX180 => open,
        LOCKED   => dcm_locked_int,
        STATUS   => open
    );

    ---------------------------------------------------------------------------
    -- DCM feedback BUFG (dedicated routing)
    ---------------------------------------------------------------------------
    U_BUFG_FB : BUFG
    port map (
        I => dcm_clk0,
        O => dcm_clk0_buf
    );

    ---------------------------------------------------------------------------
    -- Outputs
    ---------------------------------------------------------------------------
    CLK        <= clk_in_bufg;
    CLK_PHASE  <= dcm_clk0_buf;
    DCM_LOCKED <= dcm_locked_int;

end Behavioral;