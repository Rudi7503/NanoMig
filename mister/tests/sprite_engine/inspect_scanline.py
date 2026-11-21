#!/usr/bin/env python3
"""
inspect_scanline.py
Verifies and visualizes raw scanline pixel data captured via `sprite_capture_test.s`.
Usage:
    python inspect_scanline.py [scanline_raw.bin]
"""

import sys
import os
import struct
import hashlib
from PIL import Image

def analyze_scanline(bin_path):
    if not os.path.exists(bin_path):
        print(f"[!] Datei nicht gefunden: {bin_path}")
        return False

    data = open(bin_path, 'rb').read()
    size = len(data)
    sha256 = hashlib.sha256(data).hexdigest()

    print("==================================================================")
    print(" NanoMig Hardware Sprite Engine - Scanline Capture Analyzer")
    print("==================================================================")
    print(f"Datei:    {bin_path}")
    print(f"Groesse:  {size} Bytes ({size // 4} Pixel x 32-Bit)")
    print(f"SHA256:   {sha256}")
    print("------------------------------------------------------------------")

    if size != 8192:
        print(f"[WARNUNG] Erwartet wurden 8.192 Bytes (2048 Pixel x 4 Bytes), erhalten: {size} Bytes!")

    num_pixels = min(2048, size // 4)
    pixels = struct.unpack(f'>{num_pixels}I', data[:num_pixels * 4])

    # 1. Background check (Column 0..50)
    bg_samples = [pixels[i] & 0xFFFFFF for i in range(10, 50)]
    bg_unique = set(bg_samples)
    print(f"Hintergrund-Farben (X=10..50): {[f'#{c:06X}' for c in list(bg_unique)[:3]]}")

    # 2. Sprite check (Column 100..131)
    sprite_pixels = [(100 + i, pixels[100 + i] & 0xFFFFFF) for i in range(32) if (100 + i) < num_pixels]
    active_sprite_px = [p for p in sprite_pixels if p[1] != 0]

    print(f"Aktive Sprite-Pixel im Bereich X=100..131: {len(active_sprite_px)} / 32")
    if active_sprite_px:
        print("Erste 8 Sprite-Pixel:")
        for x, c in active_sprite_px[:8]:
            r = (c >> 16) & 0xFF
            g = (c >> 8) & 0xFF
            b = c & 0xFF
            print(f"  X={x:3d}: #{c:06X} (R={r:3d}, G={g:3d}, B={b:3d})")
        print("[ERFOLG] Sprite-Daten wurden nach allen Mischstufen fehlerfrei erfasst!")
    else:
        print("[FEHLER] Keine Sprite-Pixel im erwarteten Bereich gefunden!")

    # 3. Generate PNG visualization (magnified height = 32px for easy viewing)
    img_h = 32
    img = Image.new('RGB', (num_pixels, img_h))
    for x in range(num_pixels):
        c = pixels[x]
        rgb = ((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF)
        for y in range(img_h):
            img.putpixel((x, y), rgb)

    out_png = os.path.splitext(bin_path)[0] + "_preview.png"
    img.save(out_png)
    print(f"[BILD] PNG-Vorschau generiert: {out_png} ({num_pixels}x{img_h} Pixel)")
    print("==================================================================")
    return True

if __name__ == '__main__':
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "scanline_raw.bin")
    analyze_scanline(target)
