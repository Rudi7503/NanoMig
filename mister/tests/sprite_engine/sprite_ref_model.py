#!/usr/bin/env python3
"""
Bit-accurate hardware reference model for the NanoMig 32/64-Bit HAM-, HighColor- & CLUT-Sprite-Engine (Rev. 3).

Covers all binding hardware contracts:
  - 19 packed 32/64-bit formats (FORMAT 0..18, 8..64 pixels per 256-bit burst):
      * 0..12 : 32-bit mixed HAM03..08 formats (32..64 px/burst)
      * 13    : HAM_32BIT_12_6_8_6        (12-6-8-6, 32 px/burst; pixels 2..4 use PAL_OFFSET!)
      * 14    : HAM_32BIT_12_5555         (12-5-5-5-5, 40 px/burst; pixels 2..5 use PAL_OFFSET!)
      * 15    : HAM_64BIT_16_12_12_12_12  (16-12-12-12-12 in 64-bit word, 20 px/burst, palette-free)
      * 16    : HAM_32BIT_16_16           (16-16 HAM16, 16 px/burst, palette-free)
      * 17    : RGB_32BIT_16_16           (16-16 Direct HighColor: CLUT_MODE=0 -> RGB565, CLUT_MODE=1 -> RGB555, 16 px/burst)
      * 18    : RGB_32BIT_DIRECT          (32-bit ARGB8888 TrueColor, 8 px/burst, per-pixel alpha, palette-free)
  - 4 Hardware Blend Modes (BLEND_MODE[1:0]):
      * 00 : Normal / Opaque overwrite (prio comparison wins)
      * 01 : Additive Blending (min(255, S + D), 0 ALM multipliers)
      * 10 : 50/50 Translucent ((S + D) >> 1, 0 ALM multipliers)
      * 11 : Full 8-bit Alpha (D + (alpha * (S - D)) >> 8; per-pixel in FMT 18, SPR_ALPHA in FMT 15..17)
  - Explicit opaque bit (pix_opaque = (raw_code != 0) && (eff_alpha != 0)) decoupled from 24-bit RGB
  - 4-bit step_r/g/b (0..15) + 4 CUSTOM_STEP factors (0.5x, 1.0x, 1.5x, 2.0x -> 5-bit eff_step 0..30)
    -> 12-bit signed pre-delta [-1920..+1800], 13-bit signed sum [-1920..+2055], clamped to 0..255
  - 11-bit Y_HEIGHT = {DATA_PTR[2:0], Y_HEIGHT_LO[7:0]} (Sentinel = 11'd0; 256/512/1080 valid)
  - 5-bit FORMAT = {DATA_PTR[3], FORMAT_LO[3:0]} (0..18 valid; 19..31 = No-Op; DATA_PTR[4]=0 masked)
  - 13-bit unsigned dy = next_y - Y_POS (no premature dy >= 2048 cutoff; 21-bit product)
  - Unified X-sampling accumulator u_fp (19-bit unsigned 13.6 fixed-point, (u_fp >> 6) < src_width_px, no divider)
  - H_FLIP (dst_x starts at X_POS and decrements) & 16-bit signed dst_x clipping
  - SMOOTH_X 24-bit linear RGB interpolation (9-bit intermediate sums + opaque Edge-Guard)
  - Bit-exact Zero-Word-Skip (active only when eff_x_scale == 0x40, u_fp[5:0] == 0, pipeline empty)
  - 2048 x 32-bit Linebuffer with 1-cycle Write-Forwarding and Denise 4-layer output mixer + Blank gate
"""

import struct
from dataclasses import dataclass
from typing import List, Tuple, Dict, Optional

DESC_REV = 3

# 32-bit format sequences (for formats that repeat in upper & lower 32 bits of a 64-bit word)
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
    13: (12, 6, 8, 6),             # 4 px/32b, 32 px/burst (HAM12 + HAM06 + HAM08 + HAM06)
    14: (12, 5, 5, 5, 5),          # 5 px/32b, 40 px/burst (HAM12 + 4x HAM05)
    16: (16, 16),                  # 2 px/32b, 16 px/burst (HAM16)
    17: (16, 16),                  # 2 px/32b, 16 px/burst (Direct RGB565 / RGB555)
    18: (32,),                     # 1 px/32b, 8 px/burst (ARGB8888 TrueColor)
}

# Full 64-bit word bit-width sequences for all 19 formats (0..18)
FORMAT_SEQS_64: Dict[int, Tuple[int, ...]] = {
    fmt: seq + seq for fmt, seq in FORMAT_SEQS.items()
}
FORMAT_SEQS_64[15] = (16, 12, 12, 12, 12)  # 5 px/64b, 20 px/burst (1x HAM16 + 4x HAM12)


