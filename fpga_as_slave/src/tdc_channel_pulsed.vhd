library IEEE;
use IEEE.STD_LOGIC_1164.all;

library UNISIM;
use UNISIM.VComponents.all;

entity tdc_channel_pulsed is
    generic (
        TAPS : integer := 200
    );
    port (
        CLK_SYS     : in  std_logic;
        PULSE_SPIKE : in  std_logic;
        CLR         : in  std_logic;
        CLR_PULSE   : in  std_logic;
        THERMO_CODE : out std_logic_vector(TAPS - 1 downto 0)
    );
end tdc_channel_pulsed;

architecture Structural of tdc_channel_pulsed is

    constant NUM_CARRY4 : integer := (TAPS + 3) / 4;

    -- Explicit declaration keeps analysis stable when compatibility UNISIM
    -- stubs do not expose FDR, while synthesis in ISE maps to the primitive.
    component FDR
        generic (
            INIT : bit := '0'
        );
        port (
            Q : out std_logic;
            C : in  std_logic;
            D : in  std_logic;
            R : in  std_logic
        );
    end component;

    signal carry_taps   : std_logic_vector(NUM_CARRY4 * 4 - 1 downto 0);
    signal clr_any      : std_logic;

    signal thermo_cap1 : std_logic_vector(TAPS - 1 downto 0);
    signal thermo_cap2 : std_logic_vector(TAPS - 1 downto 0);
    signal thermo_step : std_logic_vector(TAPS - 1 downto 0);

    subtype bel_name_t is string(1 to 3);
    type bel_name_array_t is array (0 to 3) of bel_name_t;
    constant CAPTURE_BEL : bel_name_array_t := ("ffa", "ffb", "ffc", "ffd");

    function to_hblk_suffix(value : integer) return string is
        constant img : string := integer'image(value);
    begin
        if img(1) = ' ' then
            return img(2 to img'length);
        end if;
        return img;
    end function;

    attribute KEEP : string;
    attribute S    : string;
    attribute DONT_TOUCH : string;
    attribute BEL : string;
    attribute HBLKNM : string;
    -- KEEP attributes are disabled while using HBLKNM/BEL slice gluing.
    -- KEEP can force external visibility and block legal directed packing paths.
    --attribute KEEP of carry_taps : signal is "TRUE";
    --attribute KEEP of thermo_cap1 : signal is "TRUE";
    attribute S    of carry_taps : signal is "TRUE";
    attribute S    of thermo_cap1 : signal is "TRUE";
    attribute DONT_TOUCH of thermo_cap1 : signal is "TRUE";

begin

    -- Pulse propagates asynchronously through the carry chain.
    -- Raw taps are latched asynchronously, then snapped in CLK_SYS domain.
    clr_any       <= CLR or CLR_PULSE;

    ---------------------------------------------------------------------------
    -- CARRY4 CHAIN
    ---------------------------------------------------------------------------
    GEN_CARRY4 : for i in 0 to NUM_CARRY4 - 1 generate
        constant SLICE_BLOCK_NAME : string := "tdc_slice_" & to_hblk_suffix(i);
    begin
        GEN_CARRY4_FIRST : if i = 0 generate
            attribute HBLKNM of CARRY4_inst : label is SLICE_BLOCK_NAME;
        begin
            CARRY4_inst : CARRY4
            port map (
                CO => carry_taps(3 downto 0),
                O     => open,
                CI    => '0',
                CYINIT => PULSE_SPIKE,
                DI    => "0000",
                S     => "1111"
            );
        end generate GEN_CARRY4_FIRST;

        GEN_CARRY4_NEXT : if i > 0 generate
            attribute HBLKNM of CARRY4_inst : label is SLICE_BLOCK_NAME;
        begin
            CARRY4_inst : CARRY4
            port map (
                CO => carry_taps(4 * (i + 1) - 1 downto 4 * i),
                O     => open,
                CI    => '0',
                CYINIT => carry_taps(4 * i - 1),
                DI    => "0000",
                S     => "1111"
            );
        end generate GEN_CARRY4_NEXT;
    end generate GEN_CARRY4;

    ---------------------------------------------------------------------------
    -- CERN-style TAP CAPTURE + METASTABILITY BUFFER
    --
    -- Stage 1 (FF_CAPTURE): capture async carry taps on SYS clock.
    -- Stage 2 (FF_META): second SYS-clocked stage for metastability hardening
    -- before thermometer decoding.
    ---------------------------------------------------------------------------
    GEN_CAPTURE : for i in 0 to TAPS - 1 generate
        constant SLICE_BLOCK_NAME : string := "tdc_slice_" & to_hblk_suffix(i / 4);
        constant CAPTURE_BEL_NAME : bel_name_t := CAPTURE_BEL(i mod 4);
        attribute HBLKNM of FF_CAPTURE : label is SLICE_BLOCK_NAME;
        attribute BEL of FF_CAPTURE : label is CAPTURE_BEL_NAME;
    begin
        FF_CAPTURE : FDR
        generic map (INIT => '0')
        port map (
            C => CLK_SYS,
            D => carry_taps(i),
            R => clr_any,
            Q => thermo_cap1(i)
        );

        FF_META : FDR
        generic map (INIT => '0')
        port map (
            C => CLK_SYS,
            D => thermo_cap1(i),
            R => clr_any,
            Q => thermo_cap2(i)
        );
    end generate GEN_CAPTURE;

    ---------------------------------------------------------------------------
    -- Convert raw sampled taps to monotonic thermometer-step form.
    ---------------------------------------------------------------------------
    process (thermo_cap2, clr_any)
        variable found : std_logic;
    begin
        if clr_any = '1' then
            thermo_step <= (others => '0');
        else
            found := '0';
            for i in TAPS - 1 downto 0 loop
                if thermo_cap2(i) = '1' then
                    found := '1';
                end if;
                thermo_step(i) <= found;
            end loop;
        end if;
    end process;

    THERMO_CODE <= thermo_step;

end Structural;
