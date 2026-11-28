#!/usr/bin/env python3
"""
generate_amiga_test.py
Generates binary test assets and the AmigaOS 68000 assembly test harness `sprite_engine_test.s`.
"""

import struct
import os
import math

OUT_DIR = os.path.dirname(os.path.abspath(__file__))

def create_palette():
    # 256 entries x 24-bit (0x00RRGGBB)
    pal = [0x00000000] # Slot 0: transparent
    # Slots 1..63: Red to Yellow gradient
    for i in range(1, 64):
        r = int(i * 255 / 63)
        g = int(i * 180 / 63)
        b = 20
        pal.append((r << 16) | (g << 8) | b)
    # Slots 64..127: Blue to Cyan gradient
    for i in range(64):
        r = 10
        g = int(i * 240 / 63)
        b = int(120 + i * 135 / 63)
        pal.append((r << 16) | (g << 8) | b)
    # Slots 128..191: Green to Lime gradient
    for i in range(64):
        r = int(i * 200 / 63)
        g = int(80 + i * 175 / 63)
        b = 15
        pal.append((r << 16) | (g << 8) | b)
    # Slots 192..255: Purple to White gradient
    for i in range(64):
        r = int(140 + i * 115 / 63)
        g = int(i * 255 / 63)
        b = int(180 + i * 75 / 63)
        pal.append((r << 16) | (g << 8) | b)
    return pal[:256]

def create_sprite_pattern_clut8(w=32, h=32):
    # Generates a smooth spherical 32x32 ball in CLUT-8
    # 0 = transparent outside circle
    # 1..63 = shaded sphere
    data = bytearray(w * h)
    cx, cy = w / 2.0, h / 2.0
    radius = w / 2.0 - 1.0
    
    for y in range(h):
        for x in range(w):
            dx = x - cx
            dy = y - cy
            dist = math.sqrt(dx*dx + dy*dy)
            if dist < radius:
                # 3D sphere shading
                nz = math.sqrt(max(0.0, radius*radius - dx*dx - dy*dy)) / radius
                # light from top-left (-0.5, -0.5, 0.7)
                lx, ly, lz = -0.5, -0.5, 0.7
                l_len = math.sqrt(lx*lx + ly*ly + lz*lz)
                lx, ly, lz = lx/l_len, ly/l_len, lz/l_len
                diff = max(0.0, (dx/radius)*lx + (dy/radius)*ly + nz*lz)
                color_idx = int(1 + diff * 60)
                data[y * w + x] = min(63, max(1, color_idx))
            else:
                data[y * w + x] = 0 # Transparent
    return bytes(data)

def encode_descriptor(y_pos, x_pos, height, width_px, data_ptr, fmt=7, flags=0, prio=0xC0, alpha=255, x_scale=64, y_scale=64):
    """
    16-Byte Big-Endian Descriptor:
    Word 0: Y_POS (12-bit signed, [63:52])
    Word 1: X_POS (12-bit signed, [51:40]), FLAGS ([39:32])
    Word 2..3: DATA_PTR (32-bit Fast-RAM pointer, [31:0])
    Word 4: HEIGHT (12-bit, [63:52]), WIDTH_PX (12-bit, [51:40])
    Word 5: FMT (8-bit, [39:32]), PRIO (8-bit, [31:24])
    Word 6: ALPHA (8-bit, [23:16]), X_SCALE (8-bit, [15:8])
    Word 7: Y_SCALE (8-bit, [7:0])
    """
    # 64-bit word 0:
    # [63:52] y_pos (12b)
    # [51:40] x_pos (12b)
    # [39:32] flags (8b)
    # [31:0]  data_ptr (32b)
    w0_hi = ((y_pos & 0xFFF) << 20) | ((x_pos & 0xFFF) << 8) | (flags & 0xFF)
    w0_lo = data_ptr & 0xFFFFFFFF
    word0 = struct.pack('>II', w0_hi, w0_lo)

    # 64-bit word 1:
    # [63:52] height (12b)
    # [51:40] width_px (12b)
    # [39:32] fmt (8b)
    # [31:24] prio (8b)
    # [23:16] alpha (8b)
    # [15:8]  x_scale (8b)
    # [7:0]   y_scale (8b)
    w1_hi = ((height & 0xFFF) << 20) | ((width_px & 0xFFF) << 8) | (fmt & 0xFF)
    w1_lo = ((prio & 0xFF) << 24) | ((alpha & 0xFF) << 16) | ((x_scale & 0xFF) << 8) | (y_scale & 0xFF)
    word1 = struct.pack('>II', w1_hi, w1_lo)

    return word0 + word1

# Write palette file
pal = create_palette()
with open(os.path.join(OUT_DIR, "test_palette.bin"), "wb") as f:
    for c in pal:
        f.write(struct.pack('>I', c))

# Write sprite bitmap
sprite_raw = create_sprite_pattern_clut8(32, 32)
with open(os.path.join(OUT_DIR, "test_sprite32.bin"), "wb") as f:
    f.write(sprite_raw)

print(f"Generated test_palette.bin (256 entries = {len(pal)*4} bytes)")
print(f"Generated test_sprite32.bin (32x32 CLUT-8 = {len(sprite_raw)} bytes)")