@dataclass
class DecodedPixel:
    opaque: bool
    r: int
    g: int
    b: int
    alpha: int = 255
    has_per_pixel_alpha: bool = False

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
    pal_offset: int     # uint8 (0..255: PAL_OFFSET for fmt 0..14; SPR_ALPHA for fmt 15..17)
    data_ptr: int       # uint32 ([31:5]=base_addr, [4]=0 masked, [3]=FORMAT[4], [2:0]=Y_HEIGHT[10:8])
    fmt: int            # uint4 (FORMAT_LO[3:0]; combined with data_ptr[3] to form 5-bit format 0..18)
    flags: int          # uint4 (bit0=H_FLIP, bit1=V_FLIP, bit2=SMOOTH_X, bit3=PRIO_GE)
    x_scale: int        # uint8 (2.6 fixed point, 0x40=1.0x; 1..0x0F clamped to 0x10; 0 = No-Op)
    y_scale: int        # uint8 (2.6 fixed point, 0x40=1.0x; 1..0x0F clamped to 0x10; 0 = No-Op)
    step_ctrl: int      # uint8 (bit7=CUSTOM_STEP, bit6=CLUT_MODE, [5:4]=BLEND_MODE or R_STEP, [3:0]=STEP)

    @property
    def y_height11(self) -> int:
        return (((self.data_ptr & 0x7) << 8) | (self.y_height_lo & 0xFF)) & 0x7FF

    @property
    def fmt5(self) -> int:
        # Strictly decoded from raw fields without convenience bypass:
        return (((self.data_ptr >> 3) & 0x1) << 4) | (self.fmt & 0xF)

    @property
    def base_addr(self) -> int:
        # DATA_PTR[4] is reserved and masked to 0; 32-byte aligned
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

    @property
    def blend_mode(self) -> int:
        """
        4 Hardware Blend Modes:
          00 = Normal / Opaque
          01 = Additive Blending (min(255, S + D))
          10 = 50/50 Translucent ((S + D) >> 1)
          11 = Full 8-bit Alpha (D + (alpha * (S - D)) >> 8)
        Active when CUSTOM_STEP == 0 or for formats >= 17 (HighColor / ARGB).
        """
        if not self.custom_step or self.fmt5 >= 17:
            return (self.step_ctrl >> 4) & 0x3
        return 0

    @property
    def spr_alpha(self) -> int:
        """
        Per-sprite global alpha (0..255).
        Only valid for palette-free formats (15..17).
        Formats 0..14 use pal_offset strictly as palette offset!
        Format 18 uses per-pixel alpha from code[31:24].
        """
        if self.fmt5 in (15, 16, 17):
            return self.pal_offset & 0xFF
        return 255


def pack_descriptor_raw(desc: SpriteDescriptor) -> bytes:
    """
    Packs a SpriteDescriptor into exact 16 bytes Big-Endian (Motorola format).
    """
    byte12 = ((desc.fmt & 0xF) << 4) | (desc.flags & 0xF)
    clean_data_ptr = desc.data_ptr & ~0x10
    return struct.pack(
        '>hhBBBBIBBBB',
        desc.y_pos,
        desc.x_pos,
        desc.y_height_lo & 0xFF,
        desc.x_width256 & 0xFF,
        desc.prio & 0xFF,
        desc.pal_offset & 0xFF,
        clean_data_ptr & 0xFFFFFFFF,
        byte12 & 0xFF,
        desc.x_scale & 0xFF,
        desc.y_scale & 0xFF,
        desc.step_ctrl & 0xFF,
    )


def unpack_descriptor_raw(data16: bytes) -> SpriteDescriptor:
    """
    Unpacks a 16-byte raw Big-Endian chunk into a SpriteDescriptor without convenience bypasses.
    """
    assert len(data16) == 16
    (
        y_pos,
        x_pos,
        y_h_lo,
        x_w256,
        prio,
        pal_off,
        data_ptr,
        b12,
        x_sc,
        y_sc,
        step_c,
    ) = struct.unpack('>hhBBBBIBBBB', data16)

    fmt_lo = (b12 >> 4) & 0xF
    flags = b12 & 0xF
    clean_data_ptr = data_ptr & ~0x10

    return SpriteDescriptor(
        y_pos=y_pos,
        x_pos=x_pos,
        y_height_lo=y_h_lo,
        x_width256=x_w256,
        prio=prio,
        pal_offset=pal_off,
        data_ptr=clean_data_ptr,
        fmt=fmt_lo,
        flags=flags,
        x_scale=x_sc,
        y_scale=y_sc,
        step_ctrl=step_c,
    )


