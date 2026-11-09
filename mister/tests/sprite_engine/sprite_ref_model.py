"""
NanoMig / Minimig-AGA 32/64-Bit HAM, ARGB, HighColor & CLUT Sprite Engine
Deterministic Golden Reference Model & Self-Test Suite
Architecture Spec Revision 4 (DESC_REV = 4)

Key Revision 4 Architectural Rules:
  - 100% 68000 Word- and Long-Aligned 16-Byte Sprite Descriptor:
      +$00: int16_t  y_pos      (Sort primarily Y and secondarily X)
      +$02: int16_t  x_pos
      +$04: uint32_t data_ptr   (Clean 32-bit Fast-RAM pointer, 32-byte aligned)
      +$08: uint16_t height     (1..2047 scanlines, 0 = Sentinel / list end!)
      +$0A: uint8_t  width      (1..64 256-bit bursts)
      +$0B: uint8_t  format     (0..16: CLUT 1..8, HAM, RGB16, ARGB32)
      +$0C: uint8_t  prio       (1..255; 0 = inactive/skip)
      +$0D: uint8_t  alpha      (Global Sprite Alpha or PAL_OFFSET)
      +$0E: uint16_t ctrl       (Scale, Flip, Smooth, Blend-Mode, Prio-GE)
  - CLUT Modes 1..8 with 256-Bit Burst Container:
      FMT 0 (CLUT01): 256 px / burst (0 pad)
      FMT 1 (CLUT02): 128 px / burst (0 pad)
      FMT 2 (CLUT03): 85 px / burst (1 pad bit @ bit 0)
      FMT 3 (CLUT04): 64 px / burst (0 pad)
      FMT 4 (CLUT05): 51 px / burst (1 pad bit @ bit 0)
      FMT 5 (CLUT06): 42 px / burst (4 pad bits @ bits [3:0])
      FMT 6 (CLUT07): 36 px / burst (4 pad bits @ bits [3:0])
      FMT 7 (CLUT08): 32 px / burst (0 pad)
  - HAM Step Size fixed in hardware to 4 (<< 2). Register $DFF58C removed.
  - Power-of-2 Scaling in ctrl [2:0] (X_SCALE) and [5:3] (Y_SCALE):
      0=1x, 1=2x, 2=4x, 3=1/2, 4=1/4.
  - Formats > 16 are treated strictly as No-Op.
"""

from __future__ import annotations
import struct
from dataclasses import dataclass
from typing import Dict, List, Tuple, Optional, Any

DESC_REV = 4

# Fixed HAM step size in Hardware
FIXED_HAM_STEP = 4

def two_delta(bits2: int) -> int:
    return (-2, -1, 1, 2)[bits2 & 0x3]

# 256-bit burst bit-width sequences for all 17 formats (0..16)
FORMAT_SEQS_256: Dict[int, Tuple[int, ...]] = {
    0:  (1,) * 256,                 # CLUT 1-bit: 256 px (0 pad)
    1:  (2,) * 128,                 # CLUT 2-bit: 128 px (0 pad)
    2:  (3,) * 85,                  # CLUT 3-bit: 85 px (1 pad @ bit 0)
    3:  (4,) * 64,                  # CLUT 4-bit: 64 px (0 pad)
    4:  (5,) * 51,                  # CLUT 5-bit: 51 px (1 pad @ bit 0)
    5:  (6,) * 42,                  # CLUT 6-bit: 42 px (4 pad @ bits [3:0])
    6:  (7,) * 36,                  # CLUT 7-bit: 36 px (4 pad @ bits [3:0])
    7:  (8,) * 32,                  # CLUT 8-bit: 32 px (0 pad)
    8:  (4,) * 64,                  # HAM04: 64 px
    9:  (6, 3, 4, 3) * 16,          # HAM06 Standard: 64 px
    10: (8,) * 32,                  # HAM08: 32 px
    11: (12, 6, 8, 6) * 8,          # HAM12 12_686: 32 px
    12: (12, 5, 5, 5, 5) * 8,       # HAM12 12_5555: 40 px
    13: (16, 12, 12, 12, 12) * 4,   # HAM16 12X4: 20 px
    14: (16,) * 16,                 # HAM16 Direct: 16 px
    15: (16,) * 16,                 # RGB16 Direct (RGB565): 16 px
    16: (32,) * 8,                  # ARGB32 TrueColor: 8 px
}

