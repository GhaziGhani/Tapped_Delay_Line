import argparse
import csv
import os
import time

import matplotlib.pyplot as plt
import numpy as np
import serial

# Configuration
PORT = 'COM11'  # Change as required
BAUD = 115200
PHASE_STEPS = 200
HITS_PER_PHASE = 256
BINS = 256
CLOCK_PERIOD_PS = 20000  # 20ns = 20000ps
DEFAULT_ACQ_SECONDS = 1.0

# Commands
CMD_STEP_PHASE = b'\x01'
CMD_FIRE_BURST = b'\x02'
CMD_SEND_BRAM  = b'\x03'
CMD_RESET_BRAM = b'\x04'
CMD_GET_STATUS = b'\x05'
CMD_GET_STATUS_FRAME = b'\x06'
ACK_BYTE = b'\x06'
NACK_BYTE = b'\x15'
OUTPUT_CSV = "fpga_as_slave/calibration_results.csv"
TIMING_CSV = "fpga_as_slave/phase_ack_timing.csv"
PHASE_DIAG_CSV = "fpga_as_slave/phase_diag_results.csv"
STARTUP_STREAM_SYNC = b'\xA5\x5A'
STARTUP_STREAM_TYPE_CAL = 0xC1
STARTUP_STREAM_VERSION = 0x01
STARTUP_STREAM_END = b'\x55\xAA'
STARTUP_STREAM_TIMEOUT = 20.0
RX_ONLY = True

ERROR_CODE_NAMES = {
    0x00: "none",
    0x01: "rx_overrun",
    0x02: "invalid_command",
    0x03: "step_timeout",
    0x04: "burst_trigger_timeout",
    0x05: "burst_no_hits",
    0x06: "tx_stream_timeout",
    0x07: "ack_wait_timeout",
    0x08: "clear_start_timeout",
    0x09: "clear_busy_timeout",
    0x0A: "send_ack_timeout",
}


def decode_status_code(code: int) -> str:
    return ERROR_CODE_NAMES.get(code, f"unknown_0x{code:02X}")


def decode_status_flags(flags: int):
    return {
        "dcm_locked": bool(flags & (1 << 0)),
        "sweep_done": bool(flags & (1 << 1)),
        "sweep_finish": bool(flags & (1 << 2)),
        "bram_ready": bool(flags & (1 << 3)),
        "clear_busy": bool(flags & (1 << 4)),
        "time_valid": bool(flags & (1 << 5)),
        "burst_hit_seen": bool(flags & (1 << 6)),
        "last_rsp_was_nack": bool(flags & (1 << 7)),
    }

def wait_for_ack(ser: serial.Serial, timeout=5.0, what="command"):
    start = time.time()
    seen = bytearray()
    while True:
        if ser.in_waiting > 0:
            resp = ser.read(1)
            if resp == ACK_BYTE:
                return True
            if resp == NACK_BYTE:
                seen_hex = seen.hex() if len(seen) > 0 else "none"
                raise RuntimeError(f"NACK received after {what} (seen_before_nack={seen_hex})")
            seen.extend(resp)
        if time.time() - start > timeout:
            seen_hex = seen.hex() if len(seen) > 0 else "none"
            raise TimeoutError(f"Timeout waiting for ACK after {what} (seen={seen_hex})")

def connect_serial(port: str, baud: int, flush_buffers: bool = True) -> serial.Serial:
    print(f"Connecting to {port} at {baud}...")
    ser = serial.Serial(port, baud, timeout=1)
    if flush_buffers:
        ser.reset_input_buffer()
        ser.reset_output_buffer()
    return ser


def send_cmd_and_wait_ack(ser: serial.Serial, cmd: bytes, what: str, timeout: float = 5.0) -> float:
    if RX_ONLY:
        raise RuntimeError("TX command path disabled in RX-only mode")

    # Drop stale bytes before issuing a new command to avoid ghost ACK/data.
    if ser.in_waiting:
        ser.reset_input_buffer()

    t0 = time.perf_counter()
    ser.write(cmd)
    wait_for_ack(ser, timeout=timeout, what=what)
    return (time.perf_counter() - t0) * 1000.0


