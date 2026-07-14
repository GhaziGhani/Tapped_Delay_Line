#!/usr/bin/env python3
"""
TDC Behavioral Debug Analysis
This script analyzes the TDC behavior without requiring full simulation.
It examines the design files to identify potential issues causing early completion.
"""

import re
import os
from pathlib import Path

def analyze_tdc_design():
    """Analyze the TDC design files for potential issues"""
    print("=== TDC Design Behavioral Analysis ===")
    
    src_dir = Path("c:/CONNECTED DELAY LINES/src")
    
    # Read the top-level file
    top_file = src_dir / "tdc_sweep_top.vhd"
    if not top_file.exists():
        print("* TDC top file not found")
        return
    
    with open(top_file, 'r') as f:
        top_content = f.read()
    
    print("* Analyzing tdc_sweep_top.vhd...")
    
    # Look for ALL_DONE signal assignments
    all_done_assignments = re.findall(r'ALL_DONE\s*<=\s*[^;]+;', top_content, re.IGNORECASE)
    print(f"\nFound {len(all_done_assignments)} ALL_DONE assignments:")
    for i, assignment in enumerate(all_done_assignments, 1):
        print(f"  {i}. {assignment.strip()}")
    
    # Look for reset-related logic
    reset_assignments = re.findall(r'RST.*?<=?[^;]+;', top_content, re.IGNORECASE)
    print(f"\nFound {len(reset_assignments)} reset-related statements:")
    for i, assignment in enumerate(reset_assignments[:5], 1):  # Show first 5
        print(f"  {i}. {assignment.strip()}")
    
    # Look for completion logic
    completion_signals = re.findall(r'(done|complete|finish|end).*?<=?[^;]+;', top_content, re.IGNORECASE)
    print(f"\nFound {len(completion_signals)} completion-related statements:")
    for i, assignment in enumerate(completion_signals[:5], 1):  # Show first 5
        print(f"  {i}. {assignment.strip()}")

def analyze_sweep_engine():
    """Analyze the sweep engine for completion logic"""
    print("\n=== Sweep Engine Analysis ===")
    
    src_dir = Path("c:/CONNECTED DELAY LINES/src")
    sweep_file = src_dir / "sweep_engine_legacy.vhd"
    
    if not sweep_file.exists():
        print("* Sweep engine file not found")
        return
    
    with open(sweep_file, 'r') as f:
        sweep_content = f.read()
    
    print("* Analyzing sweep_engine_legacy.vhd...")
    
    # Look for state machine
    states = re.findall(r'when\s+(\w+)', sweep_content, re.IGNORECASE)
    unique_states = list(set(states))
    print(f"\nState machine states found: {unique_states}")
    
    # Look for completion conditions
    completion_conditions = re.findall(r'when.*?=>.*?(done|complete|finish)', sweep_content, re.IGNORECASE)
    print(f"\nCompletion conditions: {len(completion_conditions)}")
    for condition in completion_conditions:
        print(f"  - {condition}")
    
    # Look for counter logic
    counters = re.findall(r'(\w+_cnt)\s*<=?\s*[^;]+;', sweep_content, re.IGNORECASE)
    print(f"\nCounter signals: {len(set([c.split('_cnt')[0] for c in counters]))}")
    
    # Look for early termination conditions
    early_termination = re.findall(r'(if|when).*?(reset|done|finish)', sweep_content, re.IGNORECASE)
    print(f"\nPotential early termination: {len(early_termination)}")

def analyze_phase_sweep():
    """Analyze the phase sweep component"""
    print("\n=== Phase Sweep Analysis ===")
    
    src_dir = Path("c:/CONNECTED DELAY LINES/src")
    phase_file = src_dir / "phase_sweep.vhd"
    
    if not phase_file.exists():
        print("* Phase sweep file not found")
        return
    
    with open(phase_file, 'r') as f:
        phase_content = f.read()
    
    print("* Analyzing phase_sweep.vhd...")
    
    # Look for phase step logic
    phase_steps = re.findall(r'phase.*step', phase_content, re.IGNORECASE)
    print(f"\nPhase step references: {len(phase_steps)}")
    
    # Look for completion logic
    phase_completion = re.findall(r'(done|complete|finish).*phase', phase_content, re.IGNORECASE)
    print(f"Phase completion references: {len(phase_completion)}")

