#!/usr/bin/env python3
"""
Generates the official versioned JSON fixture suite for NanoMig Sprite Engine Rev. 3.
Output file: fixtures/sprite_engine_fixtures_v3.json
"""

import json
import os
import sys
from typing import Dict, Any, List

# Ensure local module import
sys.path.insert(0, os.path.dirname(__file__))
from sprite_ref_model import (
    DESC_REV,
    SpriteDescriptor,
    pack_descriptor_raw,
    unpack_descriptor_raw,
    render_scanline,
    LineStats,
    FORMAT_SEQS_64,
)

FIXTURES_DIR = os.path.join(os.path.dirname(__file__), "fixtures")
os.makedirs(FIXTURES_DIR, exist_ok=True)
FIXTURE_PATH = os.path.join(FIXTURES_DIR, "sprite_engine_fixtures_v3.json")


def desc_to_dict(d: SpriteDescriptor) -> Dict[str, Any]:
    raw_b = pack_descriptor_raw(d)
    return {
        "raw_hex": raw_b.hex(),
        "y_pos": d.y_pos,
        "x_pos": d.x_pos,
        "y_height_lo": d.y_height_lo,
        "y_height11": d.y_height11,
        "x_width256": d.x_width256,
        "prio": d.prio,
        "pal_offset": d.pal_offset,
        "data_ptr": hex(d.data_ptr),
        "fmt": d.fmt,
        "fmt5": d.fmt5,
        "flags": d.flags,
        "h_flip": d.h_flip,
        "v_flip": d.v_flip,
        "smooth_x": d.smooth_x,
        "prio_ge": d.prio_ge,
        "x_scale": d.x_scale,
        "y_scale": d.y_scale,
        "step_ctrl": d.step_ctrl,
        "clut_mode": d.clut_mode,
        "custom_step": d.custom_step,
        "blend_mode": d.blend_mode,
        "spr_alpha": d.spr_alpha,
    }


