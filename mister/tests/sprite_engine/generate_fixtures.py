#!/usr/bin/env python3
"""
Generates the official versioned JSON fixture suite for NanoMig Sprite Engine Rev. 3.
Output file: fixtures/sprite_engine_fixtures_v3.json

All fixtures contain full raw descriptors, RAM, palette, and expected linebuffer pixels
so they can be independently rendered and verified by Python, Browser JS, and hardware testbenches.
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
FIXTURE_PATH = os.path.join(FIXTURES_DIR, "sprite_engine_fixtures_v3.json")


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
    palette[1] = 0xFF0000  # Red
    palette[2] = 0x00FF00  # Green
    palette[3] = 0x0000FF  # Blue
    palette[4] = 0xFFFFFF  # White
    palette[5] = 0x000000  # Opaque black
    palette[6] = 0x804020  # Brown
    palette[10] = 0x646464 # Grey (100, 100, 100)
    palette[11] = 0x963214 # Orange (150, 50, 20)
    palette[129] = 0x00FF00 # Green for pal_offset=128 in fmt 13/14

    suite: Dict[str, Any] = {
        "desc_rev": DESC_REV,
        "generator": "generate_fixtures.py",
        "description": "Comprehensive reference fixture suite for NanoMig Sprite Engine Rev. 3",
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
        y_pos=-10, x_pos=-4, y_height_lo=20, x_width256=1, prio=180, pal_offset=0,
        data_ptr=0x00100000, fmt=12, flags=0, x_scale=0x40, y_scale=0x40, step_ctrl=0x40
    )
    suite["cases"]["negative_coords_clip"] = make_case("negative_coords_clip", [d_neg], ram_neg, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 2. H_FLIP & V_FLIP Non-Symmetric Rendering
    # -------------------------------------------------------------------------
    ram_flip: Dict[int, int] = {}
    for line_idx in range(4):
        base = 0x00200000 + (line_idx << 5)
        # Row 0: 1, 2, 3, 4; Row 1: 2, 3, 4, 1, etc.
        p = ((line_idx + 1) << 24) | ((line_idx + 2) << 16) | ((line_idx + 3) << 8) | (line_idx + 4)
        ram_flip[base + 0] = (p << 32) | p
        ram_flip[base + 8] = (p << 32) | p
        ram_flip[base + 16] = (p << 32) | p
        ram_flip[base + 24] = (p << 32) | p

    # Normal vs H_FLIP vs V_FLIP
    d_norm = SpriteDescriptor(0, 10, 4, 1, 150, 0, 0x00200000, 12, 0b0000, 0x40, 0x40, 0x40)
    d_hflip = SpriteDescriptor(0, 41, 4, 1, 150, 0, 0x00200000, 12, 0b0001, 0x40, 0x40, 0x40) # H_FLIP
    d_vflip = SpriteDescriptor(0, 50, 4, 1, 150, 0, 0x00200000, 12, 0b0010, 0x40, 0x40, 0x40) # V_FLIP

    suite["cases"]["flip_normal"] = make_case("flip_normal", [d_norm], ram_flip, palette, next_y=0)
    suite["cases"]["flip_h"] = make_case("flip_h", [d_hflip], ram_flip, palette, next_y=0)
    suite["cases"]["flip_v"] = make_case("flip_v", [d_vflip], ram_flip, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 3. PRIO_GE Arbitration (PRIO_GE = 0 vs PRIO_GE = 1)
    # -------------------------------------------------------------------------
    ram_prio: Dict[int, int] = {
        0x00300000: 0x01010101_01010101, 0x00300008: 0x01010101_01010101,
        0x00300010: 0x01010101_01010101, 0x00300018: 0x01010101_01010101,
        0x00300020: 0x02020202_02020202, 0x00300028: 0x02020202_02020202,
        0x00300030: 0x02020202_02020202, 0x00300038: 0x02020202_02020202,
    }
    d_prio_base = SpriteDescriptor(0, 0, 1, 1, 150, 0, 0x00300000, 12, 0, 0x40, 0x40, 0x40)
    d_prio_ge0 = SpriteDescriptor(0, 0, 1, 1, 150, 0, 0x00300020, 12, 0b0000, 0x40, 0x40, 0x40) # GE=0
    d_prio_ge1 = SpriteDescriptor(0, 0, 1, 1, 150, 0, 0x00300020, 12, 0b1000, 0x40, 0x40, 0x40) # GE=1

    suite["cases"]["prio_ge_0"] = make_case("prio_ge_0", [d_prio_base, d_prio_ge0], ram_prio, palette, next_y=0)
    suite["cases"]["prio_ge_1"] = make_case("prio_ge_1", [d_prio_base, d_prio_ge1], ram_prio, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 4. Opaque Black Semantics vs Transparency
    # -------------------------------------------------------------------------
    ram_black: Dict[int, int] = {
        0x00400000: (0x8000 << 48) | (0x0000 << 32) | (0x8000 << 16) | 0x0000,
        0x00400008: 0, 0x00400010: 0, 0x00400018: 0,
    }
    d_black = SpriteDescriptor(0, 0, 1, 1, 160, 0, 0x00400008, 1, 0, 0x40, 0x40, 0x40) # RGB555 0x8000
    suite["cases"]["opaque_black"] = make_case("opaque_black", [d_black], ram_black, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 5. All 4 Hardware Blend Modes (00 Opaque, 01 Additive, 10 50/50, 11 Alpha)
    # -------------------------------------------------------------------------
    ram_blend: Dict[int, int] = {
        0x00500000: 0x0A0A0A0A_0A0A0A0A, 0x00500008: 0x0A0A0A0A_0A0A0A0A,
        0x00500010: 0x0A0A0A0A_0A0A0A0A, 0x00500018: 0x0A0A0A0A_0A0A0A0A,
        0x00500020: 0x0B0B0B0B_0B0B0B0B, 0x00500028: 0x0B0B0B0B_0B0B0B0B,
        0x00500030: 0x0B0B0B0B_0B0B0B0B, 0x00500038: 0x0B0B0B0B_0B0B0B0B,
    }
    d_bg = SpriteDescriptor(0, 0, 1, 1, 100, 0, 0x00500000, 12, 0, 0x40, 0x40, 0x40)
    for mode_val, mode_name in [(0, "opaque"), (1, "additive"), (2, "translucent_50_50"), (3, "alpha_8bit")]:
        d_fg = SpriteDescriptor(0, 0, 1, 1, 180, 128 if mode_val == 3 else 0, 0x00500020, 12, 0, 0x40, 0x40, 0x40 | (mode_val << 4))
        suite["cases"][f"blend_{mode_name}"] = make_case(f"blend_{mode_name}", [d_bg, d_fg], ram_blend, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 6. FORMAT 18 (ARGB8888 TrueColor) Alpha Sweep (0, 1, 128, 255)
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
    d_argb_sweep = SpriteDescriptor(0, 0, 1, 1, 200, 0, 0x00600008, 2, 0, 0x40, 0x40, 0b0011_0000) # Blend 3
    suite["cases"]["format_18_argb_sweep"] = make_case("format_18_argb_sweep", [d_bg, d_argb_sweep], {**ram_blend, **ram_argb_sweep}, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 7. FORMAT 13 and 14 PAL_OFFSET Preservation (Review #6 Point 2 & Review #7 Point 2)
    # -------------------------------------------------------------------------
    # FORMAT 13: 12-6-8-6
    w64_f13 = (0x7F8 << 52) | (0x01 << 46) | (0x01 << 38) | (0x01 << 32)
    ram_f13: Dict[int, int] = {0x00700000: w64_f13, 0x00700008: 0, 0x00700010: 0, 0x00700018: 0}
    d_f13_0 = SpriteDescriptor(0, 0, 1, 1, 180, 0, 0x00700000, 13, 0, 0x40, 0x40, 0)
    d_f13_128 = SpriteDescriptor(0, 0, 1, 1, 180, 128, 0x00700000, 13, 0, 0x40, 0x40, 0)
    suite["cases"]["format_13_pal_0"] = make_case("format_13_pal_0", [d_f13_0], ram_f13, palette, next_y=0)
    suite["cases"]["format_13_pal_128"] = make_case("format_13_pal_128", [d_f13_128], ram_f13, palette, next_y=0)

    # FORMAT 14: 12-5-5-5-5 (HAM12 direct anchor + 4x HAM05 palette anchors)
    w32_f14 = (0x7F8 << 20) | (0x01 << 15) | (0x01 << 10) | (0x01 << 5) | 0x01
    w64_f14 = (w32_f14 << 32) | w32_f14
    ram_f14: Dict[int, int] = {0x00800000: w64_f14, 0x00800008: 0, 0x00800010: 0, 0x00800018: 0}
    d_f14_0 = SpriteDescriptor(0, 0, 1, 1, 180, 0, 0x00800000, 14, 0, 0x40, 0x40, 0)
    d_f14_128 = SpriteDescriptor(0, 0, 1, 1, 180, 128, 0x00800000, 14, 0, 0x40, 0x40, 0)
    suite["cases"]["format_14_pal_0"] = make_case("format_14_pal_0", [d_f14_0], ram_f14, palette, next_y=0)
    suite["cases"]["format_14_pal_128"] = make_case("format_14_pal_128", [d_f14_128], ram_f14, palette, next_y=0)

    # -------------------------------------------------------------------------
    # 8. Opaque Black in HAM16 ($8000) & Multiline V_FLIP (Review #7 Point 2)
    # -------------------------------------------------------------------------
    # HAM16 (FORMAT 16): 0x8000 = zero delta from black -> opaque black 0x000000!
    w64_h16 = (0x8000 << 48) | (0x0000 << 32) | (0x8000 << 16) | 0x0000
    ram_h16: Dict[int, int] = {0x00810000: w64_h16, 0x00810008: 0, 0x00810010: 0, 0x00810018: 0}
    # DATA_PTR bit 3 = 1, fmt = 0 -> fmt5 = 16
    d_h16_black = SpriteDescriptor(0, 0, 1, 1, 190, 0, 0x00810008, 0, 0, 0x40, 0x40, 0)
    suite["cases"]["opaque_black_ham16"] = make_case("opaque_black_ham16", [d_h16_black], ram_h16, palette, next_y=0)

    # V_FLIP Multiline at next_y = 3 (accesses source line (4-1)-3 = 0, inverting flip_v at next_y=0)
    suite["cases"]["flip_v_y3"] = make_case("flip_v_y3", [d_vflip], ram_flip, palette, next_y=3)

    # -------------------------------------------------------------------------
    # 9. Zero-Word-Skip Pair Verification (Review #7 Point 2)
    # -------------------------------------------------------------------------
    ram_skip_pair: Dict[int, int] = {
        0x00900000: 0x01020304_00000000,
        0x00900008: 0x00000000_00000000, # Zero word -> skipped in 1 cycle
        0x00900010: 0x05060708_00000000,
        0x00900018: 0x00000000_00000000,
    }
    d_skip = SpriteDescriptor(0, 0, 1, 1, 170, 0, 0x00900000, 12, 0, 0x40, 0x40, 0x40)
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
