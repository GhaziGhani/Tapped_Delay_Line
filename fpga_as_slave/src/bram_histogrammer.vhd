library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity bram_histogrammer is
    Generic (
        ADDR_WIDTH : integer := 8;
        DATA_WIDTH : integer := 32
    );
    Port (
        clk         : in  STD_LOGIC;
        reset       : in  STD_LOGIC;
        clear_start : in  STD_LOGIC;
        clear_busy  : out STD_LOGIC;
        hit_valid   : in  STD_LOGIC;
        hit_bin     : in  STD_LOGIC_VECTOR(ADDR_WIDTH-1 downto 0);
        hit_ready   : out STD_LOGIC;
        hit_accepted: out STD_LOGIC;
        read_addr   : in  STD_LOGIC_VECTOR(ADDR_WIDTH-1 downto 0);
        read_data   : out STD_LOGIC_VECTOR(DATA_WIDTH-1 downto 0)
    );
end bram_histogrammer;

architecture Behavioral of bram_histogrammer is
    type ram_type is array (0 to (2**ADDR_WIDTH)-1) 
        of std_logic_vector(DATA_WIDTH-1 downto 0);
    signal ram : ram_type := (others => (others => '0'));

    signal we_a   : std_logic;
    signal addr_a : std_logic_vector(ADDR_WIDTH-1 downto 0);
    signal din_a  : std_logic_vector(DATA_WIDTH-1 downto 0);
    signal dout_a : std_logic_vector(DATA_WIDTH-1 downto 0);

    type state_type is (IDLE, READ_WAIT, DO_WRITE, CLEAR_LOOP);
    signal state : state_type := IDLE;
    signal clear_addr : unsigned(ADDR_WIDTH-1 downto 0) := (others => '0');

    -- FIX: Buffer incoming hits so single-cycle pulses aren't lost
    signal hit_pending  : std_logic := '0';
    signal hit_bin_held : std_logic_vector(ADDR_WIDTH-1 downto 0) 
        := (others => '0');
begin

    -- Port A: Read/Write
    process(clk)
    begin
        if rising_edge(clk) then
            if we_a = '1' then
                ram(to_integer(unsigned(addr_a))) <= din_a;
            end if;
            dout_a <= ram(to_integer(unsigned(addr_a)));
        end if;
    end process;

    -- Port B: Read-Only
    process(clk)
    begin
        if rising_edge(clk) then
            read_data <= ram(to_integer(unsigned(read_addr)));
        end if;
    end process;

    -- One-deep hit buffer. New hits overwrite pending when FSM is busy.
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                hit_pending  <= '0';
                hit_bin_held <= (others => '0');
            elsif hit_valid = '1' then
                -- Capture latest hit. If busy, this behaves as one-entry overwrite.
                hit_pending  <= '1';
                hit_bin_held <= hit_bin;
            elsif state = DO_WRITE then
                -- Pending hit was consumed by the read-modify-write transaction.
                hit_pending <= '0';
            end if;
        end if;
    end process;

    -- FSM
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                state      <= IDLE;
                clear_busy <= '0';
                hit_ready  <= '0';
                hit_accepted <= '0';
                we_a       <= '0';
                addr_a     <= (others => '0');
                din_a      <= (others => '0');
                clear_addr <= (others => '0');
            else
                we_a <= '0';
                hit_accepted <= '0';

                case state is
                    when IDLE =>
                        hit_ready  <= '1';
                        clear_busy <= '0';
                        if clear_start = '1' then
                            hit_ready  <= '0';
                            clear_busy <= '1';
                            clear_addr <= (others => '0');
                            addr_a     <= (others => '0');
                            din_a      <= (others => '0');
                            we_a       <= '1';
                            state      <= CLEAR_LOOP;
                        elsif hit_pending = '1' then
                            hit_ready <= '0';
                            addr_a    <= hit_bin_held;
                            state     <= READ_WAIT;
                        end if;

                    when READ_WAIT =>
                        state <= DO_WRITE;

                    when DO_WRITE =>
                        we_a  <= '1';
                        din_a <= std_logic_vector(unsigned(dout_a) + 1);
                        hit_accepted <= '1';
                        state <= IDLE;

                    when CLEAR_LOOP =>
                        if clear_addr = (2**ADDR_WIDTH) - 1 then
                            state <= IDLE;
                        else
                            clear_addr <= clear_addr + 1;
                            addr_a     <= std_logic_vector(clear_addr + 1);
                            din_a      <= (others => '0');
                            we_a       <= '1';
                        end if;
                end case;
            end if;
        end if;
    end process;
end Behavioral;