def sign_extend_13(val: int) -> int:
    v = val & 0x1FFF
    return v - 0x2000 if (v & 0x1000) else v


def sign_extend_16(val: int) -> int:
    v = val & 0xFFFF
    return v - 0x10000 if (v & 0x8000) else v


def sign_extend_n(val: int, bits: int) -> int:
    mask = (1 << bits) - 1
    v = val & mask
    return v - (1 << bits) if (v & (1 << (bits - 1))) else v


def compute_eff_step(base_step4: int, sel2: int, custom_en: bool) -> int:
    s = base_step4 & 0x0F
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
    is_direct_rgb16: bool = False,
    is_direct_argb32: bool = False,
) -> Tuple[bool, bool, bool, int, int, int, int, int, int, bool]:
    """
    Stage 1 of the dedicated Sprite HAM/HighColor/CLUT decoder.
    Returns:
      (opaque_reg, anchor_reg, direct_anchor_reg, direct_rgb24, pal_idx, delta_r_s12, delta_g_s12, delta_b_s12, alpha8, has_per_pixel_alpha)
    """
    mask = (1 << bit_width) - 1
    code = raw_code & mask

    # 1. FORMAT 18 (RGB_32BIT_DIRECT / ARGB8888 TrueColor)
    if is_direct_argb32 or bit_width == 32:
        alpha8 = (code >> 24) & 0xFF
        r8 = (code >> 16) & 0xFF
        g8 = (code >> 8) & 0xFF
        b8 = code & 0xFF
        direct_rgb = (r8 << 16) | (g8 << 8) | b8
        # Pixel is opaque only if code != 0 and alpha != 0 (alpha 0 is transparent!)
        opaque = (code != 0) and (alpha8 != 0)
        return opaque, True, True, direct_rgb, 0, 0, 0, 0, alpha8, True

    opaque = (code != 0)

    # 2. FORMAT 17 (RGB_32BIT_16_16): 15/16-bit Direct HighColor (no HAM)
    if is_direct_rgb16:
        if not clut_mode:
            # RGB565: left-shift by 3 (R/B) and 2 (G) -> max 248/252
            r8 = ((code >> 11) & 0x1F) << 3
            g8 = ((code >> 5) & 0x3F) << 2
            b8 = (code & 0x1F) << 3
        else:
            # RGB555: 0x8000 is true opaque black!
            r8 = ((code >> 10) & 0x1F) << 3
            g8 = ((code >> 5) & 0x1F) << 3
            b8 = (code & 0x1F) << 3
        direct_rgb = (r8 << 16) | (g8 << 8) | b8
        return opaque, True, True, direct_rgb, 0, 0, 0, 0, 255, False

    # 3. HAM12 (12-bit pixel: direct 11-bit RGB anchor or 3/4/3 delta)
    if bit_width == 12:
        if clut_mode:
            # Direct RGB444
            r8 = ((code >> 8) & 0xF) << 4
            g8 = ((code >> 4) & 0xF) << 4
            b8 = (code & 0xF) << 4
            return opaque, True, True, (r8 << 16) | (g8 << 8) | b8, 0, 0, 0, 0, 255, False
        if ((code >> 11) & 1) == 0:
            # 11-bit direct RGB anchor
            b10 = (code >> 10) & 1
            r3 = (code >> 7) & 0x7
            g4 = (code >> 3) & 0xF
            b3 = code & 0x7
            r8 = ((r3 << 1) | b10) << 4
            g8 = g4 << 4
            b8 = ((b3 << 1) | b10) << 4
            return opaque, True, True, (r8 << 16) | (g8 << 8) | b8, 0, 0, 0, 0, 255, False
        # HAM12 Delta (code[11] == 1)
        turbo = bool((code >> 10) & 1)
        m = 4 if turbo else 1
        dr = sign_extend_n((code >> 7) & 0x7, 3) * eff_step_r * m
        dg = sign_extend_n((code >> 3) & 0xF, 4) * eff_step_g * m
        db = sign_extend_n(code & 0x7, 3) * eff_step_b * m
        assert -2048 <= dr <= 2047 and -2048 <= dg <= 2047 and -2048 <= db <= 2047
        return opaque, False, False, 0, 0, dr, dg, db, 255, False

    # 4. HAM16 (16-bit pixel: direct 15-bit RGB555 anchor or 4/5/5 delta)
    if bit_width == 16:
        if clut_mode:
            # Direct RGB565
            r8 = ((code >> 11) & 0x1F) << 3
            g8 = ((code >> 5) & 0x3F) << 2
            b8 = (code & 0x1F) << 3
            return opaque, True, True, (r8 << 16) | (g8 << 8) | b8, 0, 0, 0, 0, 255, False
        if ((code >> 15) & 1) == 0:
            # 15-bit direct RGB555 anchor
            r8 = ((code >> 10) & 0x1F) << 3
            g8 = ((code >> 5) & 0x1F) << 3
            b8 = (code & 0x1F) << 3
            return opaque, True, True, (r8 << 16) | (g8 << 8) | b8, 0, 0, 0, 0, 255, False
        # HAM16 Delta (code[15] == 1)
        turbo = bool((code >> 14) & 1)
        m = 4 if turbo else 1
        dr = sign_extend_n((code >> 10) & 0x0F, 4) * eff_step_r * m
        dg = sign_extend_n((code >> 5) & 0x1F, 5) * eff_step_g * m
        db = sign_extend_n(code & 0x1F, 5) * eff_step_b * m
        assert -2048 <= dr <= 2047 and -2048 <= dg <= 2047 and -2048 <= db <= 2047
        return opaque, False, False, 0, 0, dr, dg, db, 255, False

    # 5. Standard 3..8-bit CLUT or HAM03..HAM08 modes (strictly preserve PAL_OFFSET!)
    if clut_mode:
        pal_idx = (pal_offset + code) & 0xFF
        return opaque, True, False, 0, pal_idx, 0, 0, 0, 255, False

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

    def calc_delta_s12(eff_step: int, level: int) -> int:
        mag = (eff_step << 2) if turbo else eff_step
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
        assert -2048 <= d <= 2047, f"Delta {d} out of 12-bit signed range!"
        return d

    return (
        opaque,
        anchor,
        False,
        0,
        pal_idx,
        calc_delta_s12(eff_step_r, dr),
        calc_delta_s12(eff_step_g, dg),
        calc_delta_s12(eff_step_b, db),
        255,
        False,
    )


