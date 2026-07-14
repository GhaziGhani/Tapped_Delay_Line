"""
tdc_analyzer.py (FIXED - handles zero bin widths and degenerate data)
"""

import serial
import struct
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.gridspec import GridSpec
import argparse
import sys
import time
import csv
import os
from datetime import datetime
from collections import deque


DEFAULT_PORT = 'COM11'
DEFAULT_BAUD = 115200
PACKET_SIZE = 19
START_MARKER = 0xAA
END_MARKER = 0x55
DEFAULT_PHASES = 32
DEFAULT_VALUE_FORMAT = 'auto'

RAW_CSV = 'tdc_raw_data.csv'
DNL_INL_CSV = 'tdc_dnl_inl.csv'
BIN_WIDTH_CSV = 'tdc_bin_widths.csv'
SUMMARY_CSV = 'tdc_summary.csv'
PLOT_FILE = 'tdc_dnl_inl.png'
MATRIX_LOG_CSV = 'tdc_matrix_results.csv'


class TDCPacket:
    def __init__(self, phase, min_val, max_val, sum_val, count, value_format='auto'):
        self.phase = phase
        self.min = min_val
        self.max = max_val
        self.sum = sum_val
        self.count = count
        self.average = sum_val / count if count > 0 else 0

        if value_format == 'auto':
            # Packed words usually have non-zero bits above bit 15.
            if (min_val & 0xFFFF0000) != 0 or (max_val & 0xFFFF0000) != 0:
                self.value_format = 'packed32'
            else:
                self.value_format = 'raw32'
        else:
            self.value_format = value_format

        # Debug fields are still useful even in raw32 mode.
        self.dbg_coarse_min = (min_val >> 26) & 0x3F
        self.dbg_coarse_max = (max_val >> 26) & 0x3F
        self.dbg_fine_min = (min_val >> 16) & 0x3FF
        self.dbg_fine_max = (max_val >> 16) & 0x3FF

        if self.value_format == 'packed32':
            # Packed format: [31:26]=coarse, [25:16]=fine, [15:0]=tap total.
            self.code_min = min_val & 0xFFFF
            self.code_max = max_val & 0xFFFF
            self.code_average = self.average % 65536
            self.code_average_mid = (self.code_min + self.code_max) / 2.0
        else:
            # Raw32 format: min/max/sum already represent direct code values.
            self.code_min = min_val
            self.code_max = max_val
            self.code_average = self.average
            self.code_average_mid = (self.code_min + self.code_max) / 2.0

        self.spread = self.code_max - self.code_min

    def __repr__(self):
        return (f"Phase {self.phase:3d}: "
            f"fmt={self.value_format:8s} "
                f"code=[{self.code_min:5d},{self.code_max:5d}] "
                f"avg={self.code_average:8.2f} spread={self.spread:4d} "
                f"fine=[{self.dbg_fine_min:3d},{self.dbg_fine_max:3d}] "
                f"count={self.count}")


def decode_packet(data, value_format='auto'):
    if len(data) != PACKET_SIZE:
        return None
    if data[0] != START_MARKER or data[18] != END_MARKER:
        return None
    phase = data[1]
    min_val = struct.unpack('>I', data[2:6])[0]
    max_val = struct.unpack('>I', data[6:10])[0]
    sum_val = int.from_bytes(data[10:16], byteorder='big', signed=False)
    count = struct.unpack('>H', data[16:18])[0]
    return TDCPacket(phase, min_val, max_val, sum_val, count, value_format=value_format)


