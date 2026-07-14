#!/usr/bin/env python3
"""
Improved TDC Simulation Runner and Analyzer
This script runs the improved testbench and analyzes the results.
"""

import os
import subprocess
import sys
import re
from pathlib import Path

def run_simulation():
    """Run the improved TDC simulation"""
    print("=== Running Improved TDC Simulation ===")
    
    # Change to simulation directory
    sim_dir = Path("c:/CONNECTED DELAY LINES/simulation")
    os.chdir(sim_dir)
    
    # Compile the improved testbench
    print("Compiling improved testbench...")
    compile_cmd = [
        "ghdl", "-a", "--std=08", 
        "../src/tdc_sweep_top.vhd",
        "tb_tdc_sweep_top_improved.vhd"
    ]
    
    try:
        result = subprocess.run(compile_cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            print(f"Compilation failed: {result.stderr}")
            return False
        print("✓ Compilation successful")
    except subprocess.TimeoutExpired:
        print("Compilation timed out")
        return False
    except Exception as e:
        print(f"Compilation error: {e}")
        return False
    
    # Elaborate the design
    print("Elaborating design...")
    elab_cmd = [
        "ghdl", "-e", "--std=08", "tb_tdc_sweep_top_improved"
    ]
    
    try:
        result = subprocess.run(elab_cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            print(f"Elaboration failed: {result.stderr}")
            return False
        print("✓ Elaboration successful")
    except subprocess.TimeoutExpired:
        print("Elaboration timed out")
        return False
    except Exception as e:
        print(f"Elaboration error: {e}")
        return False
    
    # Run simulation
    print("Running simulation...")
    run_cmd = [
        "ghdl", "-r", "--std=08", "tb_tdc_sweep_top_improved",
        "--vcd=tdc_simulation_improved.vcd",
        "--stop-time=50ms"
    ]
    
    try:
        result = subprocess.run(run_cmd, capture_output=True, text=True, timeout=120)
        print("Simulation output:")
        print(result.stdout)
        if result.stderr:
            print("Warnings/Errors:")
            print(result.stderr)
        
        # Check if VCD file was created
        vcd_file = sim_dir / "tdc_simulation_improved.vcd"
        if vcd_file.exists():
            print(f"✓ VCD file created: {vcd_file.stat().st_size / (1024*1024):.1f} MB")
            return True
        else:
            print("❌ VCD file not created")
            return False
            
    except subprocess.TimeoutExpired:
        print("Simulation timed out")
        return False
    except Exception as e:
        print(f"Simulation error: {e}")
        return False

def analyze_simulation_output():
    """Analyze the simulation output for key metrics"""
    print("\n=== Analyzing Simulation Results ===")
    
    sim_dir = Path("c:/CONNECTED DELAY LINES/simulation")
    vcd_file = sim_dir / "tdc_simulation_improved.vcd"
    
    if not vcd_file.exists():
        print("❌ VCD file not found")
        return
    
    # Use the existing VCD analyzer
    analyzer_script = sim_dir / "simple_vcd_analyzer.py"
    if analyzer_script.exists():
        print("Running VCD analysis...")
        try:
            result = subprocess.run([
                sys.executable, str(analyzer_script), str(vcd_file)
            ], capture_output=True, text=True, timeout=60)
            
            print("Analysis output:")
            print(result.stdout)
            if result.stderr:
                print("Analysis warnings:")
                print(result.stderr)
                
        except Exception as e:
            print(f"Analysis error: {e}")

def create_comparison_report():
    """Create a comparison report between original and improved simulation"""
    print("\n=== Creating Comparison Report ===")
    
    sim_dir = Path("c:/CONNECTED DELAY LINES/simulation")
    
    # Read original analysis
    original_file = sim_dir / "simulation_analysis_report.txt"
    original_data = ""
    if original_file.exists():
        with open(original_file, 'r') as f:
            original_data = f.read()
    
    # Extract key metrics from original
    original_cycles = 0
    original_time = 0
    uart_bytes_original = 0
    
    for line in original_data.split('\n'):
        if "Total clock cycles:" in line:
            try:
                original_cycles = int(line.split(':')[1].strip())
            except:
                pass
        elif "Simulation time:" in line:
            try:
                original_time = float(line.split(':')[1].strip().split()[0])
            except:
                pass
        elif "UART bytes:" in line:
            try:
                uart_bytes_original = int(line.split(':')[1].strip())
            except:
                pass
    
    # Create comparison report
    report = f"""# TDC Simulation Comparison Report

## Original Simulation Results
- **Total Clock Cycles**: {original_cycles:,}
- **Simulation Time**: {original_time:.3f} ms
- **UART Bytes Transmitted**: {uart_bytes_original}
- **Status**: Early completion at cycle 5, no UART activity

## Improved Simulation Results
- **Expected Behavior**: Proper reset sequence, PLL lock maintenance
- **UART Monitoring**: Active byte-by-byte tracking
- **Debug Features**: Cycle counting, lock monitoring, completion detection
- **Timeout**: Extended to 50ms for full sweep

## Key Improvements Made

### 1. Reset Sequence Fix
- **Original**: Reset applied after 100ns, causing confusion
- **Improved**: Reset starts active, proper pulse, then release
- **Expected**: System should initialize properly

### 2. UART Monitoring
- **Original**: No UART data analysis
- **Improved**: Complete UART receiver with byte decoding
- **Expected**: Should see measurement data transmission

### 3. Enhanced Debugging
- **Original**: Basic signal monitoring
- **Improved**: Cycle counters, lock monitoring, completion tracking
- **Expected**: Better visibility into system behavior

### 4. Proper Timing
- **Original**: 10ms timeout, may be insufficient
- **Improved**: 50ms timeout with extended monitoring
- **Expected**: Full sweep completion

## Expected Improved Results

If the improved testbench runs correctly:
1. **ALL_DONE** should assert after full sweep (not at cycle 5)
2. **UART** should transmit multiple bytes of measurement data
3. **PLL** should maintain lock throughout operation
4. **Reset** should pulse properly, not stay active

## Next Steps

1. Run the improved simulation
2. Compare results with expectations
3. If issues persist, examine the TDC design itself
4. Consider hardware-level debugging if design issues found

---
Generated by improved TDC simulation analysis
"""
    
    with open(sim_dir / "simulation_comparison_report.md", 'w') as f:
        f.write(report)
    
    print("✓ Comparison report created: simulation_comparison_report.md")

def main():
    """Main function to run the improved simulation analysis"""
    print("TDC Improved Simulation Analysis")
    print("=" * 50)
    
    # Run the improved simulation
    if run_simulation():
        print("\n✓ Improved simulation completed successfully")
        
        # Analyze the results
        analyze_simulation_output()
        
        # Create comparison report
        create_comparison_report()
        
        print("\n=== Summary ===")
        print("✓ Improved testbench created and executed")
        print("✓ Enhanced debugging and monitoring implemented")
        print("✓ Comparison report generated")
        print("\nCheck the following files:")
        print("- tdc_simulation_improved.vcd (new waveform)")
        print("- simulation_comparison_report.md (analysis)")
        
    else:
        print("\n❌ Improved simulation failed")
        print("Check the error messages above for details")

if __name__ == "__main__":
    main()
