import argparse
import csv
import os
import time
from typing import Optional

import serial

try:
    import matplotlib.pyplot as plt
except Exception:
    plt = None


FRAME_SYNC = b"\xA5\x5A"
FRAME_TYPE_CAL = 0xC1
FRAME_VERSION = 0x01
FRAME_END = b"\x55\xAA"
MAX_REASONABLE_BINS = 4096


def read_exact(ser: serial.Serial, nbytes: int, deadline: Optional[float], what: str) -> bytes:
    data = bytearray()
    while len(data) < nbytes:
        if deadline is not None and time.time() > deadline:
            raise TimeoutError(f"Timeout waiting for {what}: got {len(data)}/{nbytes} bytes")
        chunk = ser.read(nbytes - len(data))
        if chunk:
            data.extend(chunk)
    return bytes(data)


def wait_for_sync(ser: serial.Serial, deadline: Optional[float]) -> None:
    window = bytearray()
    while True:
        if deadline is not None and time.time() > deadline:
            raise TimeoutError("Timeout waiting for frame sync")
        b = ser.read(1)
        if not b:
            continue
        window.extend(b)
        if len(window) > len(FRAME_SYNC):
            window = window[-len(FRAME_SYNC) :]
        if bytes(window) == FRAME_SYNC:
            return


def receive_one_histogram_frame(
    ser: serial.Serial,
    deadline: Optional[float],
    expected_bins: Optional[int],
) -> list[int]:
    wait_for_sync(ser, deadline)

    header = read_exact(ser, 4, deadline, "frame header")
    frame_type, version, bins_lsb, bins_msb = header
    bins = bins_lsb | (bins_msb << 8)

    if frame_type != FRAME_TYPE_CAL:
        raise RuntimeError(
            f"Unexpected frame type 0x{frame_type:02X}, expected 0x{FRAME_TYPE_CAL:02X}"
        )
    if version != FRAME_VERSION:
        raise RuntimeError(
            f"Unexpected frame version 0x{version:02X}, expected 0x{FRAME_VERSION:02X}"
        )
    if bins <= 0:
        raise RuntimeError(f"Invalid bin count in frame: {bins}")
    if bins > MAX_REASONABLE_BINS:
        raise RuntimeError(
            f"Frame bin count {bins} exceeds sanity limit {MAX_REASONABLE_BINS}"
        )
    if expected_bins is not None and bins != expected_bins:
        raise RuntimeError(
            f"Unexpected frame bins {bins}, expected {expected_bins}"
        )

    payload = read_exact(ser, bins * 4, deadline, "histogram payload")
    trailer = read_exact(ser, 2, deadline, "frame trailer")
    if trailer != FRAME_END:
        raise RuntimeError(f"Bad trailer {trailer.hex()}, expected {FRAME_END.hex()}")

    counts: list[int] = [0] * bins
    for i in range(bins):
        word = payload[i * 4 : (i + 1) * 4]
        counts[i] = int.from_bytes(word, byteorder="little", signed=False)
    return counts


def receive_histogram_frame(
    ser: serial.Serial,
    timeout_s: float,
    expected_bins: Optional[int],
    verbose: bool,
) -> list[int]:
    deadline = None if timeout_s <= 0 else (time.time() + timeout_s)
    attempts = 0
    last_error: Optional[str] = None

    while deadline is None or time.time() < deadline:
        attempts += 1
        try:
            return receive_one_histogram_frame(
                ser=ser,
                deadline=deadline,
                expected_bins=expected_bins,
            )
        except RuntimeError as e:
            last_error = str(e)
            if verbose:
                print(f"Resync attempt {attempts} skipped: {e}")

    detail = f" Last frame error: {last_error}" if last_error else ""
    raise TimeoutError(
        f"Timeout waiting for a valid calibration frame after {attempts} sync attempts.{detail}"
    )


