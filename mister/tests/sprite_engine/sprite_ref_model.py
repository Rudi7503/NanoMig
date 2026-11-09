"""
NanoMig / Minimig-AGA 32/64-Bit HAM, ARGB, HighColor & CLUT Sprite Engine
Deterministic Golden Reference Model & Self-Test Suite
Architecture Spec Revision 4 (DESC_REV = 4)

Key Revision 4 Architectural Rules:
  - 100% 68000 Word- and Long-Aligned 16-Byte Sprite Descriptor:
      +$00: int16_t  y_pos      (CMP.L (A0),(A1) sorts primarily Y and secondarily X!)
      +$02: int16_t  x_pos
      +$04: uint32_t data_ptr   (Clean 32-bit Fast-RAM pointer, no hidden bits!)
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
  - CLUT_MODE bit completely removed (determined by format).
"""

from __future__ import annotations
import struct
from dataclasses import dataclass
from typing import Dict, List, Tuple, Optional, Any

# Fixed HAM step size in Hardware
FIXED_HAM_STEP = 4

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
    15: (16,) * 16,                 # RGB16 Direct: 16 px
    16: (32,) * 8,                  # ARGB32 TrueColor: 8 px
}

# 64-bit word sequences for 64-bit memory word access
FORMAT_SEQS_64: Dict[int, Tuple[int, ...]] = {
    0:  (1,) * 64,
    1:  (2,) * 32,
    3:  (4,) * 16,
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
    2:  (6, 3, 4, 3) * 4,           # Legacy alias for HAM06
    18: (32,) * 2,                  # Legacy alias for ARGB32
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
        if self.fmt5 in (13, 14, 15):
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
    Unpacks 16 bytes Big-Endian into a SpriteDescriptor (DESC_REV=4).
    """
    y_pos, x_pos, data_ptr, height, width, format_id, prio, alpha, ctrl = struct.unpack(
        '>hhIHBBBBH', data16[:16]
    )
    return SpriteDescriptor(
        y_pos=y_pos,
        x_pos=x_pos,
        data_ptr=data_ptr,
        height=height,
        width=width,
        format=format_id,
        prio=prio,
        alpha=alpha,
        ctrl=ctrl,
    )


def unpack_256bit_burst(w64_list: List[int], fmt5: int) -> List[Tuple[int, int]]:
    """
    Unpacks 4x 64-bit words (256-bit DDR3 burst) from MSB to LSB.
    Any padding bits naturally remain at the lower end.
    """
    assert len(w64_list) == 4
    w256 = (w64_list[0] << 192) | (w64_list[1] << 128) | (w64_list[2] << 64) | w64_list[3]
    seq = FORMAT_SEQS_256.get(fmt5, ())
    out: List[Tuple[int, int]] = []
    shift = 256
    for bw in seq:
        shift -= bw
        code = (w256 >> shift) & ((1 << bw) - 1)
        out.append((code, bw))
    return out


def precompute_ham_stage1(
    raw_code: int,
    bw: int,
    fmt5: int,
    pal_offset: int,
) -> Tuple[bool, bool, int, int, int, int, int, int, bool]:
    """
    Precomputes anchor, direct colors, palette index and deltas with fixed step = 4.
    Returns:
      (anchor, direct_anchor, direct_rgb, pal_idx, delta_r, delta_g, delta_b, alpha, has_ppa)
    """
    if raw_code == 0:
        return (False, False, 0, 0, 0, 0, 0, 0, False)

    # 1. CLUT Modes 0..7
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

    # 3. FMT 15: Direct RGB16 HighColor (RGB565 / RGB555)
    if fmt5 == 15:
        if raw_code == 0x8000:
            # Opaque black semantic
            return (True, True, 0x000000, 0, 0, 0, 0, 255, False)
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
            dr_s3 = (raw_code >> 10) & 0x7
            if dr_s3 >= 4:
                dr_s3 -= 8
            dg_s5 = (raw_code >> 5) & 0x1F
            if dg_s5 >= 16:
                dg_s5 -= 32
            db_s5 = raw_code & 0x1F
            if db_s5 >= 16:
                db_s5 -= 32
            return (False, False, 0, 0, dr_s3 * mult, dg_s5 * mult, db_s5 * mult, 255, False)

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
        turbo = bool(raw_code & (1 << (bw - 2))) if bw >= 4 else False
        mult = 16 if turbo else 4
        chan = (raw_code >> (bw - 4)) & 0x3 if bw >= 5 else 0
        dr = dg = db = 0
        delta_val = mult
        if chan == 0:
            dr = delta_val
        elif chan == 1:
            dg = delta_val
        else:
            db = delta_val
        return (False, False, 0, 0, dr, dg, db, 255, False)


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

    sr, sg, sb = src_px.r, src_px.g, src_px.b
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


def render_scanline(
    scanline_y: int,
    descriptors: List[SpriteDescriptor],
    ram_words64: Dict[int, int],
    palette256: List[int],
    clip_xmax: int = 2048,
) -> List[int]:
    """
    Renders one scanline with all descriptors according to Revision 4 rules.
    Linebuffer is 2048 entries of uint32: [31:24] prio, [23:0] rgb24.
    """
    linebuffer = [0] * clip_xmax

    for desc in descriptors:
        if desc.height == 0 or desc.prio == 0:
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
            for raw_code, bw in unpack_256bit_burst(w64_list, desc.fmt5):
                anchor, direct_anchor, direct_rgb, pal_idx, dr, dg, db, a, has_ppa = precompute_ham_stage1(
                    raw_code, bw, desc.fmt5, desc.pal_offset
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

        # Write to Linebuffer with Power-of-2 X-Scale
        x_sc = desc.x_scale_code
        dst_x = desc.x_pos
        blend_mode = desc.blend_mode

        for px in decoded_line:
            # Repeat counts per pixel:
            repeats = 1
            if x_sc == 1:
                repeats = 2  # 2x Zoom
            elif x_sc == 2:
                repeats = 4  # 4x Zoom

            for _ in range(repeats):
                if 0 <= dst_x < clip_xmax and px.opaque:
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

    print("=" * 70)
    print("ALL REVISION 4 MODEL SELF-TESTS PASSED!")
    print("=" * 70)


if __name__ == "__main__":
    run_self_tests()