# 64-bit word sequences for 64-bit memory word access
FORMAT_SEQS_64: Dict[int, Tuple[int, ...]] = {
    0:  (1,) * 64,
    1:  (2,) * 32,
    2:  (3,) * 21,
    3:  (4,) * 16,
    4:  (5,) * 12,
    5:  (6,) * 10,
    6:  (7,) * 9,
    7:  (8,) * 8,
    8:  (4,) * 16,
    9:  (6, 3, 4, 3) * 4,
    10: (8,) * 8,
    11: (12, 6, 8, 6) * 2,
    12: (12, 5, 5, 5, 5) * 2,
    13: (16, 12, 12, 12, 12),
    14: (16,) * 4,
    15: (16,) * 4,
    16: (32,) * 2,
}

FORMAT_PAD_BITS: Dict[int, int] = {
    0: 0, 1: 0, 2: 1, 3: 0, 4: 1, 5: 4, 6: 4, 7: 0,
    8: 0, 9: 0, 10: 0, 11: 0, 12: 0, 13: 0, 14: 0, 15: 0, 16: 0
}


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
    y_pos: int          # int16 (-4096..+4095)
    x_pos: int          # int16 (-4096..+4095)
    data_ptr: int       # uint32 (clean 32-bit Fast-RAM pointer, 32-byte aligned)
    height: int         # uint16 (1..2047, 0 = Sentinel / list end!)
    width: int          # uint8 (1..64 bursts)
    format: int         # uint8 (0..16)
    prio: int           # uint8 (1..255; 0 = inactive)
    alpha: int          # uint8 (0..255: global alpha or pal_offset)
    ctrl: int           # uint16 (scale, flags, blend)

    @property
    def y_height11(self) -> int:
        return self.height & 0x7FF

    @property
    def x_width256(self) -> int:
        return self.width

    @property
    def fmt5(self) -> int:
        return self.format & 0x1F

    @property
    def base_addr(self) -> int:
        return self.data_ptr & 0xFFFFFFE0

    @property
    def pal_offset(self) -> int:
        return self.alpha & 0xFF

    @property
    def x_scale_code(self) -> int:
        return self.ctrl & 0x7

    @property
    def y_scale_code(self) -> int:
        return (self.ctrl >> 3) & 0x7

    @property
    def h_flip(self) -> bool:
        return bool(self.ctrl & (1 << 6))

    @property
    def v_flip(self) -> bool:
        return bool(self.ctrl & (1 << 7))

    @property
    def smooth_x(self) -> bool:
        return bool(self.ctrl & (1 << 8))

    @property
    def blend_mode(self) -> int:
        return (self.ctrl >> 9) & 0x3

    @property
    def prio_ge(self) -> bool:
        return bool(self.ctrl & (1 << 11))

    @property
    def spr_alpha(self) -> int:
        # ARGB32 (FMT 16) uses per-pixel alpha from code[31:24]
        # FMT 13..15 use self.alpha
        # FMT 0..12 use self.alpha as PAL_OFFSET; if blended, alpha=255
        if self.format in (13, 14, 15):
            return self.alpha & 0xFF
        return 255


def pack_descriptor_raw(desc: SpriteDescriptor) -> bytes:
    """
    Packs a SpriteDescriptor into exact 16 bytes Big-Endian (Motorola format, DESC_REV=4).
    """
    return struct.pack(
        '>hhIHBBBBH',
        desc.y_pos,
        desc.x_pos,
        desc.data_ptr & 0xFFFFFFFF,
        desc.height & 0xFFFF,
        desc.width & 0xFF,
        desc.format & 0xFF,
        desc.prio & 0xFF,
        desc.alpha & 0xFF,
        desc.ctrl & 0xFFFF,
    )