def sniff_serial(ser: serial.Serial, seconds: float, preview_limit: int = 128) -> None:
    if seconds <= 0:
        return

    deadline = time.time() + seconds
    total_bytes = 0
    sync_hits = 0
    window = bytearray()
    preview = bytearray()

    print(f"Sniffing raw UART for {seconds:.1f}s...")
    while time.time() < deadline:
        chunk = ser.read(256)
        if not chunk:
            continue

        total_bytes += len(chunk)
        for b in chunk:
            window.append(b)
            if len(window) > len(FRAME_SYNC):
                window = window[-len(FRAME_SYNC) :]
            if bytes(window) == FRAME_SYNC:
                sync_hits += 1

        if len(preview) < preview_limit:
            remaining = preview_limit - len(preview)
            preview.extend(chunk[:remaining])

    preview_hex = preview.hex() if preview else "none"
    print(
        "Sniff result: "
        f"bytes={total_bytes}, sync_hits={sync_hits}, preview_hex={preview_hex}"
    )
    if total_bytes == 0:
        print("No UART bytes observed during sniff window.")
    elif sync_hits == 0:
        print("UART data observed, but no A55A sync marker detected.")


def ensure_parent_dir(path: str) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)


def compute_metrics(counts: list[int], clock_period_ps: float, mask_bin0: bool = True):
    analyzed = list(counts)
    if mask_bin0 and analyzed:
        analyzed[0] = 0

    total_hits = sum(analyzed)
    nonzero = [i for i, c in enumerate(analyzed) if c > 0]
    if not nonzero:
        raise RuntimeError("No active histogram bins after processing")

    first_active = nonzero[0]
    last_active = nonzero[-1]
    active_bins = last_active - first_active + 1
    expected = total_hits / active_bins

    rows = []
    running_inl = 0.0
    for i, c in enumerate(analyzed):
        if first_active <= i <= last_active and total_hits > 0:
            prob = c / total_hits
            dnl = (c / expected) - 1.0
            running_inl += dnl
            width_ps = prob * clock_period_ps
            inl = running_inl
        else:
            prob = 0.0
            dnl = 0.0
            width_ps = 0.0
            inl = 0.0

        rows.append(
            {
                "bin": i,
                "counts": c,
                "probability": prob,
                "width_ps": width_ps,
                "dnl_lsb": dnl,
                "inl_lsb": inl,
            }
        )

    summary = {
        "total_hits": total_hits,
        "first_active": first_active,
        "last_active": last_active,
        "active_bins": active_bins,
    }
    return analyzed, rows, summary


def save_counts_csv(path: str, counts: list[int]) -> None:
    ensure_parent_dir(path)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Bin", "Counts"])
        for i, c in enumerate(counts):
            w.writerow([i, c])


def save_metrics_csv(path: str, rows) -> None:
    ensure_parent_dir(path)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Bin", "Counts", "Probability", "Width_ps_est", "DNL_LSB", "INL_LSB"])
        for r in rows:
            w.writerow(
                [
                    r["bin"],
                    r["counts"],
                    f"{r['probability']:.8f}",
                    f"{r['width_ps']:.3f}",
                    f"{r['dnl_lsb']:.6f}",
                    f"{r['inl_lsb']:.6f}",
                ]
            )


def save_plot(path: str, rows, summary) -> None:
    if plt is None:
        print("WARNING: matplotlib not available; skipping plot generation")
        return

    ensure_parent_dir(path)
    bins = [r["bin"] for r in rows]
    counts = [r["counts"] for r in rows]
    dnl = [r["dnl_lsb"] for r in rows]
    inl = [r["inl_lsb"] for r in rows]

    left = max(0, summary["first_active"] - 5)
    right = summary["last_active"] + 5

    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(10, 10))

    ax1.bar(bins, counts, width=1, color="steelblue", edgecolor="black", linewidth=0.3)
    ax1.set_title("Startup Calibration Histogram")
    ax1.set_ylabel("Counts")
    ax1.set_xlim(left, right)

    ax2.plot(bins, dnl, color="red", marker=".")
    ax2.axhline(0, color="black", linestyle="--")
    ax2.set_title("DNL")
    ax2.set_ylabel("LSB")
    ax2.set_xlim(left, right)

    ax3.plot(bins, inl, color="green", marker=".")
    ax3.axhline(0, color="black", linestyle="--")
    ax3.set_title("INL")
    ax3.set_ylabel("LSB")
    ax3.set_xlabel("Bin")
    ax3.set_xlim(left, right)

    plt.tight_layout()
    plt.savefig(path)
    print(f"Saved plot to {path}")