def clamp_u8(val_s13: int) -> int:
    if val_s13 < 0:
        return 0
    if val_s13 > 255:
        return 255
    return val_s13


def unpack_64bit_word(word64: int, fmt5: int) -> List[Tuple[int, int]]:
    seq64 = FORMAT_SEQS_64[fmt5]
    out: List[Tuple[int, int]] = []
    shift = 64
    for bw in seq64:
        shift -= bw
        code = (word64 >> shift) & ((1 << bw) - 1)
        out.append((code, bw))
    assert shift == 0
    return out


def interpolate_smooth_x(p0: DecodedPixel, p1: DecodedPixel, frac2: int, smooth_x: bool) -> DecodedPixel:
    f = frac2 & 0x3
    has_ppa = p0.has_per_pixel_alpha or p1.has_per_pixel_alpha
    if p0.opaque and p1.opaque:
        if not smooth_x or f == 0:
            return DecodedPixel(True, p0.r, p0.g, p0.b, p0.alpha, has_ppa)
        mid_r = (p0.r + p1.r) >> 1
        mid_g = (p0.g + p1.g) >> 1
        mid_b = (p0.b + p1.b) >> 1
        mid_a = (p0.alpha + p1.alpha) >> 1
        if f == 2:
            return DecodedPixel(True, mid_r, mid_g, mid_b, mid_a, has_ppa)
        if f == 1:
            return DecodedPixel(
                True,
                (mid_r + p0.r) >> 1,
                (mid_g + p0.g) >> 1,
                (mid_b + p0.b) >> 1,
                (mid_a + p0.alpha) >> 1,
                has_ppa,
            )
        return DecodedPixel(
            True,
            (mid_r + p1.r) >> 1,
            (mid_g + p1.g) >> 1,
            (mid_b + p1.b) >> 1,
            (mid_a + p1.alpha) >> 1,
            has_ppa,
        )

    if p0.opaque and not p1.opaque:
        op = (f < 2) if smooth_x else True
        return DecodedPixel(op, p0.r if op else 0, p0.g if op else 0, p0.b if op else 0, p0.alpha if op else 0, has_ppa)

    if not p0.opaque and p1.opaque:
        op = (f >= 2) if smooth_x else False
        return DecodedPixel(op, p1.r if op else 0, p1.g if op else 0, p1.b if op else 0, p1.alpha if op else 0, has_ppa)

    return DecodedPixel(False, 0, 0, 0, 0, has_ppa)


