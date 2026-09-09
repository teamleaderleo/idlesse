#!/usr/bin/env python3
"""Rebuild the original Undertow contour artwork using only Python's standard library."""
import math
from pathlib import Path
import struct
import zlib

size = 2048
rows = bytearray()
for row in range(size):
    rows.append(0)  # PNG filter: none
    y = row / (size - 1) * 2 - 1
    for column in range(size):
        x = column / (size - 1) * 2 - 1
        dx = x + 0.22 * math.sin(y * 3.5) - 0.12
        dy = y * 0.8 + 0.10 * math.sin(x * 3)
        radius = math.sqrt(dx * dx + dy * dy + 0.018)
        phase = radius * 115 + 2.2 * math.sin(y * 5 + x * 2)
        # Soft edges prevent harsh stair steps when the wallpaper is scaled down.
        stripe = min(1, max(0, math.sin(phase) * 5 + 0.5))
        stripe = stripe * stripe * (3 - 2 * stripe)
        warmth = min(1, max(0, 0.5 + y * 0.5 + x * 0.22))
        dark = (0.065, 0.035, 0.15)
        light = (0.95, 0.30 + warmth * 0.29, 0.62 - warmth * 0.38)
        edge = 1 - min(0.25, (x * x + y * y) * 0.07)
        rows.extend(round((a + (b - a) * stripe) * edge * 255) for a, b in zip(dark, light))

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(rows, 9))
png += chunk(b"IEND", b"")
output = Path(__file__).resolve().parent.parent / "Examples/Undertow.idlesse/assets/contours.png"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_bytes(png)
print(f"Undertow: {size}×{size}, {len(png):,} bytes")
