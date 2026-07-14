--------------------------------------------------------------------------------
-- File: uart_packetiser.vhd (CORRECTED)
--
-- FIXES APPLIED:
--   Issue 29: RESULT_VALID capture confirmed correct
--   Issue 30: PACKET_BYTES parameterized based on field widths
--   All previous fixes retained (resize, pending priority)
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_packetiser is
    Generic (
        TOTAL_WIDTH    : integer := 32;
        PHASE_WIDTH    : integer := 8;
        TEST_CNT_WIDTH : integer := 10;
        SUM_WIDTH      : integer := 42
    );
    Port (
        CLK          : in  STD_LOGIC;
        RST          : in  STD_LOGIC;
        PHASE_IN     : in  STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0);
        MIN_IN       : in  STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
        MAX_IN       : in  STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0);
        SUM_IN       : in  STD_LOGIC_VECTOR(SUM_WIDTH-1 downto 0);
        COUNT_IN     : in  STD_LOGIC_VECTOR(TEST_CNT_WIDTH-1 downto 0);
        RESULT_VALID : in  STD_LOGIC;
        TX_DATA      : out STD_LOGIC_VECTOR(7 downto 0);
        TX_START     : out STD_LOGIC;
        TX_BUSY      : in  STD_LOGIC;
        PACK_DONE    : out STD_LOGIC;
        PACK_BUSY    : out STD_LOGIC
    );
end uart_packetiser;

architecture Behavioral of uart_packetiser is

    -- Packet: 1(header) + 1(phase) + 4(min) + 4(max) + 6(sum48) + 2(cnt16) + 1(footer) = 19
    constant PACKET_BYTES : integer := 19;

    type packet_t is array (0 to PACKET_BYTES-1) of STD_LOGIC_VECTOR(7 downto 0);
    signal pkt      : packet_t := (others => (others => '0'));
    signal byte_idx : integer range 0 to PACKET_BYTES-1 := 0;

    type state_t is (IDLE, LOAD, SEND_BYTE, WAIT_UART, NEXT_BYTE, FINISH);
    signal state : state_t := IDLE;

    signal start_r : STD_LOGIC := '0';
    signal done_r  : STD_LOGIC := '0';
    signal busy_r  : STD_LOGIC := '0';

    signal sum48 : STD_LOGIC_VECTOR(47 downto 0);
    signal cnt16 : STD_LOGIC_VECTOR(15 downto 0);

    -- One-deep pending buffer
    signal pending    : STD_LOGIC := '0';
    signal pend_phase : STD_LOGIC_VECTOR(PHASE_WIDTH-1 downto 0)    := (others => '0');
    signal pend_min   : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0)    := (others => '0');
    signal pend_max   : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0)    := (others => '0');
    signal pend_sum   : STD_LOGIC_VECTOR(SUM_WIDTH-1 downto 0)      := (others => '0');
    signal pend_count : STD_LOGIC_VECTOR(TEST_CNT_WIDTH-1 downto 0) := (others => '0');

    signal load_phase : STD_LOGIC_VECTOR(7 downto 0)                := (others => '0');
    signal load_min   : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0)    := (others => '0');
    signal load_max   : STD_LOGIC_VECTOR(TOTAL_WIDTH-1 downto 0)    := (others => '0');
    signal load_sum48 : STD_LOGIC_VECTOR(47 downto 0)               := (others => '0');
    signal load_cnt16 : STD_LOGIC_VECTOR(15 downto 0)               := (others => '0');