class TDCReceiver:
    def __init__(self, port, baudrate, expected_phases, value_format='auto'):
        self.port = port
        self.baudrate = baudrate
        self.expected_phases = expected_phases
        self.value_format = value_format
        self.ser = None

    def open(self):
        try:
            self.ser = serial.Serial(
                port=self.port, baudrate=self.baudrate,
                bytesize=serial.EIGHTBITS, parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE, timeout=2.0
            )
            print(f"Opened {self.port} at {self.baudrate} baud")
            time.sleep(0.5)
            self.ser.reset_input_buffer()
            return True
        except serial.SerialException as e:
            print(f"Failed to open {self.port}: {e}")
            return False

    def close(self):
        if self.ser and self.ser.is_open:
            self.ser.close()
            print("Serial port closed")

    def find_start_marker(self):
        discarded = 0
        while True:
            byte = self.ser.read(1)
            if len(byte) == 0:
                return False
            if byte[0] == START_MARKER:
                return True
            discarded += 1

    def read_packet(self):
        if not self.find_start_marker():
            return None
        packet = bytearray([START_MARKER])
        remaining = self.ser.read(PACKET_SIZE - 1)
        if len(remaining) != PACKET_SIZE - 1:
            return None
        packet.extend(remaining)
        if packet[18] != END_MARKER:
            return None
        return bytes(packet)

    def receive_all_phases(self):
        packets = {}
        received_count = 0
        start_time = time.time()
        print(f"\nWaiting for {self.expected_phases} phase measurements...")
        print("Press Ctrl+C to stop early.\n")
        try:
            timeout_count = 0
            while received_count < self.expected_phases:
                raw = self.read_packet()
                if raw is None:
                    timeout_count += 1
                    if timeout_count > 10:
                        print("\n10 consecutive timeouts. Stopping.")
                        break
                    continue
                timeout_count = 0
                pkt = decode_packet(raw, value_format=self.value_format)
                if pkt is None:
                    continue
                if pkt.phase >= self.expected_phases:
                    continue
                if pkt.phase not in packets:
                    received_count += 1
                packets[pkt.phase] = pkt
                elapsed = time.time() - start_time
                pct = 100 * received_count / self.expected_phases
                print(f"  [{received_count:3d}/{self.expected_phases}] "
                      f"({pct:5.1f}%) {pkt}  [{elapsed:.1f}s]")
        except KeyboardInterrupt:
            print("\n\nInterrupted by user.")
        result = [packets[i] for i in sorted(packets.keys())]
        print(f"\nReceived {len(result)} unique phases")
        return result


