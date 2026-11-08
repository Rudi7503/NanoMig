#!/usr/bin/env python3
"""
Bit-accurate hardware reference model for the NanoMig 32/64-Bit HAM- & CLUT-Sprite-Engine (Rev. 2).

Covers all binding hardware contracts:
  - 13 packed 32-bit formats (FORMAT 0..12, 32..64 pixels per 256-bit burst)
  - Per-sprite CLUT_MODE (0 = HAM, 1 = Direct Palette)
  - Explicit opaque bit (pix_opaque = (raw_code != 0)) decoupled from 24-bit RGB
  - 5-bit step_r/g/b (0..31) + 4 CUSTOM_STEP factors (0.5x, 1.0x, 1.5x, 2.0x)
    -> 10-bit signed pre-delta [-496..+496], 11-bit signed sum [-496..+751], clamped to 0..255
  - 11-bit Y_HEIGHT = {DATA_PTR[2:0], Y_HEIGHT_LO[7:0]} (Sentinel = 11'd0; 256/512/1080 valid)
  - 13-bit unsigned dy = next_y - Y_POS (no premature dy >= 2048 cutoff; 21-bit product)
  - Unified X-sampling accumulator u_fp (12.6 fixed-point, (u_fp >> 6) < src_width_px, no divider)
  - H_FLIP (dst_x starts at X_POS and decrements) & 16-bit signed dst_x clipping
  - SMOOTH_X 24-bit linear RGB interpolation (9-bit intermediate sums + opaque Edge-Guard)
  - Bit-exact Zero-Word-Skip (active only when eff_x_scale == 0x40, u_fp[5:0] == 0, pipeline empty)
  - 2048 x 32-bit Linebuffer with 1-cycle Write-Forwarding and Denise 4-layer output mixer + Blank gate
"""

from dataclasses import dataclass
from typing import List, Tuple, Dict

# 13 HAM_32BIT_* format bit-width sequences per 32-bit word (MSB to LSB)
FORMAT_SEQS: Dict[int, Tuple[int, ...]] = {
    0:  (4, 4, 4, 4, 4, 4, 4, 4),  # 8 px/32b, 64 px/burst
    1:  (5, 3, 5, 3, 5, 3, 5, 3),  # 8 px/32b, 64 px/burst
    2:  (6, 3, 4, 3, 6, 3, 4, 3),  # 8 px/32b, 64 px/burst
    3:  (6, 4, 4, 6, 4, 4, 4),     # 7 px/32b, 56 px/burst
    4:  (5, 4, 5, 4, 5, 4, 5),     # 7 px/32b, 56 px/burst
    5:  (6, 4, 5, 4, 5, 4, 4),     # 7 px/32b, 56 px/burst
    6:  (6, 5, 5, 6, 5, 5),        # 6 px/32b, 48 px/burst
    7:  (8, 4, 4, 8, 4, 4),        # 6 px/32b, 48 px/burst
    8:  (8, 4, 6, 5, 5, 4),        # 6 px/32b, 48 px/burst
    9:  (6, 4, 6, 5, 6, 5),        # 6 px/32b, 48 px/burst
    10: (8, 6, 6, 6, 6),           # 5 px/32b, 40 px/burst
    11: (8, 5, 8, 6, 5),           # 5 px/32b, 40 px/burst
    12: (8, 8, 8, 8),              # 4 px/32b, 32 px/burst
}


@dataclass
class DecodedPixel:
    opaque: bool
    r: int
    g: int
    b: int

    @property
    def rgb24(self) -> int:
        return ((self.r & 0xFF) << 16) | ((self.g & 0xFF) << 8) | (self.b & 0xFF)


