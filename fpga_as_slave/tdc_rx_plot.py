import argparse
import csv
import os
import time

import matplotlib.pyplot as plt
import numpy as np
import serial


DEFAULT_PORT = "COM11"
DEFAULT_BAUD = 115200
DEFAULT_TIMEOUT_S = 30.0
DEFAULT_BINS = 256
DEFAULT_CLOCK_PERIOD_PS = 20000.0
DEFAULT_CSV = "fpga_as_slave/rx_histogram_results.csv"
DEFAULT_PLOT = "fpga_as_slave/rx_histogram_plot.png"

FRAME_SYNC = b"\xA5\x5A"
FRAME_TYPE_CAL = 0xC1
FRAME_VERSION = 0x01
FRAME_END = b"\x55\xAA"


def connect_serial(port: str, baud: int) -> serial.Serial:
    print(f"Connecting to {port} at {baud} baud...")
    ser = serial.Serial(port=port, baudrate=baud, timeout=1.0)
    print("Connection successful.")
    return ser


def read_exact(ser: serial.Serial, nbytes: int, deadline: float, what: str) -> bytes:
    raw = bytearray()
    while len(raw) < nbytes:
        if time.time() > deadline:
            raise TimeoutError(f"Timeout waiting for {what}: got {len(raw)}/{nbytes} bytes")
        chunk = ser.read(nbytes - len(raw))
        if not chunk:
            continue
        raw.extend(chunk)
    return bytes(raw)


def read_histogram_frame(ser: serial.Serial, timeout_s: float, expected_bins: int) -> np.ndarray:
    print("Waiting for FPGA histogram data frame...")
    deadline = time.time() + timeout_s
    sync_window = bytearray()

    while True:
        if time.time() > deadline:
            raise TimeoutError("Timeout waiting for frame sync")

        b = ser.read(1)
        if not b:
            continue

        sync_window.extend(b)
        if len(sync_window) > len(FRAME_SYNC):
            sync_window = sync_window[-len(FRAME_SYNC):]

        if bytes(sync_window) == FRAME_SYNC:
            break

    header = read_exact(ser, 4, deadline, "frame header")
    frame_type, frame_version, bins_lsb, bins_msb = header
    frame_bins = bins_lsb | (bins_msb << 8)

    if frame_type != FRAME_TYPE_CAL:
        raise RuntimeError(
            f"Unexpected frame type 0x{frame_type:02X}, expected 0x{FRAME_TYPE_CAL:02X}"
        )
    if frame_version != FRAME_VERSION:
        raise RuntimeError(
            f"Unexpected frame version 0x{frame_version:02X}, expected 0x{FRAME_VERSION:02X}"
        )

    payload = read_exact(ser, frame_bins * 4, deadline, "histogram payload")
    trailer = read_exact(ser, 2, deadline, "frame trailer")

    if trailer != FRAME_END:
        raise RuntimeError(f"Bad frame trailer: got {trailer.hex()}, expected {FRAME_END.hex()}")

    counts = np.zeros(frame_bins, dtype=np.int64)
    for i in range(frame_bins):
        counts[i] = int.from_bytes(payload[i * 4:(i + 1) * 4], byteorder="little")

    if frame_bins == expected_bins:
        return counts

    # Adjust if the received frame bin count differs from local expectation.
    adjusted = np.zeros(expected_bins, dtype=np.int64)
    copy_bins = min(frame_bins, expected_bins)
    adjusted[:copy_bins] = counts[:copy_bins]
    print(f"WARNING: frame bins={frame_bins}, expected bins={expected_bins}; adjusted to expected length")
    return adjusted


def ensure_parent_dir(path: str):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)