def unpack_descriptor_raw(data16: bytes) -> SpriteDescriptor:
    """
    Unpacks a 16-byte raw Big-Endian chunk into a SpriteDescriptor (DESC_REV=4).
    """
    assert len(data16) == 16, f"Expected 16 bytes, got {len(data16)}"
    (
        y_pos,
        x_pos,
        data_ptr,
        height,
        width,
        format_id,
        prio,
        alpha,
        ctrl,
    ) = struct.unpack('>hhIHBBBBH', data16)

    return SpriteDescriptor(
        y_pos=y_pos,
        x_pos=x_pos,
        data_ptr=data_ptr & 0xFFFFFFE0,
        height=height,
        width=width,
        format=format_id,
        prio=prio,
        alpha=alpha,
        ctrl=ctrl,
    )


def unpack_256bit_burst(w64_list: List[int], fmt: int) -> List[Tuple[int, int]]:
    """
    Unpacks a 256-bit burst container (4x 64-bit Big-Endian words) into raw pixel codes.
    Handles padding bits at the end of the 256-bit container.
    Returns: List of (raw_code, bit_width)
    """
    assert len(w64_list) == 4
    if fmt not in FORMAT_SEQS_256:
        return []

    seq = FORMAT_SEQS_256[fmt]
    pad_bits = FORMAT_PAD_BITS.get(fmt, 0)

    # Reassemble full 256-bit integer from 4x 64-bit words (big-endian order)
    full_val = (w64_list[0] << 192) | (w64_list[1] << 128) | (w64_list[2] << 64) | w64_list[3]

    # Shift past end-padding bits
    full_val >>= pad_bits

    # Extract pixels from right to left, then reverse
    pixels = []
    for bw in reversed(seq):
        mask = (1 << bw) - 1
        code = full_val & mask
        pixels.append((code, bw))
        full_val >>= bw

    pixels.reverse()
    return pixels


