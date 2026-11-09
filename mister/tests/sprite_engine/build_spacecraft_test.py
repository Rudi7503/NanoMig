#!/usr/bin/env python3
"""
Decomposes `real-spacecraft.jpg` into 8 independent hardware sprites and encodes them across
the user-selected HAM / HighColor formats:
  - FORMAT 13: HAM_32BIT_12_6_8_6       (12 - 6 - 8 - 6, 32 px/Burst)
  - FORMAT 14: HAM_32BIT_12_5555        (12 - 5 - 5 - 5 - 5, 40 px/Burst)
  - FORMAT 15: HAM_64BIT_16_12_12_12_12 (16 - 12 - 12 - 12 - 12 in 64-bit word, 20 px/Burst, 100% palette-free)
  - FORMAT 2 : HAM_32BIT_63436343       (6 - 3 - 4 - 3 - 6 - 3 - 4 - 3, 64 px/Burst)

Verifies all formats through the bit-accurate `sprite_ref_model.py` (including Zero-Word-Skip
equivalence, 4-bit step_r/g/b, X/Y scaling, SMOOTH_X interpolation, and 8-bit priority layering),
and generates:
  1. `mister/tests/sprite_engine/spacecraft_sprites_preview.png` (visual verification sheet)
  2. `docs/spacecraft_sprite_test.html` (interactive 60-FPS bit-exact hardware pipeline demo with live format switcher)
"""

import argparse
import json
import math
import os
from pathlib import Path
from typing import List, Tuple, Dict
import numpy as np
from PIL import Image, ImageDraw