def compute_metrics(counts: np.ndarray, clock_period_ps: float):
    c = counts.astype(np.int64).copy()
    if len(c) == 0:
        raise RuntimeError("Received empty histogram")

    # Keep historical behavior: ignore bin 0 for analysis.
    c[0] = 0
    total_hits = int(np.sum(c))
    if total_hits <= 0:
        raise RuntimeError("No hits in histogram after masking bin 0")

    nonzero_idx = np.where(c > 0)[0]
    if len(nonzero_idx) == 0:
        raise RuntimeError("No active bins in histogram")

    first_active = int(nonzero_idx[0])
    last_active = int(nonzero_idx[-1])
    active_bins = last_active - first_active + 1

    expected = total_hits / active_bins
    prob = np.zeros_like(c, dtype=np.float64)
    dnl = np.zeros_like(c, dtype=np.float64)
    inl = np.zeros_like(c, dtype=np.float64)
    width_ps = np.zeros_like(c, dtype=np.float64)

    for i in range(first_active, last_active + 1):
        prob[i] = c[i] / total_hits
        dnl[i] = (c[i] / expected) - 1.0
        width_ps[i] = prob[i] * clock_period_ps

    running = 0.0
    for i in range(first_active, last_active + 1):
        running += dnl[i]
        inl[i] = running

    return {
        "counts": c,
        "prob": prob,
        "dnl": dnl,
        "inl": inl,
        "width_ps": width_ps,
        "first_active": first_active,
        "last_active": last_active,
        "active_bins": active_bins,
        "total_hits": total_hits,
    }


def save_csv(metrics, out_csv: str):
    ensure_parent_dir(out_csv)
    with open(out_csv, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["Bin", "Counts", "Probability", "Width_ps_est", "DNL_LSB", "INL_LSB"])
        for i in range(len(metrics["counts"])):
            writer.writerow([
                i,
                int(metrics["counts"][i]),
                f"{metrics['prob'][i]:.8f}",
                f"{metrics['width_ps'][i]:.3f}",
                f"{metrics['dnl'][i]:.6f}",
                f"{metrics['inl'][i]:.6f}",
            ])
    print(f"Saved CSV: {out_csv}")


def save_plot(metrics, out_plot: str):
    ensure_parent_dir(out_plot)
    bins = np.arange(len(metrics["counts"]))

    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(10, 10))

    ax1.bar(bins, metrics["counts"], width=1, color="steelblue", edgecolor="black", linewidth=0.4)
    ax1.set_title("Histogram Counts")
    ax1.set_ylabel("Counts")

    ax2.plot(bins, metrics["dnl"], color="red", marker=".")
    ax2.axhline(0, color="black", linestyle="--")
    ax2.set_title("DNL")
    ax2.set_ylabel("LSB")

    ax3.plot(bins, metrics["inl"], color="green", marker=".")
    ax3.axhline(0, color="black", linestyle="--")
    ax3.set_title("INL")
    ax3.set_ylabel("LSB")
    ax3.set_xlabel("Bin")

    left = max(0, metrics["first_active"] - 5)
    right = min(len(metrics["counts"]) - 1, metrics["last_active"] + 5)
    ax1.set_xlim(left, right)
    ax2.set_xlim(left, right)
    ax3.set_xlim(left, right)

    plt.tight_layout()
    plt.savefig(out_plot)
    print(f"Saved plot: {out_plot}")
    plt.show()


def parse_args():
    parser = argparse.ArgumentParser(
        description="RX-only FPGA histogram receiver: connect, wait for data, calculate and plot"
    )
    parser.add_argument("--port", default=DEFAULT_PORT)
    parser.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S, help="Seconds to wait for one frame")
    parser.add_argument("--bins", type=int, default=DEFAULT_BINS)
    parser.add_argument("--clock-period-ps", type=float, default=DEFAULT_CLOCK_PERIOD_PS)
    parser.add_argument("--out-csv", default=DEFAULT_CSV)
    parser.add_argument("--out-plot", default=DEFAULT_PLOT)
    parser.add_argument("--no-plot", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()

    ser = None
    try:
        ser = connect_serial(args.port, args.baud)
        counts = read_histogram_frame(ser, timeout_s=args.timeout, expected_bins=args.bins)
        metrics = compute_metrics(counts, clock_period_ps=args.clock_period_ps)

        print(
            "Frame received and processed: "
            f"hits={metrics['total_hits']}, "
            f"active_bins={metrics['first_active']}..{metrics['last_active']} "
            f"({metrics['active_bins']})"
        )

        save_csv(metrics, args.out_csv)
        if not args.no_plot:
            save_plot(metrics, args.out_plot)

    except serial.SerialException as e:
        print(f"Serial error: {e}")
        raise SystemExit(1)
    except (TimeoutError, RuntimeError) as e:
        print(f"Data receive/analysis error: {e}")
        raise SystemExit(1)
    finally:
        if ser is not None and ser.is_open:
            ser.close()
            print("Serial port closed")


if __name__ == "__main__":
    main()