def precompute_ham_stage1(
    raw_code: int,
    bw: int,
    fmt5: int,
    pal_offset: int,
) -> Tuple[bool, bool, int, int, int, int, int, int, bool]:
    """
    Stage 1 decoder for CLUT, HAM, RGB16 and ARGB32 formats.
    Returns:
      (anchor, direct_anchor, direct_rgb, pal_idx, dr, dg, db, a, has_ppa)
    """
    if raw_code == 0:
        return (False, False, 0, 0, 0, 0, 0, 0, False)

    # 1. FMT 0..7: Direct CLUT 1..8 Bit
    if fmt5 <= 7:
        pal_idx = (pal_offset + raw_code) & 0xFF
        return (True, False, 0, pal_idx, 0, 0, 0, 255, False)

    # 2. FMT 16: Direct ARGB8888 TrueColor
    if fmt5 == 16:
        a = (raw_code >> 24) & 0xFF
        r = (raw_code >> 16) & 0xFF
        g = (raw_code >> 8) & 0xFF
        b = raw_code & 0xFF
        return (True, True, (r << 16) | (g << 8) | b, 0, 0, 0, 0, a, True)

    # 3. FMT 15: Direct RGB16 HighColor (Pure RGB565)
    if fmt5 == 15:
        r = ((raw_code >> 11) & 0x1F) << 3
        g = ((raw_code >> 5) & 0x3F) << 2
        b = (raw_code & 0x1F) << 3
        return (True, True, (r << 16) | (g << 8) | b, 0, 0, 0, 0, 255, False)

    # 4. FMT 13 / 14: HAM16
    if bw == 16:
        msb = bool(raw_code & 0x8000)
        if not msb:
            # 15-bit RGB555 direct anchor
            r = ((raw_code >> 10) & 0x1F) << 3
            g = ((raw_code >> 5) & 0x1F) << 3
            b = (raw_code & 0x1F) << 3
            return (True, True, (r << 16) | (g << 8) | b, 0, 0, 0, 0, 255, False)
        else:
            # HAM16 Delta: step = 4
            turbo = bool(raw_code & 0x4000)
            mult = 16 if turbo else 4
            dr_s4 = (raw_code >> 10) & 0xF
            if dr_s4 >= 8:
                dr_s4 -= 16
            dg_s5 = (raw_code >> 5) & 0x1F
            if dg_s5 >= 16:
                dg_s5 -= 32
            db_s5 = raw_code & 0x1F
            if db_s5 >= 16:
                db_s5 -= 32
            return (False, False, 0, 0, dr_s4 * mult, dg_s5 * mult, db_s5 * mult, 255, False)

    # 5. FMT 11 / 12: HAM12 (Anchor + HAM)
    if bw == 12:
        msb = bool(raw_code & 0x800)
        if not msb:
            b10 = (raw_code >> 10) & 0x1
            r3 = (raw_code >> 7) & 0x7
            g4 = (raw_code >> 3) & 0xF
            b3 = raw_code & 0x7
            r = ((r3 << 1) | b10) << 4
            g = g4 << 4
            b = ((b3 << 1) | b10) << 4
            return (True, True, (r << 16) | (g << 8) | b, 0, 0, 0, 0, 255, False)
        else:
            turbo = bool(raw_code & 0x400)
            mult = 16 if turbo else 4
            dr_s3 = (raw_code >> 7) & 0x7
            if dr_s3 >= 4:
                dr_s3 -= 8
            dg_s4 = (raw_code >> 3) & 0xF
            if dg_s4 >= 8:
                dg_s4 -= 16
            db_s3 = raw_code & 0x7
            if db_s3 >= 4:
                db_s3 -= 8
            return (False, False, 0, 0, dr_s3 * mult, dg_s4 * mult, db_s3 * mult, 255, False)

    # 6. Standard HAM (bw <= 8)
    msb = bool(raw_code & (1 << (bw - 1)))
    if not msb:
        pal_idx = (pal_offset + raw_code) & 0xFF
        return (True, False, 0, pal_idx, 0, 0, 0, 255, False)
    else:
        turbo = False
        dr = dg = db = 0
        if bw == 3:
            dr = 2 if (raw_code & 0x2) else -2
            dg = 2 if (raw_code & 0x1) else -2
            db = dr
        elif bw == 4:
            dr = 2 if (raw_code & 0x4) else -2
            dg = 2 if (raw_code & 0x2) else -2
            db = 2 if (raw_code & 0x1) else -2
        elif bw == 5:
            turbo = bool(raw_code & 0x8)
            dr = 1 if (raw_code & 0x4) else -1
            dg = 1 if (raw_code & 0x2) else -1
            db = 1 if (raw_code & 0x1) else -1
        elif bw == 6:
            turbo = bool(raw_code & 0x10)
            dr = 1 if (raw_code & 0x8) else -1
            dg = two_delta((raw_code >> 1) & 0x3)
            db = 1 if (raw_code & 0x1) else -1
        elif bw == 8:
            turbo = bool(raw_code & 0x40)
            dr = two_delta((raw_code >> 4) & 0x3)
            dg = two_delta((raw_code >> 2) & 0x3)
            db = two_delta(raw_code & 0x3)

        mult = (FIXED_HAM_STEP << 2) if turbo else FIXED_HAM_STEP
        def calc_d(level: int) -> int:
            if level == -2:
                return -(mult << 1)
            elif level == -1:
                return -mult
            elif level == 1:
                return mult
            elif level == 2:
                return mult << 1
            return 0

        return (False, False, 0, 0, calc_d(dr), calc_d(dg), calc_d(db), 255, False)


def clamp_u8(val: int) -> int:
    if val < 0:
        return 0
    if val > 255:
        return 255
    return val