def read_status_code(ser: serial.Serial, timeout: float = 2.0) -> int:
    if RX_ONLY:
        raise RuntimeError("Status command path disabled in RX-only mode")

    # Query one status byte and then consume trailing ACK.
    if ser.in_waiting:
        ser.reset_input_buffer()

    ser.write(CMD_GET_STATUS)
    start = time.time()
    while True:
        if ser.in_waiting > 0:
            b = ser.read(1)
            if b == NACK_BYTE:
                raise RuntimeError("NACK received for CMD_GET_STATUS")
            code = b[0]
            break
        if time.time() - start > timeout:
            raise TimeoutError("Timeout waiting for status byte after CMD_GET_STATUS")

    wait_for_ack(ser, timeout=timeout, what="CMD_GET_STATUS")
    return code


def read_status_frame(ser: serial.Serial, timeout: float = 2.0):
    if RX_ONLY:
        raise RuntimeError("Status-frame command path disabled in RX-only mode")

    # Query status frame: [last_error_code, sweep_phase, status_flags, tests_done_lsb], then ACK.
    if ser.in_waiting:
        ser.reset_input_buffer()

    ser.write(CMD_GET_STATUS_FRAME)
    expected = 4
    raw = bytearray()
    deadline = time.time() + timeout

    while len(raw) < expected:
        if time.time() > deadline:
            raise TimeoutError(
                f"Timeout waiting for status frame ({len(raw)}/{expected} bytes)"
            )
        chunk = ser.read(expected - len(raw))
        if not chunk:
            continue
        raw.extend(chunk)

    wait_for_ack(ser, timeout=timeout, what="CMD_GET_STATUS_FRAME")

    err, phase, flags, tests = raw[0], raw[1], raw[2], raw[3]
    return {
        "error_code": err,
        "error_name": decode_status_code(err),
        "phase_index": phase,
        "flags_raw": flags,
        "flags": decode_status_flags(flags),
        "tests_done_lsb": tests,
    }


def print_status_frame(frame) -> None:
    print(
        f"FPGA status frame: err=0x{frame['error_code']:02X} ({frame['error_name']}), "
        f"phase={frame['phase_index']}, flags=0x{frame['flags_raw']:02X}, "
        f"tests_done_lsb={frame['tests_done_lsb']}"
    )
    flags = frame["flags"]
    enabled = [name for name, value in flags.items() if value]
    print("  Flags set: " + (", ".join(enabled) if enabled else "none"))


def parse_bram_bytes(raw_data: bytes, bins: int) -> np.ndarray:
    counts = np.zeros(bins, dtype=int)
    for i in range(bins):
        word = raw_data[i * 4:(i + 1) * 4]
        counts[i] = int.from_bytes(word, byteorder="little")
    return counts


def _read_exact_with_deadline(ser: serial.Serial, byte_count: int, deadline: float, what: str) -> bytes:
    raw = bytearray()
    while len(raw) < byte_count:
        if time.time() > deadline:
            raise TimeoutError(f"Timeout waiting for {what}: got {len(raw)}/{byte_count} bytes")
        chunk = ser.read(byte_count - len(raw))
        if not chunk:
            continue
        raw.extend(chunk)
    return bytes(raw)


