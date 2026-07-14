#!/usr/bin/env python3
"""
Simple VCD File Analyzer for TDC Sweep Simulation
Focuses on extracting the main signals and clock cycles
"""

import re
import csv
from datetime import datetime

def parse_vcd_simple(vcd_path):
    """Parse VCD file and extract main signal transitions"""
    
    # Main signals we care about
    main_signals = {
        '!': 'clk_in',
        '"': 'rst_in', 
        '#': 'tx_out',
        '$': 'locked',
        '%': 'all_done'
    }
    
    signal_data = {name: [] for name in main_signals.values()}
    current_time = 0
    time_values = []
    
    with open(vcd_path, 'r') as f:
        content = f.read()
    
    # Split by time markers (#)
    sections = content.split('#')
    
    for i, section in enumerate(sections):
        if i == 0:  # Header section
            continue
            
        # Extract time value
        lines = section.strip().split('\n')
        if lines:
            time_match = re.match(r'^(\d+)', lines[0])
            if time_match:
                current_time = int(time_match.group(1))
                time_values.append(current_time)
                
                # Extract signal values for this time point
                signal_state = {name: '0' for name in main_signals.values()}
                
                for line in lines[1:]:
                    line = line.strip()
                    # Match pattern: value identifier
                    match = re.match(r'^([01xz])([\W])', line)
                    if match:
                        value = match.group(1)
                        identifier = match.group(2)
                        if identifier in main_signals:
                            signal_state[main_signals[identifier]] = value
                
                # Store the signal state
                for name, value in signal_state.items():
                    signal_data[name].append(value)
    
    return signal_data, time_values

def extract_clock_cycles(signal_data, time_values):
    """Extract clock cycle information"""
    clock_cycles = []
    clk_values = signal_data['clk_in']
    
    # Find rising edges
    for i in range(1, len(clk_values)):
        if clk_values[i] == '1' and clk_values[i-1] == '0':
            # Rising edge detected
            cycle_data = {
                'cycle_number': len(clock_cycles) + 1,
                'time': time_values[i] if i < len(time_values) else 0,
                'rst_in': signal_data['rst_in'][i] if i < len(signal_data['rst_in']) else '0',
                'tx_out': signal_data['tx_out'][i] if i < len(signal_data['tx_out']) else '0', 
                'locked': signal_data['locked'][i] if i < len(signal_data['locked']) else '0',
                'all_done': signal_data['all_done'][i] if i < len(signal_data['all_done']) else '0'
            }
            clock_cycles.append(cycle_data)
    
    return clock_cycles

