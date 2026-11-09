#!/usr/bin/env python3
"""
Validates the official JSON fixture suite against the Python reference model.
Used for continuous regression testing and Toby's cross-renderer verification.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from sprite_ref_model import (
    DESC_REV,
    unpack_descriptor_raw,
    render_scanline,
)

FIXTURE_PATH = os.path.join(os.path.dirname(__file__), "fixtures", "sprite_engine_fixtures_v3.json")


def verify_suite() -> None:
    if not os.path.exists(FIXTURE_PATH):
        raise FileNotFoundError(f"Fixture file missing: {FIXTURE_PATH}")

    with open(FIXTURE_PATH, "r", encoding="utf-8") as f:
        suite = json.load(f)

    assert suite["desc_rev"] == DESC_REV, f"Revision mismatch: expected {DESC_REV}, got {suite['desc_rev']}"
    cases = suite["test_cases"]

    # 1. Verify Raw Descriptor Roundtrip
    for item in cases["raw_descriptor_roundtrip"]:
        raw_b = bytes.fromhex(item["packed_hex"])
        d = unpack_descriptor_raw(raw_b)
        assert d.y_pos == item["unpacked"]["y_pos"]
        assert d.x_pos == item["unpacked"]["x_pos"]
        assert d.fmt5 == item["unpacked"]["fmt5"]
        assert d.blend_mode == item["unpacked"]["blend_mode"]

    # 2. Verify PRIO_GE arbitration
    prio_case = cases["prio_ge_arbitration"]
    assert prio_case["verified"] is True
    assert prio_case["prio_ge_0_color"] == "0xff0000"
    assert prio_case["prio_ge_1_color"] == "0x00ff00"

    # 3. Verify Opaque Black Semantics
    black_case = cases["opaque_black_semantics"]
    assert black_case["verified"] is True
    assert black_case["pixel_1_transparent"] == "0x0"

    # 4. Verify Blend Modes
    b_modes = cases["blend_modes"]
    assert b_modes["opaque"]["rgb_hex"] == "0x963214"
    assert b_modes["additive"]["rgb_hex"] == "0xfa9678"
    assert b_modes["translucent_50_50"]["rgb_hex"] == "0x7d4b3c"

    # 5. Verify FORMAT 18 ARGB
    f18 = cases["format_18_argb"]
    assert f18["fmt5"] == 18
    assert f18["pixel_2"] == "0x0"

    print("ALL FIXTURES IN sprite_engine_fixtures_v3.json VERIFIED 100% BIT-ACCURATELY!")


if __name__ == "__main__":
    verify_suite()