def blend_pixel(dest_rgb24: int, dest_prio: int, src_px: DecodedPixel, blend_mode: int, global_alpha: int = 255) -> int:
    if not src_px.opaque:
        return dest_rgb24

    eff_alpha = src_px.alpha if src_px.has_per_pixel_alpha else global_alpha

    sr = src_px.r
    sg = src_px.g
    sb = src_px.b

    dr = (dest_rgb24 >> 16) & 0xFF
    dg = (dest_rgb24 >> 8) & 0xFF
    db = dest_rgb24 & 0xFF

    if blend_mode == 0:  # Opaque
        return (sr << 16) | (sg << 8) | sb

    if blend_mode == 1:  # Additive
        or_val = min(255, sr + dr)
        og_val = min(255, sg + dg)
        ob_val = min(255, sb + db)
        return (or_val << 16) | (og_val << 8) | ob_val

    if blend_mode == 2:  # 50/50 Translucent
        if dest_prio == 0:
            return (sr << 16) | (sg << 8) | sb
        return (((sr + dr) >> 1) << 16) | (((sg + dg) >> 1) << 8) | ((sb + db) >> 1)

    if blend_mode == 3:  # 8-bit Alpha
        if eff_alpha == 0:
            return dest_rgb24
        if eff_alpha == 255:
            return (sr << 16) | (sg << 8) | sb
        if dest_prio == 0:
            er = (sr * eff_alpha) >> 8
            eg = (sg * eff_alpha) >> 8
            eb = (sb * eff_alpha) >> 8
            return (er << 16) | (eg << 8) | eb
        er = dr + (((sr - dr) * eff_alpha) >> 8)
        eg = dg + (((sg - dg) * eff_alpha) >> 8)
        eb = db + (((sb - db) * eff_alpha) >> 8)
        return (er << 16) | (eg << 8) | eb

    return (sr << 16) | (sg << 8) | sb


def denise_mix_pixel(sprite_entry: int, amiga_rgb: int, amiga_prio: int = 0) -> int:
    """
    Mixes a 32-bit linebuffer entry with Amiga native playfield pixel.
    [31:24] prio, [23:0] rgb24.
    """
    prio = (sprite_entry >> 24) & 0xFF
    rgb = sprite_entry & 0xFFFFFF
    if prio > amiga_prio and prio > 0:
        return rgb
    return amiga_rgb


