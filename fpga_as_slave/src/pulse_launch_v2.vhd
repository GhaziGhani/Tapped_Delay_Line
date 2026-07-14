--------------------------------------------------------------------------------
-- File: pulse_launch_v2.vhd (CORRECTED v2)
--
-- FIXES APPLIED:
--   Issue G:  ???? CRITICAL ??? start_sync_2 was used as level enable for
--             phase_toggle. If the CDC synchronizer stretched the pulse
--             to 2 CLK_PHASE cycles, phase_toggle would flip twice,
--             producing two spikes and corrupting the measurement.
--             FIX: Added rising-edge detector (start_sync_2_d + start_edge).
--   Issue E:  RST async to CLK_PHASE ??? uses async reset (self-correcting)
--   Issue 11: CDC fixed offset documented
--   Issue 13: LUT delay chain needs post-PAR verification
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity pulse_launch_v2 is
    Port (
        CLK_SYS      : in  STD_LOGIC;
        CLK_PHASE    : in  STD_LOGIC;
        RST          : in  STD_LOGIC;
        START_ENABLE : in  STD_LOGIC;

        PULSE_SPIKE  : out STD_LOGIC;
        LAUNCH_DONE  : out STD_LOGIC
    );
end pulse_launch_v2;

architecture Behavioral of pulse_launch_v2 is

    ---------------------------------------------------------------------------
    -- CDC: START_ENABLE (CLK_SYS domain) -> CLK_PHASE domain
    ---------------------------------------------------------------------------
    signal start_sync_1 : STD_LOGIC := '0';
    signal start_sync_2 : STD_LOGIC := '0';
    signal start_sync_3 : STD_LOGIC := '0';

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of start_sync_1 : signal is "TRUE";
    attribute ASYNC_REG of start_sync_2 : signal is "TRUE";
    attribute ASYNC_REG of start_sync_3 : signal is "TRUE";

    ---------------------------------------------------------------------------
    -- FIX Issue G: Rising edge detector for start_sync_2
    --   start_sync_3_d is a one-cycle delayed copy of start_sync_3
    --   start_edge fires for exactly one CLK_PHASE cycle on the rising
    --   edge of start_sync_3, regardless of how many cycles start_sync_3
    --   stays high. This prevents double-toggle of phase_toggle.
    ---------------------------------------------------------------------------
    signal start_sync_3_d : STD_LOGIC := '0';
    signal start_edge     : STD_LOGIC;

    ---------------------------------------------------------------------------
    -- Phase domain
    ---------------------------------------------------------------------------
    signal phase_toggle      : STD_LOGIC := '0';

    ---------------------------------------------------------------------------
    -- ASYNC timing path signals
    ---------------------------------------------------------------------------
    signal toggle_edge_raw : STD_LOGIC;

    attribute KEEP : string;
    attribute KEEP of toggle_edge_raw : signal is "TRUE";
    attribute BUFFER_TYPE : string;
    attribute BUFFER_TYPE of toggle_edge_raw : signal is "NONE";

    ---------------------------------------------------------------------------
    -- SYNC control path (CDC back to CLK_SYS)
    ---------------------------------------------------------------------------
    signal sync_s1, sync_s2, sync_s3 : STD_LOGIC := '0';
    signal sync_prev : STD_LOGIC := '0';

    attribute ASYNC_REG of sync_s1 : signal is "TRUE";
    attribute ASYNC_REG of sync_s2 : signal is "TRUE";
    attribute ASYNC_REG of sync_s3 : signal is "TRUE";

begin

    ---------------------------------------------------------------------------
    -- CDC synchronizer for START_ENABLE into CLK_PHASE domain
    -- Plus edge detector (Issue G fix)
    ---------------------------------------------------------------------------
    CDC_START : process(CLK_PHASE, RST)
    begin
        if RST = '1' then
            start_sync_1   <= '0';
            start_sync_2   <= '0';
            start_sync_3   <= '0';
            start_sync_3_d <= '0';
        elsif rising_edge(CLK_PHASE) then
            start_sync_1   <= START_ENABLE;
            start_sync_2   <= start_sync_1;
            start_sync_3   <= start_sync_2;
            start_sync_3_d <= start_sync_3;
        end if;
    end process;

    -- FIX Issue G: Edge detect ??? fires exactly once per START_ENABLE pulse
    start_edge <= start_sync_3 and not start_sync_3_d;

    ---------------------------------------------------------------------------
    -- Phase domain toggle ??? uses EDGE detect, not level
    ---------------------------------------------------------------------------
    PHASE_FF : process(CLK_PHASE, RST)
    begin
        if RST = '1' then
            phase_toggle <= '0';
        elsif rising_edge(CLK_PHASE) then
            if start_edge = '1' then
                phase_toggle <= not phase_toggle;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Pulse window generation
    --
    -- phase_toggle flips at the async phase event. sync_s1 is the next
    -- CLK_SYS-sampled copy of phase_toggle. Their XOR stays high from the
    -- event until the next CLK_SYS rising edge, so the falling edge of
    -- PULSE_SPIKE occurs on that CLK_SYS edge.
    ---------------------------------------------------------------------------
    toggle_edge_raw <= phase_toggle xor sync_s1;
    PULSE_SPIKE <= toggle_edge_raw;

    ---------------------------------------------------------------------------
    -- CONTROL PATH: CDC synchronizer back to CLK_SYS (for coordination only)
    ---------------------------------------------------------------------------
    CDC_CTRL : process(CLK_SYS, RST)
    begin
        if RST = '1' then
            sync_s1   <= '0';
            sync_s2   <= '0';
            sync_s3   <= '0';
            sync_prev <= '0';
        elsif rising_edge(CLK_SYS) then
            sync_s1   <= phase_toggle;
            sync_s2   <= sync_s1;
            sync_s3   <= sync_s2;
            sync_prev <= sync_s3;
        end if;
    end process;

    LAUNCH_DONE <= sync_s3 xor sync_prev;

end Behavioral;
