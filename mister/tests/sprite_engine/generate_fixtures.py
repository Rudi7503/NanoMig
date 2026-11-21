#!/usr/bin/env python3
"""
Generates the official versioned JSON fixture suite for NanoMig Sprite Engine Rev. 4.
Output file: fixtures/sprite_engine_fixtures_v4.json

All fixtures contain full raw descriptors (16 bytes Motorola Big-Endian),
RAM, palette, and expected linebuffer pixels so they can be independently
rendered and verified by Python, Browser JS, and hardware testbenches.
"""

import json
import os
import sys
from typing import Dict, Any, List, Tuple

sys.path.insert(0, os.path.dirname(__file__))
from sprite_ref_model import (
    DESC_REV,
    SpriteDescriptor,
    pack_descriptor_raw,
    unpack_descriptor_raw,
    render_scanline,
    denise_mix_pixel,
)

FIXTURES_DIR = os.path.join(os.path.dirname(__file__), "fixtures")
os.makedirs(FIXTURES_DIR, exist_ok=True)
FIXTURE_PATH = os.path.join(FIXTURES_DIR, "sprite_engine_fixtures_v4.json")


def make_case(
    name: str,
    descs: List[SpriteDescriptor],
    ram: Dict[int, int],
    palette: List[int],
    next_y: int = 0,
    clip_xmax: int = 320,
    global_steps: Tuple[int, int, int] = (4, 4, 4),
    zero_skip: bool = True,
) -> Dict[str, Any]:
    lb = render_scanline(
        next_y,
        descs,
        ram,
        palette,
        global_steps=global_steps,
        clip_xmax=clip_xmax,
        zero_word_skip_en=zero_skip,
    )
    non_zero = {str(x): f"0x{lb[x]:08x}" for x in range(len(lb)) if lb[x] != 0}

    raw_descs = [pack_descriptor_raw(d).hex() for d in descs]
    ram_hex = {f"0x{addr:08x}": f"0x{val:016x}" for addr, val in ram.items()}

    return {
        "name": name,
        "next_y": next_y,
        "clip_xmax": clip_xmax,
        "global_steps": list(global_steps),
        "zero_skip": zero_skip,
        "raw_descriptors_hex": raw_descs,
        "ram_words64": ram_hex,
        "palette_sparse": {str(i): f"0x{c:06x}" for i, c in enumerate(palette) if c != 0},
        "expected_non_zero_pixels": non_zero,
    }