@dataclass
class SpriteDescriptor:
    y_pos: int          # int16 (evaluated as signed int13: -4096..+4095)
    x_pos: int          # int16 (evaluated as signed int13: -4096..+4095)
    y_height_lo: int    # uint8 [7:0] of 11-bit Y_HEIGHT
    x_width256: int     # uint8 (1..64 bursts; >64 clamped to 64; 0 = No-Op)
    prio: int           # uint8 (0 = No-Op; 1..255 = active priority)
    pal_offset: int     # uint8 (0..255)
    data_ptr: int       # uint32 ([31:5] = 32-byte aligned base address, [2:0] = Y_HEIGHT[10:8])
    fmt: int            # uint4 (0..12 valid; 13..15 = No-Op)
    flags: int          # uint4 (bit0=H_FLIP, bit1=V_FLIP, bit2=SMOOTH_X, bit3=PRIO_GE)
    x_scale: int        # uint8 (2.6 fixed point, 0x40=1.0x; 1..0x0F clamped to 0x10; 0 = No-Op)
    y_scale: int        # uint8 (2.6 fixed point, 0x40=1.0x; 1..0x0F clamped to 0x10; 0 = No-Op)
    step_ctrl: int      # uint8 (bit7=CUSTOM_STEP, bit6=CLUT_MODE, [5:4]=R, [3:2]=G, [1:0]=B)

    @property
    def y_height11(self) -> int:
        return (((self.data_ptr & 0x7) << 8) | (self.y_height_lo & 0xFF)) & 0x7FF

    @property
    def base_addr(self) -> int:
        return self.data_ptr & 0xFFFFFFE0

    @property
    def h_flip(self) -> bool:
        return bool(self.flags & 0x1)

    @property
    def v_flip(self) -> bool:
        return bool(self.flags & 0x2)

    @property
    def smooth_x(self) -> bool:
        return bool(self.flags & 0x4)

    @property
    def prio_ge(self) -> bool:
        return bool(self.flags & 0x8)

    @property
    def clut_mode(self) -> bool:
        return bool(self.step_ctrl & 0x40)

    @property
    def custom_step(self) -> bool:
        return bool(self.step_ctrl & 0x80)


def sign_extend_13(val: int) -> int:
    v = val & 0x1FFF
    return v - 0x2000 if (v & 0x1000) else v


def sign_extend_16(val: int) -> int:
    v = val & 0xFFFF
    return v - 0x10000 if (v & 0x8000) else v


def compute_eff_step(base_step5: int, sel2: int, custom_en: bool) -> int:
    """
    5-bit base step (0..31) scaled by 2-bit CUSTOM_STEP selector:
      00 -> 0.5x: step >> 1
      01 -> 1.0x: step
      10 -> 1.5x: step + (step >> 1)
      11 -> 2.0x: step << 1
    Result fits in 6 bits unsigned (0..62).
    """
    s = base_step5 & 0x1F
    if not custom_en:
        return s
    sel = sel2 & 0x3
    if sel == 0:
        return s >> 1
    if sel == 1:
        return s
    if sel == 2:
        return s + (s >> 1)
    return s << 1


def two_delta(bits2: int) -> int:
    return (-2, -1, 1, 2)[bits2 & 0x3]


