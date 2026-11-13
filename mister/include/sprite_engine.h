/**
 * NanoMig / Minimig-AGA 32/64-Bit HAM, ARGB & HighColor Sprite Engine
 * C/C++ Hardware Header & API (AmigaOS / m68k-amigaos-gcc)
 * Architecture Spec Revision 4.1
 *
 * All registers and memory structures follow Motorola 68000 Big-Endian conventions.
 * 16-Byte Sprite Descriptors are naturally word- and long-aligned in Fast-RAM.
 * Native VBlank Pointer Latching: Pass NULL (0) to disable; write pointer to enable!
 */

#ifndef SPRITE_ENGINE_H
#define SPRITE_ENGINE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * 1. Hardware Custom Registers ($DFF580 .. $DFF59E)
 * ========================================================================= */
#define CUSTOM_BASE             0x00DFF000

#define REG_SPR_LIST_PTR        (*(volatile uint32_t*)(CUSTOM_BASE + 0x580)) /* W: Atomic 32-bit pointer commit; R: Active rendering ptr */
#define REG_SPR_LIST_PTR_H      (*(volatile uint16_t*)(CUSTOM_BASE + 0x580)) /* W: High-word staging register (no commit) */
#define REG_SPR_LIST_PTR_L      (*(volatile uint16_t*)(CUSTOM_BASE + 0x582)) /* W: Low-word + atomic shadow latch */
#define REG_SPR_CTRL            (*(volatile uint16_t*)(CUSTOM_BASE + 0x584)) /* Bit 2: Reset */
#define REG_SPR_PAL_ADDR        (*(volatile uint16_t*)(CUSTOM_BASE + 0x586))
#define REG_SPR_PAL_DATA_H      (*(volatile uint16_t*)(CUSTOM_BASE + 0x588)) /* Red [7:0] */
#define REG_SPR_PAL_DATA_L      (*(volatile uint16_t*)(CUSTOM_BASE + 0x58A)) /* Green [15:8], Blue [7:0] */
#define REG_SPR_MAX_BUSY        (*(volatile uint16_t*)(CUSTOM_BASE + 0x590)) /* Max line busy cycles */
#define REG_SPR_DMA_STALL       (*(volatile uint16_t*)(CUSTOM_BASE + 0x592)) /* DMA wait cycles */
#define REG_SPR_OVERRUN_CNT     (*(volatile uint16_t*)(CUSTOM_BASE + 0x594)) /* Line budget overruns */
#define REG_SPR_CUR_Y           (*(volatile uint16_t*)(CUSTOM_BASE + 0x596)) /* Current raster scanline */

/* Bits in SPR_CTRL ($DFF584) */
#define SPR_CTRL_RESET          (1u << 2)  /* Reset engine pipeline & FIFOs */

/* =========================================================================
 * 2. Supported Formats (FORMAT 0..16)
 * ========================================================================= */
#define SPR_FMT_CLUT01          0   /* 1-bit CLUT (2 colors, 256 px/burst, 0 pad) */
#define SPR_FMT_CLUT02          1   /* 2-bit CLUT (4 colors, 128 px/burst, 0 pad) */
#define SPR_FMT_CLUT03          2   /* 3-bit CLUT (8 colors, 85 px/burst, 1 pad @ bit 0) */
#define SPR_FMT_CLUT04          3   /* 4-bit CLUT (16 colors, 64 px/burst, 0 pad) */
#define SPR_FMT_CLUT05          4   /* 5-bit CLUT (32 colors, 51 px/burst, 1 pad @ bit 0) */
#define SPR_FMT_CLUT06          5   /* 6-bit CLUT (64 colors/EHB, 42 px/burst, 4 pad @ bits [3:0]) */
#define SPR_FMT_CLUT07          6   /* 7-bit CLUT (128 colors, 36 px/burst, 4 pad @ bits [3:0]) */
#define SPR_FMT_CLUT08          7   /* 8-bit CLUT (256 colors, 32 px/burst, 0 pad) */
#define SPR_FMT_HAM04_64PX      8   /* HAM04 (4-4-4-4...), 64 px/burst */
#define SPR_FMT_HAM06_03_64PX   9   /* HAM06 (6-3-4-3-6-3-4-3), 64 px/burst (Standard) */
#define SPR_FMT_HAM08_32PX      10  /* HAM08 (8-8-8-8), 32 px/burst */
#define SPR_FMT_HAM12_12_686    11  /* 12-6-8-6, 32 px/burst (HAM12 anchor + HAM06/08) */
#define SPR_FMT_HAM12_12_5555   12  /* 12-5-5-5-5, 40 px/burst (HAM12 anchor + 4x HAM05) */
#define SPR_FMT_HAM16_12X4      13  /* 16-12-12-12-12, 20 px/burst (100% palette-free) */
#define SPR_FMT_HAM16_DIRECT    14  /* 16-16, 16 px/burst (Pure HAM16 palette-free) */
#define SPR_FMT_RGB16_HIGHCOLOR 15  /* 16-16 Direct HighColor (RGB565 / RGB555 $8000=black) */
#define SPR_FMT_ARGB32_DIRECT   16  /* 32-bit ARGB8888 TrueColor (8 px/burst, per-pixel alpha) */
#define SPR_FMT_HAM12_5D        17  /* 12-5-5-5-5, 40 px/burst (HAM12 anchor + 4x ham5delta, palette-free) */
#define SPR_FMT_HAM12_686_D     18  /* 12-6-8-6, 32 px/burst (HAM12 anchor + ham6delta/ham8delta, palette-free) */
#define SPR_FMT_HAM08_D         19  /* 8-8-8-8, 32 px/burst (Pure ham8delta 4-level turbo, palette-free) */