def create_workflow_spreadsheet(clock_cycles, output_path):
    """Create a comprehensive spreadsheet of the workflow"""
    
    with open(output_path, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        
        # Write header
        header = ['Cycle', 'Time (ns)', 'Reset', 'Locked', 'All_Done', 'TX_Out', 'State_Description']
        writer.writerow(header)
        
        # Write cycle data
        for cycle in clock_cycles:
            time_ns = cycle['time'] / 1000000.0  # Convert fs to ns
            
            # Create state description
            state_desc = []
            if cycle['rst_in'] == '1':
                state_desc.append('RESET')
            if cycle['locked'] == '1':
                state_desc.append('LOCKED')
            if cycle['all_done'] == '1':
                state_desc.append('DONE')
            if cycle['tx_out'] == '1':
                state_desc.append('TX_ACTIVE')
            
            if not state_desc:
                state_desc.append('IDLE')
            
            row = [
                cycle['cycle_number'],
                f"{time_ns:.3f}",
                cycle['rst_in'],
                cycle['locked'],
                cycle['all_done'],
                cycle['tx_out'],
                ','.join(state_desc)
            ]
            
            writer.writerow(row)

def analyze_behavior(clock_cycles):
    """Analyze the simulation for abnormal behavior"""
    issues = []
    
    if not clock_cycles:
        issues.append("No clock cycles detected")
        return issues
    
    # Check reset behavior
    reset_cycles = [c for c in clock_cycles if c['rst_in'] == '1']
    if not reset_cycles:
        issues.append("No reset cycles detected")
    else:
        first_reset = reset_cycles[0]['cycle_number']
        issues.append(f"Reset starts at cycle {first_reset}")
        
        if first_reset > 10:
            issues.append(f"Reset starts late at cycle {first_reset}")
    
    # Check lock behavior
    lock_cycles = [c for c in clock_cycles if c['locked'] == '1']
    if not lock_cycles:
        issues.append("PLL never locked")
    else:
        first_lock = lock_cycles[0]['cycle_number']
        issues.append(f"PLL locked at cycle {first_lock}")
        
        if first_lock > 1000:
            issues.append(f"PLL lock delayed until cycle {first_lock}")
    
    # Check completion
    done_cycles = [c for c in clock_cycles if c['all_done'] == '1']
    if not done_cycles:
        issues.append("Simulation never completed")
    else:
        first_done = done_cycles[0]['cycle_number']
        issues.append(f"Simulation completed at cycle {first_done}")
        
        total_cycles = len(clock_cycles)
        if first_done < total_cycles * 0.5:
            issues.append(f"Early completion at cycle {first_done} (total: {total_cycles})")
    
    # Check TX activity
    tx_cycles = [c for c in clock_cycles if c['tx_out'] == '1']
    if tx_cycles:
        issues.append(f"TX active in {len(tx_cycles)} cycles")
        first_tx = tx_cycles[0]['cycle_number']
        issues.append(f"TX first active at cycle {first_tx}")
    else:
        issues.append("No TX activity detected")
    
    # Clock frequency analysis
    if len(clock_cycles) > 1:
        first_cycle = clock_cycles[0]['time']
        last_cycle = clock_cycles[-1]['time']
        total_time_ns = (last_cycle - first_cycle) / 1000000.0
        avg_period_ns = total_time_ns / len(clock_cycles)
        expected_freq = 50  # MHz
        expected_period_ns = 1000 / expected_freq  # 20ns
        
        if abs(avg_period_ns - expected_period_ns) > 2:  # 2ns tolerance
            issues.append(f"Clock period anomaly: avg {avg_period_ns:.3f}ns, expected {expected_period_ns:.3f}ns")
        else:
            issues.append(f"Clock period OK: avg {avg_period_ns:.3f}ns")
    
    return issues

def main():
    vcd_path = "tdc_sweep_top_tb.vcd"
    output_path = "tdc_simulation_workflow.csv"
    
    print("Analyzing VCD file...")
    signal_data, time_values = parse_vcd_simple(vcd_path)
    
    print(f"Total time points: {len(time_values)}")
    if time_values:
        total_time_ns = time_values[-1] / 1000000.0
        print(f"Total simulation time: {total_time_ns:.3f} ns ({total_time_ns/1000000:.3f} ms)")
    
    print("\nExtracting clock cycles...")
    clock_cycles = extract_clock_cycles(signal_data, time_values)
    print(f"Found {len(clock_cycles)} clock cycles")
    
    if clock_cycles:
        print("\nCreating workflow spreadsheet...")
        create_workflow_spreadsheet(clock_cycles, output_path)
        print(f"Workflow spreadsheet saved to: {output_path}")
        
        print("\nAnalyzing behavior...")
        issues = analyze_behavior(clock_cycles)
        print("\nBehavior Analysis:")
        for issue in issues:
            print(f"  - {issue}")
        
        # Save analysis report
        with open("simulation_analysis_report.txt", 'w') as f:
            f.write("TDC Sweep Simulation Analysis Report\n")
            f.write("=" * 40 + "\n\n")
            f.write(f"Simulation completed at: {datetime.now()}\n")
            f.write(f"Total simulation time: {total_time_ns:.3f} ns ({total_time_ns/1000000:.3f} ms)\n")
            f.write(f"Number of clock cycles: {len(clock_cycles)}\n")
            f.write(f"Number of time points: {len(time_values)}\n\n")
            
            f.write("Main Signals Tracked:\n")
            f.write("  - clk_in: System clock\n")
            f.write("  - rst_in: Reset signal\n")
            f.write("  - tx_out: UART transmitter output\n")
            f.write("  - locked: PLL lock indicator\n")
            f.write("  - all_done: Simulation completion flag\n\n")
            
            f.write("Behavior Analysis:\n")
            for issue in issues:
                f.write(f"  - {issue}\n")
            
            f.write("\nClock Cycle Summary:\n")
            f.write(f"  First cycle: {clock_cycles[0]['cycle_number']} at {clock_cycles[0]['time']/1000000.0:.3f} ns\n")
            f.write(f"  Last cycle: {clock_cycles[-1]['cycle_number']} at {clock_cycles[-1]['time']/1000000.0:.3f} ns\n")
        
        print(f"\nAnalysis report saved to: simulation_analysis_report.txt")
    else:
        print("No clock cycles found - check VCD file format")

if __name__ == "__main__":
    main()
