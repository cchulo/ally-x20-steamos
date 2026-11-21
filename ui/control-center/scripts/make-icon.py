#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Draw the app icon (src-tauri/icons/icon.png) from scratch.

An original mark for this project: a dark rounded square with a 2x2 grid of
tiles, one of them red (the "selected" tile of the panel). Standard library
only. Usage: python3 scripts/make-icon.py [size]
"""
import struct
import sys
import zlib
from pathlib import Path

SIZE = int(sys.argv[1]) if len(sys.argv) > 1 else 512
BG = (22, 24, 28, 255)
TILE = (58, 63, 72, 255)
RED = (255, 45, 70, 255)
CLEAR = (0, 0, 0, 0)


def in_round_rect(x, y, x0, y0, x1, y1, r):
    if not (x0 <= x < x1 and y0 <= y < y1):
        return False
    cx = min(max(x, x0 + r), x1 - r - 1)
    cy = min(max(y, y0 + r), y1 - r - 1)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def pixel(x, y):
    s = SIZE
    if not in_round_rect(x, y, 0, 0, s, s, s * 0.18):
        return CLEAR
    pad, gap = s * 0.2, s * 0.08
    cell = (s - 2 * pad - gap) / 2
    for row in range(2):
        for col in range(2):
            x0 = pad + col * (cell + gap)
            y0 = pad + row * (cell + gap)
            if in_round_rect(x, y, x0, y0, x0 + cell, y0 + cell, s * 0.04):
                return RED if (row, col) == (0, 1) else TILE
    return BG


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def main():
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)
        for x in range(SIZE):
            raw.extend(pixel(x, y))
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    out = Path(__file__).resolve().parent.parent / "src-tauri" / "icons" / "icon.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(png)
    print(f"wrote {out} ({SIZE}x{SIZE}, {len(png)} bytes)")


if __name__ == "__main__":
    main()