def render_scanline(
    scanline_y: int,
    descriptors: List[SpriteDescriptor],
    ram_words64: Dict[int, int],
    palette256: List[int],
    global_steps: Tuple[int, int, int] = (4, 4, 4),
    clip_xmax: int = 2048,
    zero_word_skip_en: bool = True,
) -> List[int]:
    """
    Renders one scanline with all descriptors according to Revision 4 rules.
    Linebuffer is 2048 entries of uint32: [31:24] prio, [23:0] rgb24.
    """
    linebuffer = [0] * clip_xmax

    for desc in descriptors:
        # Sentinel height == 0 terminates list processing immediately!
        if desc.height == 0:
            break
        # Format > 16 is reserved / No-Op; Prio 0 is inactive sprite
        if desc.format > 16 or desc.prio == 0:
            continue

        dy = scanline_y - desc.y_pos
        if dy < 0:
            continue

        # Power-of-2 Y-Scale
        y_sc = desc.y_scale_code
        if y_sc == 0:
            src_y = dy
        elif y_sc == 1:
            src_y = dy >> 1  # 2x Zoom
        elif y_sc == 2:
            src_y = dy >> 2  # 4x Zoom
        elif y_sc == 3:
            src_y = dy << 1  # 1/2 Shrink
        elif y_sc == 4:
            src_y = dy << 2  # 1/4 Shrink
        else:
            src_y = dy

        if src_y >= desc.height:
            continue

        rel_y = (desc.height - 1 - src_y) if desc.v_flip else src_y
        line_addr = desc.base_addr + ((rel_y * desc.width) << 5)

        # Unpack bursts
        decoded_line: List[DecodedPixel] = []
        acc_r = acc_g = acc_b = 0

        for b_idx in range(desc.width):
            burst_addr = line_addr + (b_idx << 5)
            w64_list = [
                ram_words64.get(burst_addr, 0),
                ram_words64.get(burst_addr + 8, 0),
                ram_words64.get(burst_addr + 16, 0),
                ram_words64.get(burst_addr + 24, 0),
            ]
            for raw_code, bw in unpack_256bit_burst(w64_list, desc.format):
                anchor, direct_anchor, direct_rgb, pal_idx, dr, dg, db, a, has_ppa = precompute_ham_stage1(
                    raw_code, bw, desc.format, desc.pal_offset
                )
                if raw_code == 0:
                    acc_r = acc_g = acc_b = 0
                    decoded_line.append(DecodedPixel(False, 0, 0, 0, 0, False))
                elif anchor:
                    if direct_anchor:
                        acc_r = (direct_rgb >> 16) & 0xFF
                        acc_g = (direct_rgb >> 8) & 0xFF
                        acc_b = direct_rgb & 0xFF
                    else:
                        pal_rgb = palette256[pal_idx] & 0xFFFFFF
                        acc_r = (pal_rgb >> 16) & 0xFF
                        acc_g = (pal_rgb >> 8) & 0xFF
                        acc_b = pal_rgb & 0xFF
                    decoded_line.append(DecodedPixel(True, acc_r, acc_g, acc_b, a, has_ppa))
                else:
                    acc_r = clamp_u8(acc_r + dr)
                    acc_g = clamp_u8(acc_g + dg)
                    acc_b = clamp_u8(acc_b + db)
                    decoded_line.append(DecodedPixel(True, acc_r, acc_g, acc_b, a, has_ppa))

        if desc.h_flip:
            decoded_line.reverse()

        # Scale X (Power-of-2 with shrink and smooth_x)
        x_sc = desc.x_scale_code
        smooth = desc.smooth_x
        scaled_pixels: List[DecodedPixel] = []

        if x_sc == 0:  # 1x
            scaled_pixels = decoded_line
        elif x_sc == 1:  # 2x Zoom
            for i in range(len(decoded_line)):
                p0 = decoded_line[i]
                scaled_pixels.append(p0)
                if smooth and (i + 1 < len(decoded_line)):
                    p1 = decoded_line[i + 1]
                    if p0.opaque and p1.opaque:
                        mr = (p0.r + p1.r) >> 1
                        mg = (p0.g + p1.g) >> 1
                        mb = (p0.b + p1.b) >> 1
                        ma = (p0.alpha + p1.alpha) >> 1
                        scaled_pixels.append(DecodedPixel(True, mr, mg, mb, ma, p0.has_per_pixel_alpha or p1.has_per_pixel_alpha))
                    elif p0.opaque:
                        scaled_pixels.append(p0)
                    elif p1.opaque:
                        scaled_pixels.append(p1)
                    else:
                        scaled_pixels.append(DecodedPixel(False, 0, 0, 0, 0, False))
                else:
                    scaled_pixels.append(p0)
        elif x_sc == 2:  # 4x Zoom
            for i in range(len(decoded_line)):
                p0 = decoded_line[i]
                scaled_pixels.append(p0)
                if smooth and (i + 1 < len(decoded_line)):
                    p1 = decoded_line[i + 1]
                    if p0.opaque and p1.opaque:
                        mr = (p0.r + p1.r) >> 1
                        mg = (p0.g + p1.g) >> 1
                        mb = (p0.b + p1.b) >> 1
                        ma = (p0.alpha + p1.alpha) >> 1
                        has_ppa = p0.has_per_pixel_alpha or p1.has_per_pixel_alpha
                        # Subpixel 1: 1/4 towards p1
                        r1 = (mr + p0.r) >> 1
                        g1 = (mg + p0.g) >> 1
                        b1 = (mb + p0.b) >> 1
                        a1 = (ma + p0.alpha) >> 1
                        scaled_pixels.append(DecodedPixel(True, r1, g1, b1, a1, has_ppa))
                        # Subpixel 2: 1/2 towards p1
                        scaled_pixels.append(DecodedPixel(True, mr, mg, mb, ma, has_ppa))
                        # Subpixel 3: 3/4 towards p1
                        r3 = (mr + p1.r) >> 1
                        g3 = (mg + p1.g) >> 1
                        b3 = (mb + p1.b) >> 1
                        a3 = (ma + p1.alpha) >> 1
                        scaled_pixels.append(DecodedPixel(True, r3, g3, b3, a3, has_ppa))
                    elif p0.opaque:
                        scaled_pixels.extend([p0, p0, p0])
                    elif p1.opaque:
                        scaled_pixels.extend([p1, p1, p1])
                    else:
                        scaled_pixels.extend([DecodedPixel(False, 0, 0, 0, 0, False)] * 3)
                else:
                    scaled_pixels.extend([p0, p0, p0])
        elif x_sc == 3:  # 1/2 Half Shrink
            for i in range(0, len(decoded_line), 2):
                p0 = decoded_line[i]
                if smooth and (i + 1 < len(decoded_line)):
                    p1 = decoded_line[i + 1]
                    if p0.opaque and p1.opaque:
                        mr = (p0.r + p1.r) >> 1
                        mg = (p0.g + p1.g) >> 1
                        mb = (p0.b + p1.b) >> 1
                        ma = (p0.alpha + p1.alpha) >> 1
                        scaled_pixels.append(DecodedPixel(True, mr, mg, mb, ma, p0.has_per_pixel_alpha or p1.has_per_pixel_alpha))
                    elif p0.opaque:
                        scaled_pixels.append(p0)
                    elif p1.opaque:
                        scaled_pixels.append(p1)
                    else:
                        scaled_pixels.append(DecodedPixel(False, 0, 0, 0, 0, False))
                else:
                    scaled_pixels.append(p0)
        elif x_sc == 4:  # 1/4 Quarter Shrink
            for i in range(0, len(decoded_line), 4):
                chunk = [decoded_line[j] for j in range(i, min(i + 4, len(decoded_line))) if decoded_line[j].opaque]
                if smooth and chunk:
                    mr = sum(p.r for p in chunk) // len(chunk)
                    mg = sum(p.g for p in chunk) // len(chunk)
                    mb = sum(p.b for p in chunk) // len(chunk)
                    ma = sum(p.alpha for p in chunk) // len(chunk)
                    has_ppa = any(p.has_per_pixel_alpha for p in chunk)
                    scaled_pixels.append(DecodedPixel(True, mr, mg, mb, ma, has_ppa))
                elif chunk:
                    scaled_pixels.append(decoded_line[i])
                else:
                    scaled_pixels.append(DecodedPixel(False, 0, 0, 0, 0, False))
        else:
            scaled_pixels = decoded_line

        # Write to Linebuffer with priority & alpha write-enable guard
        dst_x = desc.x_pos
        blend_mode = desc.blend_mode

        for px in scaled_pixels:
            if 0 <= dst_x < clip_xmax and px.opaque:
                eff_a = px.alpha if (blend_mode == 3 and px.has_per_pixel_alpha) else desc.spr_alpha
                # Alpha=0 in blend mode 3 means completely transparent: WE remains OFF!
                if not (blend_mode == 3 and eff_a == 0):
                    curr_entry = linebuffer[dst_x]
                    curr_prio = (curr_entry >> 24) & 0xFF
                    curr_rgb = curr_entry & 0xFFFFFF

                    win = (desc.prio >= curr_prio) if desc.prio_ge else (desc.prio > curr_prio)
                    if win:
                        final_rgb = blend_pixel(curr_rgb, curr_prio, px, blend_mode, desc.spr_alpha)
                        linebuffer[dst_x] = (desc.prio << 24) | final_rgb
            dst_x += 1

    return linebuffer


