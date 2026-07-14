-- File: T2b.vhd (CORRECTED)
--
-- Thermometer-to-binary encoder — fully generic adder tree.
--
-- FIXES APPLIED:
--   Issue 8:  Non-multiple-of-4 remainder bits now handled explicitly.
--             If NUM_BITS is not divisible by 4, the remaining 1-3 bits
--             are summed into an additional partial group at stage 0.
--   Issue 10: Register count is inherent to adder tree; documented.
--
-- ARCHITECTURE:
--   Stage 0: N+1 bits -> groups of 4, pop-count each to 3-bit sums
--            Plus optional partial group for remainder bits
--   Stage 1+: Pairwise reduction, each stage halves element count
--   Total pipeline latency: 1 + ceil(log2(num_groups)) cycles
--------------------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.all;
use IEEE.NUMERIC_STD.all;

entity T2b is
  generic (
    N : integer := 799; -- thermo_in is (N downto 0), so N+1 bits
    M : integer := 10 -- output width
  );
  port (
    CLK        : in std_logic;
    thermo_in  : in std_logic_vector(N downto 0);
    binary_out : out std_logic_vector(M - 1 downto 0)
  );
end T2b;

architecture Behavioral of T2b is

  constant NUM_BITS    : integer := N + 1;
  constant FULL_GROUPS : integer := NUM_BITS / 4;
  constant REMAINDER   : integer := NUM_BITS mod 4;
  -- FIX Issue 8: If there are remainder bits, add one more group
  constant TOTAL_GROUPS : integer := FULL_GROUPS + (REMAINDER + 3) / 4;
  -- Note: (REMAINDER+3)/4 = 1 when REMAINDER>0, 0 when REMAINDER=0

  ---------------------------------------------------------------------------
  -- Helper function: ceiling of log2
  ---------------------------------------------------------------------------
  function clog2(val : integer) return integer is
    variable result    : integer := 0;
    variable v         : integer := val - 1;
  begin
    if val <= 1 then
      return 1;
    end if;
    while v > 0 loop
      result := result + 1;
      v      := v / 2;
    end loop;
    return result;
  end function;

  constant NUM_REDUCE_STAGES : integer := clog2(TOTAL_GROUPS);
  constant TOTAL_STAGES      : integer := NUM_REDUCE_STAGES + 1;

  -- Array must be large enough to hold index FULL_GROUPS (used by remainder
  -- block, which GHDL evaluates at elaboration even when REMAINDER=0).
  -- TOTAL_GROUPS drives the reduction tree element counts.
  constant MAX_ELEMENTS : integer := FULL_GROUPS + 1;
  constant MAX_WIDTH    : integer := 3 + NUM_REDUCE_STAGES;

  type elem_array_t is array (0 to MAX_ELEMENTS - 1) of unsigned(MAX_WIDTH - 1 downto 0);
  type tree_t is array (0 to TOTAL_STAGES - 1) of elem_array_t;

  signal tree : tree_t := (others => (others => (others => '0')));

  ---------------------------------------------------------------------------
  -- Number of active elements at each stage
  ---------------------------------------------------------------------------
  type int_array_t is array (0 to TOTAL_STAGES - 1) of integer;

  function compute_counts return int_array_t is
    variable result : int_array_t;
  begin
    result(0) := TOTAL_GROUPS;
    for s in 1 to TOTAL_STAGES - 1 loop
      result(s) := (result(s - 1) + 1) / 2;
    end loop;
    return result;
  end function;

  constant STAGE_COUNTS : int_array_t := compute_counts;

begin

  TREE_PROC : process (CLK)
    variable a, b, sum_v : unsigned(MAX_WIDTH - 1 downto 0);
    variable prev_cnt    : integer;
    variable cnt         : integer;
  begin
    if rising_edge(CLK) then

      ---------------------------------------------------------------
      -- Stage 0: full 4-bit groups
      ---------------------------------------------------------------
      for g in 0 to FULL_GROUPS - 1 loop
        tree(0)(g) <= resize(
        ("00" & unsigned(thermo_in(4 * g + 0 downto 4 * g + 0)))
        + ("00" & unsigned(thermo_in(4 * g + 1 downto 4 * g + 1)))
        + ("00" & unsigned(thermo_in(4 * g + 2 downto 4 * g + 2)))
        + ("00" & unsigned(thermo_in(4 * g + 3 downto 4 * g + 3))),
        MAX_WIDTH
        );
      end loop;

      ---------------------------------------------------------------
      -- FIX Issue 8: Handle remainder bits (1, 2, or 3 leftover)
      ---------------------------------------------------------------
      if REMAINDER > 0 then
        -- Partial group starting at bit index FULL_GROUPS*4
        case REMAINDER is
          when 1 =>
            tree(0)(FULL_GROUPS) <= resize(
            unsigned(thermo_in(FULL_GROUPS * 4 downto FULL_GROUPS * 4)),
            MAX_WIDTH
            );
          when 2 =>
            tree(0)(FULL_GROUPS) <= resize(
            ("00" & unsigned(thermo_in(FULL_GROUPS * 4 downto FULL_GROUPS * 4)))
            + ("00" & unsigned(thermo_in(FULL_GROUPS * 4 + 1 downto FULL_GROUPS * 4 + 1))),
            MAX_WIDTH
            );
          when 3 =>
            tree(0)(FULL_GROUPS) <= resize(
            ("00" & unsigned(thermo_in(FULL_GROUPS * 4 downto FULL_GROUPS * 4)))
            + ("00" & unsigned(thermo_in(FULL_GROUPS * 4 + 1 downto FULL_GROUPS * 4 + 1)))
            + ("00" & unsigned(thermo_in(FULL_GROUPS * 4 + 2 downto FULL_GROUPS * 4 + 2))),
            MAX_WIDTH
            );
          when others =>
            null;
        end case;
      end if;

      ---------------------------------------------------------------
      -- Stages 1..N: pairwise reduction
      ---------------------------------------------------------------
      for s in 1 to TOTAL_STAGES - 1 loop
        prev_cnt := STAGE_COUNTS(s - 1);
        cnt      := STAGE_COUNTS(s);

        for g in 0 to cnt - 1 loop
          if 2 * g + 1 < prev_cnt then
            a     := tree(s - 1)(2 * g);
            b     := tree(s - 1)(2 * g + 1);
            sum_v := resize(a, MAX_WIDTH) + resize(b, MAX_WIDTH);
            tree(s)(g) <= sum_v;
          else
            tree(s)(g) <= tree(s - 1)(2 * g);
          end if;
        end loop;

        for g in cnt to MAX_ELEMENTS - 1 loop
          tree(s)(g) <= (others => '0');
        end loop;
      end loop;

    end if;
  end process;

  binary_out <= std_logic_vector(resize(tree(TOTAL_STAGES - 1)(0), M));

end Behavioral;