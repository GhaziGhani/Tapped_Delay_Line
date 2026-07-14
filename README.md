# Tapped Delay Line TDC

This repository contains a Spartan-6 tapped delay line time-to-digital converter (TDC) project. The main design lives in `fpga_as_slave`, which implements a startup calibration flow that collects a large histogram of asynchronous events, stores the counts in BRAM, and streams the result to a PC over UART for analysis.

## What the project does

The design measures the relative arrival time of an asynchronous pulse against the FPGA clock using a tapped delay line. During calibration mode, the FPGA repeatedly samples an async pulse source, bins the results into a histogram, and later transmits the full histogram to the host.

This makes it possible to estimate:

- bin width variation
- differential non-linearity (DNL)
- integral non-linearity (INL)
- histogram shape and stimulus quality

## Main project flow

The active RTL is centered on `fpga_as_slave/src/tdc_slave_top.vhd` and works like this:

1. `CLK_IN` provides the 50 MHz board clock.
2. The clocking logic generates the internal system clock and calibration clocking resources.
3. On reset, the histogram BRAM is cleared.
4. Calibration mode is enabled and the tapped delay line begins collecting samples.
5. The async pulse source is taken from `EXT_CAL_CLK` on the board pin defined in `fpga_as_slave/constraint/tdc_slave_constraints.ucf`.
6. Each accepted hit increments the histogram through `fpga_as_slave/src/bram_histogrammer.vhd`.
7. When the requested number of samples is reached, the histogram is framed and sent over UART.
8. The host receiver script parses the frame, saves CSV output, and can generate plots.

## How the measurement path works

### 1. Clocking and reset

The board clock enters through `CLK_IN`. The design uses `clk_gen.vhd` and `tdc_calib_pll.vhd` to derive internal clocking and keep the measurement logic synchronized.

### 2. External pulse input

The statistical calibration source is the external async pulse input `EXT_CAL_CLK`.

- FPGA pin: `C10`
- I/O standard: `LVCMOS33`
- Constraint: pulldown enabled so the input does not float when disconnected

The pulse is synchronized and edge-detected inside `tapped_delay_line.vhd` before being used as a valid calibration event.

### 3. Tapped delay line measurement

`tapped_delay_line.vhd` is the core measurement block. It captures the pulse position through the delay chain and produces a packed timing result on `TOTAL_TIME`.

In statistical mode, the design publishes one timing sample per detected async pulse event. That sample is then converted into a histogram bin.

### 4. Histogram accumulation

`bram_histogrammer.vhd` stores counts in BRAM.

- `hit_valid` requests a histogram increment
- `hit_ready` indicates the histogram block can accept the hit
- `hit_accepted` confirms the write was committed

The top-level design increments the sample counter only when a hit is actually accepted, so the sample count matches real memory writes.

### 5. UART frame output

After histogram acquisition finishes, `tdc_slave_top.vhd` streams the results over UART as a framed packet.

Frame structure:

- Sync bytes: `A5 5A`
- Frame type: `C1` for startup calibration histogram
- Version: `01`
- Bin count: 16-bit little-endian
- Payload: 256 bins, 32-bit counts each, little-endian byte order
- Trailer: `55 AA`

## Hardware connections

Use these board connections for the current slave design:

- `CLK_IN` on `T8` for the system clock
- `RST_IN` on `L3` for reset
- `TX` on `D12` for UART transmit to the PC
- `RX` on `C11` for UART receive, reserved for future command handling
- `EXT_CAL_CLK` on `C10` for the external async pulse source

The external pulse source should be a clean 3.3 V CMOS-level signal with a common ground shared with the FPGA board.

## Repository layout

The useful project files are grouped under `fpga_as_slave`:

- `fpga_as_slave/src/` - VHDL sources for the TDC, clocking, UART, and histogram logic
- `fpga_as_slave/constraint/tdc_slave_constraints.ucf` - pin mappings and timing/placement constraints
- `fpga_as_slave/FPGA_as_slave/` - ISE project files and implementation results
- `fpga_as_slave/tdc_startup_cal_rx.py` - host-side receiver for histogram frames

Supporting simulation and analysis files are in `simulation/`.

## Simulation and analysis files

The simulation folder includes testbenches and helper scripts for checking the design without hardware:

- `simulation/tb_tdc_behavioral.vhd`
- `simulation/tb_tdc_sweep_top_improved.vhd`
- `simulation/tdc_sweep_top_fixed.vhd`
- `simulation/phase_sweep_fixed.vhd`
- `simulation/run_ghdl_sim.ps1`
- `simulation/launch_gtkwave_oss.bat`

These files are useful for verifying timing behavior, UART output, and the startup calibration sequence.

## Building the FPGA design

The project targets Xilinx ISE 14.7 and Spartan-6.

Typical workflow:

1. Open `fpga_as_slave/FPGA_as_slave/FPGA_as_slave.xise` in ISE.
2. Run synthesis, mapping, place-and-route, and bitstream generation.
3. Program the FPGA with the generated bitstream.

If the router reports unroutable nets, check `fpga_as_slave/constraint/tdc_slave_constraints.ucf` first. The TDC carry-chain placement is intentionally tight, so overly restrictive AREA_GROUP ranges can block routing.

## Reading the histogram on the PC

The host receiver is `fpga_as_slave/tdc_startup_cal_rx.py`.

It is used to:

- receive the startup calibration frame
- decode the bin counts
- save CSV output
- compute calibration metrics
- generate plots

## Notes on current behavior

- The design is intended to operate in startup calibration mode by default.
- If `EXT_CAL_CLK` is disconnected, the pulldown keeps it from floating.
- Continuous LED activity usually means the state machine is acquiring samples or retransmitting the histogram frame.
- The top-level project is `fpga_as_slave`; the other top-level workspace folders are not part of the main FPGA design.

## Files worth reading first

- `fpga_as_slave/src/tdc_slave_top.vhd`
- `fpga_as_slave/src/tapped_delay_line.vhd`
- `fpga_as_slave/src/bram_histogrammer.vhd`
- `fpga_as_slave/constraint/tdc_slave_constraints.ucf`
- `fpga_as_slave/tdc_startup_cal_rx.py`

## Summary

This project is a TDC calibration system built around a tapped delay line, a BRAM-based histogrammer, and a UART streaming interface. It measures an external async pulse source, bins the results, and sends the histogram to a PC for analysis.