def read_startup_histogram_stream(ser: serial.Serial, bins: int, timeout: float = STARTUP_STREAM_TIMEOUT) -> np.ndarray:
    # Frame format:
    #   [A5 5A][C1][01][bins_lsb][bins_msb][bins*4 bytes little-endian][55 AA]
    deadline = time.time() + timeout
    sync_window = bytearray()

    while True:
        if time.time() > deadline:
            raise TimeoutError("Timeout waiting for startup histogram sync bytes")
        b = ser.read(1)
        if not b:
            continue
        sync_window.extend(b)
        if len(sync_window) > len(STARTUP_STREAM_SYNC):
            sync_window = sync_window[-len(STARTUP_STREAM_SYNC):]
        if bytes(sync_window) == STARTUP_STREAM_SYNC:
            break

    header = _read_exact_with_deadline(ser, 4, deadline, "startup histogram header")
    frame_type, frame_version, bins_lsb, bins_msb = header
    frame_bins = bins_lsb | (bins_msb << 8)

    if frame_type != STARTUP_STREAM_TYPE_CAL:
        raise RuntimeError(
            f"Unexpected startup frame type 0x{frame_type:02X} (expected 0x{STARTUP_STREAM_TYPE_CAL:02X})"
        )

    if frame_version != STARTUP_STREAM_VERSION:
        raise RuntimeError(
            f"Unexpected startup frame version 0x{frame_version:02X} (expected 0x{STARTUP_STREAM_VERSION:02X})"
        )

    payload = _read_exact_with_deadline(
        ser,
        frame_bins * 4,
        deadline,
        f"startup histogram payload ({frame_bins} bins)",
    )
    trailer = _read_exact_with_deadline(ser, 2, deadline, "startup histogram trailer")
    if trailer != STARTUP_STREAM_END:
        raise RuntimeError(
            f"Startup histogram trailer mismatch: got {trailer.hex()}, expected {STARTUP_STREAM_END.hex()}"
        )

    counts = parse_bram_bytes(payload, frame_bins)
    if frame_bins == bins:
        return counts

    adjusted = np.zeros(bins, dtype=int)
    copy_bins = min(bins, frame_bins)
    adjusted[:copy_bins] = counts[:copy_bins]
    print(f"WARNING: startup frame bins={frame_bins}, expected={bins}; truncated/padded to {bins} bins")
    return adjusted


def read_bram_counts(ser: serial.Serial, bins: int, timeout: float = 5.0) -> np.ndarray:
    if RX_ONLY:
        raise RuntimeError("BRAM command-read path disabled in RX-only mode")

    # Clear stale bytes so BRAM block framing starts from a known boundary.
    if ser.in_waiting:
        ser.reset_input_buffer()

    ser.write(CMD_SEND_BRAM)
    expected_bytes = bins * 4
    raw_data = bytearray()
    
    deadline = time.time() + timeout
    while len(raw_data) < expected_bytes:
        if time.time() > deadline:
            raise RuntimeError(
                f"BRAM read timeout: got {len(raw_data)}/{expected_bytes} bytes"
            )
        remaining = expected_bytes - len(raw_data)
        chunk = ser.read(remaining)
        if not chunk:
            continue
        raw_data.extend(chunk)
    
    # Wait for trailing ACK separately. If missing, treat frame as invalid.
    try:
        wait_for_ack(ser, timeout=max(1.0, timeout * 0.25), what="CMD_SEND_BRAM")
    except TimeoutError as e:
        tail = bytes(raw_data[-8:]).hex() if raw_data else "none"
        raise RuntimeError(
            f"BRAM block received but trailing ACK missing ({e}). "
            f"Possible framing loss; data_tail={tail}"
        ) from e

    return parse_bram_bytes(bytes(raw_data), bins)


def print_latency_stats(name: str, values_ms):
    arr = np.array(values_ms, dtype=float)
    print(
        f"{name}: min={arr.min():.3f} ms, avg={arr.mean():.3f} ms, "
        f"p95={np.percentile(arr, 95):.3f} ms, max={arr.max():.3f} ms"
    )