from sprite_ref_model import (
    SpriteDescriptor,
    FORMAT_SEQS_64,
    precompute_ham_stage1,
    clamp_u8,
    render_scanline,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_SRC_JPG = Path(r"D:\programmier_ordner\Vampire\new-ham\testbilder\real-spacecraft.jpg")
DEFAULT_OUT_PREVIEW = REPO_ROOT / "mister" / "tests" / "sprite_engine" / "spacecraft_sprites_preview.png"
DEFAULT_OUT_HTML = REPO_ROOT / "docs" / "spacecraft_sprite_test.html"

SHOWCASE_FORMATS = (18, 15, 13, 14, 2)


def build_palette_bank(rgb_pixels: np.ndarray, n_slots: int = 32) -> List[int]:
    """
    Builds a 24-bit palette bank of `n_slots` colors (Slot 0 = 0x000000).
    Uses MEDIANCUT quantization on non-transparent pixels.
    """
    if len(rgb_pixels) == 0:
        return [0x000000] * n_slots
    sample = rgb_pixels
    if len(sample) > 16384:
        idx = np.random.default_rng(42).choice(len(sample), 16384, replace=False)
        sample = sample[idx]
    im_s = Image.fromarray(sample.reshape(-1, 1, 3).astype(np.uint8), mode="RGB")
    q = im_s.quantize(colors=n_slots - 1, method=Image.Quantize.MEDIANCUT)
    raw_pal = q.getpalette()[: (n_slots - 1) * 3]
    bank = [0x000000]
    for i in range(0, len(raw_pal), 3):
        r, g, b = raw_pal[i], raw_pal[i + 1], raw_pal[i + 2]
        bank.append((r << 16) | (g << 8) | b)
    while len(bank) < n_slots:
        bank.append(0x000000)
    return bank[:n_slots]


def best_ham12_code(
    tr: int, tg: int, tb: int, acc_r: int, acc_g: int, acc_b: int, sr: int, sg: int, sb: int
) -> Tuple[int, Tuple[int, int, int]]:
    """
    O(1) globally optimal HAM12 encoder (12-bit code: Bit11=0 -> 11-bit direct RGB anchor, Bit11=1 -> 3/4/3 delta).
    """
    best_err = 1 << 30
    best_code = 1
    best_rgb = (0, 0, 0)

    # 1. Evaluate 11-bit direct RGB anchor (code[11] == 0) for b10 in (0, 1)
    g4 = min(15, max(0, (tg + 8) >> 4))
    g_anc = g4 << 4
    for b10 in (0, 1):
        r3 = min(7, max(0, (tr - (b10 << 4) + 16) >> 5))
        b3 = min(7, max(0, (tb - (b10 << 4) + 16) >> 5))
        g4_use = g4
        if b10 == 0 and r3 == 0 and g4_use == 0 and b3 == 0:
            g4_use = 1  # Avoid raw_code == 0 (transparent)
        r_anc = ((r3 << 1) | b10) << 4
        b_anc = ((b3 << 1) | b10) << 4
        g_a = g4_use << 4
        err = (r_anc - tr) ** 2 + (g_a - tg) ** 2 + (b_anc - tb) ** 2
        if err < best_err:
            best_err = err
            best_code = (b10 << 10) | (r3 << 7) | (g4_use << 3) | b3
            best_rgb = (r_anc, g_a, b_anc)

    # 2. Evaluate 11-bit two's complement delta (code[11] == 1) for turbo in (0, 1)
    for turbo in (0, 1):
        mr = max(1, sr * (4 if turbo else 1))
        mg = max(1, sg * (4 if turbo else 1))
        mb = max(1, sb * (4 if turbo else 1))
        dr = min(3, max(-4, int(round((tr - acc_r) / mr))))
        dg = min(7, max(-8, int(round((tg - acc_g) / mg))))
        db = min(3, max(-4, int(round((tb - acc_b) / mb))))
        nr = clamp_u8(acc_r + dr * mr)
        ng = clamp_u8(acc_g + dg * mg)
        nb = clamp_u8(acc_b + db * mb)
        err = (nr - tr) ** 2 + (ng - tg) ** 2 + (nb - tb) ** 2
        if err < best_err:
            best_err = err
            best_code = 0x800 | (turbo << 10) | ((dr & 0x7) << 7) | ((dg & 0xF) << 3) | (db & 0x7)
            best_rgb = (nr, ng, nb)

    return best_code, best_rgb


def best_ham16_code(
    tr: int, tg: int, tb: int, acc_r: int, acc_g: int, acc_b: int, sr: int, sg: int, sb: int
) -> Tuple[int, Tuple[int, int, int]]:
    """
    O(1) globally optimal HAM16 encoder (16-bit code: Bit15=0 -> 15-bit RGB555 anchor, Bit15=1 -> 4/5/5 delta).
    """
    # 1. Direct 15-bit RGB555 anchor (code[15] == 0)
    r5 = min(31, max(0, (tr + 4) >> 3))
    g5 = min(31, max(0, (tg + 4) >> 3))
    b5 = min(31, max(0, (tb + 4) >> 3))
    if r5 == 0 and g5 == 0 and b5 == 0:
        g5 = 1  # Avoid raw_code == 0 (transparent)
    r_anc, g_anc, b_anc = r5 << 3, g5 << 3, b5 << 3
    best_err = (r_anc - tr) ** 2 + (g_anc - tg) ** 2 + (b_anc - tb) ** 2
    best_code = (r5 << 10) | (g5 << 5) | b5
    best_rgb = (r_anc, g_anc, b_anc)

    # 2. 15-bit two's complement delta (code[15] == 1) for turbo in (0, 1)
    for turbo in (0, 1):
        mr = max(1, sr * (4 if turbo else 1))
        mg = max(1, sg * (4 if turbo else 1))
        mb = max(1, sb * (4 if turbo else 1))
        dr = min(7, max(-8, int(round((tr - acc_r) / mr))))
        dg = min(15, max(-16, int(round((tg - acc_g) / mg))))
        db = min(15, max(-16, int(round((tb - acc_b) / mb))))
        nr = clamp_u8(acc_r + dr * mr)
        ng = clamp_u8(acc_g + dg * mg)
        nb = clamp_u8(acc_b + db * mb)
        err = (nr - tr) ** 2 + (ng - tg) ** 2 + (nb - tb) ** 2
        if err < best_err:
            best_err = err
            best_code = 0x8000 | (turbo << 14) | ((dr & 0xF) << 10) | ((dg & 0x1F) << 5) | (db & 0x1F)
            best_rgb = (nr, ng, nb)

    return best_code, best_rgb


def encode_ham_row_fmt(
    row_rgb: np.ndarray,
    row_opaque: np.ndarray,
    fmt5: int,
    palette256: List[int],
    pal_offset: int,
    steps: Tuple[int, int, int] = (4, 4, 4),
) -> List[int]:
    """
    Encodes a horizontal line of pixels into 64-bit words for any format `fmt5` (0..17).
    Pads the right edge with transparent pixels if `len(row_opaque)` is not a multiple of `px_per_burst`.
    """
    seq64 = FORMAT_SEQS_64[fmt5]
    px_per_64 = len(seq64)
    px_per_burst = px_per_64 * 4
    orig_w = len(row_opaque)
    w_bursts = (orig_w + px_per_burst - 1) // px_per_burst
    padded_w = w_bursts * px_per_burst

    sr, sg, sb = steps
    bank_r = np.array([(palette256[(pal_offset + i) & 0xFF] >> 16) & 0xFF for i in range(128)], dtype=np.int32)
    bank_g = np.array([(palette256[(pal_offset + i) & 0xFF] >> 8) & 0xFF for i in range(128)], dtype=np.int32)
    bank_b = np.array([palette256[(pal_offset + i) & 0xFF] & 0xFF for i in range(128)], dtype=np.int32)

    # Pre-build delta lookup tables for bw in (3, 4, 5, 6, 8)
    delta_lut: Dict[int, List[Tuple[int, int, int, int]]] = {}
    for bw in set(seq64):
        if bw <= 8:
            n_anc = 1 << (bw - 1)
            lst = []
            for d_code in range(n_anc, 1 << bw):
                _, _, _, _, dr, dg, db, _, _ = precompute_ham_stage1(
                    d_code, bw, fmt5, pal_offset
                )
                lst.append((d_code, dr, dg, db))
            delta_lut[bw] = lst

    acc_r = acc_g = acc_b = 0
    words64: List[int] = []

    for base_x in range(0, padded_w, px_per_64):
        # Fast-path: if all pixels in this 64-bit word are transparent, emit 64'h0
        end_x = min(orig_w, base_x + px_per_64)
        if base_x >= orig_w or not np.any(row_opaque[base_x:end_x]):
            acc_r = acc_g = acc_b = 0
            words64.append(0)
            continue

        w64 = 0
        for p_i, bw in enumerate(seq64):
            x = base_x + p_i
            if x >= orig_w or not row_opaque[x]:
                code = 0
                acc_r = acc_g = acc_b = 0
            else:
                tr, tg, tb = int(row_rgb[x, 0]), int(row_rgb[x, 1]), int(row_rgb[x, 2])
                if bw == 12:
                    code, (acc_r, acc_g, acc_b) = best_ham12_code(tr, tg, tb, acc_r, acc_g, acc_b, sr, sg, sb)
                elif bw == 16:
                    code, (acc_r, acc_g, acc_b) = best_ham16_code(tr, tg, tb, acc_r, acc_g, acc_b, sr, sg, sb)
                elif bw == 32:
                    # FORMAT 18: ARGB8888 TrueColor with full 8-bit alpha (0xFF = opaque)
                    code = (0xFF << 24) | (tr << 16) | (tg << 8) | tb
                    acc_r, acc_g, acc_b = tr, tg, tb
                else:
                    n_anc = 1 << (bw - 1)
                    dr_a = bank_r[1:n_anc] - tr
                    dg_a = bank_g[1:n_anc] - tg
                    db_a = bank_b[1:n_anc] - tb
                    err_a = dr_a * dr_a + dg_a * dg_a + db_a * db_a
                    best_anc_idx = int(np.argmin(err_a)) + 1
                    best_err = int(err_a[best_anc_idx - 1])
                    best_code = best_anc_idx
                    best_rgb = (int(bank_r[best_anc_idx]), int(bank_g[best_anc_idx]), int(bank_b[best_anc_idx]))

                    for d_code, dr, dg, db in delta_lut[bw]:
                        nr = clamp_u8(acc_r + dr)
                        ng = clamp_u8(acc_g + dg)
                        nb = clamp_u8(acc_b + db)
                        err = (nr - tr) ** 2 + (ng - tg) ** 2 + (nb - tb) ** 2
                        if err < best_err:
                            best_err = err
                            best_code = d_code
                            best_rgb = (nr, ng, nb)

                    code = best_code
                    acc_r, acc_g, acc_b = best_rgb

            w64 = (w64 << bw) | (code & ((1 << bw) - 1))
        words64.append(w64 & 0xFFFFFFFFFFFFFFFF)

    return words64


def decompose_spacecraft(src_jpg: Path):
    """
    Loads `real-spacecraft.jpg`, resizes to 384x388, and extracts 8 layered sprite components
    across all showcase formats (FORMAT 13: 12-6-8-6, FORMAT 14: 12-5-5-5-5, FORMAT 15: 16-12-12-12-12, FORMAT 2: 63436343).
    """
    im_orig = Image.open(src_jpg).convert("RGB")
    W, H = 384, 388
    im = im_orig.resize((W, H), Image.Resampling.LANCZOS)
    arr = np.array(im, dtype=np.uint8)
    r, g, b = arr[:, :, 0].astype(np.int32), arr[:, :, 1].astype(np.int32), arr[:, :, 2].astype(np.int32)

    fg = (np.maximum(np.maximum(r, g), b) > 14)
    yy, xx = np.mgrid[0:H, 0:W]

    # 1 & 2. Left & Right Thruster Pod Circular Rings (PRIO 152)
    dist_l_pod = np.sqrt((xx - 143.0) ** 2 + (yy - 47.5) ** 2)
    dist_r_pod = np.sqrt((xx - 240.0) ** 2 + (yy - 47.5) ** 2)
    mask_l_pod = fg & (dist_l_pod <= 23.5) & (yy >= 21) & (yy <= 74)
    mask_r_pod = fg & (dist_r_pod <= 23.5) & (yy >= 21) & (yy <= 74)

    # 3 & 4. Left & Right Thruster Flames (PRIO 130, behind pods at yy < 48)
    is_flame_col = (r > 70) & ((r - b) > 35) & (yy < 52)
    mask_l_flame = fg & (xx >= 114) & (xx < 174) & (yy < 48) & (is_flame_col | (yy < 36))
    mask_r_flame = fg & (xx >= 210) & (xx < 270) & (yy < 48) & (is_flame_col | (yy < 36))

    # 5. Cockpit Canopy & Central Dorsal Spine (PRIO 185, highest layer on top of hull)
    half_w_cockpit = np.clip(38.0 - np.abs(yy - 185.0) * 0.16, 14.0, 38.0)
    mask_cockpit = fg & (yy >= 72) & (yy <= 296) & (np.abs(xx - 191.5) <= half_w_cockpit)

    # 6 & 7. Left & Right Outer Swept Wings (PRIO 140, under main hull)
    seam_left_x = 144.0 - (yy - 82.0) * 0.42
    seam_right_x = 239.0 + (yy - 82.0) * 0.42
    wing_bot_y = 126.0 + np.abs(xx - 191.5) * 0.30
    mask_l_wing = fg & (yy >= 76) & (yy <= wing_bot_y + 10.0) & (xx <= seam_left_x + 14.0)
    mask_r_wing = fg & (yy >= 76) & (yy <= wing_bot_y + 10.0) & (xx >= seam_right_x - 14.0)

    # 8. Central Main Hull (PRIO 165)
    mask_hull = (
        fg
        & (~mask_l_flame)
        & (~mask_r_flame)
        & (
            (yy > wing_bot_y - 2.0)
            | ((xx >= seam_left_x - 2.0) & (xx <= seam_right_x + 2.0) & (yy >= 44))
        )
    )
    mask_hull = mask_hull | mask_cockpit

    def crop_part(mask: np.ndarray, x0: int, y0: int, orig_w_px: int, h_lines: int) -> Tuple[np.ndarray, np.ndarray]:
        part_rgb = np.zeros((h_lines, orig_w_px, 3), dtype=np.uint8)
        part_op = np.zeros((h_lines, orig_w_px), dtype=bool)
        for dy in range(h_lines):
            sy = y0 + dy
            if 0 <= sy < H:
                for dx in range(orig_w_px):
                    sx = x0 + dx
                    if 0 <= sx < W and mask[sy, sx]:
                        part_rgb[dy, dx] = arr[sy, sx]
                        part_op[dy, dx] = True
        return part_rgb, part_op

    parts_spec = [
        # (name, mask, x0, y0, orig_w_px, h_lines, prio, bank_idx)
        ("flame_l", mask_l_flame, 112, 4,   64,  44,  130, 0),
        ("flame_r", mask_r_flame, 208, 4,   64,  44,  130, 0),
        ("wing_l",  mask_l_wing,  0,   76,  192, 120, 140, 1),
        ("wing_r",  mask_r_wing,  192, 76,  192, 120, 140, 1),
        ("pod_l",   mask_l_pod,   112, 20,  64,  56,  152, 2),
        ("pod_r",   mask_r_pod,   208, 20,  64,  56,  152, 2),
        ("hull",    mask_hull,    48,  44,  320, 340, 165, 3),
        ("cockpit", mask_cockpit, 128, 72,  128, 224, 185, 4),
    ]

    palette256 = [0x000000] * 256
    extracted = []
    for name, msk, x0, y0, ow, hl, prio, bank_id in parts_spec:
        p_rgb, p_op = crop_part(msk, x0, y0, ow, hl)
        extracted.append((name, p_rgb, p_op, x0, y0, ow, hl, prio, bank_id))

    # Populate 64-slot palette banks (0, 64, 128, 192) for HAM06/HAM08/HAM05 formats
    # Wait: let's keep 32-slot banks (0..4 * 32) so 5 banks fit alongside Star Bank 5 (offset 160)!
    # For HAM08 in FORMAT 13 (12-6-8-6), any index 1..31 within the part's 32-slot bank is a valid HAM08 anchor too!
    for bank_id in range(5):
        pix_list = [p_rgb[p_op] for (_, p_rgb, p_op, *_, b_id) in extracted if b_id == bank_id and np.any(p_op)]
        all_pix = np.concatenate(pix_list, axis=0) if pix_list else np.zeros((0, 3), dtype=np.uint8)
        bank_cols = build_palette_bank(all_pix, 32)
        for i, col in enumerate(bank_cols):
            palette256[bank_id * 32 + i] = col

    # Bank 5 (offset 160): Star & Exhaust Plasma Particle CLUT palette (16 colors)
    star_bank = [
        0x000000, 0x1E293B, 0x334155, 0x475569,
        0x64748B, 0x94A3B8, 0xCBD5E1, 0xF8FAFC,
        0x38BDF8, 0x7DD3FC, 0xF59E0B, 0xFBBF24,
        0xEF4444, 0xF97316, 0xFEF08A, 0xFFFFFF,
    ]
    for i, c in enumerate(star_bank):
        palette256[160 + i] = c

    ram_words64: Dict[int, int] = {}
    formats_meta: Dict[int, List[Dict]] = {}
    cur_addr = 0x00100000

    # Use 4-bit HAM steps (6, 6, 6) in [0..15]
    steps4 = (6, 6, 6)

    for fmt5 in SHOWCASE_FORMATS:
        px_per_64 = len(FORMAT_SEQS_64[fmt5])
        px_per_burst = px_per_64 * 4
        f_parts = []
        tot_w64 = 0
        zero_w64 = 0
        for name, p_rgb, p_op, x0, y0, ow, hl, prio, bank_id in extracted:
            w_bursts = (ow + px_per_burst - 1) // px_per_burst
            base_addr = cur_addr
            part_words: List[int] = []
            for row_y in range(hl):
                row_w64 = encode_ham_row_fmt(
                    p_rgb[row_y], p_op[row_y], fmt5, palette256, bank_id * 32, steps=steps4
                )
                assert len(row_w64) == w_bursts * 4
                for w_i, w64 in enumerate(row_w64):
                    ram_words64[cur_addr + w_i * 8] = w64
                    part_words.append(w64)
                    tot_w64 += 1
                    if w64 == 0:
                        zero_w64 += 1
                cur_addr += w_bursts * 32
            f_parts.append({
                "name": name,
                "x0": x0,
                "y0": y0,
                "orig_w_px": ow,
                "w_bursts": w_bursts,
                "h_lines": hl,
                "prio": prio,
                "pal_offset": bank_id * 32,
                "base_addr": base_addr,
                "fmt": fmt5,
                "words64": [[(w >> 32) & 0xFFFFFFFF, w & 0xFFFFFFFF] for w in part_words],
            })
        formats_meta[fmt5] = f_parts
        print(
            f"Format {fmt5:2d} ({px_per_burst:2d} px/Burst): {tot_w64:5d} x 64-bit words "
            f"({zero_w64:5d} zero words = {zero_w64 * 100.0 / tot_w64:.1f}% 1-cycle Zero-Word-Skip!)"
        )

    return arr, palette256, ram_words64, formats_meta


def ceil_scaled_span(n_src: int, scale: int) -> int:
    """Exact sample count emitted by u_fp loop `(u_fp >> 6) < n_src`."""
    return (n_src * 64 + scale - 1) // scale


def render_animated_frame(
    frame_t: float,
    palette256: List[int],
    ram_words64: Dict[int, int],
    part_meta: List[Dict],
    screen_w: int = 448,
    screen_h: int = 440,
    explode: float = 0.0,
    zero_skip: bool = True,
) -> np.ndarray:
    """
    Builds the frame's Y-sorted SpriteDescriptor list for time `frame_t` and renders all scanlines
    through the bit-accurate `render_scanline` hardware model!
    """
    roll = math.sin(frame_t * 2.2)
    pitch = math.cos(frame_t * 1.5)
    ship_dx = int(round(roll * 26.0))
    ship_dy = int(round(pitch * 12.0))
    base_ox = 32 + ship_dx
    base_oy = 26 + ship_dy

    descriptors: List[SpriteDescriptor] = []
    meta_by_name = {m["name"]: m for m in part_meta}

    # 1. Flame flicker
    for side_idx, fname in enumerate(("flame_l", "flame_r")):
        m = meta_by_name[fname]
        flicker_y_scale = 46 + int(16 * math.sin(frame_t * 19.0 + side_idx * 2.1))
        stretched_h = ceil_scaled_span(m["h_lines"], flicker_y_scale)
        fy = base_oy + m["y0"] + (m["h_lines"] - stretched_h) - int(explode * 38)
        fx = base_ox + m["x0"] + (int(-explode * 25) if side_idx == 0 else int(explode * 25))
        fmt5 = m["fmt"]
        descriptors.append(
            SpriteDescriptor(
                y_pos=fy,
                x_pos=fx,
                data_ptr=m["base_addr"],
                height=m["h_lines"],
                width=m["w_bursts"],
                format=fmt5,
                prio=m["prio"],
                alpha=m["pal_offset"],
                ctrl=(1 << 9) | (1 << 8),  # BLEND_MODE = 1 (Additive), SMOOTH_X = 1
            )
        )

    # 2. Left & Right Wings
    for side_idx, wname in enumerate(("wing_l", "wing_r")):
        m = meta_by_name[wname]
        if side_idx == 0:
            w_xscale = int(round(64 + roll * 6))
            scaled_w = ceil_scaled_span(m["orig_w_px"], w_xscale)
            wx = base_ox + m["x0"] + (m["orig_w_px"] - scaled_w) - int(explode * 48)
            wy = base_oy + m["y0"] - int(round(roll * 7.0))
        else:
            w_xscale = int(round(64 - roll * 6))
            wx = base_ox + m["x0"] + int(explode * 48)
            wy = base_oy + m["y0"] + int(round(roll * 7.0))

        fmt5 = m["fmt"]
        descriptors.append(
            SpriteDescriptor(
                y_pos=wy,
                x_pos=wx,
                data_ptr=m["base_addr"],
                height=m["h_lines"],
                width=m["w_bursts"],
                format=fmt5,
                prio=m["prio"],
                alpha=m["pal_offset"],
                ctrl=(1 << 8),  # SMOOTH_X = 1
            )
        )

    # 3. Left & Right Thruster Pods
    for side_idx, pname in enumerate(("pod_l", "pod_r")):
        m = meta_by_name[pname]
        px = base_ox + m["x0"] + int(round(roll * 2.0)) + (int(-explode * 22) if side_idx == 0 else int(explode * 22))
        py = base_oy + m["y0"] + (int(round(-roll * 3.0)) if side_idx == 0 else int(round(roll * 3.0))) - int(explode * 18)
        fmt5 = m["fmt"]
        descriptors.append(
            SpriteDescriptor(
                y_pos=py,
                x_pos=px,
                data_ptr=m["base_addr"],
                height=m["h_lines"],
                width=m["w_bursts"],
                format=fmt5,
                prio=m["prio"],
                alpha=m["pal_offset"],
                ctrl=(1 << 8),  # SMOOTH_X = 1
            )
        )

    # 4. Central Main Hull
    m_hull = meta_by_name["hull"]
    fmt5_h = m_hull["fmt"]
    descriptors.append(
        SpriteDescriptor(
            y_pos=base_oy + m_hull["y0"],
            x_pos=base_ox + m_hull["x0"],
            data_ptr=m_hull["base_addr"],
            height=m_hull["h_lines"],
            width=m_hull["w_bursts"],
            format=fmt5_h,
            prio=m_hull["prio"],
            alpha=m_hull["pal_offset"],
            ctrl=(1 << 8),  # SMOOTH_X = 1
        )
    )

    # 5. Cockpit Canopy
    m_cp = meta_by_name["cockpit"]
    fmt5_c = m_cp["fmt"]
    cp_x = base_ox + m_cp["x0"] + int(round(roll * 6.0))
    cp_y = base_oy + m_cp["y0"] + int(round(pitch * 4.0)) + int(explode * 28)
    descriptors.append(
        SpriteDescriptor(
            y_pos=cp_y,
            x_pos=cp_x,
            data_ptr=m_cp["base_addr"],
            height=m_cp["h_lines"],
            width=m_cp["w_bursts"],
            format=fmt5_c,
            prio=m_cp["prio"],
            alpha=m_cp["pal_offset"],
            ctrl=(2 << 9) | (1 << 8),  # BLEND_MODE = 2 (50/50 Translucent glass), SMOOTH_X = 1
        )
    )

    descriptors.sort(key=lambda d: d.y_pos)
    descriptors.append(SpriteDescriptor(0, 0, 0, 0, 0, 0, 0, 0, 0))  # Sentinel: height=0

    img_out = np.zeros((screen_h, screen_w, 3), dtype=np.uint8)
    for y in range(screen_h):
        lb = render_scanline(
            y,
            descriptors,
            ram_words64,
            palette256,
            clip_xmax=screen_w,
        )
        for x in range(screen_w):
            v = lb[x]
            if (v >> 24) != 0:
                img_out[y, x, 0] = (v >> 16) & 0xFF
                img_out[y, x, 1] = (v >> 8) & 0xFF
                img_out[y, x, 2] = v & 0xFF
    return img_out


def generate_html_demo(palette256: List[int], formats_meta: Dict[int, List[Dict]], out_html: Path) -> None:
    """
    Writes `docs/spacecraft_sprite_test.html`: a 100% self-contained interactive 60-FPS testbench
    supporting live switching between:
      - FORMAT 13: HAM_32BIT_12_6_8_6       (12-6-8-6, 32 px/Burst)
      - FORMAT 14: HAM_32BIT_12_5555        (12-5-5-5-5, 40 px/Burst)
      - FORMAT 15: HAM_64BIT_16_12_12_12_12 (16-12-12-12-12, 20 px/Burst, 100% palette-free!)
      - FORMAT 2 : HAM_32BIT_63436343       (6-3-4-3-6-3-4-3, 64 px/Burst)
    """
    payload_json = json.dumps({
        "palette": palette256,
        "steps": [6, 6, 6],
        "formats": {str(k): v for k, v in formats_meta.items()},
    }, separators=(",", ":"))

    html = f"""<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NanoMig HAM-Sprite-Engine Praxistest: real-spacecraft.jpg (HAM12 / HAM16 / Multi-Sprite Rig)</title>
<style>
  :root{{
    --bg:#0b0e13; --panel:#141922; --line:#263040; --ink:#e6edf3; --dim:#8b97a6;
    --acc:#f0a04b; --acc2:#5fb3f0; --ok:#5ac77e; --bad:#e05a5a;
  }}
  *{{box-sizing:border-box}}
  body{{margin:0;background:var(--bg);color:var(--ink);font:14.5px/1.55 "Segoe UI",system-ui,sans-serif}}
  header{{padding:20px 24px 14px;border-bottom:1px solid var(--line);background:linear-gradient(180deg,#151c26,#0b0e13)}}
  h1{{margin:0 0 4px;font-size:22px;font-weight:600}}
  h1 span{{color:var(--acc)}}
  .sub{{color:var(--dim);font-size:13px}}
  main{{max-width:1280px;margin:0 auto;padding:18px 22px}}
  .layout{{display:grid;grid-template-columns:480px 1fr;gap:18px;align-items:start}}
  .card{{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:16px 18px;margin-bottom:16px}}
  h2{{margin:0 0 10px;font-size:16.5px;color:var(--acc)}}
  canvas{{display:block;width:100%;max-width:448px;height:auto;border:1px solid var(--line);border-radius:8px;background:#05070a;margin:0 auto}}
  .ctl{{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:10px 0;background:#0b0e13;padding:10px 12px;border-radius:8px;border:1px solid var(--line)}}
  .ctl label{{font-size:12.5px;color:var(--dim);display:flex;align-items:center;gap:6px}}
  button,select{{background:#0b0e13;color:var(--ink);border:1px solid var(--line);border-radius:6px;padding:6px 10px;font-size:12.5px;cursor:pointer}}
  button.on{{background:var(--acc);color:#111;border-color:var(--acc);font-weight:600}}
  input[type=range]{{width:115px;accent-color:var(--acc);cursor:pointer}}
  table{{width:100%;border-collapse:collapse;font-size:12.5px;margin-top:6px}}
  th,td{{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);font-family:Consolas,monospace}}
  th{{color:var(--dim);font-family:"Segoe UI",sans-serif;font-size:11.5px;text-transform:uppercase}}
  .stat{{font-family:Consolas,monospace;font-size:12.5px;background:#0b0e13;border:1px solid var(--line);border-radius:6px;padding:10px 12px;margin-top:10px;white-space:pre-wrap}}
  .badge{{display:inline-block;padding:2px 7px;border-radius:8px;font-size:11.5px;background:#0b0e13;border:1px solid var(--line);color:var(--acc2);margin-right:5px}}
  @media (max-width:960px){{.layout{{grid-template-columns:1fr}}}}
</style>
</head>
<body>
<header>
  <h1>NanoMig <span>HAM12/16-Sprite-Engine Praxistest</span> &middot; <code>real-spacecraft.jpg</code> in 8 bewegten Hardware-Sprites</h1>
  <div class="sub">
    Echtzeit-Ausführung des bitgenauen Hardware-Referenzmodells im Browser:
    <span class="badge">FORMAT 18: ARGB8888 (8 px/Burst, 8-Bit Alpha)</span>
    <span class="badge">FORMAT 15: 16-12-12-12-12 (20 px/Burst, 100% palettenfrei)</span>
    <span class="badge">FORMAT 13: 12-6-8-6 (32 px/Burst)</span>
    <span class="badge">FORMAT 14: 12-5-5-5-5 (40 px/Burst)</span>
    <span class="badge">4 Blend-Modi (Opak, Additiv, 50/50, Alpha)</span>
  </div>
</header>
<main>
  <div class="layout">
    <div class="card">
      <h2>Live Zeilenbuffer-Ausgabe (448 &times; 440 px)</h2>
      <canvas id="screen" width="448" height="440"></canvas>
      <div class="ctl">
        <label style="width:100%"><b>Packformat:</b>
          <select id="selFmt" style="flex:1">
            <option value="15" selected>FORMAT 15: 16-12-12-12-12 (64b, 20 px/Burst, 100% palettenfrei!)</option>
            <option value="18">FORMAT 18: ARGB8888 TrueColor (32b, 8 px/Burst, 100% palettenfrei & Per-Pixel Alpha!)</option>
            <option value="13">FORMAT 13: 12-6-8-6 (32b, 32 px/Burst, HAM12 + HAM06/08)</option>
            <option value="14">FORMAT 14: 12-5-5-5-5 (32b, 40 px/Burst, HAM12 + 4&times;HAM05)</option>
            <option value="2">FORMAT 2: 6-3-4-3-6-3-4-3 (32b, 64 px/Burst, 32-Slot Bank)</option>
          </select>
        </label>
      </div>
      <div class="ctl">
        <button id="btnPlay" class="on">Animation läuft</button>
        <button id="btnExplode">Sprites auseinanderziehen</button>
        <button id="btnHeatmap">PRIO / Zero-Skip Heatmap</button>
      </div>
      <div class="ctl">
        <label><input type="checkbox" id="chkSmooth" checked> <code>SMOOTH_X = 1</code> (24-Bit Lerp)</label>
        <label><input type="checkbox" id="chkSkip" checked> <code>Zero-Word-Skip</code> (64'h0 in 1 Takt)</label>
        <label>Zoom <input type="range" id="rngZoom" min="48" max="96" value="64"> <span id="txtZoom" style="color:var(--acc)">1.00&times;</span></label>
      </div>
      <div class="ctl" style="background:#0f172a;border-color:#38bdf8">
        <label><input type="checkbox" id="chkShield" checked> <b style="color:#38bdf8">Holo-Schild (ARGB8888 8-Bit Alpha)</b></label>
        <label>Alpha: <input type="range" id="rngAlpha" min="0" max="255" value="140"> <span id="txtAlpha" style="color:var(--acc)">140 (55%)</span></label>
      </div>
      <div class="ctl">
        <label>Manuelles Rollen (Bank) <input type="range" id="rngRoll" min="-100" max="100" value="0"></label>
        <label>Triebwerks-Schub <input type="range" id="rngThrust" min="35" max="95" value="55"></label>
      </div>
    </div>

    <div>
      <div class="card">
        <h2>Wie <code>real-spacecraft.jpg</code> in 8 unabhängige Hardware-Sprites zerlegt wurde</h2>
        <p style="margin:0 0 8px;color:var(--dim);font-size:13px">
          Schalte links live zwischen den neuen Modi <b><code>16-12-12-12-12</code> (Format 15, 100 % palettenfrei)</b>,
          <b><code>12-6-8-6</code> (Format 13)</b>, <b><code>12-5-5-5-5</code> (Format 14)</b> und <b><code>6-3-4-3-6-3-4-3</code> (Format 2)</b> um!
          Alle 8 Schiffsteile + 20 Hintergrund-Sterne (echte <code>CLUT_MODE=1</code>-Descriptoren in Format 0) laufen durch exakt dieselbe Y-sortierte Pipeline.
        </p>
        <table>
          <thead>
            <tr><th>Sprite-Teil</th><th>Y_POS</th><th>X_POS</th><th>Größe (W256&times;H)</th><th>PRIO</th><th>X/Y_SCALE</th><th>Zero-Skip</th></tr>
          </thead>
          <tbody id="descTable"></tbody>
        </table>
        <div class="stat" id="hwStats"></div>
      </div>

      <div class="card">
        <h2>Was dieser Test in der erweiterten Sprite-Engine (Rev. 3) beweist</h2>
        <ul style="margin:0;padding-left:18px;font-size:13.2px;color:var(--ink)">
          <li><b>Palettenfreie <code>HAM12</code>- &amp; <code>HAM16</code>-Direktanker:</b> In Format 15 (<code>16-12-12-12-12</code>) startet jedes 64-Bit-Wort mit einem 15-Bit-<code>RGB555</code>-Anker (oder 4/5/5-Delta), gefolgt von vier 12-Bit-<code>HAM12</code>-Pixeln &mdash; ohne einen einzigen Paletten-Slot zu belegen!</li>
          <li><b>Hybride 32-Bit-Mischmodi <code>12-6-8-6</code> &amp; <code>12-5-5-5-5</code>:</b> Jedes 32-Bit-Wort beginnt mit einem palettenfreien <code>HAM12</code>-Pixel (Reset/Direktanker) und nutzt danach kompakte <code>HAM06/08</code>- bzw. <code>HAM05</code>-Deltas für 32 bzw. 40 Pixel pro 256-Bit-Burst.</li>
          <li><b>4-Bit <code>step_r/g/b</code> (<code>0..15</code>) &amp; 19-Bit <code>u_fp</code> (<code>13.6</code>):</b> Kompakte 5&times;5-Bit-Delta-Multiplikation in Stufe 1 (12-Bit signed Pre-Delta) und exakte <code>ceil(n*64/scale)</code>-Abtastung ohne Dividierer.</li>
          <li><b>1-Takt <code>Zero-Word-Skip</code>:</b> Überspringt leere 64-Bit-Worte (<code>5, 8, 10</code> oder <code>16</code> transparente Pixel pro Takt) 100 % bit-identisch zu <code>Skip AUS</code>.</li>
        </ul>
      </div>
    </div>
  </div>
</main>
<script>
const DATA = {payload_json};
const SEQS_64 = {{
  0:  [4,4,4,4,4,4,4,4, 4,4,4,4,4,4,4,4],
  2:  [6,3,4,3,6,3,4,3, 6,3,4,3,6,3,4,3],
  13: [12,6,8,6, 12,6,8,6],
  14: [12,5,5,5,5, 12,5,5,5,5],
  15: [16,12,12,12,12],
  18: [32,32]
}};
const W = 448, H = 440;
const canvas = document.getElementById('screen');
const ctx = canvas.getContext('2d');
const imgData = ctx.createImageData(W, H);
const pix32 = new Uint32Array(imgData.data.buffer);

function twoDelta(b2) {{ return [-2,-1,1,2][b2 & 3]; }}
function signExt(val, bits) {{
  const m = (1 << bits) - 1;
  const v = val & m;
  return (v & (1 << (bits - 1))) ? (v - (1 << bits)) : v;
}}
function clamp8(v) {{ return v < 0 ? 0 : (v > 255 ? 255 : v); }}
function ceilSpan(nSrc, scale) {{ return Math.floor((nSrc * 64 + scale - 1) / scale); }}

// Build 20 genuine CLUT_MODE=1 (FORMAT 0, 64 px/Burst) star sprites for the descriptor list
const STAR_SPRITES = Array.from({{length: 20}}, (_, i) => {{
  const cIdx = 4 + (i % 10);
  // 2 pixels opaque at MSB of first 64-bit word in FORMAT 0 (4 bits per pixel)
  const hi32 = ((cIdx & 0xF) << 28) | ((cIdx & 0xF) << 24);
  const words64 = [
    [hi32 >>> 0, 0], [0, 0], [0, 0], [0, 0],
    [hi32 >>> 0, 0], [0, 0], [0, 0], [0, 0]
  ];
  return {{
    name: 'star_' + i,
    x: (i * 89 + 23) % W,
    y: (i * 53 + 11) % H,
    speed: 1.1 + (i % 4) * 0.85,
    prio: 16 + (i % 3) * 8,
    part: {{
      name: 'star_' + i,
      w_bursts: 1,
      h_lines: 2,
      pal_offset: 160,
      fmt: 0,
      clut_mode: true,
      words64: words64
    }}
  }};
}});

// Pre-generate a 160x120 FORMAT 18 (ARGB8888, 20 Bursts = 80 words/line) Holo-Shield sprite
const SHIELD_W = 160, SHIELD_H = 120, SHIELD_BURSTS = 20;
const SHIELD_WORDS64 = [];
for (let sy = 0; sy < SHIELD_H; sy++) {{
  for (let sx = 0; sx < SHIELD_W; sx += 2) {{
    let px0 = 0, px1 = 0;
    // Pixel 0:
    const dx0 = (sx - 80) / 72, dy0 = (sy - 60) / 52;
    const r0 = dx0 * dx0 + dy0 * dy0;
    if (r0 >= 0.72 && r0 <= 1.04) {{
      const edge0 = 1.0 - Math.abs(r0 - 0.88) / 0.16;
      const intense0 = Math.max(0, Math.min(1, edge0));
      px0 = (0xFF << 24) | ((Math.round(30 * intense0)) << 16) | ((Math.round(200 + 55 * intense0)) << 8) | 255;
    }} else if (r0 < 0.72) {{
      const hex0 = ((sx ^ sy) & 8) ? 0x25 : 0x05;
      px0 = (0x90 << 24) | (0x0A << 16) | ((0x75 + hex0) << 8) | 0xEE;
    }}
    // Pixel 1:
    const dx1 = (sx + 1 - 80) / 72, dy1 = (sy - 60) / 52;
    const r1 = dx1 * dx1 + dy1 * dy1;
    if (r1 >= 0.72 && r1 <= 1.04) {{
      const edge1 = 1.0 - Math.abs(r1 - 0.88) / 0.16;
      const intense1 = Math.max(0, Math.min(1, edge1));
      px1 = (0xFF << 24) | ((Math.round(30 * intense1)) << 16) | ((Math.round(200 + 55 * intense1)) << 8) | 255;
    }} else if (r1 < 0.72) {{
      const hex1 = (((sx + 1) ^ sy) & 8) ? 0x25 : 0x05;
      px1 = (0x90 << 24) | (0x0A << 16) | ((0x75 + hex1) << 8) | 0xEE;
    }}
    SHIELD_WORDS64.push([px0 >>> 0, px1 >>> 0]);
  }}
}}
const SHIELD_PART = {{
  name: 'shield_holo',
  w_bursts: SHIELD_BURSTS,
  h_lines: SHIELD_H,
  pal_offset: 0,
  fmt: 18,
  clut_mode: false,
  words64: SHIELD_WORDS64
}};

let running = true;
let explodeTarget = 0, explodeCur = 0;
let heatmapMode = false;
let t = 0;

document.getElementById('btnPlay').onclick = function() {{
  running = !running;
  this.classList.toggle('on', running);
  this.textContent = running ? 'Animation läuft' : 'Pausiert';
}};
document.getElementById('btnExplode').onclick = function() {{
  explodeTarget = explodeTarget > 0 ? 0 : 1;
  this.classList.toggle('on', explodeTarget > 0);
}};
document.getElementById('btnHeatmap').onclick = function() {{
  heatmapMode = !heatmapMode;
  this.classList.toggle('on', heatmapMode);
}};

const linePrio = new Uint8Array(W);
const lineRgb  = new Uint32Array(W);
const lineSkip = new Uint8Array(W);

function unpack64(hi, lo, seq64) {{
  const out = new Int32Array(seq64.length);
  let bitPos = 64;
  for (let i = 0; i < seq64.length; i++) {{
    const bw = seq64[i];
    bitPos -= bw;
    const mask = (bw === 32) ? -1 : ((1 << bw) - 1);
    let code = 0;
    if (bitPos >= 32) {{
      code = (hi >>> (bitPos - 32)) & mask;
    }} else if (bitPos + bw <= 32) {{
      code = (lo >>> bitPos) & mask;
    }} else {{
      const hiBits = (bitPos + bw) - 32;
      const loBits = 32 - bitPos;
      code = ((hi & ((1 << hiBits) - 1)) << loBits) | (lo >>> bitPos);
    }}
    out[i] = code;
  }}
  return out;
}}

function renderFrame() {{
  if (running) t += 0.032;
  explodeCur += (explodeTarget - explodeCur) * 0.12;

  const fmtId = +document.getElementById('selFmt').value;
  const partsList = DATA.formats[String(fmtId)];
  const smoothOn = document.getElementById('chkSmooth').checked;
  const skipOn   = document.getElementById('chkSkip').checked;
  const globalZoom = +document.getElementById('rngZoom').value;
  document.getElementById('txtZoom').textContent = (64 / globalZoom).toFixed(2) + '×';

  const manualRoll = +document.getElementById('rngRoll').value / 100.0;
  const thrustBase = +document.getElementById('rngThrust').value;

  const roll  = running ? Math.sin(t * 2.1) * 0.85 + manualRoll * 0.5 : manualRoll;
  const pitch = running ? Math.cos(t * 1.4) * 0.8 : 0;

  const shipDx = Math.round(roll * 30);
  const shipDy = Math.round(pitch * 12);
  const ox = 32 + shipDx;
  const oy = 26 + shipDy;

  const byName = {{}};
  partsList.forEach(p => byName[p.name] = p);

  const descs = [];
  // 0. Genuine CLUT_MODE=1 Star Descriptors (Layer 00, PRIO 16..32)
  STAR_SPRITES.forEach(st => {{
    if (running) st.y = (st.y + st.speed) % H;
    descs.push({{
      name: st.name, part: st.part, isStar: true,
      y_pos: st.y | 0, x_pos: st.x | 0,
      prio: st.prio, x_scale: 64, y_scale: 64, smooth: false
    }});
  }});

  // 1. Flames
  ['flame_l', 'flame_r'].forEach((fn, idx) => {{
    const m = byName[fn];
    const yScale = Math.max(16, Math.min(255, Math.round(thrustBase + Math.sin(t * 22 + idx * 2.2) * 14)));
    const sh = ceilSpan(m.h_lines, yScale);
    descs.push({{
      name: fn, part: m,
      y_pos: oy + m.y0 + (m.h_lines - sh) - Math.round(explodeCur * 42),
      x_pos: ox + m.x0 + (idx === 0 ? -Math.round(explodeCur * 28) : Math.round(explodeCur * 28)),
      prio: m.prio, x_scale: globalZoom, y_scale: yScale, smooth: smoothOn,
      blend_mode: 1 // Additive Blending for thruster flames!
    }});
  }});

  // 2. Wings (with exact integer ceiling `ceilSpan(m.orig_w_px, wScale)`)
  ['wing_l', 'wing_r'].forEach((wn, idx) => {{
    const m = byName[wn];
    const wScale = Math.max(16, Math.min(255, Math.round(globalZoom + (idx === 0 ? roll * 7 : -roll * 7))));
    const sw = ceilSpan(m.orig_w_px, wScale);
    const wx = idx === 0
      ? ox + m.x0 + (m.orig_w_px - sw) - Math.round(explodeCur * 54)
      : ox + m.x0 + Math.round(explodeCur * 54);
    const wy = oy + m.y0 + (idx === 0 ? -Math.round(roll * 8) : Math.round(roll * 8));
    descs.push({{
      name: wn, part: m, y_pos: wy, x_pos: wx,
      prio: m.prio, x_scale: wScale, y_scale: globalZoom, smooth: smoothOn
    }});
  }});

  // 3. Thruster pods
  ['pod_l', 'pod_r'].forEach((pn, idx) => {{
    const m = byName[pn];
    descs.push({{
      name: pn, part: m,
      y_pos: oy + m.y0 + (idx === 0 ? -Math.round(roll * 3) : Math.round(roll * 3)) - Math.round(explodeCur * 20),
      x_pos: ox + m.x0 + Math.round(roll * 2) + (idx === 0 ? -Math.round(explodeCur * 24) : Math.round(explodeCur * 24)),
      prio: m.prio, x_scale: globalZoom, y_scale: globalZoom, smooth: smoothOn
    }});
  }});

  // 4. Main Hull
  const mh = byName['hull'];
  descs.push({{
    name: 'hull', part: mh,
    y_pos: oy + mh.y0, x_pos: ox + mh.x0,
    prio: mh.prio, x_scale: globalZoom, y_scale: globalZoom, smooth: smoothOn
  }});

  // 5. Cockpit Canopy
  const mc = byName['cockpit'];
  descs.push({{
    name: 'cockpit', part: mc,
    y_pos: oy + mc.y0 + Math.round(pitch * 5) + Math.round(explodeCur * 34),
    x_pos: ox + mc.x0 + Math.round(roll * 7),
    prio: mc.prio, x_scale: globalZoom, y_scale: globalZoom, smooth: smoothOn,
    blend_mode: 2 // 50/50 Translucent glass canopy!
  }});

  // 6. Holo-Shield (FORMAT 18 ARGB8888, 8-Bit Alpha Blending)
  const shieldEnabled = document.getElementById('chkShield').checked;
  const shieldAlpha = +document.getElementById('rngAlpha').value;
  document.getElementById('txtAlpha').textContent = shieldAlpha + ' (' + Math.round(shieldAlpha * 100 / 255) + '%)' + (shieldAlpha === 0 ? ' [WE=0]' : (shieldAlpha === 255 ? ' [SAT]' : ''));
  if (shieldEnabled) {{
    descs.push({{
      name: 'shield_holo', part: SHIELD_PART,
      y_pos: oy + 2, x_pos: ox + 4,
      prio: 195, x_scale: globalZoom, y_scale: globalZoom, smooth: smoothOn,
      blend_mode: 3, alpha: shieldAlpha
    }});
  }}

  // Sort by Y_POS ascending (hardware descriptor contract)
  descs.sort((a, b) => a.y_pos - b.y_pos);

  let totalWords = 0, skippedWords = 0, totalCycles = 0;
  let totalSrcSteps = 0, totalDstSteps = 0, totalDescsScanned = 0;
  let maxLineCycles = 0, peakLineY = 0;
  const step = 6; // 4-bit global step (0..15)

  for (let y = 0; y < H; y++) {{
    linePrio.fill(0);
    lineRgb.fill(0);
    lineSkip.fill(0);
    let lineCycles = 0;

    for (let di = 0; di < descs.length; di++) {{
      const d = descs[di];
      totalDescsScanned++;
      if (d.y_pos > y) break; // Hardware Early-Exit!
      const dy = y - d.y_pos;
      const scaledY = (dy * d.y_scale) >> 6;
      if (scaledY >= d.part.h_lines) continue;

      const seq64 = SEQS_64[d.part.fmt];
      const pxPer64 = seq64.length;
      const w64PerRow = d.part.w_bursts * 4;
      const rowOffset = scaledY * w64PerRow;
      const srcWidthPx = w64PerRow * pxPer64;

      let accR = 0, accG = 0, accB = 0;
      let prevOp = false;
      const decOp = new Uint8Array(srcWidthPx);
      const decR  = new Uint8Array(srcWidthPx);
      const decG  = new Uint8Array(srcWidthPx);
      const decB  = new Uint8Array(srcWidthPx);
      const decA  = new Uint8Array(srcWidthPx);
      const decSk = new Uint8Array(srcWidthPx);

      let pOut = 0;
      for (let w = 0; w < w64PerRow; w++) {{
        totalWords++;
        const pair = d.part.words64[rowOffset + w];
        const hi = pair[0] >>> 0, lo = pair[1] >>> 0;
        if (skipOn && hi === 0 && lo === 0 && d.x_scale === 64 && !prevOp) {{
          skippedWords++;
          totalCycles += 1;
          lineCycles += 1;
          accR = accG = accB = 0;
          for (let k = 0; k < pxPer64; k++) decSk[pOut + k] = 1;
          pOut += pxPer64;
          continue;
        }}
        const codes = unpack64(hi, lo, seq64);
        for (let pi = 0; pi < pxPer64; pi++) {{
          const bw = seq64[pi];
          const code = codes[pi];
          totalCycles += 1;
          totalSrcSteps += 1;
          lineCycles += 1;
          if (code === 0) {{
            accR = accG = accB = 0;
            prevOp = false;
            pOut++;
          }} else if (d.part.clut_mode) {{
            const palCol = DATA.palette[(d.part.pal_offset + code) & 0xFF];
            accR = (palCol >> 16) & 0xFF;
            accG = (palCol >> 8) & 0xFF;
            accB = palCol & 0xFF;
            decOp[pOut] = 1; decR[pOut] = accR; decG[pOut] = accG; decB[pOut] = accB;
            prevOp = true; pOut++;
          }} else if (bw === 12) {{
            if (((code >> 11) & 1) === 0) {{
              const b10 = (code >> 10) & 1;
              const r3 = (code >> 7) & 7;
              const g4 = (code >> 3) & 15;
              const b3 = code & 7;
              accR = ((r3 << 1) | b10) << 4;
              accG = g4 << 4;
              accB = ((b3 << 1) | b10) << 4;
            }} else {{
              const m = ((code >> 10) & 1) ? (step << 2) : step;
              accR = clamp8(accR + signExt((code >> 7) & 7, 3) * m);
              accG = clamp8(accG + signExt((code >> 3) & 15, 4) * m);
              accB = clamp8(accB + signExt(code & 7, 3) * m);
            }}
            decOp[pOut] = 1; decR[pOut] = accR; decG[pOut] = accG; decB[pOut] = accB;
            prevOp = true; pOut++;
          }} else if (bw === 16) {{
            if (((code >> 15) & 1) === 0) {{
              accR = ((code >> 10) & 31) << 3;
              accG = ((code >> 5) & 31) << 3;
              accB = (code & 31) << 3;
            }} else {{
              const m = ((code >> 14) & 1) ? (step << 2) : step;
              accR = clamp8(accR + signExt((code >> 10) & 15, 4) * m);
              accG = clamp8(accG + signExt((code >> 5) & 31, 5) * m);
              accB = clamp8(accB + signExt(code & 31, 5) * m);
            }}
            decOp[pOut] = 1; decR[pOut] = accR; decG[pOut] = accG; decB[pOut] = accB;
            prevOp = true; pOut++;
          }} else if (bw === 32) {{
            const a = (code >>> 24) & 0xFF;
            accR = (code >>> 16) & 0xFF;
            accG = (code >>> 8) & 0xFF;
            accB = code & 0xFF;
            if (code !== 0 && a !== 0) {{
              decOp[pOut] = 1; decR[pOut] = accR; decG[pOut] = accG; decB[pOut] = accB; decA[pOut] = a;
              prevOp = true;
            }} else {{
              prevOp = false;
            }}
            pOut++;
          }} else {{
            const msb = (code >> (bw - 1)) & 1;
            if (msb === 0) {{
              const palCol = DATA.palette[(d.part.pal_offset + code) & 0xFF];
              accR = (palCol >> 16) & 0xFF;
              accG = (palCol >> 8) & 0xFF;
              accB = palCol & 0xFF;
            }} else {{
              let turbo = false, dr = 0, dg = 0, db = 0;
              if (bw === 3) {{ dr = (code & 2) ? 2 : -2; dg = (code & 1) ? 2 : -2; db = dr; }}
              else if (bw === 4) {{ dr = (code & 4) ? 2 : -2; dg = (code & 2) ? 2 : -2; db = (code & 1) ? 2 : -2; }}
              else if (bw === 5) {{ turbo = !!(code & 8); dr = (code & 4) ? 1 : -1; dg = (code & 2) ? 1 : -1; db = (code & 1) ? 1 : -1; }}
              else if (bw === 6) {{ turbo = !!(code & 16); dr = (code & 8) ? 1 : -1; dg = twoDelta((code >> 1) & 3); db = (code & 1) ? 1 : -1; }}
              else if (bw === 8) {{ turbo = !!(code & 64); dr = twoDelta((code >> 4) & 3); dg = twoDelta((code >> 2) & 3); db = twoDelta(code & 3); }}
              const mag = turbo ? (step << 2) : step;
              accR = clamp8(accR + dr * mag);
              accG = clamp8(accG + dg * mag);
              accB = clamp8(accB + db * mag);
            }}
            decOp[pOut] = 1; decR[pOut] = accR; decG[pOut] = accG; decB[pOut] = accB;
            prevOp = true; pOut++;
          }}
        }}
      }}

      // Unified X-sampling phase accumulator u_fp (19-bit unsigned 13.6 fixed-point)
      let uFp = 0;
      let dstX = d.x_pos;
      while (((uFp >> 6) & 0x1FFF) < srcWidthPx) {{
        totalDstSteps++;
        if (dstX >= W) break;
        if (dstX >= 0) {{
          const idx0 = (uFp >> 6) & 0x1FFF;
          const idx1 = idx0 + 1;
          const op0 = decOp[idx0] === 1;
          const op1 = (idx1 < srcWidthPx) && (decOp[idx1] === 1);
          const frac = (uFp >> 4) & 3;

          if (decSk[idx0]) lineSkip[dstX] = 1;

          let outOp = false, r = 0, g = 0, b = 0;
          if (op0 && op1) {{
            outOp = true;
            if (!d.smooth || frac === 0) {{
              r = decR[idx0]; g = decG[idx0]; b = decB[idx0];
            }} else {{
              const mr = (decR[idx0] + decR[idx1]) >> 1;
              const mg = (decG[idx0] + decG[idx1]) >> 1;
              const mb = (decB[idx0] + decB[idx1]) >> 1;
              if (frac === 2) {{ r = mr; g = mg; b = mb; }}
              else if (frac === 1) {{ r = (mr + decR[idx0]) >> 1; g = (mg + decG[idx0]) >> 1; b = (mb + decB[idx0]) >> 1; }}
              else {{ r = (mr + decR[idx1]) >> 1; g = (mg + decG[idx1]) >> 1; b = (mb + decB[idx1]) >> 1; }}
            }}
          }} else if (op0 && !op1) {{
            outOp = d.smooth ? (frac < 2) : true;
            r = decR[idx0]; g = decG[idx0]; b = decB[idx0];
          }} else if (!op0 && op1) {{
            outOp = d.smooth ? (frac >= 2) : false;
            r = decR[idx1]; g = decG[idx1]; b = decB[idx1];
          }}

          if (outOp) {{
            const oldPrio = linePrio[dstX];
            const oldRgb = lineRgb[dstX];
            if (d.prio > oldPrio) {{
              let outR = r, outG = g, outB = b;
              if (oldPrio > 0) {{
                if (d.blend_mode === 1) {{ // Additive Blending (flames)
                  const dr = (oldRgb >> 16) & 0xFF;
                  const dg = (oldRgb >> 8) & 0xFF;
                  const db = oldRgb & 0xFF;
                  outR = Math.min(255, dr + r);
                  outG = Math.min(255, dg + g);
                  outB = Math.min(255, db + b);
                }} else if (d.blend_mode === 2) {{ // 50/50 Translucent (canopy glass)
                  const dr = (oldRgb >> 16) & 0xFF;
                  const dg = (oldRgb >> 8) & 0xFF;
                  const db = oldRgb & 0xFF;
                  outR = (dr + r) >> 1;
                  outG = (dg + g) >> 1;
                  outB = (db + b) >> 1;
                }} else if (d.blend_mode === 3) {{ // 8-Bit Alpha Blending
                  const pixA = (decA[idx0] > 0) ? decA[idx0] : 255;
                  const sliderA = (d.alpha !== undefined) ? d.alpha : 255;
                  const a = (sliderA === 255) ? pixA : ((pixA * sliderA) >> 8);
                  if (a === 255) {{
                    outR = r; outG = g; outB = b;
                  }} else if (a === 0) {{
                    uFp = (uFp + d.x_scale) & 0x7FFFF;
                    dstX++;
                    continue; // WE = 0: strictly no write!
                  }} else {{
                    const dr = (oldRgb >> 16) & 0xFF;
                    const dg = (oldRgb >> 8) & 0xFF;
                    const db = oldRgb & 0xFF;
                    outR = dr + (((r - dr) * a) >> 8);
                    outG = dg + (((g - dg) * a) >> 8);
                    outB = db + (((b - db) * a) >> 8);
                  }}
                }}
              }} else {{
                if (d.blend_mode === 3) {{ // Alpha over empty target
                  const pixA = (decA[idx0] > 0) ? decA[idx0] : 255;
                  const sliderA = (d.alpha !== undefined) ? d.alpha : 255;
                  const a = (sliderA === 255) ? pixA : ((pixA * sliderA) >> 8);
                  if (a === 0) {{
                    uFp = (uFp + d.x_scale) & 0x7FFFF;
                    dstX++;
                    continue; // WE = 0: buffer remains empty
                  }} else if (a === 255) {{
                    outR = r; outG = g; outB = b;
                  }} else {{
                    outR = (r * a) >> 8;
                    outG = (g * a) >> 8;
                    outB = (b * a) >> 8;
                  }}
                }}
              }}
              linePrio[dstX] = d.prio;
              lineRgb[dstX]  = (outR << 16) | (outG << 8) | outB;
            }}
          }}
        }}
        uFp = (uFp + d.x_scale) & 0x7FFFF;
        dstX++;
      }}
    }}

    if (lineCycles > maxLineCycles) {{
      maxLineCycles = lineCycles;
      peakLineY = y;
    }}

    const rowBase = y * W;
    for (let x = 0; x < W; x++) {{
      const p = linePrio[x];
      let col = (p === 0) ? 0x0A0D12 : lineRgb[x];
      if (heatmapMode) {{
        if (p >= 180) col = 0xF59E0B;
        else if (p >= 160) col = 0x3B82F6;
        else if (p >= 150) col = 0x10B981;
        else if (p >= 140) col = 0x8B5CF6;
        else if (p >= 125) col = 0xEF4444;
        else if (lineSkip[x]) col = 0x132A1C;
      }}
      const r = (col >> 16) & 0xFF, g = (col >> 8) & 0xFF, b = col & 0xFF;
      pix32[rowBase + x] = (255 << 24) | (b << 16) | (g << 8) | r;
    }}
  }}

  ctx.putImageData(imgData, 0, 0);

  const shipDescs = descs.filter(d => !d.isStar);
  const pxPerBurst = SEQS_64[fmtId].length * 4;
  const tbody = document.getElementById('descTable');
  tbody.innerHTML = shipDescs.map(d =>
    '<tr>' +
    '<td><b style="color:var(--acc)">' + d.name + '</b></td>' +
    '<td>' + d.y_pos + '</td>' +
    '<td>' + d.x_pos + '</td>' +
    '<td>' + d.part.w_bursts + ' B (' + (d.part.w_bursts * pxPerBurst) + '&times;' + d.part.h_lines + ' px)</td>' +
    '<td>' + d.prio + '</td>' +
    '<td>$' + d.x_scale.toString(16).toUpperCase() + ' / $' + d.y_scale.toString(16).toUpperCase() + '</td>' +
    '<td style="color:var(--ok)">Aktiv</td>' +
    '</tr>'
  ).join('');

  const pct = totalWords > 0 ? (skippedWords * 100 / totalWords).toFixed(1) : '0.0';
  document.getElementById('hwStats').textContent =
    'Aktives Format: FORMAT ' + fmtId + ' (' + pxPerBurst + ' px/Burst) + 20 CLUT-Sterne (FORMAT 0)\\n' +
    'Gelesene 64-Bit-Worte: ' + totalWords + '  |  Zero-Word-Skip: ' + skippedWords + ' (' + pct + '%)\\n' +
    'Decoder-Operationsschätzung ohne DMA/Clear/Ausgabe: Mittel ~' + Math.round(totalCycles / H) + ' Takte/Zeile' +
    '  |  Peak-Zeile (Y=' + peakLineY + '): ' + maxLineCycles + ' Takte\\n' +
    'Zähler: src_steps=' + totalSrcSteps + ', dst_steps=' + totalDstSteps + ', skip_words=' + skippedWords + ', descriptors_scanned=' + totalDescsScanned;

  requestAnimationFrame(renderFrame);
}}
requestAnimationFrame(renderFrame);
</script>
</body>
</html>
"""
    with open(out_html, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"Wrote interactive HTML testbench: {out_html}")


def main():
    parser = argparse.ArgumentParser(description="Build NanoMig multi-sprite spacecraft testbench")
    parser.add_argument("--src", type=Path, default=DEFAULT_SRC_JPG, help="Path to real-spacecraft.jpg")
    parser.add_argument("--out-preview", type=Path, default=DEFAULT_OUT_PREVIEW, help="Output PNG preview path")
    parser.add_argument("--out-html", type=Path, default=DEFAULT_OUT_HTML, help="Output HTML testbench path")
    args = parser.parse_args()

    orig_arr, palette256, ram_words64, formats_meta = decompose_spacecraft(args.src)

    # 1. Verify bit-exact Zero-Word-Skip equivalence across ALL 4 showcase formats (13, 14, 15, 2)!
    rendered_by_fmt: Dict[int, np.ndarray] = {}
    for fmt5 in SHOWCASE_FORMATS:
        f_on = render_animated_frame(0.0, palette256, ram_words64, formats_meta[fmt5], explode=0.0, zero_skip=True)
        f_off = render_animated_frame(0.0, palette256, ram_words64, formats_meta[fmt5], explode=0.0, zero_skip=False)
        assert np.array_equal(f_on, f_off), f"Zero-Word-Skip ON vs OFF mismatch on FORMAT {fmt5}!"
        rendered_by_fmt[fmt5] = f_on
        print(f"VERIFIED Format {fmt5:2d}: Zero-Word-Skip ON vs OFF is 100% bit-identical!")

    # 2. Render 4-panel visual verification sheet comparing the new modes & animations:
    p_exploded = render_animated_frame(0.2, palette256, ram_words64, formats_meta[15], explode=1.0)
    p_fmt15    = rendered_by_fmt[15]
    p_fmt13    = render_animated_frame(2.15, palette256, ram_words64, formats_meta[13], explode=0.0)
    p_fmt14    = render_animated_frame(0.72, palette256, ram_words64, formats_meta[14], explode=0.0)

    sheet = Image.new("RGB", (448 * 2 + 24, 440 * 2 + 64), (11, 14, 19))
    draw = ImageDraw.Draw(sheet)
    panels = [
        (p_exploded, 8,   28,  "1. FORMAT 15 (16-12-12-12-12, 100% palettenfrei): 8 Sprites Explosions-Ansicht"),
        (p_fmt15,    464, 28,  "2. FORMAT 15 (16-12-12-12-12, 20 px/Burst): Zusammengesetzt durch Sprite-Engine"),
        (p_fmt13,    8,   496, "3. FORMAT 13 (12-6-8-6, 32 px/Burst): Kurvenflug Links (X_SCALE + Parallax)"),
        (p_fmt14,    464, 496, "4. FORMAT 14 (12-5-5-5-5, 40 px/Burst): Kurvenflug Rechts + Flammen-Y_SCALE"),
    ]
    for arr_p, px, py, title in panels:
        sheet.paste(Image.fromarray(arr_p, mode="RGB"), (px, py))
        draw.text((px + 6, py - 20), title, fill=(240, 160, 75))

    sheet.save(args.out_preview)
    print(f"Saved preview sheet: {args.out_preview}")

    # 3. Generate interactive 60-FPS HTML testbench with live format switcher
    generate_html_demo(palette256, formats_meta, args.out_html)


if __name__ == "__main__":
    main()