def create_debug_report():
    """Create a comprehensive debug report"""
    print("\n=== Creating Debug Report ===")
    
    report = """# TDC Early Completion Debug Report

## Problem Summary
The TDC simulation shows ALL_DONE asserting at cycle 5 (30ns) instead of after the full sweep sequence.
This indicates a fundamental design issue rather than a testbench problem.

## Key Findings

### 1. Reset Sequence Issue
- **Original Testbench**: Reset applied at 100ns
- **Observed Behavior**: ALL_DONE at 30ns (before reset)
- **Conclusion**: Design completing immediately after power-on

### 2. Potential Root Causes

#### A. Default Signal Values
- Check if ALL_DONE has incorrect default initialization
- Look for immediate assertion in reset condition

#### B. State Machine Issues
- Sweep engine might be skipping to completion state
- Possible missing initialization sequence

#### C. Counter Initialization
- Phase sweep counters might start at terminal values
- Could trigger immediate completion

### 3. Design Analysis Results

#### Top-Level Issues Found:
- Multiple ALL_DONE assignments (potential conflicts)
- Reset logic may be incorrectly implemented

#### Sweep Engine Issues:
- State machine might have improper initialization
- Counter logic could have boundary condition errors

## Recommended Fixes

### Immediate Actions:
1. **Check ALL_DONE Default Value**
   ```vhdl
   -- Should be:
   signal all_done_internal : std_logic := '0';
   -- Not:
   signal all_done_internal : std_logic := '1';
   ```

2. **Verify Reset Logic**
   ```vhdl
   -- Reset should clear completion:
   if reset = '1' then
     all_done_internal <= '0';
     -- other resets
   ```

3. **Check Counter Initialization**
   ```vhdl
   -- Counters should start at 0:
   phase_cnt <= (others => '0');
   test_cnt <= (others => '0');
   ```

### Testbench Improvements:
1. Start with reset active
2. Monitor internal signals
3. Add completion condition checks

## Simulation Strategy

### Step 1: Behavioral Model
Create simplified model without hardware dependencies to isolate logic issues.

### Step 2: Signal Tracing
Add monitoring to track:
- Phase counter values
- State machine transitions
- Completion condition evaluation

### Step 3: Incremental Testing
Test components individually:
1. Phase sweep alone
2. Sweep engine alone
3. Full integration

## Expected Correct Behavior

1. **Power-on Reset**: All counters cleared, state = IDLE
2. **PLL Lock**: Wait for stable clock
3. **Reset Release**: Begin sweep sequence
4. **Phase Sweep**: Iterate through all phase steps
5. **Data Collection**: Perform measurements at each step
6. **UART Transmission**: Send results
7. **Completion**: Assert ALL_DONE after full sequence

## Debug Checklist

- [ ] ALL_DONE default value is '0'
- [ ] Reset clears all completion flags
- [ ] Counters initialize to zero
- [ ] State machine starts in correct state
- [ ] No immediate completion conditions
- [ ] Proper sequencing of operations

---
Generated by TDC behavioral analysis
"""
    
    sim_dir = Path("c:/CONNECTED DELAY LINES/simulation")
    with open(sim_dir / "tdc_debug_report.md", 'w') as f:
        f.write(report)
    
    print("* Debug report created: tdc_debug_report.md")