def save_raw_csv(packets, filename):
    with open(filename, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow([
            'phase', 'min', 'max', 'sum', 'count', 'average', 'spread',
            'code_min', 'code_max', 'code_average',
            'code_average_mid', 'value_format',
            'dbg_coarse_min', 'dbg_coarse_max',
            'dbg_fine_min', 'dbg_fine_max'
        ])
        for p in packets:
            writer.writerow([p.phase, p.min, p.max, p.sum, p.count,
                             f'{p.average:.4f}', p.spread,
                             p.code_min, p.code_max, f'{p.code_average:.4f}',
                             f'{p.code_average_mid:.4f}', p.value_format,
                             p.dbg_coarse_min, p.dbg_coarse_max,
                             p.dbg_fine_min, p.dbg_fine_max])
    print(f"Raw data saved:       {filename}")


def save_dnl_inl_csv(calc, filename):
    with open(filename, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['bin', 'phase_start', 'phase_end',
                         'bin_width_taps', 'ideal_bin_width_taps',
                         'dnl_lsb', 'inl_lsb'])
        for i in range(len(calc.dnl)):
            writer.writerow([
                i, calc.phases[i], calc.phases[i + 1],
                f'{calc.bin_widths[i]:.4f}',
                f'{calc.ideal_bin_width:.4f}',
                f'{calc.dnl[i]:.6f}',
                f'{calc.inl[i + 1]:.6f}'
            ])
    print(f"DNL/INL data saved:   {filename}")


def save_bin_width_csv(calc, filename):
    with open(filename, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['bin', 'bin_width_taps', 'bin_width_ps',
                         'deviation_from_ideal_taps', 'deviation_from_ideal_ps'])
        ps_per_step = 78.125
        for i in range(len(calc.bin_widths)):
            width = calc.bin_widths[i]
            deviation = width - calc.ideal_bin_width
            if calc.ideal_bin_width != 0:
                width_ps = width * ps_per_step / abs(calc.ideal_bin_width)
                dev_ps = deviation * ps_per_step / abs(calc.ideal_bin_width)
            else:
                width_ps = 0
                dev_ps = 0
            writer.writerow([i, f'{width:.4f}', f'{width_ps:.2f}',
                             f'{deviation:.4f}', f'{dev_ps:.2f}'])
    print(f"Bin widths saved:     {filename}")


def save_summary_csv(calc, packets, filename):
    summary = calc.get_summary()
    with open(filename, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['parameter', 'value', 'unit'])
        writer.writerow(['timestamp', datetime.now().isoformat(), ''])
        writer.writerow(['num_phases', len(packets), ''])
        writer.writerow(['num_bins', summary.get('num_bins', 0), ''])
        writer.writerow(['tests_per_phase', packets[0].count if packets else 0, ''])
        for key in ['total_range', 'ideal_bin_width']:
            writer.writerow([key, f"{summary.get(key, 0):.4f}", 'taps'])
        for key in ['dnl_min', 'dnl_max', 'dnl_mean', 'dnl_std',
                     'inl_min', 'inl_max', 'inl_std']:
            val = summary.get(key, 0)
            if np.isfinite(val):
                writer.writerow([key, f"{val:.6f}", 'LSB'])
            else:
                writer.writerow([key, 'N/A', 'LSB'])
        writer.writerow(['missing_codes', summary.get('missing_codes', 0), ''])
        writer.writerow(['data_quality', summary.get('data_quality', 'UNKNOWN'), ''])
    print(f"Summary saved:        {filename}")


def to_finite_float(value, default=np.nan):
    try:
        val = float(value)
        if np.isfinite(val):
            return val
    except (TypeError, ValueError):
        pass
    return default


def compute_matrix_score(summary):
    """Lower score is better. Penalize missing codes and non-OK quality heavily."""
    quality = str(summary.get('data_quality', 'UNKNOWN')).upper()
    missing_codes = int(summary.get('missing_codes', 0))

    dnl_std = abs(to_finite_float(summary.get('dnl_std'), default=1e6))
    inl_std = abs(to_finite_float(summary.get('inl_std'), default=1e6))
    inl_min = abs(to_finite_float(summary.get('inl_min'), default=1e6))
    inl_max = abs(to_finite_float(summary.get('inl_max'), default=1e6))
    inl_span = inl_min + inl_max

    quality_penalty = 0.0 if quality == 'OK' else 1000.0
    return quality_penalty + 100.0 * missing_codes + 4.0 * dnl_std + 2.0 * inl_std + 0.05 * inl_span


def ensure_matrix_log_schema(filename, fieldnames):
    if not os.path.exists(filename) or os.path.getsize(filename) == 0:
        return

    with open(filename, 'r', newline='') as f:
        reader = csv.DictReader(f)
        existing_fields = reader.fieldnames or []
        if existing_fields == fieldnames:
            return
        existing_rows = [row for row in reader]

    with open(filename, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for row in existing_rows:
            migrated = {k: row.get(k, '') for k in fieldnames}
            writer.writerow(migrated)

    print(f"Matrix log schema migrated: {filename}")


def append_matrix_log(filename, calc_summary, packets, args, run_timestamp, sum_csv):
    fields = [
        'timestamp', 'run_tag',
        'cfg_stop_delay', 'cfg_phase_steps', 'cfg_use_nccc', 'cfg_use_cal_lut', 'cfg_taps', 'cfg_taps_per_cnt',
        'num_phases', 'tests_per_phase', 'missing_codes', 'data_quality',
        'dnl_min', 'dnl_max', 'dnl_std',
        'inl_min', 'inl_max', 'inl_std',
        'total_range', 'ideal_bin_width',
        'score', 'summary_csv'
    ]

    row = {
        'timestamp': run_timestamp,
        'run_tag': args.run_tag or '',
        'cfg_stop_delay': '' if args.cfg_stop_delay is None else args.cfg_stop_delay,
        'cfg_phase_steps': '' if args.cfg_phase_steps is None else args.cfg_phase_steps,
        'cfg_use_nccc': '' if args.cfg_use_nccc is None else args.cfg_use_nccc,
        'cfg_use_cal_lut': '' if args.cfg_use_cal_lut is None else args.cfg_use_cal_lut,
        'cfg_taps': '' if args.cfg_taps is None else args.cfg_taps,
        'cfg_taps_per_cnt': '' if args.cfg_taps_per_cnt is None else args.cfg_taps_per_cnt,
        'num_phases': len(packets),
        'tests_per_phase': packets[0].count if packets else 0,
        'missing_codes': int(calc_summary.get('missing_codes', 0)),
        'data_quality': calc_summary.get('data_quality', 'UNKNOWN'),
        'dnl_min': f"{to_finite_float(calc_summary.get('dnl_min'), default=0.0):.6f}",
        'dnl_max': f"{to_finite_float(calc_summary.get('dnl_max'), default=0.0):.6f}",
        'dnl_std': f"{to_finite_float(calc_summary.get('dnl_std'), default=0.0):.6f}",
        'inl_min': f"{to_finite_float(calc_summary.get('inl_min'), default=0.0):.6f}",
        'inl_max': f"{to_finite_float(calc_summary.get('inl_max'), default=0.0):.6f}",
        'inl_std': f"{to_finite_float(calc_summary.get('inl_std'), default=0.0):.6f}",
        'total_range': f"{to_finite_float(calc_summary.get('total_range'), default=0.0):.4f}",
        'ideal_bin_width': f"{to_finite_float(calc_summary.get('ideal_bin_width'), default=0.0):.4f}",
        'score': f"{compute_matrix_score(calc_summary):.6f}",
        'summary_csv': sum_csv,
    }

    ensure_matrix_log_schema(filename, fields)

    write_header = not os.path.exists(filename) or os.path.getsize(filename) == 0
    with open(filename, 'a', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        if write_header:
            writer.writeheader()
        writer.writerow(row)

    print(f"Matrix log updated:   {filename}")
    print(f"Matrix score:         {row['score']} (lower is better)")


def rank_matrix_log(filename, top_n=8):
    if not os.path.exists(filename):
        print(f"Matrix log not found: {filename}")
        return False

    rows = []
    with open(filename, 'r', newline='') as f:
        reader = csv.DictReader(f)
        for row in reader:
            score = to_finite_float(row.get('score'), default=np.inf)
            if not np.isfinite(score):
                score = np.inf
            row['_score_num'] = score
            rows.append(row)

    if not rows:
        print(f"Matrix log is empty:  {filename}")
        return False

    rows.sort(key=lambda r: r['_score_num'])
    limit = max(1, min(top_n, len(rows)))

    print(f"\n{'=' * 92}")
    print("  MATRIX RANKING (lower score is better)")
    print(f"{'=' * 92}")
    print(f"{'rank':>4}  {'score':>10}  {'quality':>10}  {'miss':>4}  {'dnl_std':>8}  {'inl_std':>8}  {'stop':>4}  {'steps':>5}  run_tag")
    for idx, row in enumerate(rows[:limit], start=1):
        print(
            f"{idx:4d}  "
            f"{row.get('score', 'N/A'):>10}  "
            f"{row.get('data_quality', 'N/A'):>10}  "
            f"{row.get('missing_codes', 'N/A'):>4}  "
            f"{row.get('dnl_std', 'N/A'):>8}  "
            f"{row.get('inl_std', 'N/A'):>8}  "
            f"{row.get('cfg_stop_delay', 'N/A'):>4}  "
            f"{row.get('cfg_phase_steps', 'N/A'):>5}  "
            f"{row.get('run_tag', '')}"
        )
    print(f"{'=' * 92}")
    return True


def print_matrix_template():
    print("\nRecommended stage-1 matrix (NCCC fixed, TAPS=200):")
    print("  STOP_DELAY in {2, 3, 4}")
    print("  PHASE_STEPS in {24, 32, 40}")
    print("  Total runs: 9")
    print("\nRun tags:")
    for stop_delay in [2, 3, 4]:
        for phase_steps in [24, 32, 40]:
            print(f"  sd{stop_delay}_ph{phase_steps}")


def load_raw_csv(filename, value_format='auto'):
    packets = []
    with open(filename, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            pkt = TDCPacket(
                phase=int(row['phase']), min_val=int(row['min']),
                max_val=int(row['max']), sum_val=int(row['sum']),
                count=int(row['count']), value_format=value_format
            )
            packets.append(pkt)
    print(f"Loaded {len(packets)} phases from: {filename}")
    return packets


class DNLINLCalculator:
    def __init__(self, packets):
        self.packets = sorted(packets, key=lambda p: p.phase)
        self.phases = np.array([p.phase for p in self.packets])
        self.averages = np.array([p.code_average for p in self.packets])
        self.counts = np.array([p.count for p in self.packets])
        self.mins = np.array([p.code_min for p in self.packets])
        self.maxs = np.array([p.code_max for p in self.packets])
        self.spreads = np.array([p.spread for p in self.packets])
        self.debug_coarse = np.array([p.dbg_coarse_min for p in self.packets])
        self.debug_fine = np.array([p.dbg_fine_min for p in self.packets])

        self.bin_widths = None
        self.ideal_bin_width = None
        self.dnl = None
        self.inl = None
        self.data_quality = "UNKNOWN"

        self._compute()

    def _compute(self):
        n = len(self.averages)
        if n < 2:
            print("Error: need at least 2 phase measurements")
            return

        self.bin_widths = np.diff(self.averages)

        total_range = self.averages[-1] - self.averages[0]
        num_bins = n - 1

        # Check for degenerate data
        unique_values = len(np.unique(np.round(self.averages, 1)))
        non_zero_bins = np.sum(np.abs(self.bin_widths) > 0.01)

        print(f"\n{'='*60}")
        print(f"  TDC DATA ANALYSIS")
        print(f"{'='*60}")
        print(f"  Phases received:     {n}")
        print(f"  Unique avg values:   {unique_values}")
        print(f"  Non-zero bin widths: {non_zero_bins} / {num_bins}")
        print(f"  Total range:         {total_range:.2f} taps")
        print(f"  Average range:       [{self.averages.min():.2f}, {self.averages.max():.2f}]")
        print(f"  Spread range:        [{self.spreads.min()}, {self.spreads.max()}]")
        print(f"  Debug coarse range:  [{self.debug_coarse.min()}, {self.debug_coarse.max()}]")
        print(f"  Debug fine range:    [{self.debug_fine.min()}, {self.debug_fine.max()}]")

        if total_range == 0:
            print(f"\n  *** ALL PHASES RETURN SAME VALUE ***")
            print(f"  *** TDC is not measuring phase changes ***")
            self.data_quality = "STUCK"
            self.ideal_bin_width = 1.0
            self.dnl = np.zeros(num_bins)
            self.inl = np.zeros(n)
            return

        if unique_values <= 3:
            print(f"\n  *** ONLY {unique_values} UNIQUE VALUES ***")
            print(f"  *** TDC has no fine resolution (only coarse) ***")
            self.data_quality = "COARSE_ONLY"
        elif non_zero_bins < num_bins * 0.3:
            print(f"\n  *** MOST BINS ARE ZERO WIDTH ***")
            print(f"  *** Fine time not varying with phase ***")
            self.data_quality = "MOSTLY_STUCK"
        else:
            self.data_quality = "OK"

        self.ideal_bin_width = total_range / num_bins

        if abs(self.ideal_bin_width) < 1e-10:
            self.ideal_bin_width = 1.0

        self.dnl = (self.bin_widths - self.ideal_bin_width) / self.ideal_bin_width

        # Clamp extreme values to prevent plotting issues
        max_dnl = 10.0
        self.dnl = np.clip(self.dnl, -max_dnl, max_dnl)

        self.inl = np.concatenate(([0], np.cumsum(self.dnl)))

        # Replace any remaining inf/nan
        self.dnl = np.nan_to_num(self.dnl, nan=0.0, posinf=max_dnl, neginf=-max_dnl)
        self.inl = np.nan_to_num(self.inl, nan=0.0, posinf=100.0, neginf=-100.0)

        print(f"")
        print(f"  Ideal bin width:     {self.ideal_bin_width:.4f} taps")
        print(f"  DNL range:           [{self.dnl.min():.4f}, {self.dnl.max():.4f}] LSB")
        print(f"  INL range:           [{self.inl.min():.4f}, {self.inl.max():.4f}] LSB")
        print(f"  Data quality:        {self.data_quality}")
        print(f"{'='*60}")

    def get_summary(self):
        if self.dnl is None:
            return {'data_quality': self.data_quality}

        finite_dnl = self.dnl[np.isfinite(self.dnl)]
        finite_inl = self.inl[np.isfinite(self.inl)]

        return {
            'num_bins': len(self.bin_widths),
            'ideal_bin_width': self.ideal_bin_width,
            'total_range': self.averages[-1] - self.averages[0],
            'dnl_min': finite_dnl.min() if len(finite_dnl) > 0 else 0,
            'dnl_max': finite_dnl.max() if len(finite_dnl) > 0 else 0,
            'dnl_mean': finite_dnl.mean() if len(finite_dnl) > 0 else 0,
            'dnl_std': finite_dnl.std() if len(finite_dnl) > 0 else 0,
            'inl_min': finite_inl.min() if len(finite_inl) > 0 else 0,
            'inl_max': finite_inl.max() if len(finite_inl) > 0 else 0,
            'inl_std': finite_inl.std() if len(finite_inl) > 0 else 0,
            'missing_codes': int(np.sum(np.abs(self.bin_widths) < 0.01)),
            'data_quality': self.data_quality
        }


class TDCPlotter:
    def __init__(self, calc):
        self.calc = calc

    def _safe_hist(self, ax, data, **kwargs):
        """Histogram that handles degenerate data."""
        finite_data = data[np.isfinite(data)]
        if len(finite_data) == 0:
            ax.text(0.5, 0.5, 'No finite data', transform=ax.transAxes,
                    ha='center', va='center', fontsize=12, color='red')
            return

        data_range = finite_data.max() - finite_data.min()
        if data_range < 1e-10:
            # All values are the same — show a single bar
            val = finite_data[0]
            ax.bar([val], [len(finite_data)], width=max(abs(val) * 0.1, 0.1),
                   color=kwargs.get('color', 'blue'), alpha=kwargs.get('alpha', 0.7))
            ax.set_xlim(val - 1, val + 1)
            return

        bins = min(kwargs.pop('bins', 50), max(int(len(finite_data) / 3), 5))
        ax.hist(finite_data, bins=bins, **kwargs)

    def plot_all(self, filename=None):
        fig = plt.figure(figsize=(18, 10))
        gs = GridSpec(2, 3, figure=fig, hspace=0.35, wspace=0.3)

        ax_dnl = fig.add_subplot(gs[0, 0])
        ax_dnl_hist = fig.add_subplot(gs[0, 1])
        ax_bin_hist = fig.add_subplot(gs[0, 2])
        ax_inl = fig.add_subplot(gs[1, 0])
        ax_inl_hist = fig.add_subplot(gs[1, 1])
        ax_raw = fig.add_subplot(gs[1, 2])

        self._plot_dnl(ax_dnl)
        self._plot_dnl_histogram(ax_dnl_hist)
        self._plot_bin_histogram(ax_bin_hist)
        self._plot_inl(ax_inl)
        self._plot_inl_histogram(ax_inl_hist)
        self._plot_raw(ax_raw)

        summary = self.calc.get_summary()
        quality = summary.get('data_quality', 'UNKNOWN')
        title_color = 'red' if quality != 'OK' else 'black'

        fig.suptitle(
            f"TDC Analysis  |  Quality: {quality}  |  "
            f"DNL: [{summary.get('dnl_min', 0):.3f}, {summary.get('dnl_max', 0):.3f}] LSB  |  "
            f"INL: [{summary.get('inl_min', 0):.3f}, {summary.get('inl_max', 0):.3f}] LSB",
            fontsize=13, fontweight='bold', color=title_color
        )

        if filename:
            plt.savefig(filename, dpi=150, bbox_inches='tight')
            print(f"Plot saved:           {filename}")

        plt.show()

    def _plot_dnl(self, ax):
        if self.calc.dnl is None or len(self.calc.dnl) == 0:
            ax.text(0.5, 0.5, 'No DNL data', transform=ax.transAxes,
                    ha='center', va='center')
            return
        bins = np.arange(len(self.calc.dnl))
        colors = ['red' if abs(d) > 0.5 else 'blue' for d in self.calc.dnl]
        ax.bar(bins, self.calc.dnl, color=colors, width=1.0, alpha=0.7)
        ax.axhline(0, color='k', linestyle='-', linewidth=0.8)
        ax.axhline(0.5, color='r', linestyle='--', linewidth=0.8, alpha=0.5)
        ax.axhline(-0.5, color='r', linestyle='--', linewidth=0.8, alpha=0.5)
        ax.grid(True, alpha=0.3)
        ax.set_xlabel('Bin Number')
        ax.set_ylabel('DNL (LSB)')
        ax.set_title('Differential Non-Linearity (DNL)')

    def _plot_dnl_histogram(self, ax):
        if self.calc.dnl is None or len(self.calc.dnl) == 0:
            ax.text(0.5, 0.5, 'No DNL data', transform=ax.transAxes,
                    ha='center', va='center')
            return
        self._safe_hist(ax, self.calc.dnl, bins=50, color='blue',
                        alpha=0.7, edgecolor='black', linewidth=0.5)
        ax.axvline(0, color='red', linestyle='--', linewidth=1.5,
                   label='Ideal (0 LSB)')
        ax.grid(True, alpha=0.3, axis='y')
        ax.set_xlabel('DNL (LSB)')
        ax.set_ylabel('Count')
        ax.set_title('DNL Distribution')
        ax.legend(fontsize=8)

    def _plot_bin_histogram(self, ax):
        if self.calc.bin_widths is None or len(self.calc.bin_widths) == 0:
            ax.text(0.5, 0.5, 'No bin width data', transform=ax.transAxes,
                    ha='center', va='center')
            return
        finite_bw = self.calc.bin_widths[np.isfinite(self.calc.bin_widths)]
        if len(finite_bw) == 0:
            ax.text(0.5, 0.5, 'No finite bin widths', transform=ax.transAxes,
                    ha='center', va='center')
            return
        self._safe_hist(ax, finite_bw, bins=50, color='green',
                        alpha=0.7, edgecolor='black', linewidth=0.5)
        if np.isfinite(self.calc.ideal_bin_width):
            ax.axvline(self.calc.ideal_bin_width, color='red', linestyle='--',
                       linewidth=1.5,
                       label=f'Ideal ({self.calc.ideal_bin_width:.2f})')
        ax.grid(True, alpha=0.3, axis='y')
        ax.set_xlabel('Bin Width (taps)')
        ax.set_ylabel('Count')
        ax.set_title('Bin Width Distribution')
        ax.legend(fontsize=8)

    def _plot_inl(self, ax):
        if self.calc.inl is None or len(self.calc.inl) == 0:
            ax.text(0.5, 0.5, 'No INL data', transform=ax.transAxes,
                    ha='center', va='center')
            return
        bins = np.arange(len(self.calc.inl))
        ax.plot(bins, self.calc.inl, 'r.-', linewidth=0.8, markersize=3)
        ax.axhline(0, color='k', linestyle='-', linewidth=0.8)
        ax.fill_between(bins, self.calc.inl, alpha=0.1, color='red')
        ax.grid(True, alpha=0.3)
        ax.set_xlabel('Bin Number')
        ax.set_ylabel('INL (LSB)')
        ax.set_title('Integral Non-Linearity (INL)')

    def _plot_inl_histogram(self, ax):
        if self.calc.inl is None or len(self.calc.inl) == 0:
            ax.text(0.5, 0.5, 'No INL data', transform=ax.transAxes,
                    ha='center', va='center')
            return
        self._safe_hist(ax, self.calc.inl, bins=50, color='red',
                        alpha=0.7, edgecolor='black', linewidth=0.5)
        ax.axvline(0, color='blue', linestyle='--', linewidth=1.5,
                   label='Ideal (0 LSB)')
        ax.grid(True, alpha=0.3, axis='y')
        ax.set_xlabel('INL (LSB)')
        ax.set_ylabel('Count')
        ax.set_title('INL Distribution')
        ax.legend(fontsize=8)

    def _plot_raw(self, ax):
        ax.plot(self.calc.phases, self.calc.averages, 'ko-',
                linewidth=1, markersize=3, label='Average')
        ax.fill_between(self.calc.phases, self.calc.mins, self.calc.maxs,
                         alpha=0.15, color='blue', label='Min/Max range')

        # Only draw ideal line if range is non-zero
        total_range = self.calc.averages[-1] - self.calc.averages[0]
        if abs(total_range) > 0.01:
            ideal_line = np.linspace(self.calc.averages[0],
                                      self.calc.averages[-1],
                                      len(self.calc.phases))
            ax.plot(self.calc.phases, ideal_line, 'g--', linewidth=1,
                    alpha=0.7, label='Ideal linear')

        ax.grid(True, alpha=0.3)
        ax.set_xlabel('Phase Step')
        ax.set_ylabel('TDC Code (taps)')
        ax.set_title('TDC Transfer Function')
        ax.legend(fontsize=8)


def main():
    parser = argparse.ArgumentParser(description='TDC DNL/INL Analyzer')
    parser.add_argument('--port', default=DEFAULT_PORT)
    parser.add_argument('--baud', type=int, default=DEFAULT_BAUD)
    parser.add_argument('--phases', type=int, default=DEFAULT_PHASES)
    parser.add_argument('--load', default=None, metavar='CSV_FILE')
    parser.add_argument('--value-format', choices=['auto', 'packed32', 'raw32'],
                        default=DEFAULT_VALUE_FORMAT,
                        help='Interpret incoming 32-bit min/max values')
    parser.add_argument('--outdir', default='.')
    parser.add_argument('--no-plot', action='store_true')
    parser.add_argument('--matrix-template', action='store_true',
                        help='Print recommended STOP_DELAY x PHASE_STEPS matrix and exit')
    parser.add_argument('--matrix-log', default=None, metavar='CSV_FILE',
                        help='Append this run to matrix log CSV (default: <outdir>/tdc_matrix_results.csv when any cfg metadata is provided)')
    parser.add_argument('--matrix-rank', action='store_true',
                        help='Rank runs in matrix log CSV and exit')
    parser.add_argument('--matrix-top', type=int, default=8,
                        help='Top N rows to print for --matrix-rank')
    parser.add_argument('--run-tag', default='',
                        help='Label for this run, e.g. sd3_ph32')
    parser.add_argument('--cfg-stop-delay', type=int, default=None,
                        help='Metadata only: RTL STOP_DELAY used for this run')
    parser.add_argument('--cfg-phase-steps', type=int, default=None,
                        help='Metadata only: RTL PHASE_STEPS used for this run')
    parser.add_argument('--cfg-use-nccc', choices=['true', 'false'], default=None,
                        help='Metadata only: RTL USE_NCCC used for this run')
    parser.add_argument('--cfg-use-cal-lut', choices=['true', 'false'], default=None,
                        help='Metadata only: RTL USE_CAL_LUT used for this run')
    parser.add_argument('--cfg-taps', type=int, default=None,
                        help='Metadata only: RTL TAPS used for this run')
    parser.add_argument('--cfg-taps-per-cnt', type=int, default=None,
                        help='Metadata only: RTL TAPS_PER_CNT used for this run')
    args = parser.parse_args()

    if args.matrix_template:
        print_matrix_template()
        sys.exit(0)

    if args.outdir != '.' and not os.path.exists(args.outdir):
        os.makedirs(args.outdir)

    raw_csv = os.path.join(args.outdir, RAW_CSV)
    dnl_inl_csv = os.path.join(args.outdir, DNL_INL_CSV)
    bin_csv = os.path.join(args.outdir, BIN_WIDTH_CSV)
    sum_csv = os.path.join(args.outdir, SUMMARY_CSV)
    plot_file = os.path.join(args.outdir, PLOT_FILE)
    matrix_log_csv = args.matrix_log if args.matrix_log else os.path.join(args.outdir, MATRIX_LOG_CSV)

    if args.matrix_rank:
        ok = rank_matrix_log(matrix_log_csv, top_n=args.matrix_top)
        sys.exit(0 if ok else 1)

    if args.load:
        if not os.path.exists(args.load):
            print(f"File not found: {args.load}")
            sys.exit(1)
        packets = load_raw_csv(args.load, value_format=args.value_format)
    else:
        receiver = TDCReceiver(args.port, args.baud, args.phases,
                               value_format=args.value_format)
        if not receiver.open():
            sys.exit(1)
        try:
            packets = receiver.receive_all_phases()
        finally:
            receiver.close()

    if len(packets) < 2:
        print("\nNot enough data.")
        sys.exit(1)

    save_raw_csv(packets, raw_csv)

    formats_seen = sorted(set(p.value_format for p in packets))
    print(f"Value format used:    {', '.join(formats_seen)}")

    calc = DNLINLCalculator(packets)

    if calc.dnl is not None:
        save_dnl_inl_csv(calc, dnl_inl_csv)
        save_bin_width_csv(calc, bin_csv)
    save_summary_csv(calc, packets, sum_csv)

    summary = calc.get_summary()
    meta_present = any([
        args.run_tag,
        args.cfg_stop_delay is not None,
        args.cfg_phase_steps is not None,
        args.cfg_use_nccc is not None,
        args.cfg_use_cal_lut is not None,
        args.cfg_taps is not None,
        args.cfg_taps_per_cnt is not None,
        args.matrix_log is not None,
    ])
    if meta_present:
        append_matrix_log(
            matrix_log_csv,
            summary,
            packets,
            args,
            run_timestamp=datetime.now().isoformat(),
            sum_csv=sum_csv,
        )

    print(f"\n{'='*60}")
    print(f"  OUTPUT FILES")
    print(f"{'='*60}")
    print(f"  {raw_csv}")
    if calc.dnl is not None:
        print(f"  {dnl_inl_csv}")
        print(f"  {bin_csv}")
    print(f"  {sum_csv}")
    if not args.no_plot:
        print(f"  {plot_file}")
    print(f"{'='*60}")

    if not args.no_plot:
        plotter = TDCPlotter(calc)
        plotter.plot_all(plot_file)


if __name__ == '__main__':
    main()