def precompute_ham_stage1(
    raw_code: int,
    bit_width: int,
    clut_mode: bool,
    pal_offset: int,
    eff_step_r: int,
    eff_step_g: int,
    eff_step_b: int,
) -> Tuple[bool, bool, int, int, int, int]:
    """
    Stage 1 of the dedicated Sprite HAM/CLUT decoder (parallel to synchronous M10K palette read).
    Returns: (opaque_reg, anchor_reg, pal_idx, delta_r_s10, delta_g_s10, delta_b_s10)
    """
    mask = (1 << bit_width) - 1
    code = raw_code & mask
    opaque = (code != 0)

    if clut_mode:
        pal_idx = (pal_offset + code) & 0xFF
        return opaque, True, pal_idx, 0, 0, 0

    # HAM mode: MSB selects anchor (0) vs delta (1)
    msb = (code >> (bit_width - 1)) & 1
    anchor = (msb == 0)
    low_mask = (1 << (bit_width - 1)) - 1
    pal_idx = (pal_offset + (code & low_mask)) & 0xFF

    turbo = False
    dr = dg = db = 0
    if bit_width == 3:     # HAM03
        dr = 2 if (code & 0x2) else -2
        dg = 2 if (code & 0x1) else -2
        db = dr
    elif bit_width == 4:   # HAM04
        dr = 2 if (code & 0x4) else -2
        dg = 2 if (code & 0x2) else -2
        db = 2 if (code & 0x1) else -2
    elif bit_width == 5:   # HAM05
        turbo = bool(code & 0x8)
        dr = 1 if (code & 0x4) else -1
        dg = 1 if (code & 0x2) else -1
        db = 1 if (code & 0x1) else -1
    elif bit_width == 6:   # HAM06
        turbo = bool(code & 0x10)
        dr = 1 if (code & 0x8) else -1
        dg = two_delta((code >> 1) & 0x3)
        db = 1 if (code & 0x1) else -1
    elif bit_width == 8:   # HAM08
        turbo = bool(code & 0x40)
        dr = two_delta((code >> 4) & 0x3)
        dg = two_delta((code >> 2) & 0x3)
        db = two_delta(code & 0x3)
    else:
        raise ValueError(f"Unsupported bit_width={bit_width}")

    def calc_delta_s10(eff_step: int, level: int) -> int:
        mag = (eff_step << 2) if turbo else eff_step  # max 62 * 4 = 248
        if level == -2:
            d = -(mag << 1)
        elif level == -1:
            d = -mag
        elif level == 1:
            d = mag
        elif level == 2:
            d = mag << 1
        else:
            d = 0
        # Verify 10-bit signed range [-512..+511]
        assert -512 <= d <= 511, f"Delta {d} out of 10-bit signed range!"
        return d

    return (
        opaque,
        anchor,
        pal_idx,
        calc_delta_s10(eff_step_r, dr),
        calc_delta_s10(eff_step_g, dg),
        calc_delta_s10(eff_step_b, db),
    )


def clamp_u8(val_s11: int) -> int:
    assert -512 <= val_s11 <= 767, f"11-bit signed sum out of bounds: {val_s11}"
    if val_s11 < 0:
        return 0
    if val_s11 > 255:
        return 255
    return val_s11


def unpack_32bit_word(word32: int, fmt: int) -> List[Tuple[int, int]]:
    """Unpacks a 32-bit word MSB-first into a list of (raw_code, bit_width)."""
    seq = FORMAT_SEQS[fmt]
    out: List[Tuple[int, int]] = []
    shift = 32
    for bw in seq:
        shift -= bw
        code = (word32 >> shift) & ((1 << bw) - 1)
        out.append((code, bw))
    assert shift == 0
    return out


def interpolate_smooth_x(p0: DecodedPixel, p1: DecodedPixel, frac2: int, smooth_x: bool) -> DecodedPixel:
    """
    24-bit RGB horizontal interpolator with 9-bit unsigned intermediate sums and opaque Edge-Guard.
    """
    f = frac2 & 0x3
    if p0.opaque and p1.opaque:
        if not smooth_x or f == 0:
            return DecodedPixel(True, p0.r, p0.g, p0.b)
        mid_r = (p0.r + p1.r) >> 1
        mid_g = (p0.g + p1.g) >> 1
        mid_b = (p0.b + p1.b) >> 1
        if f == 2:
            return DecodedPixel(True, mid_r, mid_g, mid_b)
        if f == 1:
            return DecodedPixel(
                True,
                (mid_r + p0.r) >> 1,
                (mid_g + p0.g) >> 1,
                (mid_b + p0.b) >> 1,
            )
        return DecodedPixel(
            True,
            (mid_r + p1.r) >> 1,
            (mid_g + p1.g) >> 1,
            (mid_b + p1.b) >> 1,
        )

    if p0.opaque and not p1.opaque:
        op = (f < 2) if smooth_x else True
        return DecodedPixel(op, p0.r if op else 0, p0.g if op else 0, p0.b if op else 0)

    if not p0.opaque and p1.opaque:
        op = (f >= 2) if smooth_x else False
        return DecodedPixel(op, p1.r if op else 0, p1.g if op else 0, p1.b if op else 0)

    return DecodedPixel(False, 0, 0, 0)


