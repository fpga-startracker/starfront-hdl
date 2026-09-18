#!/usr/bin/env python3
"""Send an image to the ALINX AX7010 FPGA star tracker via serial or socket.

Protocol:
    1. 4-byte Magic Word:  0xAA 0x55 0xAA 0x55
    2. Image Payload:
       - Grayscale mode:  640 x 480 bytes = 307,200 bytes
       - RGB565 mode:     640 x 480 x 2   = 614,400 bytes

Usage:
    # Send a star photo over UART (e.g. COM3 at 921600 baud)
    python scripts/send_image_stream.py --port COM3 --baud 921600 --image my_stars.png

    # Generate a synthetic star test pattern and stream it
    python scripts/send_image_stream.py --port COM3 --baud 921600 --synthetic
"""

import argparse
import sys
import time
from pathlib import Path

MAGIC_HEADER = bytes([0xAA, 0x55, 0xAA, 0x55])
WIDTH = 640
HEIGHT = 480


def create_synthetic_star_image():
    """Generates a synthetic 640x480 star field in memory using PIL or raw bytes."""
    try:
        from PIL import Image, ImageDraw
        img = Image.new("L", (WIDTH, HEIGHT), color=10) # dark background noise
        draw = ImageDraw.Draw(img)

        # Draw 5 synthetic stars with different brightnesses
        stars = [
            (320, 240, 255), # Center bright star
            (150, 100, 220), # Top-left
            (480, 120, 180), # Top-right
            (200, 380, 150), # Bottom-left
            (500, 350, 120), # Bottom-right
        ]

        for x, y, peak in stars:
            # Draw halo
            halo = peak // 3
            draw.ellipse([x - 2, y - 2, x + 2, y + 2], fill=halo)
            draw.point((x, y), fill=peak)

        return img.tobytes()

    except ImportError:
        # Fallback to pure python if PIL not installed
        buf = bytearray([10] * (WIDTH * HEIGHT))
        stars = [(320, 240, 255), (150, 100, 220), (480, 120, 180)]
        for sx, sy, peak in stars:
            buf[sy * WIDTH + sx] = peak
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    buf[(sy + dy) * WIDTH + (sx + dx)] = max(buf[(sy + dy) * WIDTH + (sx + dx)], peak // 3)
        return bytes(buf)


def load_image_bytes(image_path: Path, mode: str = "gray") -> bytes:
    """Loads an image file, resizes to 640x480, and converts to grayscale or RGB565."""
    try:
        from PIL import Image
    except ImportError:
        sys.exit("ERROR: Pillow is required to load image files. Run 'pip install Pillow' or 'uv add Pillow'.")

    img = Image.open(image_path)
    img = img.resize((WIDTH, HEIGHT))

    if mode == "gray":
        img = img.convert("L")
        return img.tobytes()
    else:
        # RGB565 mode: 2 bytes per pixel
        img = img.convert("RGB")
        out = bytearray(WIDTH * HEIGHT * 2)
        idx = 0
        for r, g, b in img.getdata():
            # r5, g6, b5
            r5 = (r >> 3) & 0x1F
            g6 = (g >> 2) & 0x3F
            b5 = (b >> 3) & 0x1F
            byte1 = (r5 << 3) | (g6 >> 3)
            byte2 = ((g6 & 0x07) << 5) | b5
            out[idx] = byte1
            out[idx + 1] = byte2
            idx += 2
        return bytes(out)


def main():
    parser = argparse.ArgumentParser(description="Stream images to the FPGA star tracker.")
    parser.add_argument("--port", type=str, default="COM3", help="Serial port (e.g. COM3 or /dev/ttyUSB0)")
    parser.add_argument("--baud", type=int, default=921600, help="UART baud rate (default: 921600)")
    parser.add_argument("--image", type=Path, default=None, help="Path to image file (.png, .jpg)")
    parser.add_argument("--synthetic", action="store_true", help="Generate a synthetic star field")
    parser.add_argument("--mode", choices=["gray", "rgb565"], default="gray", help="Image mode (default: gray)")
    parser.add_argument("--dry-run", action="store_true", help="Format payload without transmitting")

    args = parser.parse_args()

    # 1. Prepare image payload
    if args.synthetic or args.image is None:
        print("Generating synthetic star field (640x480 grayscale)...")
        payload = create_synthetic_star_image()
    else:
        print(f"Loading image from {args.image} ({args.mode} mode)...")
        payload = load_image_bytes(args.image, args.mode)

    total_bytes = len(MAGIC_HEADER) + len(payload)
    print(f"Ready to transmit: {total_bytes:,} bytes (Header: 4B, Payload: {len(payload):,}B)")

    if args.dry_run:
        print("Dry-run complete. No hardware transmission performed.")
        return

    # 2. Connect to Serial Port
    try:
        import serial
    except ImportError:
        sys.exit("ERROR: pyserial is required to send data. Run 'pip install pyserial' or 'uv add pyserial'.")

    print(f"Connecting to {args.port} at {args.baud} baud...")
    try:
        ser = serial.Serial(args.port, baudrate=args.baud, timeout=2)
    except Exception as e:
        sys.exit(f"Failed to open {args.port}: {e}")

    # 3. Transmit with progress
    start_time = time.time()
    ser.write(MAGIC_HEADER)

    chunk_size = 4096
    sent = 0
    for i in range(0, len(payload), chunk_size):
        chunk = payload[i : i + chunk_size]
        ser.write(chunk)
        sent += len(chunk)
        pct = (sent / len(payload)) * 100
        print(f"\rProgress: {pct:5.1f}% [{sent:,}/{len(payload):,} bytes]", end="", flush=True)

    ser.flush()
    elapsed = time.time() - start_time
    rate_kb = (total_bytes / 1024) / max(elapsed, 0.001)
    print(f"\nDone! Sent {total_bytes:,} bytes in {elapsed:.2f}s ({rate_kb:.1f} KB/s).")
    ser.close()


if __name__ == "__main__":
    main()