def run_self_tests() -> None:
    print("=" * 70)
    print("NanoMig Sprite Engine Revision 4 Self-Test Suite")
    print("=" * 70)

    # 1. Test Descriptor Pack/Unpack Roundtrip
    d_orig = SpriteDescriptor(
        y_pos=-100, x_pos=250, data_ptr=0x00100000, height=120, width=4,
        format=16, prio=200, alpha=128, ctrl=0b0000_0110_0000_1001
    )
    raw = pack_descriptor_raw(d_orig)
    assert len(raw) == 16, f"Expected 16 bytes, got {len(raw)}"
    d_un = unpack_descriptor_raw(raw)
    assert d_un.y_pos == -100 and d_un.x_pos == 250
    assert d_un.data_ptr == 0x00100000
    assert d_un.height == 120 and d_un.width == 4
    assert d_un.format == 16 and d_un.prio == 200
    assert d_un.alpha == 128 and d_un.ctrl == 0b0000_0110_0000_1001
    print("[PASS] 16-Byte Descriptor Pack/Unpack Roundtrip (DESC_REV=4)")

    # 2. Test CLUT 1..8 Bit Container & Padding
    for fmt in range(8):
        seq = FORMAT_SEQS_256[fmt]
        pad = FORMAT_PAD_BITS[fmt]
        total_bits = sum(seq) + pad
        assert total_bits == 256, f"FMT {fmt}: total bits {total_bits} != 256"
    print("[PASS] CLUT 1..8 256-Bit Burst Container & End-Padding verified")

    # 3. 1536-Matrix Alpha Blending Test
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
            assert out_empty == exp_empty

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
            assert out_occ == exp_occ
    print("[PASS] 1536-Case Alpha Blending Matrix verified")

    # 4. Render scanline with CLUT 8-bit, 4-bit, and ARGB32
    palette = [0] * 256
    palette[1] = 0xFF0000
    palette[2] = 0x00FF00
    palette[3] = 0x0000FF

    # 1 burst of CLUT08 (Format 7): 32 pixels
    w64_clut = (0x0102030102030102 << 0)
    ram_test = {
        0x00200000: w64_clut, 0x00200008: w64_clut,
        0x00200010: w64_clut, 0x00200018: w64_clut,
    }
    d_clut = SpriteDescriptor(0, 0, 0x00200000, 1, 1, 7, 200, 0, 0)
    lb = render_scanline(0, [d_clut], ram_test, palette)
    assert (lb[0] & 0xFFFFFF) == palette[1]
    assert (lb[1] & 0xFFFFFF) == palette[2]
    assert (lb[2] & 0xFFFFFF) == palette[3]
    print("[PASS] CLUT 8-Bit Render Scanline verified")

    # 5. Review 10 Regression Verifications:
    # A) Sentinel height=0 terminates processing
    d_sentinel = SpriteDescriptor(0, 0, 0x00200000, 0, 1, 7, 200, 0, 0)
    lb_sentinel = render_scanline(0, [d_sentinel, d_clut], ram_test, palette)
    assert sum(v != 0 for v in lb_sentinel) == 0, "Sentinel height=0 must halt processing!"

    # B) Alpha=0 with blend_mode=3 does NOT modify priority
    d_bg = SpriteDescriptor(0, 0, 0x00200000, 1, 1, 7, 100, 0, 0) # Prio 100
    d_fg = SpriteDescriptor(0, 0, 0x00300000, 1, 1, 16, 200, 255, (3 << 9)) # ARGB32, blend=3, prio=200
    w64_a0 = (0x00FF0000 << 32) | 0x00FF0000 # Alpha = 0
    ram_alpha0 = {
        0x00200000: w64_clut, 0x00200008: w64_clut, 0x00200010: w64_clut, 0x00200018: w64_clut,
        0x00300000: w64_a0, 0x00300008: w64_a0, 0x00300010: w64_a0, 0x00300018: w64_a0,
    }
    lb_a0 = render_scanline(0, [d_bg, d_fg], ram_alpha0, palette)
    assert ((lb_a0[0] >> 24) & 0xFF) == 100, f"Alpha 0 must preserve prio 100, got {(lb_a0[0] >> 24) & 0xFF}"

    # C) HAM16 red delta for 0xA000
    _, _, _, _, dr, _, _, _, _ = precompute_ham_stage1(0xA000, 16, 14, 0)
    assert dr == -32, f"Expected dr=-32 for HAM16 0xA000, got {dr}"

    # D) RGB565 for 0x8000
    _, _, rgb565, _, _, _, _, _, _ = precompute_ham_stage1(0x8000, 16, 15, 0)
    assert rgb565 == 0x800000, f"Expected 0x800000 for RGB565 0x8000, got {hex(rgb565)}"

    # E) HAM04 code 8 delta
    _, _, _, _, dr, dg, db, _, _ = precompute_ham_stage1(8, 4, 8, 0)
    assert (dr, dg, db) == (-8, -8, -8), f"Expected (-8,-8,-8) for HAM04 code 8, got {(dr, dg, db)}"

    print("[PASS] All Review 10 Regression Verifications satisfied!")

    print("=" * 70)
    print("ALL REVISION 4 MODEL SELF-TESTS PASSED!")
    print("=" * 70)


if __name__ == "__main__":
    run_self_tests()