def parse_args():
    p = argparse.ArgumentParser(
        description="Receive startup calibration histogram frame from FPGA and save calibration CSV files"
    )
    p.add_argument("--port", default="COM11")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--timeout", type=float, default=45.0, help="Seconds to wait (<=0 means wait forever)")
    p.add_argument("--clock-period-ps", type=float, default=20000.0)
    p.add_argument("--expected-bins", type=int, default=256)
    p.add_argument("--expected-hits", type=int, default=32768)
    p.add_argument("--out-counts", default="fpga_as_slave/startup_hist_counts.csv")
    p.add_argument("--out-metrics", default="fpga_as_slave/startup_hist_metrics.csv")
    p.add_argument("--out-plot", default="fpga_as_slave/startup_hist_plot.png")
    p.add_argument("--keep-bin0", action="store_true", help="Do not mask bin 0 before DNL/INL")
    p.add_argument("--no-plot", action="store_true", help="Disable plot output")
    p.add_argument("--flush", action="store_true", help="Flush serial input/output buffers on connect")
    p.add_argument("--sniff-seconds", type=float, default=0.0, help="Raw UART sniff window before frame decode")
    p.add_argument("--sniff-bytes", type=int, default=128, help="Raw hex preview byte count during sniff")
    p.add_argument("--verbose", action="store_true", help="Print resynchronization diagnostics")
    return p.parse_args()


def main():
    args = parse_args()

    ser = None
    try:
        print(f"Connecting to {args.port} @ {args.baud}...")
        ser = serial.Serial(port=args.port, baudrate=args.baud, timeout=1.0)
        if args.flush:
            ser.reset_input_buffer()
            ser.reset_output_buffer()
        print("Connected. Waiting for startup calibration frame...")

        sniff_serial(ser, seconds=args.sniff_seconds, preview_limit=args.sniff_bytes)

        raw_counts = receive_histogram_frame(
            ser=ser,
            timeout_s=args.timeout,
            expected_bins=args.expected_bins,
            verbose=args.verbose,
        )
        print(f"Frame received: bins={len(raw_counts)}")

        analyzed_counts, metric_rows, summary = compute_metrics(
            raw_counts,
            clock_period_ps=args.clock_period_ps,
            mask_bin0=not args.keep_bin0,
        )

        save_counts_csv(args.out_counts, raw_counts)
        save_metrics_csv(args.out_metrics, metric_rows)

        print(f"Saved raw counts to {args.out_counts}")
        print(f"Saved calibration metrics to {args.out_metrics}")
        print(
            "Summary: "
            f"hits={summary['total_hits']}, "
            f"active_bins={summary['first_active']}..{summary['last_active']} "
            f"({summary['active_bins']})"
        )

        if not args.no_plot:
            save_plot(args.out_plot, metric_rows, summary)

        if args.expected_hits > 0 and summary["total_hits"] != args.expected_hits:
            print(
                "WARNING: total hits mismatch: "
                f"expected={args.expected_hits}, got={summary['total_hits']}"
            )

    except serial.SerialException as e:
        print(f"Serial error: {e}")
        raise SystemExit(1)
    except TimeoutError as e:
        print(f"Calibration receive error: {e}")
        print("Hint: if FPGA LEDs are all ON, it likely finished and sent before listener sync.")
        print("Keep the receiver running and press FPGA reset once, or use the re-send enabled bitstream.")
        print("Tip: run with --sniff-seconds 3 --verbose to inspect raw UART activity.")
        raise SystemExit(1)
    except (RuntimeError, ValueError) as e:
        print(f"Calibration receive error: {e}")
        raise SystemExit(1)
    finally:
        if ser is not None and ser.is_open:
            ser.close()
            print("Serial port closed")


if __name__ == "__main__":
    main()