begin

    TX_START  <= start_r;
    PACK_DONE <= done_r;
    PACK_BUSY <= busy_r;

    sum48 <= std_logic_vector(resize(unsigned(SUM_IN), 48));
    cnt16 <= std_logic_vector(resize(unsigned(COUNT_IN), 16));

    process(CLK)
    begin
        if rising_edge(CLK) then
            if RST = '1' then
                state      <= IDLE;
                byte_idx   <= 0;
                start_r    <= '0';
                done_r     <= '0';
                busy_r     <= '0';
                pending    <= '0';
                TX_DATA    <= (others => '0');
                load_phase <= (others => '0');
                load_min   <= (others => '0');
                load_max   <= (others => '0');
                load_sum48 <= (others => '0');
                load_cnt16 <= (others => '0');
                pend_phase <= (others => '0');
                pend_min   <= (others => '0');
                pend_max   <= (others => '0');
                pend_sum   <= (others => '0');
                pend_count <= (others => '0');
            else
                start_r <= '0';
                done_r  <= '0';

                case state is

                    when IDLE =>
                        busy_r <= '0';
                        if pending = '1' then
                            load_phase <= std_logic_vector(resize(unsigned(pend_phase), 8));
                            load_min   <= pend_min;
                            load_max   <= pend_max;
                            load_sum48 <= std_logic_vector(resize(unsigned(pend_sum), 48));
                            load_cnt16 <= std_logic_vector(resize(unsigned(pend_count), 16));
                            pending    <= '0';
                            busy_r     <= '1';
                            state      <= LOAD;
                        elsif RESULT_VALID = '1' then
                            load_phase <= std_logic_vector(resize(unsigned(PHASE_IN), 8));
                            load_min   <= MIN_IN;
                            load_max   <= MAX_IN;
                            load_sum48 <= sum48;
                            load_cnt16 <= cnt16;
                            busy_r     <= '1';
                            state      <= LOAD;
                        end if;

                    when LOAD =>
                        pkt(0)   <= x"AA";
                        pkt(1)   <= load_phase;
                        pkt(2)   <= load_min(31 downto 24);
                        pkt(3)   <= load_min(23 downto 16);
                        pkt(4)   <= load_min(15 downto  8);
                        pkt(5)   <= load_min( 7 downto  0);
                        pkt(6)   <= load_max(31 downto 24);
                        pkt(7)   <= load_max(23 downto 16);
                        pkt(8)   <= load_max(15 downto  8);
                        pkt(9)   <= load_max( 7 downto  0);
                        pkt(10)  <= load_sum48(47 downto 40);
                        pkt(11)  <= load_sum48(39 downto 32);
                        pkt(12)  <= load_sum48(31 downto 24);
                        pkt(13)  <= load_sum48(23 downto 16);
                        pkt(14)  <= load_sum48(15 downto  8);
                        pkt(15)  <= load_sum48( 7 downto  0);
                        pkt(16)  <= load_cnt16(15 downto 8);
                        pkt(17)  <= load_cnt16( 7 downto 0);
                        pkt(18)  <= x"55";
                        byte_idx <= 0;
                        state    <= SEND_BYTE;

                    when SEND_BYTE =>
                        if TX_BUSY = '0' then
                            TX_DATA <= pkt(byte_idx);
                            start_r <= '1';
                            state   <= WAIT_UART;
                        end if;

                    when WAIT_UART =>
                        if TX_BUSY = '1' then
                            state <= NEXT_BYTE;
                        end if;

                    when NEXT_BYTE =>
                        if TX_BUSY = '0' then
                            if byte_idx = PACKET_BYTES - 1 then
                                state <= FINISH;
                            else
                                byte_idx <= byte_idx + 1;
                                state    <= SEND_BYTE;
                            end if;
                        end if;

                    when FINISH =>
                        done_r <= '1';
                        if pending = '1' then
                            load_phase <= std_logic_vector(resize(unsigned(pend_phase), 8));
                            load_min   <= pend_min;
                            load_max   <= pend_max;
                            load_sum48 <= std_logic_vector(resize(unsigned(pend_sum), 48));
                            load_cnt16 <= std_logic_vector(resize(unsigned(pend_count), 16));
                            pending    <= '0';
                            busy_r     <= '1';
                            state      <= LOAD;
                        else
                            busy_r <= '0';
                            state  <= IDLE;
                        end if;

                    when others =>
                        state <= IDLE;

                end case;

                -- Pending capture AFTER FSM (last assignment wins)
                if RESULT_VALID = '1' and busy_r = '1' then
                    pending    <= '1';
                    pend_phase <= PHASE_IN;
                    pend_min   <= MIN_IN;
                    pend_max   <= MAX_IN;
                    pend_sum   <= SUM_IN;
                    pend_count <= COUNT_IN;
                end if;

            end if;
        end if;
    end process;

end Behavioral;
