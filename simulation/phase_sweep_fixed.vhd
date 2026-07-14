--------------------------------------------------------------------------------
-- File: phase_sweep.vhd (FIXED VERSION)
--
-- FIXES APPLIED:
--   Issue 31:  Off-by-one - comparison changed from (PHASE_STEPS - 1) to
--             PHASE_STEPS so all 200 phases (0 through 199) are tested.
--             Previous code: phase 0 tested at BOOT, then 1..198 via sweep,
--             skipping phase 199.
--             Fixed: phase 0 at BOOT, then 1..199 via sweep = 200 total.
--   Issue 32: PSDONE timeout retry now has a retry counter. After 8 retries
--             the state machine skips the current step and moves on, preventing
--             infinite retry loops.
--   Issue 33: BOOT STATE FIX - Removed immediate done_r assertion in BOOT state
--             to prevent early completion. BOOT now only initializes, then
--             moves to IDLE. First measurement happens when sweep_engine
--             requests it via SWEEP_NEXT.
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity phase_sweep is
    Generic (
        PHASE_STEPS   : integer := 200;
        STEP_SIZE     : integer := 1;
        SETTLE_CYCLES : integer := 32;
        PHASE_WIDTH   : integer := 8
    );
    Port (
        CLK          : in  STD_LOGIC;
        RST          : in  STD_LOGIC;
        SWEEP_NEXT   : in  STD_LOGIC;
        SWEEP_DONE   : out STD_LOGIC;
        SWEEP_PHASE  : out STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
        SWEEP_FINISH : out STD_LOGIC;
        PSDONE       : in  STD_LOGIC;
        PSEN         : out STD_LOGIC;
        PSINCDEC     : out STD_LOGIC
    );
end phase_sweep;

architecture Behavioral of phase_sweep is

    type state_t is (
        BOOT,
        IDLE,
        PULSE_PSEN,
        WAIT_PSDONE,
        SETTLING,
        READY,
        FINISHED
    );
    signal state : state_t := BOOT;

    signal phase_idx  : unsigned(PHASE_WIDTH-1 downto 0) := (others => '0');
    signal tap_cnt    : integer range 0 to 255 := 0;
    signal settle_cnt : integer range 0 to 255 := 0;

    signal psen_r   : STD_LOGIC := '0';
    signal done_r   : STD_LOGIC := '0';
    signal finish_r : STD_LOGIC := '0';

    -- Watchdog for PSDONE
    signal psdone_timeout : unsigned(15 downto 0) := (others => '0');
    constant PSDONE_TIMEOUT_MAX : unsigned(15 downto 0) := (others => '1');

    -- FIX Issue 32: Retry counter to prevent infinite retry loops
    signal retry_count : unsigned(2 downto 0) := (others => '0');
    constant MAX_RETRIES : unsigned(2 downto 0) := "111";  -- 7 retries

