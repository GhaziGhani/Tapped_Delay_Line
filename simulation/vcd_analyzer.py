#!/usr/bin/env python3
"""
VCD File Analyzer for TDC Sweep Simulation
Analyzes the VCD waveform file to extract clock cycle data and create a comprehensive workflow spreadsheet
"""

import re
import csv
from datetime import datetime
from collections import defaultdict

def parse_vcd_file(vcd_path):
    """Parse VCD file and extract signal transitions"""
    signals = {}
    signal_values = {}
    timescale = None
    current_time = 0
    
    with open(vcd_path, 'r') as f:
        lines = f.readlines()
    
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        
        # Parse timescale
        if line.startswith('$timescale'):
            # Look for the next non-empty line that contains the timescale value
            i += 1
            while i < len(lines) and not lines[i].strip().startswith('$end'):
                if lines[i].strip():
                    timescale_parts = lines[i].strip().split()
                    if len(timescale_parts) >= 2:
                        timescale = ' '.join(timescale_parts[:2])
                    else:
                        timescale = timescale_parts[0] if timescale_parts else "1 fs"
                    break
                i += 1
            while i < len(lines) and not lines[i].strip().startswith('$end'):
                i += 1
            i += 1
            continue
            
        # Parse variable definitions
        elif line.startswith('$var'):
            parts = line.split()
            if len(parts) >= 5:
                var_type = parts[1]
                size = parts[2]
                identifier = parts[3]
                name = parts[4]
                
                # Handle multi-word names
                if len(parts) > 5:
                    name = ' '.join(parts[4:])
                    name = name.rstrip('$end')
                
                signals[identifier] = {
                    'name': name,
                    'type': var_type,
                    'size': size,
                    'transitions': []
                }
                signal_values[identifier] = '0'
            
            i += 1
            while not lines[i].strip().startswith('$end'):
                i += 1
            i += 1
            continue
            
        # Parse signal value changes
        elif re.match(r'^[01xz]', line):
            # Value change format: value identifier
            match = re.match(r'^([01xz])(\S+)', line)
            if match:
                value = match.group(1)
                identifier = match.group(2)
                
                if identifier in signals:
                    old_value = signal_values.get(identifier, '0')
                    signal_values[identifier] = value
                    signals[identifier]['transitions'].append({
                        'time': current_time,
                        'value': value,
                        'old_value': old_value
                    })
            
            i += 1
            
        # Parse time transitions
        elif line.startswith('#'):
            current_time = int(line[1:])
            i += 1
            
        # Skip other sections
        elif line.startswith('$'):
            # Skip until $end
            i += 1
            while i < len(lines) and not lines[i].strip().startswith('$end'):
                i += 1
            i += 1
        else:
            i += 1
    
    return signals, timescale, current_time

def extract_clock_cycles(signals, total_time):
    """Extract clock cycle information from signals"""
    clock_cycles = []
    
    # Find clock signal
    clk_signal = None
    for sig_id, sig_data in signals.items():
        if 'clk' in sig_data['name'].lower():
            clk_signal = sig_id
            break
    
    if not clk_signal:
        print("Warning: No clock signal found")
        return clock_cycles
    
    # Extract clock transitions
    clk_transitions = signals[clk_signal]['transitions']
    
    # Group transitions into clock cycles
    rising_edges = []
    falling_edges = []
    
    for trans in clk_transitions:
        if trans['value'] == '1' and trans['old_value'] == '0':
            rising_edges.append(trans['time'])
        elif trans['value'] == '0' and trans['old_value'] == '1':
            falling_edges.append(trans['time'])
    
    # Create clock cycle data
    for i, rising_time in enumerate(rising_edges):
        cycle_data = {
            'cycle_number': i + 1,
            'rising_time': rising_time,
            'falling_time': falling_edges[i] if i < len(falling_edges) else None,
            'period': (falling_edges[i] - rising_time) if i < len(falling_edges) else None,
            'signals': {}
        }
        
        # Extract signal states during this cycle
        for sig_id, sig_data in signals.items():
            if sig_id != clk_signal:  # Skip clock itself
                # Find the last transition before or at rising edge
                signal_state = '0'
                for trans in reversed(sig_data['transitions']):
                    if trans['time'] <= rising_time:
                        signal_state = trans['value']
                        break
                cycle_data['signals'][sig_data['name']] = signal_state
        
        clock_cycles.append(cycle_data)
    
    return clock_cycles