def render_scanline(
    next_y: int,
    descriptors: List[SpriteDescriptor],
    ram_words64: Dict[int, int],
    palette256: List[int],
    global_steps: Tuple[int, int, int] = (4, 4, 4),
    clip_xmax: int = 2048,
    zero_word_skip_en: bool = True,
    max_descriptors: int = 4096,
) -> List[int]:
    """
    Renders scanline `next_y` into a 2048 x 32-bit linebuffer ({BUF_PRIO[7:0], BUF_RGB[23:0]}).
    Models 1-cycle Write-Forwarding on consecutive accesses to the same dst_x.
    """
    assert 0 <= clip_xmax <= 2048
    linebuf = [0] * 2048

    # 1-cycle write-forwarding registers
    last_wr_valid = False
    last_wr_x = -1
    last_wr_prio = 0

    for idx, desc in enumerate(descriptors[:max_descriptors]):
        # 1. Check 11-bit Y_HEIGHT sentinel (0 = end of list)
        y_height = desc.y_height11
        if y_height == 0:
            break

        # 2. Signed 13-bit Y_POS check (Early Exit because list is Y-sorted)
        y_pos = sign_extend_13(desc.y_pos)
        if y_pos > next_y:
            break

        # 3. Deterministic No-Op checks
        if (
            desc.prio == 0
            or desc.x_width256 == 0
            or desc.x_scale == 0
            or desc.y_scale == 0
            or desc.fmt >= 13
        ):
            continue

        eff_w256 = min(desc.x_width256 & 0xFF, 64)
        eff_x_scale = max(desc.x_scale & 0xFF, 0x10)
        eff_y_scale = max(desc.y_scale & 0xFF, 0x10)

        # 4. 13-bit unsigned dy (no premature dy >= 2048 cutoff!)
        dy = next_y - y_pos
        assert 0 <= dy < 8192
        scaled_y = (dy * eff_y_scale) >> 6
        if scaled_y >= y_height:
            continue

        rel_y = (y_height - 1 - scaled_y) if desc.v_flip else scaled_y
        line_addr = desc.base_addr + ((rel_y * eff_w256) << 5)

        # Effective 6-bit HAM steps per channel
        eff_sr = compute_eff_step(global_steps[0], (desc.step_ctrl >> 4) & 0x3, desc.custom_step)
        eff_sg = compute_eff_step(global_steps[1], (desc.step_ctrl >> 2) & 0x3, desc.custom_step)
        eff_sb = compute_eff_step(global_steps[2], desc.step_ctrl & 0x3, desc.custom_step)

        # Unpack & decode source line left-to-right (with optional Zero-Word-Skip at 1:1)
        seq = FORMAT_SEQS[desc.fmt]
        px_per_64 = len(seq) * 2
        # 13-bit unsigned src_width_px (up to 64 * 64 = 4096)
        src_width_px = (eff_w256 * (len(seq) * 8)) & 0x1FFF

        acc_r = acc_g = acc_b = 0
        decoded_line: List[DecodedPixel] = []
        prev_opaque = False

        num_words64 = eff_w256 * 4
        for w_idx in range(num_words64):
            w64 = ram_words64.get(line_addr + w_idx * 8, 0) & 0xFFFFFFFFFFFFFFFF
            # Bit-exact Zero-Word-Skip condition:
            if (
                zero_word_skip_en
                and w64 == 0
                and eff_x_scale == 0x40
                and not prev_opaque
            ):
                acc_r = acc_g = acc_b = 0
                prev_opaque = False
                decoded_line.extend([DecodedPixel(False, 0, 0, 0)] * px_per_64)
                continue

            hi32 = (w64 >> 32) & 0xFFFFFFFF
            lo32 = w64 & 0xFFFFFFFF
            for w32 in (hi32, lo32):
                for raw_code, bw in unpack_32bit_word(w32, desc.fmt):
                    op, anchor, pal_idx, dr, dg, db = precompute_ham_stage1(
                        raw_code, bw, desc.clut_mode, desc.pal_offset, eff_sr, eff_sg, eff_sb
                    )
                    pal_rgb = palette256[pal_idx] & 0xFFFFFF
                    if not op:
                        acc_r = acc_g = acc_b = 0
                        px = DecodedPixel(False, 0, 0, 0)
                    elif anchor:
                        acc_r = (pal_rgb >> 16) & 0xFF
                        acc_g = (pal_rgb >> 8) & 0xFF
                        acc_b = pal_rgb & 0xFF
                        px = DecodedPixel(True, acc_r, acc_g, acc_b)
                    else:
                        acc_r = clamp_u8(acc_r + dr)
                        acc_g = clamp_u8(acc_g + dg)
                        acc_b = clamp_u8(acc_b + db)
                        px = DecodedPixel(True, acc_r, acc_g, acc_b)
                    decoded_line.append(px)
                    prev_opaque = op

        assert len(decoded_line) == src_width_px

        # 5. Unified X-sampling phase accumulator u_fp (19-bit unsigned 13.6 fixed point, no divider)
        u_fp = 0
        dst_x = sign_extend_13(desc.x_pos)

        while ((u_fp >> 6) & 0x1FFF) < src_width_px:
            # Right/left early clipping abort
            if not desc.h_flip and dst_x >= clip_xmax:
                break
            if desc.h_flip and dst_x < 0:
                break

            idx0 = (u_fp >> 6) & 0x1FFF
            p0 = decoded_line[idx0]
            p1 = decoded_line[idx0 + 1] if (idx0 + 1 < src_width_px) else DecodedPixel(False, 0, 0, 0)
            frac2 = (u_fp >> 4) & 0x3

            out_px = interpolate_smooth_x(p0, p1, frac2, desc.smooth_x)

            # Linebuffer write with 16-bit signed dst_x clipping and 1-cycle Write-Forwarding
            if 0 <= dst_x < clip_xmax:
                ram_old_prio = (linebuf[dst_x] >> 24) & 0xFF
                eff_old_prio = last_wr_prio if (last_wr_valid and dst_x == last_wr_x) else ram_old_prio
                prio_win = (desc.prio >= eff_old_prio) if desc.prio_ge else (desc.prio > eff_old_prio)
                if out_px.opaque and prio_win:
                    linebuf[dst_x] = ((desc.prio & 0xFF) << 24) | out_px.rgb24
                    last_wr_valid = True
                    last_wr_x = dst_x
                    last_wr_prio = desc.prio & 0xFF
                else:
                    last_wr_valid = False
            else:
                last_wr_valid = False

            # Explicit 19-bit unsigned hardware register mask (13.6 fixed-point: 0..524287)
            u_fp = (u_fp + eff_x_scale) & 0x7FFFF
            dst_x = sign_extend_16(dst_x - 1 if desc.h_flip else dst_x + 1)

    return linebuf