def generate_suite() -> Dict[str, Any]:
    palette = [0x000000] * 256
    palette[1] = 0xFF0000  # Red
    palette[2] = 0x00FF00  # Green
    palette[3] = 0x0000FF  # Blue
    palette[4] = 0xFFFFFF  # White
    palette[5] = 0x000000  # Opaque black in palette
    palette[6] = 0x804020  # Brown

    suite: Dict[str, Any] = {
        "desc_rev": DESC_REV,
        "generator": "generate_fixtures.py",
        "description": "Comprehensive reference test suite for NanoMig Sprite Engine Rev. 3",
        "global_steps": [4, 4, 4],
        "palette_sample": {i: hex(palette[i]) for i in range(7)},
        "test_cases": {},
    }

    # -------------------------------------------------------------------------
    # Case 1: Raw Descriptor Pack / Unpack Roundtrip & Masking
    # -------------------------------------------------------------------------
    raw_tests = []
    d_cases = [
        SpriteDescriptor(-1500, 100, 1080 & 0xFF, 1, 200, 0, 0x00100008 | ((1080 >> 8) & 0x7), 1, 0b1101, 0x40, 16, 0x40),
        SpriteDescriptor(0, 0, 16, 4, 150, 64, 0x00200000, 12, 0, 0x40, 0x40, 0x80 | 0b11_10_01),
        SpriteDescriptor(100, -50, 32, 2, 80, 200, 0x00300008, 2, 0b0110, 0x20, 0x80, 0b01_0000), # Additive blend
    ]
    for d in d_cases:
        packed = pack_descriptor_raw(d)
        unpacked = unpack_descriptor_raw(packed)
        raw_tests.append({
            "orig": desc_to_dict(d),
            "packed_hex": packed.hex(),
            "unpacked": desc_to_dict(unpacked),
            "verified": (unpacked.y_pos == d.y_pos and unpacked.x_pos == d.x_pos and unpacked.fmt5 == d.fmt5)
        })
    suite["test_cases"]["raw_descriptor_roundtrip"] = raw_tests

    # -------------------------------------------------------------------------
    # Case 2: Negative Coordinates & Horizontal/Vertical Clipping
    # -------------------------------------------------------------------------
    ram_neg: Dict[int, int] = {
        0x00100000: 0x01020304_04030201,
        0x00100008: 0x01020304_04030201,
        0x00100010: 0x01020304_04030201,
        0x00100018: 0x01020304_04030201,
    }
    d_neg = SpriteDescriptor(y_pos=-10, x_pos=-8, y_height_lo=20, x_width256=1, prio=180, pal_offset=0,
                             data_ptr=0x00100000, fmt=12, flags=0, x_scale=0x40, y_scale=0x40, step_ctrl=0x40)
    lb_neg = render_scanline(0, [d_neg], ram_neg, palette, clip_xmax=320)
    suite["test_cases"]["negative_coords_clip"] = {
        "descriptor": desc_to_dict(d_neg),
        "next_y": 0,
        "clip_xmax": 320,
        "non_zero_pixels": {x: hex(lb_neg[x]) for x in range(len(lb_neg)) if lb_neg[x] != 0},
    }

    # -------------------------------------------------------------------------
    # Case 3: Scale Extrema (16, 63, 65, 255)
    # -------------------------------------------------------------------------
    scale_tests = {}
    for sc in (16, 63, 65, 255):
        d_sc = SpriteDescriptor(y_pos=0, x_pos=10, y_height_lo=10, x_width256=1, prio=180, pal_offset=0,
                                data_ptr=0x00100000, fmt=12, flags=0, x_scale=sc, y_scale=sc, step_ctrl=0x40)
        lb_sc = render_scanline(0, [d_sc], ram_neg, palette, clip_xmax=320)
        active_px = [x for x in range(len(lb_sc)) if lb_sc[x] != 0]
        scale_tests[f"scale_{sc}"] = {
            "scale": sc,
            "count": len(active_px),
            "first_x": active_px[0] if active_px else None,
            "last_x": active_px[-1] if active_px else None,
        }
    suite["test_cases"]["scale_extrema"] = scale_tests

    # -------------------------------------------------------------------------
    # Case 4: Equal Priority Arbitration (PRIO_GE = 0 vs PRIO_GE = 1)
    # -------------------------------------------------------------------------
    # Sprite 1 writes color Red (slot 1) at prio 150
    # Sprite 2 writes color Green (slot 2) at prio 150
    ram_prio: Dict[int, int] = {
        0x00200000: 0x01010101_01010101,
        0x00200008: 0x01010101_01010101,
        0x00200010: 0x01010101_01010101,
        0x00200018: 0x01010101_01010101,
        0x00200020: 0x02020202_02020202,
        0x00200028: 0x02020202_02020202,
        0x00200030: 0x02020202_02020202,
        0x00200038: 0x02020202_02020202,
    }
    d_prio1 = SpriteDescriptor(0, 0, 1, 1, 150, 0, 0x00200000, 12, 0, 0x40, 0x40, 0x40)
    # PRIO_GE = 0: sprite 2 should NOT overwrite sprite 1
    d_prio2_no = SpriteDescriptor(0, 0, 1, 1, 150, 0, 0x00200020, 12, 0, 0x40, 0x40, 0x40)
    # PRIO_GE = 1: sprite 2 SHOULD overwrite sprite 1
    d_prio2_yes = SpriteDescriptor(0, 0, 1, 1, 150, 0, 0x00200020, 12, 0b1000, 0x40, 0x40, 0x40)

    lb_prio_no = render_scanline(0, [d_prio1, d_prio2_no], ram_prio, palette)
    lb_prio_yes = render_scanline(0, [d_prio1, d_prio2_yes], ram_prio, palette)

    suite["test_cases"]["prio_ge_arbitration"] = {
        "prio_ge_0_color": f"0x{lb_prio_no[0] & 0xFFFFFF:06x}",   # Red: 0xff0000
        "prio_ge_1_color": f"0x{lb_prio_yes[0] & 0xFFFFFF:06x}",  # Green: 0x00ff00
        "verified": ((lb_prio_no[0] & 0xFFFFFF) == 0xFF0000 and (lb_prio_yes[0] & 0xFFFFFF) == 0x00FF00)
    }

    # -------------------------------------------------------------------------
    # Case 5: Opaque Black Semantics vs Transparency
    # -------------------------------------------------------------------------
    # FORMAT 17: RGB565 vs RGB555 (0x8000 = opaque black in RGB555)
    # FORMAT 15: HAM12 delta 0x800 after reset = opaque black
    # CLUT: palette slot 5 = 0x000000 = opaque black
    # Raw code 0 = transparent
    ram_black: Dict[int, int] = {
        0x00300000: (0x8000 << 48) | (0x0000 << 32) | (0x8000 << 16) | 0x0000, # RGB16
        0x00300008: 0x00000000_00000000,
        0x00300010: 0x00000000_00000000,
        0x00300018: 0x00000000_00000000,
    }
    # RGB555: 0x8000 is opaque black (CLUT_MODE=1)
    d_black_555 = SpriteDescriptor(0, 0, 1, 1, 160, 0, 0x00300008, 1, 0, 0x40, 0x40, 0x40)
    lb_black = render_scanline(0, [d_black_555], ram_black, palette)
    suite["test_cases"]["opaque_black_semantics"] = {
        "pixel_0_opaque_black": hex(lb_black[0]), # Should be (160 << 24) | 0x000000
        "pixel_1_transparent": hex(lb_black[1]),  # Should be 0
        "verified": (lb_black[0] == ((160 << 24) | 0x000000) and lb_black[1] == 0)
    }

    # -------------------------------------------------------------------------
    # Case 6: 4 Hardware Blend Modes
    # -------------------------------------------------------------------------
    # Destination background = (100, 100, 100) = 0x646464 at prio 100
    # Source foreground = (150, 50, 20) = 0x963214 at prio 180
    palette[10] = 0x646464
    palette[11] = 0x963214
    ram_blend: Dict[int, int] = {
        0x00400000: 0x0A0A0A0A_0A0A0A0A,
        0x00400008: 0x0A0A0A0A_0A0A0A0A,
        0x00400010: 0x0A0A0A0A_0A0A0A0A,
        0x00400018: 0x0A0A0A0A_0A0A0A0A,
        0x00400020: 0x0B0B0B0B_0B0B0B0B,
        0x00400028: 0x0B0B0B0B_0B0B0B0B,
        0x00400030: 0x0B0B0B0B_0B0B0B0B,
        0x00400038: 0x0B0B0B0B_0B0B0B0B,
    }
    d_dest = SpriteDescriptor(0, 0, 1, 1, 100, 0, 0x00400000, 12, 0, 0x40, 0x40, 0x40)
    blend_results = {}
    for mode, name in [(0, "opaque"), (1, "additive"), (2, "translucent_50_50"), (3, "alpha_8bit")]:
        ctrl = 0x40 | (mode << 4)
        pal_off = 128 if mode == 3 else 0
        d_src = SpriteDescriptor(0, 0, 1, 1, 180, pal_off, 0x00400020, 12, 0, 0x40, 0x40, ctrl)
        lb_b = render_scanline(0, [d_dest, d_src], ram_blend, palette)
        blend_results[name] = {
            "mode": mode,
            "prio": lb_b[0] >> 24,
            "rgb_hex": f"0x{lb_b[0] & 0xFFFFFF:06x}",
        }
    suite["test_cases"]["blend_modes"] = blend_results

    # -------------------------------------------------------------------------
    # Case 7: FORMAT 18 (ARGB8888 TrueColor)
    # -------------------------------------------------------------------------
    w64_argb = (0xFF804020 << 32) | 0x80FF0080
    ram_argb: Dict[int, int] = {
        0x00500000: w64_argb,
        0x00500008: 0x00000000_00000000,
        0x00500010: w64_argb,
        0x00500018: 0x00000000_00000000,
    }
    d_argb = SpriteDescriptor(0, 0, 1, 1, 210, 0, 0x00500008, 2, 0, 0x40, 0x40, 0x00)
    lb_argb = render_scanline(0, [d_argb], ram_argb, palette)
    suite["test_cases"]["format_18_argb"] = {
        "fmt5": d_argb.fmt5,
        "pixel_0": hex(lb_argb[0]),
        "pixel_1": hex(lb_argb[1]),
        "pixel_2": hex(lb_argb[2]), # Skipped zero
    }

    return suite


def main() -> None:
    suite = generate_suite()
    with open(FIXTURE_PATH, "w", encoding="utf-8") as f:
        json.dump(suite, f, indent=2)
    print(f"Generated official fixture suite: {FIXTURE_PATH}")
    print(f"Total test categories: {len(suite['test_cases'])}")


if __name__ == "__main__":
    main()