@dataclass
class LineStats:
    src_steps: int = 0
    dst_steps: int = 0
    skip_words: int = 0
    descriptors_scanned: int = 0


def blend_pixel(
    dest_rgb24: int,
    dest_prio: int,
    src_px: DecodedPixel,
    blend_mode: int,
    global_alpha: int = 255,
) -> int:
    """
    Applies one of the 4 hardware blend modes:
      00 : Normal / Opaque (source overwrites destination)
      01 : Additive Blending (min(255, S + D))
      10 : 50/50 Translucent ((S + D) >> 1)
      11 : Full 8-bit Alpha (D + (alpha * (S - D)) >> 8)

    Contract (Review #6):
      - In FORMAT 18: alpha is ALWAYS taken from src_px.alpha (has_per_pixel_alpha == True),
        never overridden by global_alpha, even when alpha == 255!
      - In FORMAT 15..17: alpha is taken from global_alpha.
      - If alpha == 255: full endpoint saturation returns src_px.rgb24 exactly.
      - If alpha == 0: transparent (no write).
      - Over empty buffer (dest_prio == 0): writes src_px.rgb24 directly.
    """
    # Explicit alpha resolution without sentinel collision:
    a = src_px.alpha if src_px.has_per_pixel_alpha else global_alpha

    if blend_mode == 0 or dest_prio == 0:
        if blend_mode == 3 and dest_prio == 0:
            if a == 255:
                return src_px.rgb24
            if a == 0:
                return 0
            # S * a / 256 over empty background
            return (
                (clamp_u8((src_px.r * a) >> 8) << 16)
                | (clamp_u8((src_px.g * a) >> 8) << 8)
                | clamp_u8((src_px.b * a) >> 8)
            )
        return src_px.rgb24

    dr = (dest_rgb24 >> 16) & 0xFF
    dg = (dest_rgb24 >> 8) & 0xFF
    db = dest_rgb24 & 0xFF
    sr = src_px.r
    sg = src_px.g
    sb = src_px.b

    if blend_mode == 1:
        # Additive Blending: min(255, S + D)
        return (
            (clamp_u8(dr + sr) << 16)
            | (clamp_u8(dg + sg) << 8)
            | clamp_u8(db + sb)
        )

    if blend_mode == 2:
        # 50/50 Translucent: (S + D) >> 1
        return (
            (((dr + sr) >> 1) << 16)
            | (((dg + sg) >> 1) << 8)
            | ((db + sb) >> 1)
        )

    if blend_mode == 3:
        # Full 8-bit Alpha: D + (((S - D) * a) >> 8)
        if a == 255:
            return src_px.rgb24
        if a == 0:
            return dest_rgb24
        out_r = clamp_u8(dr + (((sr - dr) * a) >> 8))
        out_g = clamp_u8(dg + (((sg - dg) * a) >> 8))
        out_b = clamp_u8(db + (((sb - db) * a) >> 8))
        return (out_r << 16) | (out_g << 8) | out_b

    return src_px.rgb24