def create_workflow_spreadsheet(clock_cycles, signals, output_path):
    """Create a comprehensive spreadsheet of the workflow"""
    
    # Get all unique signal names
    signal_names = []
    for sig_id, sig_data in signals.items():
        if sig_data['name'] not in signal_names:
            signal_names.append(sig_data['name'])
    
    signal_names.sort()
    
    with open(output_path, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        
        # Write header
        header = ['Cycle', 'Time (ns)', 'Period (ns)', 'Reset', 'Locked', 'All_Done', 'TX_Out']
        # Add other signals
        for name in signal_names:
            if name not in ['CLK_IN', 'RST_IN', 'LOCKED', 'ALL_DONE', 'TX_OUT']:
                header.append(name)
        
        writer.writerow(header)
        
        # Write cycle data
        for cycle in clock_cycles:
            time_ns = cycle['rising_time'] / 1000.0  # Convert ps to ns
            period_ns = cycle['period'] / 1000.0 if cycle['period'] else ''
            
            row = [
                cycle['cycle_number'],
                f"{time_ns:.3f}",
                f"{period_ns:.3f}" if period_ns else '',
                cycle['signals'].get('RST_IN', '0'),
                cycle['signals'].get('LOCKED', '0'),
                cycle['signals'].get('ALL_DONE', '0'),
                cycle['signals'].get('TX_OUT', '0')
            ]
            
            # Add other signals
            for name in signal_names:
                if name not in ['CLK_IN', 'RST_IN', 'LOCKED', 'ALL_DONE', 'TX_OUT']:
                    row.append(cycle['signals'].get(name, '0'))
            
            writer.writerow(row)

def analyze_behavior(clock_cycles, signals):
    """Analyze the simulation for abnormal behavior"""
    issues = []
    
    # Check reset behavior
    reset_cycles = [c for c in clock_cycles if c['signals'].get('RST_IN') == '1']
    if not reset_cycles:
        issues.append("No reset cycles detected")
    else:
        first_reset = reset_cycles[0]['cycle_number']
        if first_reset > 10:
            issues.append(f"Reset starts late at cycle {first_reset}")
    
    # Check lock behavior
    lock_cycles = [c for c in clock_cycles if c['signals'].get('LOCKED') == '1']
    if not lock_cycles:
        issues.append("PLL never locked")
    else:
        first_lock = lock_cycles[0]['cycle_number']
        issues.append(f"PLL locked at cycle {first_lock}")
    
    # Check completion
    done_cycles = [c for c in clock_cycles if c['signals'].get('ALL_DONE') == '1']
    if not done_cycles:
        issues.append("Simulation never completed")
    else:
        first_done = done_cycles[0]['cycle_number']
        issues.append(f"Simulation completed at cycle {first_done}")
    
    # Check clock period consistency
    periods = [c['period'] for c in clock_cycles if c['period'] is not None]
    if periods:
        avg_period = sum(periods) / len(periods)
        expected_period = 20000  # 20ns for 50MHz clock
        if abs(avg_period - expected_period) > 1000:  # 1ns tolerance
            issues.append(f"Clock period anomaly: avg {avg_period/1000:.3f}ns, expected {expected_period/1000:.3f}ns")
    
    return issues

def main():
    vcd_path = "tdc_sweep_top_tb.vcd"
    output_path = "tdc_simulation_workflow.csv"
    
    print("Analyzing VCD file...")
    signals, timescale, total_time = parse_vcd_file(vcd_path)
    
    print(f"Timescale: {timescale}")
    print(f"Total simulation time: {total_time} ps ({total_time/1000000:.3f} ms)")
    print(f"Found {len(signals)} signals")
    
    print("\nExtracting clock cycles...")
    clock_cycles = extract_clock_cycles(signals, total_time)
    print(f"Found {len(clock_cycles)} clock cycles")
    
    print("\nCreating workflow spreadsheet...")
    create_workflow_spreadsheet(clock_cycles, signals, output_path)
    print(f"Workflow spreadsheet saved to: {output_path}")
    
    print("\nAnalyzing behavior...")
    issues = analyze_behavior(clock_cycles, signals)
    print("\nBehavior Analysis:")
    for issue in issues:
        print(f"  - {issue}")
    
    # Save analysis report
    with open("simulation_analysis_report.txt", 'w') as f:
        f.write("TDC Sweep Simulation Analysis Report\n")
        f.write("=" * 40 + "\n\n")
        f.write(f"Simulation completed at: {datetime.now()}\n")
        f.write(f"Total simulation time: {total_time} ps ({total_time/1000000:.3f} ms)\n")
        f.write(f"Number of clock cycles: {len(clock_cycles)}\n")
        f.write(f"Number of signals: {len(signals)}\n")
        f.write(f"Timescale: {timescale}\n\n")
        
        f.write("Signal List:\n")
        for sig_id, sig_data in signals.items():
            f.write(f"  {sig_data['name']} ({sig_data['type']})\n")
        
        f.write("\nBehavior Analysis:\n")
        for issue in issues:
            f.write(f"  - {issue}\n")
    
    print(f"\nAnalysis report saved to: simulation_analysis_report.txt")

if __name__ == "__main__":
    main()