def generate_suite() -> Dict[str, Any]:
    palette = [0x000000] * 256
    palette[1] = 0xFF0000   # Red
    palette[2] = 0x00FF00   # Green
    palette[3] = 0x0000FF   # Blue
    palette[4] = 0xFFFFFF   # White
    palette[5] = 0x000000   # Opaque black
    palette[6] = 0x804020   # Brown
    palette[10] = 0x646464  # Grey (100, 100, 100)
    palette[11] = 0x963214  # Orange (150, 50, 20)
    palette[129] = 0x00FF00 # Green for pal_offset=128 in fmt 11/12

    suite: Dict[str, Any] = {
        "desc_rev": DESC_REV,
        "generator": "generate_fixtures.py",
        "description": "Comprehensive reference fixture suite for NanoMig Sprite Engine Rev. 4",
        "cases": {},
    }

    # -------------------------------------------------------------------------
    # 1. Negative Coordinates & Offscreen Clipping (Y_POS = -10, rel_y = 10)
    # -------------------------------------------------------------------------
    ram_neg: Dict[int, int] = {}
    for line_idx in range(20):
        base = 0x00100000 + (line_idx << 5)
        pattern = (0x01020304 << 32) | 0x04030201 if line_idx == 10 else 0x02020202_02020202
        ram_neg[base + 0] = pattern
        ram_neg[base + 8] = pattern
        ram_neg[base + 16] = pattern
        ram_neg[base + 24] = pattern

    d_neg = SpriteDescriptor(
        y_pos=-10, x_pos=-4, data_ptr=0x00100000, height=20, width=1,
        format=12, prio=180, alpha=0, ctrl=0
    )
    suite["cases"]["negative_coords_clip"] = make_case("negative_coords_clip", [d_neg], ram_neg, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 2. H_FLIP & V_FLIP Non-Symmetric Rendering
    # -------------------------------------------------------------------------
    ram_flip: Dict[int, int] = {}
    for line_idx in range(4):
        base = 0x00200000 + (line_idx << 5)
        p = ((line_idx + 1) << 24) | ((line_idx + 2) << 16) | ((line_idx + 3) << 8) | (line_idx + 4)
        ram_flip[base + 0] = (p << 32) | p
        ram_flip[base + 8] = (p << 32) | p
        ram_flip[base + 16] = (p << 32) | p
        ram_flip[base + 24] = (p << 32) | p

    # Normal vs H_FLIP (bit 6) vs V_FLIP (bit 7)
    d_norm = SpriteDescriptor(y_pos=0, x_pos=10, data_ptr=0x00200000, height=4, width=1, format=12, prio=150, alpha=0, ctrl=0)
    d_hflip = SpriteDescriptor(y_pos=0, x_pos=41, data_ptr=0x00200000, height=4, width=1, format=12, prio=150, alpha=0, ctrl=(1 << 6))
    d_vflip = SpriteDescriptor(y_pos=0, x_pos=50, data_ptr=0x00200000, height=4, width=1, format=12, prio=150, alpha=0, ctrl=(1 << 7))

    suite["cases"]["flip_normal"] = make_case("flip_normal", [d_norm], ram_flip, palette, next_y=0)
    suite["cases"]["flip_h"] = make_case("flip_h", [d_hflip], ram_flip, palette, next_y=0)
    suite["cases"]["flip_v"] = make_case("flip_v", [d_vflip], ram_flip, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 3. PRIO_GE Arbitration (PRIO_GE = 0 vs PRIO_GE = 1, bit 11)
    # -------------------------------------------------------------------------
    ram_prio: Dict[int, int] = {
        0x00300000: 0x01010101_01010101, 0x00300008: 0x01010101_01010101,
        0x00300010: 0x01010101_01010101, 0x00300018: 0x01010101_01010101,
        0x00300020: 0x02020202_02020202, 0x00300028: 0x02020202_02020202,
        0x00300030: 0x02020202_02020202, 0x00300038: 0x02020202_02020202,
    }
    d_prio_base = SpriteDescriptor(y_pos=0, x_pos=0, data_ptr=0x00300000, height=1, width=1, format=12, prio=150, alpha=0, ctrl=0)
    d_prio_ge0 = SpriteDescriptor(y_pos=0, x_pos=0, data_ptr=0x00300020, height=1, width=1, format=12, prio=150, alpha=0, ctrl=0)
    d_prio_ge1 = SpriteDescriptor(y_pos=0, x_pos=0, data_ptr=0x00300020, height=1, width=1, format=12, prio=150, alpha=0, ctrl=(1 << 11))

    suite["cases"]["prio_ge_0"] = make_case("prio_ge_0", [d_prio_base, d_prio_ge0], ram_prio, palette, next_y=0)
    suite["cases"]["prio_ge_1"] = make_case("prio_ge_1", [d_prio_base, d_prio_ge1], ram_prio, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 4. Opaque Black Semantics vs Transparency in RGB16 (FMT 15)
    # -------------------------------------------------------------------------
    ram_rgb16: Dict[int, int] = {
        0x00400000: (0x8000 << 48) | (0x0000 << 32) | (0xF800 << 16) | 0x0000,
        0x00400008: 0, 0x00400010: 0, 0x00400018: 0,
    }
    # 0x8000 is Dark Red (128, 0, 0), 0x0000 is Transparent, 0xF800 is Bright Red (255, 0, 0)
    d_rgb16 = SpriteDescriptor(y_pos=0, x_pos=0, data_ptr=0x00400000, height=1, width=1, format=15, prio=160, alpha=255, ctrl=0)
    suite["cases"]["opaque_black"] = make_case("opaque_black", [d_rgb16], ram_rgb16, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 5. All 4 Hardware Blend Modes (00 Opaque, 01 Additive, 10 50/50, 11 Alpha)
    # -------------------------------------------------------------------------
    ram_blend: Dict[int, int] = {
        0x00500000: 0x0A0A0A0A_0A0A0A0A, 0x00500008: 0x0A0A0A0A_0A0A0A0A,
        0x00500010: 0x0A0A0A0A_0A0A0A0A, 0x00500018: 0x0A0A0A0A_0A0A0A0A,
        0x00500020: 0x0B0B0B0B_0B0B0B0B, 0x00500028: 0x0B0B0B0B_0B0B0B0B,
        0x00500030: 0x0B0B0B0B_0B0B0B0B, 0x00500038: 0x0B0B0B0B_0B0B0B0B,
    }
    d_bg = SpriteDescriptor(y_pos=0, x_pos=0, data_ptr=0x00500000, height=1, width=1, format=12, prio=100, alpha=0, ctrl=0)
    for mode_val, mode_name in [(0, "opaque"), (1, "additive"), (2, "translucent_50_50"), (3, "alpha_8bit")]:
        d_fg = SpriteDescriptor(
            y_pos=0, x_pos=0, data_ptr=0x00500020, height=1, width=1,
            format=15 if mode_val == 3 else 12, # Use FMT 15 with alpha for mode 3
            prio=180, alpha=128 if mode_val == 3 else 0, ctrl=(mode_val << 9)
        )
        suite["cases"][f"blend_{mode_name}"] = make_case(f"blend_{mode_name}", [d_bg, d_fg], ram_blend, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 6. FORMAT 16 (ARGB32 TrueColor) Alpha Sweep (0, 1, 128, 255)
    # -------------------------------------------------------------------------
    # Pixel 0: Alpha=0 (transparent, WE=0!)
    # Pixel 1: Alpha=1 (subtle)
    # Pixel 2: Alpha=128 (50%)
    # Pixel 3: Alpha=255 (100% full saturation)
    w64_argb_sweep0 = (0x00FF0000 << 32) | 0x01FF0000
    w64_argb_sweep1 = (0x80FF0000 << 32) | 0xFFFF0000
    ram_argb_sweep: Dict[int, int] = {
        0x00600000: w64_argb_sweep0, 0x00600008: w64_argb_sweep1,
        0x00600010: 0, 0x00600018: 0,
    }
    # Sprite over destination background (Grey: 100, 100, 100 = 0x646464 at prio 100)
    d_argb_sweep = SpriteDescriptor(
        y_pos=0, x_pos=0, data_ptr=0x00600000, height=1, width=1,
        format=16, prio=200, alpha=0, ctrl=(3 << 9) # Blend 3 (Alpha)
    )
    suite["cases"]["format_16_argb_sweep"] = make_case("format_16_argb_sweep", [d_bg, d_argb_sweep], {**ram_blend, **ram_argb_sweep}, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 7. FORMAT 11 and 12 PAL_OFFSET Preservation
    # -------------------------------------------------------------------------
    # FORMAT 11: 12-6-8-6
    w64_f11 = (0x7F8 << 52) | (0x01 << 46) | (0x01 << 38) | (0x01 << 32)
    ram_f11: Dict[int, int] = {0x00700000: w64_f11, 0x00700008: 0, 0x00700010: 0, 0x00700018: 0}
    d_f11_0 = SpriteDescriptor(y_pos=0, x_pos=0, data_ptr=0x00700000, height=1, width=1, format=11, prio=180, alpha=0, ctrl=0)
    d_f11_128 = SpriteDescriptor(y_pos=0, x_pos=0, data_ptr=0x00700000, height=1, width=1, format=11, prio=180, alpha=128, ctrl=0)
    suite["cases"]["format_11_pal_0"] = make_case("format_11_pal_0", [d_f11_0], ram_f11, palette, next_y=0)
    suite["cases"]["format_11_pal_128"] = make_case("format_11_pal_128", [d_f11_128], ram_f11, palette, next_y=0)

    # FORMAT 12: 12-5-5-5-5 (HAM12 direct anchor + 4x HAM05 palette anchors)
    w32_f12 = (0x7F8 << 20) | (0x01 << 15) | (0x01 << 10) | (0x01 << 5) | 0x01
    w64_f12 = (w32_f12 << 32) | w32_f12
    ram_f12: Dict[int, int] = {0x00800000: w64_f12, 0x00800008: 0, 0x00800010: 0, 0x00800018: 0}
    d_f12_0 = SpriteDescriptor(y_pos=0, x_pos=0, data_ptr=0x00800000, height=1, width=1, format=12, prio=180, alpha=0, ctrl=0)
    d_f12_128 = SpriteDescriptor(y_pos=0, x_pos=0, data_ptr=0x00800000, height=1, width=1, format=12, prio=180, alpha=128, ctrl=0)
    suite["cases"]["format_12_pal_0"] = make_case("format_12_pal_0", [d_f12_0], ram_f12, palette, next_y=0)
    suite["cases"]["format_12_pal_128"] = make_case("format_12_pal_128", [d_f12_128], ram_f12, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 8. Opaque Black in HAM16 Direct (FMT 14) & Multiline V_FLIP
    # -------------------------------------------------------------------------
    # HAM16 Direct (FMT 14): 0x8000 = Red anchor R=0 -> (0, 0, 0)
    w64_h16 = (0x8000 << 48) | (0x0000 << 32) | (0x8000 << 16) | 0x0000
    ram_h16: Dict[int, int] = {0x00810000: w64_h16, 0x00810008: 0, 0x00810010: 0, 0x00810018: 0}
    d_h16_black = SpriteDescriptor(y_pos=0, x_pos=0, data_ptr=0x00810000, height=1, width=1, format=14, prio=190, alpha=0, ctrl=0)
    suite["cases"]["opaque_black_ham16"] = make_case("opaque_black_ham16", [d_h16_black], ram_h16, palette, next_y=0)

    # V_FLIP Multiline at next_y = 3 (accesses source line (4-1)-3 = 0, inverting flip_v at next_y=0)
    suite["cases"]["flip_v_y3"] = make_case("flip_v_y3", [d_vflip], ram_flip, palette, next_y=3)

    # -------------------------------------------------------------------------
    # 9. Zero-Word-Skip Pair Verification
    # -------------------------------------------------------------------------
    ram_skip_pair: Dict[int, int] = {
        0x00900000: 0x01020304_00000000,
        0x00900008: 0x00000000_00000000, # Zero word -> skipped in 1 cycle
        0x00900010: 0x05060708_00000000,
        0x00900018: 0x00000000_00000000,
    }
    d_skip = SpriteDescriptor(y_pos=0, x_pos=0, data_ptr=0x00900000, height=1, width=1, format=12, prio=170, alpha=0, ctrl=0)
    suite["cases"]["skip_pair_on"] = make_case("skip_pair_on", [d_skip], ram_skip_pair, palette, next_y=0, zero_skip=True)
    suite["cases"]["skip_pair_off"] = make_case("skip_pair_off", [d_skip], ram_skip_pair, palette, next_y=0, zero_skip=False)

    return suite


def main() -> None:
    suite = generate_suite()
    with open(FIXTURE_PATH, "w", encoding="utf-8") as f:
        json.dump(suite, f, indent=2)
    print(f"Generated official fixture suite: {FIXTURE_PATH}")
    print(f"Total test cases: {len(suite['cases'])}")


if __name__ == "__main__":
    main()