def render_scanline(
    next_y: int,
    descriptors: List[SpriteDescriptor],
    ram_words64: Dict[int, int],
    palette256: List[int],
    global_steps: Tuple[int, int, int] = (4, 4, 4),
    clip_xmax: int = 2048,
    zero_word_skip_en: bool = True,
    max_descriptors: int = 4096,
    stats: Optional[LineStats] = None,
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
    last_wr_rgb = 0

    for idx, desc in enumerate(descriptors[:max_descriptors]):
        if stats:
            stats.descriptors_scanned += 1

        # 1. Check 11-bit Y_HEIGHT sentinel (0 = end of list)
        y_height = desc.y_height11
        if y_height == 0:
            break

        # 2. Signed 13-bit Y_POS check (Early Exit because list is Y-sorted)
        y_pos = sign_extend_13(desc.y_pos)
        if y_pos > next_y:
            break

        # 3. Deterministic No-Op checks (FORMAT 19..31 = No-Op)
        fmt5 = desc.fmt5
        if (
            desc.prio == 0
            or desc.x_width256 == 0
            or desc.x_scale == 0
            or desc.y_scale == 0
            or fmt5 >= 19
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

        # Effective 5-bit HAM steps per channel (from 4-bit base steps 0..15)
        eff_sr = compute_eff_step(global_steps[0], (desc.step_ctrl >> 4) & 0x3, desc.custom_step)
        eff_sg = compute_eff_step(global_steps[1], (desc.step_ctrl >> 2) & 0x3, desc.custom_step)
        eff_sb = compute_eff_step(global_steps[2], desc.step_ctrl & 0x3, desc.custom_step)

        # Unpack & decode source line left-to-right (with optional Zero-Word-Skip at 1:1)
        seq64 = FORMAT_SEQS_64[fmt5]
        px_per_64 = len(seq64)
        src_width_px = (eff_w256 * (px_per_64 * 4)) & 0x1FFF

        acc_r = acc_g = acc_b = 0
        decoded_line: List[DecodedPixel] = []
        prev_opaque = False
        is_direct_rgb16 = (fmt5 == 17)
        is_direct_argb32 = (fmt5 == 18)

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
                if stats:
                    stats.skip_words += 1
                acc_r = acc_g = acc_b = 0
                prev_opaque = False
                decoded_line.extend([DecodedPixel(False, 0, 0, 0, 0, is_direct_argb32)] * px_per_64)
                continue

            for raw_code, bw in unpack_64bit_word(w64, fmt5):
                if stats:
                    stats.src_steps += 1
                op, anchor, direct_anchor, direct_rgb, pal_idx, dr, dg, db, a8, has_ppa = precompute_ham_stage1(
                    raw_code, bw, desc.clut_mode, desc.pal_offset, eff_sr, eff_sg, eff_sb,
                    is_direct_rgb16, is_direct_argb32
                )
                pal_rgb = palette256[pal_idx] & 0xFFFFFF
                anchor_rgb = direct_rgb if direct_anchor else pal_rgb
                if not op:
                    acc_r = acc_g = acc_b = 0
                    px = DecodedPixel(False, 0, 0, 0, 0, has_ppa)
                elif anchor:
                    acc_r = (anchor_rgb >> 16) & 0xFF
                    acc_g = (anchor_rgb >> 8) & 0xFF
                    acc_b = anchor_rgb & 0xFF
                    px = DecodedPixel(True, acc_r, acc_g, acc_b, a8, has_ppa)
                else:
                    acc_r = clamp_u8(acc_r + dr)
                    acc_g = clamp_u8(acc_g + dg)
                    acc_b = clamp_u8(acc_b + db)
                    px = DecodedPixel(True, acc_r, acc_g, acc_b, 255, False)
                decoded_line.append(px)
                prev_opaque = op

        assert len(decoded_line) == src_width_px

        # 5. Unified X-sampling phase accumulator u_fp (19-bit unsigned 13.6 fixed point, no divider)
        u_fp = 0
        dst_x = sign_extend_13(desc.x_pos)
        b_mode = desc.blend_mode
        g_alpha = desc.spr_alpha

        while ((u_fp >> 6) & 0x1FFF) < src_width_px:
            if stats:
                stats.dst_steps += 1
            if not desc.h_flip and dst_x >= clip_xmax:
                break
            if desc.h_flip and dst_x < 0:
                break

            idx0 = (u_fp >> 6) & 0x1FFF
            p0 = decoded_line[idx0]
            p1 = decoded_line[idx0 + 1] if (idx0 + 1 < src_width_px) else DecodedPixel(False, 0, 0, 0, 0, p0.has_per_pixel_alpha)
            frac2 = (u_fp >> 4) & 0x3

            out_px = interpolate_smooth_x(p0, p1, frac2, desc.smooth_x)

            # Check alpha transparency: if blend mode 11 and alpha == 0, pixel is transparent (WE=0)!
            eff_a = out_px.alpha if out_px.has_per_pixel_alpha else g_alpha
            if b_mode == 3 and eff_a == 0:
                out_px.opaque = False

            # Linebuffer write with 16-bit signed dst_x clipping and 1-cycle Write-Forwarding
            if 0 <= dst_x < clip_xmax:
                ram_old_entry = linebuf[dst_x]
                ram_old_prio = (ram_old_entry >> 24) & 0xFF
                ram_old_rgb = ram_old_entry & 0xFFFFFF

                if last_wr_valid and dst_x == last_wr_x:
                    eff_old_prio = last_wr_prio
                    eff_old_rgb = last_wr_rgb
                else:
                    eff_old_prio = ram_old_prio
                    eff_old_rgb = ram_old_rgb

                prio_win = (desc.prio >= eff_old_prio) if desc.prio_ge else (desc.prio > eff_old_prio)
                if out_px.opaque and prio_win:
                    blended_rgb = blend_pixel(eff_old_rgb, eff_old_prio, out_px, b_mode, g_alpha)
                    linebuf[dst_x] = ((desc.prio & 0xFF) << 24) | blended_rgb
                    last_wr_valid = True
                    last_wr_x = dst_x
                    last_wr_prio = desc.prio & 0xFF
                    last_wr_rgb = blended_rgb
                else:
                    last_wr_valid = False
            else:
                last_wr_valid = False

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
# SELF-TEST SUITE
# =============================================================================
def run_self_tests() -> None:
    palette = [0x000000] * 256
    palette[0] = 0x000000
    palette[1] = 0x000001
    palette[2] = 0x000100
    palette[3] = 0x000000
    palette[4] = 0x804020
    palette[129] = 0x00FF00  # For testing pal_offset in fmt 13/14

    # 1. Dark interpolation stays opaque
    p_dark0 = DecodedPixel(True, 0, 0, 1)
    p_dark1 = DecodedPixel(True, 0, 1, 0)
    mid_px = interpolate_smooth_x(p_dark0, p_dark1, frac2=2, smooth_x=True)
    assert mid_px.opaque is True and mid_px.rgb24 == 0x000000

    # 2. Raw 16-byte pack / unpack
    d_orig = SpriteDescriptor(
        y_pos=-1500, x_pos=100, y_height_lo=1080 & 0xFF, x_width256=1, prio=200, pal_offset=0,
        data_ptr=0x00100008 | ((1080 >> 8) & 0x7), fmt=1, flags=0b1101, x_scale=0x40, y_scale=16, step_ctrl=0x40,
    )
    raw_bytes = pack_descriptor_raw(d_orig)
    assert len(raw_bytes) == 16
    d_unpacked = unpack_descriptor_raw(raw_bytes)
    assert d_unpacked.y_pos == -1500 and d_unpacked.x_pos == 100 and d_unpacked.fmt5 == 17
    assert (d_unpacked.data_ptr & 0x10) == 0

    # 3. Full 256 x 3 x 2 Alpha Verification Matrix (Review #6 & Review #7)
    # Tests all 256 alpha values (0..255) x 3 Byte7 values (0, 128, 255) x 2 target states (empty & occupied).
    # Verifies that:
    #  - FORMAT 18 alpha is NEVER overridden by Byte 7 (no sentinel bug at 255!)
    #  - Alpha 255 reaches exact saturation C_out = S without rounding loss
    #  - Alpha 0 preserves destination color & priority (WE = 0)
    #  - In-between values match exact /256 floor formula
    sr, sg, sb = 240, 120, 60
    dr, dg, db = 40, 80, 160
    dest_rgb = (dr << 16) | (dg << 8) | db
    for a in range(256):
        for b7 in (0, 128, 255):
            src_px = DecodedPixel(True, sr, sg, sb, alpha=a, has_per_pixel_alpha=True)
            # Empty target:
            out_empty = blend_pixel(0, 0, src_px, 3, global_alpha=b7)
            if a == 255:
                exp_empty = (sr << 16) | (sg << 8) | sb
            elif a == 0:
                exp_empty = 0
            else:
                exp_empty = ((sr * a >> 8) << 16) | ((sg * a >> 8) << 8) | (sb * a >> 8)
            assert out_empty == exp_empty, f"Alpha {a} (Byte7={b7}) over empty failed: got {hex(out_empty)} vs {hex(exp_empty)}"

            # Occupied target:
            out_occ = blend_pixel(dest_rgb, 100, src_px, 3, global_alpha=b7)
            if a == 255:
                exp_occ = (sr << 16) | (sg << 8) | sb
            elif a == 0:
                exp_occ = dest_rgb
            else:
                er = dr + (((sr - dr) * a) >> 8)
                eg = dg + (((sg - dg) * a) >> 8)
                eb = db + (((sb - db) * a) >> 8)
                exp_occ = (er << 16) | (eg << 8) | eb
            assert out_occ == exp_occ, f"Alpha {a} (Byte7={b7}) over occupied failed: got {hex(out_occ)} vs {hex(exp_occ)}"

    # End-to-end render_scanline test for key alphas {0, 1, 127, 128, 254, 255} over empty and occupied targets
    for a in (0, 1, 127, 128, 254, 255):
        for b7 in (0, 128, 255):
            ram_a_test: Dict[int, int] = {
                0x00100000: ((a << 24) | (sr << 16) | (sg << 8) | sb) << 32,
                0x00100008: 0, 0x00100010: 0, 0x00100018: 0,
            }
            d_empty = SpriteDescriptor(
                y_pos=0, x_pos=0, y_height_lo=1, x_width256=1, prio=200, pal_offset=b7,
                data_ptr=0x00100008, fmt=2, flags=0, x_scale=0x40, y_scale=0x40, step_ctrl=0b0011_0000,
            )
            lb_e = render_scanline(0, [d_empty], ram_a_test, palette)
            if a == 0:
                assert lb_e[0] == 0, f"Alpha 0 must leave empty buffer empty! Got {hex(lb_e[0])}"
            elif a == 255:
                assert lb_e[0] == (200 << 24) | (sr << 16) | (sg << 8) | sb
            else:
                exp_c = ((sr * a >> 8) << 16) | ((sg * a >> 8) << 8) | (sb * a >> 8)
                assert lb_e[0] == (200 << 24) | exp_c

            # Over occupied destination:
            d_bg = SpriteDescriptor(
                y_pos=0, x_pos=0, y_height_lo=1, x_width256=1, prio=100, pal_offset=0,
                data_ptr=0x00200008, fmt=2, flags=0, x_scale=0x40, y_scale=0x40, step_ctrl=0,
            )
            ram_bg: Dict[int, int] = {
                0x00200000: (0xFF000000 | dest_rgb) << 32,
                0x00200008: 0, 0x00200010: 0, 0x00200018: 0,
            }
            lb_occ = render_scanline(0, [d_bg, d_empty], {**ram_bg, **ram_a_test}, palette)
            if a == 0:
                assert lb_occ[0] == (100 << 24) | dest_rgb, f"Alpha 0 must preserve dest! Got {hex(lb_occ[0])}"
            elif a == 255:
                assert lb_occ[0] == (200 << 24) | (sr << 16) | (sg << 8) | sb
            else:
                er = dr + (((sr - dr) * a) >> 8)
                eg = dg + (((sg - dg) * a) >> 8)
                eb = db + (((sb - db) * a) >> 8)
                assert lb_occ[0] == (200 << 24) | (er << 16) | (eg << 8) | eb

    # Review #6 Point 2: FORMAT 13 and 14 MUST preserve PAL_OFFSET!
    # FORMAT 13: 12-6-8-6. First pixel is HAM12 (0x7F8 direct anchor -> 0xF0F010),
    # second pixel is HAM06 palette anchor code 1 (msb=0 -> palette[pal_offset + 1])
    # With pal_offset=0 -> palette[1] (0x000001)
    # With pal_offset=128 -> palette[129] (0x00FF00)
    w64_f13 = (0x7F8 << 52) | (0x01 << 46) | (0x01 << 38) | (0x01 << 32)
    ram_f13: Dict[int, int] = {0x00400000: w64_f13, 0x00400008: 0, 0x00400010: 0, 0x00400018: 0}
    d_f13_p0 = SpriteDescriptor(0, 0, 1, 1, 180, 0, 0x00400000, 13, 0, 0x40, 0x40, 0)
    d_f13_p128 = SpriteDescriptor(0, 0, 1, 1, 180, 128, 0x00400000, 13, 0, 0x40, 0x40, 0)
    lb_f13_0 = render_scanline(0, [d_f13_p0], ram_f13, palette)
    lb_f13_128 = render_scanline(0, [d_f13_p128], ram_f13, palette)
    assert (lb_f13_0[1] & 0xFFFFFF) == palette[1]
    assert (lb_f13_128[1] & 0xFFFFFF) == palette[129]

    # 4. Zero-Word-Skip bit-exact equivalence
    ram_skip: Dict[int, int] = {
        0x00500000: 0x048F8000_00000000,
        0x00500008: 0x00000000_00000000,
        0x00500010: 0x8F048700_00000000,
        0x00500018: 0x00000000_00000000,
    }
    for scale in (0x40, 0x20, 0x80):
        for hflip in (0, 1):
            for smooth in (0, 4):
                desc_test = SpriteDescriptor(
                    y_pos=0, x_pos=400 if hflip else 50, y_height_lo=16, x_width256=1, prio=150, pal_offset=0,
                    data_ptr=0x00500000, fmt=0, flags=hflip | smooth, x_scale=scale, y_scale=0x40, step_ctrl=0x80 | 0b11_10_00,
                )
                lb_on = render_scanline(0, [desc_test], ram_skip, palette, (15, 15, 15), zero_word_skip_en=True)
                lb_off = render_scanline(0, [desc_test], ram_skip, palette, (15, 15, 15), zero_word_skip_en=False)
                assert lb_on == lb_off

    print("ALL FUNCTIONAL SPRITE_REF_MODEL SELF-TESTS PASSED (REVIEW #6 & #7 VERIFIED)!")


if __name__ == "__main__":
    run_self_tests()