/* =========================================================================
 * 3. 16-Byte Sprite Descriptor Structure (Fast-RAM, DESC_REV = 4)
 * ========================================================================= */
#define SPR_DESC_REV            4
#define MAX_SPRITE_DESCRIPTORS  4096

#pragma pack(push, 1)
typedef struct SpriteDesc {
    /* 64-Bit Word 0 (Offset +$00 .. +$07) */
    int16_t  y_pos;             /* +$00: Start scanline (-4096 .. +4095) [Wort-aligned] */
    int16_t  x_pos;             /* +$02: Start column   (-4096 .. +4095) [Wort-aligned] */
    uint32_t data_ptr;          /* +$04: Clean 32-bit Fast-RAM pointer (32-byte-aligned) [Long-aligned] */

    /* 64-Bit Word 1 (Offset +$08 .. +$0F) */
    uint16_t height;            /* +$08: Height in scanlines (1..2047; 0 = Sentinel / list end!) */
    uint8_t  width;             /* +$0A: Width in 256-bit (32-byte) bursts (1..64) */
    uint8_t  format;            /* +$0B: Format (0..7 CLUT, 8..14 HAM, 15 RGB16, 16 ARGB32) */
    uint8_t  prio;              /* +$0C: Priority (1..255; 0 = inactive/skip) */
    uint8_t  alpha;             /* +$0D: Global Alpha (Fmt 13..16) / PAL_OFFSET (Fmt 0..12) */
    uint16_t ctrl;              /* +$0E: Scale, Flip, Smooth, Blend-Mode, Prio-GE */
} SpriteDesc_t;
#pragma pack(pop)

/* Binary Scale factors in ctrl [2:0] (X_SCALE) and [5:3] (Y_SCALE) */
#define SPR_SCALE_1X            0u  /* 1:1 Normal */
#define SPR_SCALE_2X            1u  /* 2x Zoom (Pixel doubling) */
#define SPR_SCALE_4X            2u  /* 4x Zoom (Pixel quadrupling) */
#define SPR_SCALE_HALF          3u  /* 1/2 Subsampling (Every 2nd pixel) */
#define SPR_SCALE_QUARTER       4u  /* 1/4 Subsampling (Every 4th pixel) */

#define SPR_X_SCALE(s)          (((uint16_t)(s) & 7u) << 0)
#define SPR_Y_SCALE(s)          (((uint16_t)(s) & 7u) << 3)

/* Flags in ctrl [15:6] */
#define SPR_FLAG_H_FLIP         (1u << 6)  /* Horizontal mirror */
#define SPR_FLAG_V_FLIP         (1u << 7)  /* Vertical mirror */
#define SPR_FLAG_SMOOTH_X       (1u << 8)  /* 24-bit linear RGB horizontal interpolation */
#define SPR_BLEND_OPAQUE        (0u << 9)  /* 00: Normal / Opaque overwrite */
#define SPR_BLEND_ADDITIVE      (1u << 9)  /* 01: Additive min(255, S + D) (thruster flames/lasers) */
#define SPR_BLEND_50_50         (2u << 9)  /* 10: 50/50 Translucent (S + D) >> 1 (canopy glass/shadow) */
#define SPR_BLEND_ALPHA         (3u << 9)  /* 11: Full 8-bit Alpha: D + alpha*(S - D)/256 */
#define SPR_FLAG_PRIO_GE        (1u << 11) /* Priority >= instead of > on tie */

/* =========================================================================
 * 4. Helper Macros to initialize a SpriteDesc
 * ========================================================================= */
#define SPR_INIT_DESC(desc, _y, _x, _addr, _h, _w_bursts, _fmt, _prio, _alpha, _ctrl) do { \
    (desc)->y_pos    = (int16_t)(_y); \
    (desc)->x_pos    = (int16_t)(_x); \
    (desc)->data_ptr = (uint32_t)(_addr); \
    (desc)->height   = (uint16_t)(_h); \
    (desc)->width    = (uint8_t)(_w_bursts); \
    (desc)->format   = (uint8_t)(_fmt); \
    (desc)->prio     = (uint8_t)(_prio); \
    (desc)->alpha    = (uint8_t)(_alpha); \
    (desc)->ctrl     = (uint16_t)(_ctrl); \
} while(0)

#define SPR_SENTINEL(desc) do { \
    (desc)->height = 0; \
} while(0)

/* =========================================================================
 * 5. Inline Functions for Amiga C Programs
 * ========================================================================= */

/**
 * Sets a 24-bit palette slot in the dedicated Sprite Palette RAM (M10K).
 */
static inline void SprSetPalette(uint8_t slot, uint8_t r, uint8_t g, uint8_t b) {
    REG_SPR_PAL_ADDR   = (uint16_t)slot;
    REG_SPR_PAL_DATA_H = (uint16_t)r;
    REG_SPR_PAL_DATA_L = (uint16_t)(((uint16_t)g << 8) | b);
}

/**
 * Sets the pending 32-bit Sprite Descriptor List Pointer ($DFF580).
 * Hardware automatically latches this pointer at the start of each VBlank.
 * Passing NULL (0) disables the sprite engine completely (0 DMA requests).
 */
static inline void SprSetListPtr(const SpriteDesc_t* desc_list) {
    REG_SPR_LIST_PTR = (uint32_t)desc_list;
}

/**
 * Returns the currently active (rendering) Sprite Descriptor List Pointer.
 */
static inline uint32_t SprGetActiveListPtr(void) {
    return REG_SPR_LIST_PTR;
}

/**
 * Disables the Sprite Engine (0 DMA requests, completely dormant).
 */
static inline void SprDisable(void) {
    REG_SPR_LIST_PTR = 0;
}

#ifdef __cplusplus
}
#endif

#endif /* SPRITE_ENGINE_H */
