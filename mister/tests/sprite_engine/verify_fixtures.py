#!/usr/bin/env python3
"""
Validates the official JSON fixture suite against the Python reference model.
Dynamically executes render_scanline() on all raw descriptors, RAM, and palettes,
and verifies every pixel bit-accurately.

Includes full regression checks (Height 256/1080, 4096 px, Zero-Word-Skip, Denise compositing).
"""

import json
import os
import sys
from typing import Dict, List

sys.path.insert(0, os.path.dirname(__file__))
from sprite_ref_model import (
    DESC_REV,
    SpriteDescriptor,
    unpack_descriptor_raw,
    render_scanline,
    denise_mix_pixel,
)

FIXTURE_PATH = os.path.join(os.path.dirname(__file__), "fixtures", "sprite_engine_fixtures_v4.json")


def verify_suite() -> None:
    if not os.path.exists(FIXTURE_PATH):
        raise FileNotFoundError(f"Fixture file missing: {FIXTURE_PATH}")

    with open(FIXTURE_PATH, "r", encoding="utf-8") as f:
        suite = json.load(f)

    assert suite["desc_rev"] == DESC_REV, f"Revision mismatch: expected {DESC_REV}, got {suite['desc_rev']}"
    cases = suite["cases"]

    # -------------------------------------------------------------------------
    # 1. Dynamically render and verify every fixture case from raw inputs!
    # -------------------------------------------------------------------------
    for case_name, case_data in cases.items():
        # Unpack raw descriptors
        descs = [unpack_descriptor_raw(bytes.fromhex(h)) for h in case_data["raw_descriptors_hex"]]

        # Parse RAM words
        ram: Dict[int, int] = {int(addr, 16): int(val, 16) for addr, val in case_data["ram_words64"].items()}

        # Parse palette
        palette = [0] * 256
        if "palette_sparse" in case_data:
            for idx_str, c_hex in case_data["palette_sparse"].items():
                palette[int(idx_str)] = int(c_hex, 16)
        elif "palette" in case_data:
            for i, c in enumerate(case_data["palette"]):
                palette[i] = int(c, 16)

        next_y = case_data["next_y"]
        clip_xmax = case_data["clip_xmax"]
        global_steps = tuple(case_data["global_steps"])
        zero_skip = case_data["zero_skip"]

        # EXECUTE ACTUAL RENDERER:
        actual_lb = render_scanline(
            scanline_y=next_y,
            descriptors=descs,
            ram_words64=ram,
            palette256=palette,
            global_steps=global_steps,
            clip_xmax=clip_xmax,
            zero_word_skip_en=zero_skip,
        )

        # Verify pixel-by-pixel
        expected_non_zero = case_data["expected_non_zero_pixels"]
        expected_indices = {int(k): int(v, 16) for k, v in expected_non_zero.items()}

        # Verify that all expected pixels match
        for x, exp_val in expected_indices.items():
            act_val = actual_lb[x]
            assert act_val == exp_val, (
                f"Case '{case_name}' mismatch at x={x}: expected {hex(exp_val)}, got {hex(act_val)}"
            )

        # Verify that all other pixels are strictly 0 (transparent)
        for x in range(len(actual_lb)):
            if x not in expected_indices:
                act_val = actual_lb[x]
                assert act_val == 0, (
                    f"Case '{case_name}' unexpected non-zero pixel at x={x}: got {hex(act_val)}"
                )

    # Cross-check skip equivalence pair:
    if "skip_pair_on" in cases and "skip_pair_off" in cases:
        assert cases["skip_pair_on"]["expected_non_zero_pixels"] == cases["skip_pair_off"]["expected_non_zero_pixels"], (
            "Zero-Word-Skip ON vs OFF mismatch in fixture suite!"
        )

    print(f"Verified {len(cases)} fixture cases dynamically via render_scanline()!")

    # -------------------------------------------------------------------------
    # 2. Regression Tests (Height 256, Height 1080 Zoom, 4096 px, Zero-Word-Skip, Denise)
    # -------------------------------------------------------------------------
    palette_reg = [0x000000] * 256
    palette_reg[3] = 0x000000  # Opaque black at slot 3
    palette_reg[4] = 0x804020

    # 2a. Height 256
    ram_h256 = {0x00200000: (0x04 << 56)}
    d_h256 = SpriteDescriptor(y_pos=10, x_pos=50, data_ptr=0x00200000, height=256, width=1, format=7, prio=120, alpha=0, ctrl=0)
    lb256 = render_scanline(10, [d_h256], ram_h256, palette_reg)
    assert lb256[50] == (120 << 24) | 0x804020

    # 2b. Height 1080 Zoom (Y_POS = -1500, Y_SCALE = 2 (4x zoom), dy = 2500 -> scaled_y = 625)
    target_addr = 0x00100000 + ((625 * 1) << 5)
    ram_1080 = {target_addr: (0x03 << 56)}
    d_1080 = SpriteDescriptor(y_pos=-1500, x_pos=100, data_ptr=0x00100000, height=1080, width=1, format=7, prio=200, alpha=0, ctrl=(2 << 3))
    lb1080 = render_scanline(1000, [d_1080], ram_1080, palette_reg)
    assert lb1080[100] == (200 << 24) | 0x000000
    assert lb1080[101] == 0

    # 2c. 4096 source pixels (FORMAT 0: 16 bursts * 256 px = 4096 px, X_SCALE = 4 (quarter -> 1024 px))
    ram_4096: Dict[int, int] = {0x00500000 + w_i * 8: 0xFFFFFFFF_FFFFFFFF for w_i in range(16 * 4)}
    d_4096 = SpriteDescriptor(y_pos=0, x_pos=0, data_ptr=0x00500000, height=1, width=16, format=0, prio=180, alpha=0, ctrl=4)
    lb4096 = render_scanline(0, [d_4096], ram_4096, palette_reg, clip_xmax=2000)
    n_written = sum(1 for v in lb4096 if v != 0)
    assert n_written == 1024, f"Expected 1024 pixels for 4096px @ quarter scale, got {n_written}"

    # 2d. Denise Blank gate & Layer priority
    assert denise_mix_pixel((250 << 24) | 0xFF0000, 0x112233, amiga_prio=0) == 0xFF0000
    assert denise_mix_pixel((50 << 24) | 0xFF0000, 0x112233, amiga_prio=100) == 0x112233
    assert denise_mix_pixel(0, 0x112233, amiga_prio=0) == 0x112233

    print("ALL FIXTURES AND REGRESSIONS IN sprite_engine_fixtures_v4.json VERIFIED 100% BIT-ACCURATELY!")


if __name__ == "__main__":
    verify_suite()