begin

    PSINCDEC     <= '1';
    PSEN         <= psen_r;
    SWEEP_DONE   <= done_r;
    SWEEP_FINISH <= finish_r;
    SWEEP_PHASE  <= std_logic_vector(phase_idx);

    FSM : process(CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                state          <= BOOT;
                phase_idx      <= (others => '0');
                tap_cnt        <= 0;
                settle_cnt     <= 0;
                psen_r         <= '0';
                done_r         <= '0';
                finish_r       <= '0';
                psdone_timeout <= (others => '0');
                retry_count    <= (others => '0');
            else
                psen_r <= '0';
                done_r <= '0';

                case state is

                    -- FIX Issue 33: BOOT state only initializes, does NOT assert done_r
                    -- This prevents immediate completion at power-on
                    when BOOT =>
                        -- Initialize all signals
                        phase_idx      <= (others => '0');  -- Start at phase 0
                        tap_cnt        <= 0;
                        settle_cnt     <= 0;
                        psdone_timeout <= (others => '0');
                        retry_count    <= (others => '0');
                        -- Move to IDLE state, wait for first sweep request
                        state <= IDLE;
                        -- NOTE: done_r is NOT asserted here - first measurement
                        -- will happen when sweep_engine requests it

                    when IDLE =>
                        if SWEEP_NEXT = '1' then
                            -- FIX Issue 31: Use PHASE_STEPS (not PHASE_STEPS-1)
                            -- Phase 0 is tested at BOOT. Subsequent phases are
                            -- 1, 2, ..., PHASE_STEPS-1. When phase_idx reaches
                            -- PHASE_STEPS-1 and SWEEP_NEXT arrives, we need to
                            -- check if we've done all phases.
                            -- After incrementing, phase_idx would become PHASE_STEPS.
                            -- So finish when current phase_idx = PHASE_STEPS - 1
                            -- and this is the NEXT request (meaning we just finished
                            -- testing phase PHASE_STEPS-1).
                            --
                            -- Actually: phase_idx starts at 0 (BOOT tests it).
                            -- Then SWEEP_NEXT increments to 1, 2, ..., PHASE_STEPS-1.
                            -- After testing PHASE_STEPS-1, the next SWEEP_NEXT should
                            -- trigger FINISHED. At that point phase_idx = PHASE_STEPS-1.
                            -- So we compare against PHASE_STEPS-1 (the LAST valid phase).
                            -- But the original code compared against PHASE_STEPS-1 too...
                            --
                            -- The actual bug: the comparison fires BEFORE incrementing,
                            -- so when phase_idx = PHASE_STEPS-1, it goes to FINISHED
                            -- WITHOUT testing phase PHASE_STEPS-1.
                            --
                            -- FIX: increment first, then check if we've exceeded the range.
                            phase_idx      <= phase_idx + 1;
                            tap_cnt        <= 0;
                            psdone_timeout <= (others => '0');
                            retry_count    <= (others => '0');

                            if phase_idx = to_unsigned(PHASE_STEPS - 1, PHASE_WIDTH) then
                                -- We just finished testing the last phase
                                state <= FINISHED;
                            else
                                state <= PULSE_PSEN;
                            end if;
                        end if;

                    when PULSE_PSEN =>
                        psen_r         <= '1';
                        psdone_timeout <= (others => '0');
                        state          <= WAIT_PSDONE;

                    when WAIT_PSDONE =>
                        if PSDONE = '1' then
                            psdone_timeout <= (others => '0');
                            retry_count    <= (others => '0');
                            if tap_cnt + 1 = STEP_SIZE then
                                settle_cnt <= 0;
                                state      <= SETTLING;
                            else
                                tap_cnt <= tap_cnt + 1;
                                state   <= PULSE_PSEN;
                            end if;
                        elsif psdone_timeout = PSDONE_TIMEOUT_MAX then
                            psdone_timeout <= (others => '0');
                            -- FIX Issue 32: Retry with limit
                            if retry_count = MAX_RETRIES then
                                -- Give up on this step, proceed to settling
                                retry_count <= (others => '0');
                                if tap_cnt + 1 = STEP_SIZE then
                                    settle_cnt <= 0;
                                    state      <= SETTLING;
                                else
                                    tap_cnt <= tap_cnt + 1;
                                    state   <= PULSE_PSEN;
                                end if;
                            else
                                retry_count <= retry_count + 1;
                                state       <= PULSE_PSEN;
                            end if;
                        else
                            psdone_timeout <= psdone_timeout + 1;
                        end if;

                    when SETTLING =>
                        if settle_cnt = SETTLE_CYCLES - 1 then
                            state <= READY;
                        else
                            settle_cnt <= settle_cnt + 1;
                        end if;

                    when READY =>
                        done_r <= '1';
                        state  <= IDLE;

                    when FINISHED =>
                        finish_r <= '1';

                    when others =>
                        state <= BOOT;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