def save_ack_timing_csv(fire_ms, step_ms):
    with open(TIMING_CSV, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Phase", "FireAck_ms", "StepAck_ms"])
        for i in range(len(fire_ms)):
            w.writerow([i, f"{fire_ms[i]:.6f}", f"{step_ms[i]:.6f}"])
    print(f"Saved ACK timing to {TIMING_CSV}")


def run_sweep(ser: serial.Serial, phase_steps: int, do_step_phase: bool = True):
    if RX_ONLY:
        raise RuntimeError("Sweep TX path disabled in RX-only mode")

    total_hits_expected = phase_steps * HITS_PER_PHASE
    print(f"Starting Sweep: {phase_steps} phases * {HITS_PER_PHASE} hits = {total_hits_expected} total hits.")

    fire_ack_ms = []
    step_ack_ms = []

    for p in range(phase_steps):
        if p % 10 == 0:
            print(f"  Sweeping Phase {p}/{phase_steps}...")

        fire_ms = send_cmd_and_wait_ack(ser, CMD_FIRE_BURST, f"CMD_FIRE_BURST@phase{p}")
        if do_step_phase:
            step_ms = send_cmd_and_wait_ack(ser, CMD_STEP_PHASE, f"CMD_STEP_PHASE@phase{p}")
        else:
            step_ms = 0.0
        fire_ack_ms.append(fire_ms)
        step_ack_ms.append(step_ms)

    counts = read_bram_counts(ser, BINS)
    print("Data download complete.")
    return counts, fire_ack_ms, step_ack_ms


def run_phase_diag(ser: serial.Serial, diag_phases: int, do_step_phase: bool = True):
    if RX_ONLY:
        raise RuntimeError("Phase diagnostic TX path disabled in RX-only mode")

    rows = []
    print(f"Running phase diagnostic for {diag_phases} phases...")

    for p in range(diag_phases):
        send_cmd_and_wait_ack(ser, CMD_RESET_BRAM, f"CMD_RESET_BRAM@phase{p}")
        fire_ms = send_cmd_and_wait_ack(ser, CMD_FIRE_BURST, f"CMD_FIRE_BURST@phase{p}")

        counts = read_bram_counts(ser, BINS)
        counts[0] = 0

        nonzero_bins = int(np.count_nonzero(counts))
        total_hits = int(np.sum(counts))
        if nonzero_bins > 0:
            peak_bin = int(np.argmax(counts))
            peak_count = int(counts[peak_bin])
            first_bin = int(np.where(counts > 0)[0][0])
            last_bin = int(np.where(counts > 0)[0][-1])
        else:
            peak_bin = -1
            peak_count = 0
            first_bin = -1
            last_bin = -1

        if do_step_phase:
            step_ms = send_cmd_and_wait_ack(ser, CMD_STEP_PHASE, f"CMD_STEP_PHASE@phase{p}")
        else:
            step_ms = 0.0

        rows.append([p, first_bin, last_bin, peak_bin, peak_count, nonzero_bins, total_hits, fire_ms, step_ms])
        print(
            f"Phase {p:03d}: first={first_bin}, last={last_bin}, peak={peak_bin}, "
            f"nonzero={nonzero_bins}, fire_ack={fire_ms:.3f} ms, step_ack={step_ms:.3f} ms"
        )

    with open(PHASE_DIAG_CSV, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([
            "Phase",
            "FirstBin",
            "LastBin",
            "PeakBin",
            "PeakCount",
            "NonZeroBins",
            "TotalHits",
            "FireAck_ms",
            "StepAck_ms",
        ])
        w.writerows(rows)

    print(f"Saved phase diagnostic to {PHASE_DIAG_CSV}")

    peaks = sorted({r[3] for r in rows if r[3] >= 0})
    nonzero_counts = [r[5] for r in rows]
    print(f"Unique peak bins: {peaks}")
    print(f"Non-zero bin count range: {min(nonzero_counts)}..{max(nonzero_counts)}")

    if len(peaks) <= 1 and max(nonzero_counts) <= 1:
        print("DIAG RESULT: Fine bin appears stuck (single-bin behavior across phases).")
    elif len(peaks) <= 1:
        print("DIAG RESULT: Peak bin stuck, but spread exists. Phase effect may be weak.")
    else:
        print("DIAG RESULT: Peak bin moves across phases (phase sweep likely effective).")


def summarize_counts(counts: np.ndarray):
    c = counts.copy()
    c[0] = 0
    total_hits = int(np.sum(c))
    nonzero_bins = int(np.count_nonzero(c))

    if nonzero_bins > 0:
        peak_bin = int(np.argmax(c))
        peak_count = int(c[peak_bin])
        first_bin = int(np.where(c > 0)[0][0])
        last_bin = int(np.where(c > 0)[0][-1])
    else:
        peak_bin = -1
        peak_count = 0
        first_bin = -1
        last_bin = -1

    return {
        "first_bin": first_bin,
        "last_bin": last_bin,
        "peak_bin": peak_bin,
        "peak_count": peak_count,
        "nonzero_bins": nonzero_bins,
        "total_hits": total_hits,
    }


def run_fetch_once(ser: serial.Serial, acq_seconds: float) -> np.ndarray:
    if RX_ONLY:
        raise RuntimeError("Fetch-once TX path disabled in RX-only mode")

    print("Sending RESET_BRAM...")
    send_cmd_and_wait_ack(ser, CMD_RESET_BRAM, "CMD_RESET_BRAM")
    print("BRAM reset complete.")

    print(f"Collecting statistically on FPGA for {acq_seconds:.3f} s...")
    time.sleep(acq_seconds)

    counts = read_bram_counts(ser, BINS)
    print("One-shot BRAM fetch complete.")
    return counts


def analyze_and_save_statistical(counts: np.ndarray, show_plot: bool):
    c = counts.copy()
    c[0] = 0

    total_hits = int(np.sum(c))
    print(f"Total histogram hits: {total_hits}")
    if total_hits == 0:
        print("CRITICAL: no hits collected. Increase acquisition time or check routing.")
        return

    nonzero_idx = np.where(c > 0)[0]
    if len(nonzero_idx) == 0:
        print("CRITICAL: no non-zero bins after masking bin 0.")
        return

    first_active = int(nonzero_idx[0])
    last_active = int(nonzero_idx[-1])
    active_bins = last_active - first_active + 1
    print(f"Active bins: {first_active}..{last_active} ({active_bins})")

    expected = total_hits / active_bins
    prob = np.zeros(BINS)
    dnl = np.zeros(BINS)
    inl = np.zeros(BINS)
    width_ps = np.zeros(BINS)

    if total_hits > 0:
        for i in range(first_active, last_active + 1):
            prob[i] = c[i] / total_hits
            dnl[i] = (c[i] / expected) - 1.0
            width_ps[i] = prob[i] * CLOCK_PERIOD_PS

    running = 0.0
    for i in range(first_active, last_active + 1):
        running += dnl[i]
        inl[i] = running

    with open(OUTPUT_CSV, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Bin", "Counts", "Probability", "Width_ps_est", "DNL_LSB", "INL_LSB"])
        for i in range(first_active, last_active + 1):
            w.writerow([
                i,
                int(c[i]),
                f"{prob[i]:.8f}",
                f"{width_ps[i]:.3f}",
                f"{dnl[i]:.6f}",
                f"{inl[i]:.6f}",
            ])
    print(f"Saved statistical analysis to {OUTPUT_CSV}")

    if not show_plot:
        return

    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(10, 10))
    ax1.bar(range(BINS), c, width=1, color="blue", edgecolor="black", linewidth=0.5)
    ax1.set_title("Histogram Counts (Statistical Mode)")
    ax1.set_ylabel("Counts")
    ax1.set_xlim(max(0, first_active - 5), min(BINS - 1, last_active + 5))

    ax2.plot(range(BINS), dnl, color="red", marker=".")
    ax2.axhline(0, color="black", linestyle="--")
    ax2.set_title("DNL (Code Density)")
    ax2.set_ylabel("DNL (LSB)")
    ax2.set_xlim(max(0, first_active - 5), min(BINS - 1, last_active + 5))

    ax3.plot(range(BINS), inl, color="green", marker="o", markersize=3)
    ax3.axhline(0, color="black", linestyle="--")
    ax3.set_title("INL (Integrated DNL)")
    ax3.set_ylabel("INL (LSB)")
    ax3.set_xlabel("Bin Index")
    ax3.set_xlim(max(0, first_active - 5), min(BINS - 1, last_active + 5))

    plt.tight_layout()
    plt.savefig("fpga_as_slave/calibration_plot.png")
    print("Saved plot to fpga_as_slave/calibration_plot.png")
    plt.show()


def analyze_and_save(counts: np.ndarray, phase_steps: int, show_plot: bool):
    total_hits_measured = int(np.sum(counts))
    print(f"Total Hits Captured: {total_hits_measured}")

    if total_hits_measured == 0:
        print("CRITICAL: 0 hits measured. Check routing or START_ENABLE generation.")
        return

    counts = counts.copy()
    counts[0] = 0
    nonzero_idx = np.where(counts > 0)[0]
    if len(nonzero_idx) == 0:
        print("CRITICAL: No non-zero bins after masking bin 0.")
        return

    first_active = int(nonzero_idx[0])
    last_active = int(nonzero_idx[-1])
    active_bins = last_active - first_active + 1

    print(f"Active Taps: {first_active} to {last_active} ({active_bins} bins)")

    actual_tdc_hits = int(np.sum(counts))
    total_launches = phase_steps * HITS_PER_PHASE
    sweep_time_ps = (phase_steps / 256.0) * CLOCK_PERIOD_PS
    delay_line_time_ps = (actual_tdc_hits / total_launches) * sweep_time_ps
    print(f"Total valid hits in TDC: {actual_tdc_hits}/{total_launches} (represents {delay_line_time_ps:.2f} ps)")

    widths_ps = np.zeros(BINS)
    dnl = np.zeros(BINS)
    inl = np.zeros(BINS)

    w_avg = delay_line_time_ps / active_bins if active_bins > 0 else 0

    for i in range(first_active, last_active + 1):
        widths_ps[i] = (counts[i] / actual_tdc_hits) * delay_line_time_ps
        dnl[i] = (widths_ps[i] - w_avg) / w_avg if w_avg > 0 else 0

    running_sum = 0.0
    for i in range(first_active, last_active + 1):
        running_sum += dnl[i]
        inl[i] = running_sum * w_avg

    with open(OUTPUT_CSV, "w") as f:
        f.write("Bin,Counts,Width_ps,DNL,INL_ps\n")
        for i in range(first_active, last_active + 1):
            f.write(f"{i},{counts[i]},{widths_ps[i]:.2f},{dnl[i]:.4f},{inl[i]:.2f}\n")
    print(f"Saved to {OUTPUT_CSV}")

    if not show_plot:
        return

    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(10, 10))
    ax1.bar(range(BINS), counts, width=1, color="blue", edgecolor="black", linewidth=0.5)
    ax1.set_title(f"Density Histogram (Total Hits: {total_hits_measured})")
    ax1.set_ylabel("Counts")
    ax1.set_xlim(first_active - 5, last_active + 5)

    ax2.plot(range(BINS), dnl, color="red", marker=".")
    ax2.axhline(0, color="black", linestyle="--")
    ax2.set_title("Differential Non-Linearity (DNL)")
    ax2.set_ylabel("DNL (LSB)")
    ax2.set_xlim(first_active - 5, last_active + 5)

    ax3.plot(range(BINS), inl, color="green", marker="o", markersize=3)
    ax3.axhline(0, color="black", linestyle="--")
    ax3.set_title("Integral Non-Linearity (INL)")
    ax3.set_ylabel("INL (ps)")
    ax3.set_xlabel("Bin Index")
    ax3.set_xlim(first_active - 5, last_active + 5)

    plt.tight_layout()
    plt.savefig("fpga_as_slave/calibration_plot.png")
    print("Saved plot to fpga_as_slave/calibration_plot.png")
    plt.show()


def parse_args():
    parser = argparse.ArgumentParser(description="TDC slave RX-only histogram receiver")
    parser.add_argument("--mode", choices=["startup-stream"], default="startup-stream")
    parser.add_argument("--port", default=PORT)
    parser.add_argument("--baud", type=int, default=BAUD)
    parser.add_argument("--stream-timeout", type=float, default=STARTUP_STREAM_TIMEOUT, help="Timeout while waiting for startup UART histogram frame")
    parser.add_argument("--no-plot", action="store_true", help="Disable matplotlib plot")
    return parser.parse_args()


def main():
    args = parse_args()

    if os.path.exists(OUTPUT_CSV):
        os.remove(OUTPUT_CSV)
        print(f"Removed stale output: {OUTPUT_CSV}")

    ser = None
    try:
        # RX-only behavior: do not send any command bytes to FPGA.
        ser = connect_serial(args.port, args.baud, flush_buffers=False)

        print(
            "RX-only mode: waiting for startup histogram UART frame from FPGA "
            f"(timeout={args.stream_timeout:.1f}s)..."
        )
        counts = read_startup_histogram_stream(ser, BINS, timeout=args.stream_timeout)
        summary = summarize_counts(counts)
        print(
            "Startup stream summary: "
            f"first={summary['first_bin']}, last={summary['last_bin']}, "
            f"peak={summary['peak_bin']}, nonzero={summary['nonzero_bins']}, "
            f"hits={summary['total_hits']}"
        )
        analyze_and_save_statistical(counts, show_plot=not args.no_plot)
        return
    except (TimeoutError, RuntimeError) as e:
        print(f"ERROR: {e}")
        print("RX-only mode does not transmit status requests.")
    except Exception as e:
        print(f"Unhandled error: {e}")
    finally:
        if ser is not None:
            ser.close()

if __name__ == "__main__":
    main()
