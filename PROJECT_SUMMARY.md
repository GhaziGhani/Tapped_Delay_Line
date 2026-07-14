Project: CONNECTED DELAY LINES (TDC calibration)

Overview
- Purpose: FPGA-based tapped delay line (TDC) project for statistical calibration using code-density histograms. Collects many asynchronous hits, stores counts in BRAM, and streams histogram frames over UART to a PC receiver for DNL/INL analysis.
- Target device: Xilinx Spartan-6 (ISE 14.7 flow).

Key folders and files
- `fpga_as_slave/` — main FPGA project and source.
  - `src/` — VHDL sources (tdc_slave_top.vhd, tapped_delay_line.vhd, bram_histogrammer.vhd, tdc_calib_pll.vhd, clk_gen.vhd, uart_tx.vhd, etc.).
  - `constraint/tdc_slave_constraints.ucf` — pin mappings and timing/area constraints (includes EXT_CAL_CLK pin C10).
  - `FPGA_as_slave/` — ISE project files (.prj, .xise, .mrp, .par outputs).
  - `tdc_startup_cal_rx.py` — host Python receiver for startup histogram frames (CSV export, plotting).

Important behavior & recent changes
- Startup calibration flow: on reset the design clears BRAM, then enables calibration mode and accumulates `CAL_SAMPLES` samples (default 32768). When done, it streams a framed histogram (`C1`) over UART.
- External async pulse support: added `EXT_CAL_CLK` input (UCF pin C10) and pulldown to avoid floating. The tapped delay line `tapped_delay_line.vhd` now synchronizes and edge-detects this external pulse for statistical sampling.
- Histogram BRAM: `bram_histogrammer.vhd` provides one-deep buffering and `hit_accepted` handshake used to increment `sample_count` only when writes commit.
- Constraint adjustments: area-group placement previously over-constrained carry chains; a diagnosis identifies overlapping AREA_GROUP ranges (TDC_FINE_*/TDC_STOP_*) as the primary cause of unroutable PAR errors.

Build & test notes
- Synthesis/build: use the provided Makefile and `scripts/build.sh` (ISE CLI) on a machine with ISE 14.7. On Windows, use the ISE toolchain; make targets: `make synth`, `make map`, `make par`, `make bitgen`.