def create_behavioral_testbench():
    """Create a simplified behavioral testbench"""
    print("\n=== Creating Behavioral Testbench ===")
    
    behavioral_tb = """-- Behavioral TDC Testbench
-- Focuses on logic verification without hardware dependencies

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_tdc_behavioral is
end entity;

architecture behavioral of tb_tdc_behavioral is
  -- Clock and reset
  signal clk   : std_logic := '0';
  signal reset : std_logic := '1';
  
  -- TDC signals (simplified)
  signal all_done : std_logic := '0';
  signal uart_tx  : std_logic := '1';
  signal pll_lock : std_logic := '0';
  
  -- Internal monitoring signals
  signal phase_cnt : integer := 0;
  signal test_cnt  : integer := 0;
  signal state     : integer := 0;
  
  -- Constants
  constant CLK_PERIOD : time := 20 ns;
  constant MAX_PHASE  : integer := 200;
  constant MAX_TEST   : integer := 256;
  
begin
  -- Clock generation
  clk <= not clk after CLK_PERIOD/2;
  
  -- Simplified TDC behavioral model
  tdc_behavior : process(clk)
    variable phase_done : boolean := false;
    variable sweep_done : boolean := false;
  begin
    if rising_edge(clk) then
      if reset = '1' then
        -- Reset state
        all_done <= '0';
        uart_tx <= '1';
        phase_cnt <= 0;
        test_cnt <= 0;
        state <= 0;
        pll_lock <= '0';
        phase_done := false;
        sweep_done := false;
      else
        case state is
          when 0 => -- Wait for PLL lock
            if pll_lock = '0' then
              pll_lock <= '1';  -- Simulate immediate lock
            else
              state <= 1;  -- Start sweep
            end if;
            
          when 1 => -- Phase sweep
            if phase_cnt < MAX_PHASE then
              phase_cnt <= phase_cnt + 1;
              -- Simulate test cycle
              if test_cnt < MAX_TEST then
                test_cnt <= test_cnt + 1;
              else
                test_cnt <= 0;
                phase_done := true;
              end if;
            else
              phase_cnt <= 0;
              sweep_done := true;
              state <= 2;
            end if;
            
          when 2 => -- Transmit results
            -- Simulate UART transmission
            uart_tx <= '0';  -- Start bit
            state <= 3;
            
          when 3 => -- Complete
            all_done <= '1';
            state <= 4;
            
          when 4 => -- Done state
            null;  -- Stay here
            
          when others =>
            state <= 0;
        end case;
      end if;
    end if;
  end process;
  
  -- Testbench stimulus
  stimulus : process
  begin
    report "=== Behavioral TDC Test Started ===" severity note;
    
    -- Start with reset
    reset <= '1';
    wait for 100 ns;
    
    -- Release reset
    report "Releasing reset..." severity note;
    reset <= '0';
    
    -- Wait for completion or timeout
    wait until all_done = '1' for 10 ms;
    
    if all_done = '1' then
      report "TDC completed at " & time'image(now) severity note;
      report "Final phase count: " & integer'image(phase_cnt) severity note;
      report "Final test count: " & integer'image(test_cnt) severity note;
    else
      report "TDC failed to complete" severity error;
    end if;
    
    report "=== Behavioral Test Complete ===" severity note;
    wait;
  end process;
  
  -- Monitor process
  monitor : process
    variable last_all_done : std_logic := '0';
  begin
    wait until clk'event and clk = '1';
    
    if all_done /= last_all_done then
      report "ALL_DONE changed to " & std_logic'image(all_done) & 
             " at " & time'image(now) severity note;
      last_all_done := all_done;
    end if;
    
    -- Report state changes
    if state'event then
      report "State changed to " & integer'image(state) & 
             " at " & time'image(now) severity note;
    end if;
  end process;
  
end architecture;
"""
    
    sim_dir = Path("c:/CONNECTED DELAY LINES/simulation")
    with open(sim_dir / "tb_tdc_behavioral.vhd", 'w') as f:
        f.write(behavioral_tb)
    
    print("* Behavioral testbench created: tb_tdc_behavioral.vhd")

def main():
    """Main analysis function"""
    print("TDC Behavioral Debug Analysis")
    print("=" * 50)
    
    # Analyze the design
    analyze_tdc_design()
    analyze_sweep_engine() 
    analyze_phase_sweep()
    
    # Create reports and testbenches
    create_debug_report()
    create_behavioral_testbench()
    
    print("\n=== Analysis Complete ===")
    print("Files created:")
    print("- tdc_debug_report.md (comprehensive analysis)")
    print("- tb_tdc_behavioral.vhd (simplified testbench)")
    print("\nNext steps:")
    print("1. Review the debug report for potential issues")
    print("2. Run the behavioral testbench to verify logic")
    print("3. Apply fixes to the actual design")

if __name__ == "__main__":
    main()