def denise_mix_pixel(
    buf_entry32: int,
    amiga_rgb24: int,
    blank_aligned: bool,
    sprsel_aligned: bool,
    pf_front_opaque: bool,
    pf_any_opaque: bool,
) -> int:
    """
    Denise 24-bit output priority mixer (4 layers via PRIO[7:6]) + Blank gate.
    """
    if blank_aligned:
        return 0x000000
    buf_prio = (buf_entry32 >> 24) & 0xFF
    buf_rgb = buf_entry32 & 0xFFFFFF
    if buf_prio == 0:
        return amiga_rgb24 & 0xFFFFFF

    layer = (buf_prio >> 6) & 0x3
    if layer == 3:
        win = True
    elif layer == 2:
        win = not sprsel_aligned
    elif layer == 1:
        win = (not sprsel_aligned) and (not pf_front_opaque)
    else:
        win = (not sprsel_aligned) and (not pf_any_opaque)

    return buf_rgb if win else (amiga_rgb24 & 0xFFFFFF)


# =============================================================================
# SELF-TEST SUITE (Covers all 8 Review Points & Counterexamples from Toby's KI)
# =============================================================================
def run_self_tests() -> None:
    palette = [0x000000] * 256
    palette[0] = 0x000000  # Slot 0 can even be non-zero, raw_code==0 is still transparent
    palette[1] = 0x000001  # Near-black 1
    palette[2] = 0x000100  # Near-black 2
    palette[3] = 0x000000  # True opaque black at slot 3!
    palette[4] = 0x804020  # Base color

    # 1. Test: Opaque dark pixels (0,0,1) + (0,1,0) -> SMOOTH_X mid = (0,0,0) stays OPAQUE!
    p_dark0 = DecodedPixel(True, 0, 0, 1)
    p_dark1 = DecodedPixel(True, 0, 1, 0)
    mid_px = interpolate_smooth_x(p_dark0, p_dark1, frac2=2, smooth_x=True)
    assert mid_px.opaque is True and mid_px.rgb24 == 0x000000, "Dark interpolation must stay opaque!"

    # 2. Test: Toby's KI counterexample for large Y zoom & negative Y_POS:
    #    Y_HEIGHT=1080, Y_SCALE=16 (4.0x zoom), Y_POS=-1500, next_y=1000 -> dy=2500 -> scaled_y=625 (<1080)
    #    Also tests 11-bit Y_HEIGHT = 1080 (0x438: y_height_lo=0x38, data_ptr[2:0]=0x4)
    ram: Dict[int, int] = {}
    target_line_addr = 0x00100000 + ((625 * 1) << 5)
    # Put raw_code=3 (True opaque black at palette[3]!) in FORMAT 12 (8888)
    ram[target_line_addr] = (0x03000000 << 32) | 0x00000000
    d_tall = SpriteDescriptor(
        y_pos=-1500,
        x_pos=100,
        y_height_lo=1080 & 0xFF,
        x_width256=1,
        prio=200,
        pal_offset=0,
        data_ptr=0x00100000 | ((1080 >> 8) & 0x7),
        fmt=12,
        flags=0,
        x_scale=0x40,
        y_scale=16,
        step_ctrl=0x40,  # CLUT_MODE = 1
    )
    lb = render_scanline(1000, [d_tall], ram, palette)
    assert lb[100] == (200 << 24) | 0x000000, f"Expected opaque black with prio 200, got {hex(lb[100])}"
    assert lb[101] == 0, "Expected transparent pixel at x=101"

    # 3. Test: Y_HEIGHT = 256 (y_height_lo == 0, data_ptr[2:0] == 1) must NOT trigger sentinel!
    ram[0x00200000] = (0x04000000 << 32)
    d_h256 = SpriteDescriptor(
        y_pos=10,
        x_pos=50,
        y_height_lo=0,           # Low byte is 0!
        x_width256=1,
        prio=120,
        pal_offset=0,
        data_ptr=0x00200000 | 1, # High bits = 1 -> Y_HEIGHT = 256
        fmt=12,
        flags=0,
        x_scale=0x40,
        y_scale=0x40,
        step_ctrl=0x40,
    )
    lb256 = render_scanline(10, [d_h256], ram, palette)
    assert lb256[50] == (120 << 24) | 0x804020

    # 4. Test: Zero-Word-Skip bit-exact equivalence across Delta -> Zero-Word -> Delta, Zoom, H_FLIP, SMOOTH_X
    ram_skip: Dict[int, int] = {
        0x00300000: 0x048F8000_00000000,  # Anchor 4, Delta, Delta, then 0s
        0x00300008: 0x00000000_00000000,  # Full 64-bit Zero-Word!
        0x00300010: 0x8F048700_00000000,  # Delta after zero-word (starts from reset acc=0!), then Anchor 4
        0x00300018: 0x00000000_00000000,
    }
    for scale in (0x40, 0x20, 0x80):
        for hflip in (0, 1):
            for smooth in (0, 4):
                desc_test = SpriteDescriptor(
                    y_pos=0,
                    x_pos=400 if hflip else 50,
                    y_height_lo=16,
                    x_width256=1,
                    prio=150,
                    pal_offset=0,
                    data_ptr=0x00300000,
                    fmt=0,  # HAM_32BIT_44444444 (64 px/burst)
                    flags=hflip | smooth,
                    x_scale=scale,
                    y_scale=0x40,
                    step_ctrl=0x80 | 0b11_10_00,  # CUSTOM_STEP: R=2.0x, G=1.5x, B=0.5x
                )
                lb_on = render_scanline(0, [desc_test], ram_skip, palette, (31, 31, 31), zero_word_skip_en=True)
                lb_off = render_scanline(0, [desc_test], ram_skip, palette, (31, 31, 31), zero_word_skip_en=False)
                assert lb_on == lb_off, f"Zero-Word-Skip mismatch at scale={scale}, hflip={hflip}, smooth={smooth}"

    # 5. Test: H_FLIP pixel count & mirror symmetry for arbitrary X_SCALE (e.g. X_SCALE = 255)
    ram_sym: Dict[int, int] = {
        0x00400000: 0x01020304_04030201,
        0x00400008: 0x01020304_04030201,
        0x00400010: 0x01020304_04030201,
        0x00400018: 0x01020304_04030201,
    }
    d_norm = SpriteDescriptor(0, 100, 1, 1, 180, 0, 0x00400000, 12, 0, 255, 64, 0x40)
    d_flip = SpriteDescriptor(0, 108, 1, 1, 180, 0, 0x00400000, 12, 1, 255, 64, 0x40)
    lb_n = render_scanline(0, [d_norm], ram_sym, palette)
    lb_f = render_scanline(0, [d_flip], ram_sym, palette)
    n_Opaque = [x for x in range(2048) if lb_n[x] != 0]
    f_Opaque = [x for x in range(2048) if lb_f[x] != 0]
    assert len(n_Opaque) == 9 and len(f_Opaque) == 9, f"Expected 9 samples at scale=255, got {len(n_Opaque)}"
    assert [lb_n[x] for x in n_Opaque] == list(reversed([lb_f[x] for x in f_Opaque]))

    # 6. Test: Denise 4-layer mixing & Blank gate (Blank must block even Layer 11!)
    assert denise_mix_pixel((250 << 24) | 0xFF0000, 0x112233, blank_aligned=True,
                            sprsel_aligned=False, pf_front_opaque=False, pf_any_opaque=False) == 0x000000
    assert denise_mix_pixel((250 << 24) | 0xFF0000, 0x112233, blank_aligned=False,
                            sprsel_aligned=True, pf_front_opaque=True, pf_any_opaque=True) == 0xFF0000

    # 7. Test: Toby's KI reproduction of 4096 source pixels (FORMAT=0, X_WIDTH256=64, X_SCALE=255)
    #    With 19-bit u_fp (13.6 fixed-point), u_fp_next = 262395 -> u_fp[18:6] = 4099 >= 4096,
    #    so it terminates cleanly after exactly 1029 destination pixels (instead of wrapping at 18 bits)!
    ram_4096: Dict[int, int] = {}
    for w_i in range(64 * 4):
        ram_4096[0x00500000 + w_i * 8] = 0x11111111_11111111
    d_4096 = SpriteDescriptor(
        y_pos=0,
        x_pos=0,
        y_height_lo=1,
        x_width256=64,
        prio=180,
        pal_offset=0,
        data_ptr=0x00500000,
        fmt=0,         # 64 px/burst * 64 bursts = 4096 source pixels
        flags=0,
        x_scale=255,   # Shrink factor 255/64
        y_scale=0x40,
        step_ctrl=0x40 # CLUT_MODE = 1
    )
    lb_4096 = render_scanline(0, [d_4096], ram_4096, palette)
    n_written = sum(1 for v in lb_4096 if v != 0)
    assert n_written == 1029, f"Expected exactly 1029 pixels for 4096px @ X_SCALE=255, got {n_written}"

    print("ALL FUNCTIONAL SPRITE_REF_MODEL SELF-TESTS PASSED (INCLUDING 19-BIT u_fp 4096PX TEST)!")


if __name__ == "__main__":
    run_self_tests()
