import argparse
import time

import serial


FRAME_SYNC = b"\xA5\x5A"
FRAME_TYPE_SINGLE = 0xD1
FRAME_VERSION = 0x01
FRAME_END = b"\x55\xAA"


def read_exact(ser: serial.Serial, nbytes: int, deadline: float, what: str) -> bytes:
    data = bytearray()
    while len(data) < nbytes:
        if time.time() > deadline:
            raise TimeoutError(f"Timeout waiting for {what}: got {len(data)}/{nbytes} bytes")
        chunk = ser.read(nbytes - len(data))
        if chunk:
            data.extend(chunk)
    return bytes(data)


def wait_for_sync(ser: serial.Serial, deadline: float) -> None:
    window = bytearray()
    while True:
        if time.time() > deadline:
            raise TimeoutError("Timeout waiting for frame sync")
        b = ser.read(1)
        if not b:
            continue
        window.extend(b)
        if len(window) > len(FRAME_SYNC):
            window = window[-len(FRAME_SYNC):]
        if bytes(window) == FRAME_SYNC:
            return


def receive_single_measurement(ser: serial.Serial, timeout_s: float) -> int:
    deadline = time.time() + timeout_s
    wait_for_sync(ser, deadline)

    frame = read_exact(ser, 8, deadline, "single-measurement frame")
    frame_type = frame[0]
    version = frame[1]
    meas_bytes = frame[2:6]
    trailer = frame[6:8]

    if frame_type != FRAME_TYPE_SINGLE:
        raise RuntimeError(f"Unexpected frame type 0x{frame_type:02X}, expected 0x{FRAME_TYPE_SINGLE:02X}")
    if version != FRAME_VERSION:
        raise RuntimeError(f"Unexpected frame version 0x{version:02X}, expected 0x{FRAME_VERSION:02X}")
    if trailer != FRAME_END:
        raise RuntimeError(f"Bad trailer {trailer.hex()}, expected {FRAME_END.hex()}")

    return int.from_bytes(meas_bytes, byteorder="little", signed=False)


def parse_args():
    p = argparse.ArgumentParser(description="Receive one FPGA TDC measurement frame")
    p.add_argument("--port", default="COM11")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--timeout", type=float, default=15.0)
    return p.parse_args()


def main():
    args = parse_args()
    ser = None
    try:
        print(f"Connecting to {args.port} @ {args.baud}...")
        ser = serial.Serial(port=args.port, baudrate=args.baud, timeout=1.0)
        print("Connected. Waiting for one frame...")

        measurement = receive_single_measurement(ser, timeout_s=args.timeout)
        print(f"Measurement received: dec={measurement}, hex=0x{measurement:08X}")

    except serial.SerialException as e:
        print(f"Serial error: {e}")
        raise SystemExit(1)
    except (TimeoutError, RuntimeError) as e:
        print(f"Receive error: {e}")
        raise SystemExit(1)
    finally:
        if ser is not None and ser.is_open:
            ser.close()
            print("Serial port closed")


if __name__ == "__main__":
    main()
