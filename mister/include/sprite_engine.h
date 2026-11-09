#ifndef NANOMIG_SPRITE_ENGINE_H
#define NANOMIG_SPRITE_ENGINE_H

/**
 * NanoMig / Minimig-AGA 32/64-Bit HAM, ARGB & HighColor Sprite Engine
 * C/C++ Hardware Header (AmigaOS m68k / vbcc / gcc / SAS/C)
 * Architecture Spec Revision 3 (Commit a241f87 / 6d7fd28)
 *
 * Motorola 68000 Big-Endian Architecture
 */

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* =========================================================================
 * 1. Hardware Custom Registers ($DFF580 .. $DFF59E)
 * ========================================================================= */
#define CUSTOM_BASE             0x00DFF000

#define REG_SPR_LIST_PTR        (*(volatile uint32_t*)(CUSTOM_BASE + 0x580))
#define REG_SPR_LIST_PTR_H      (*(volatile uint16_t*)(CUSTOM_BASE + 0x580))
#define REG_SPR_LIST_PTR_L      (*(volatile uint16_t*)(CUSTOM_BASE + 0x582))
#define REG_SPR_CTRL            (*(volatile uint16_t*)(CUSTOM_BASE + 0x584))
#define REG_SPR_PAL_ADDR        (*(volatile uint16_t*)(CUSTOM_BASE + 0x586))
#define REG_SPR_PAL_DATA_H      (*(volatile uint16_t*)(CUSTOM_BASE + 0x588)) /* Red [7:0] */
#define REG_SPR_PAL_DATA_L      (*(volatile uint16_t*)(CUSTOM_BASE + 0x58A)) /* Green [15:8], Blue [7:0] */
#define REG_SPR_STEP_RGB        (*(volatile uint16_t*)(CUSTOM_BASE + 0x58C)) /* R[11:8], G[7:4], B[3:0] in 0..15 */
#define REG_SPR_COMMIT          (*(volatile uint16_t*)(CUSTOM_BASE + 0x58E)) /* Bit 0: REQ, Bit 1: ACK, Bit 2: BANK */
#define REG_SPR_MAX_BUSY        (*(volatile uint16_t*)(CUSTOM_BASE + 0x590)) /* Max line busy cycles */
#define REG_SPR_DMA_STALL       (*(volatile uint16_t*)(CUSTOM_BASE + 0x592)) /* DMA wait cycles */
#define REG_SPR_OVERRUN_CNT     (*(volatile uint16_t*)(CUSTOM_BASE + 0x594)) /* Line budget overruns */
#define REG_SPR_CUR_Y           (*(volatile uint16_t*)(CUSTOM_BASE + 0x596)) /* Current raster scanline */

/* Bits in SPR_CTRL ($DFF584) */
#define SPR_CTRL_ENABLE         (1u << 0)  /* Enable Sprite Engine */
#define SPR_CTRL_AUTO_SCAN      (1u << 1)  /* Automatic Y-list traversal */
#define SPR_CTRL_RESET          (1u << 2)  /* Reset engine pipeline & FIFOs */

/* Bits in SPR_COMMIT ($DFF58E) */
#define SPR_COMMIT_REQ          (1u << 0)  /* CPU request: commit shadow config */
#define SPR_COMMIT_ACK          (1u << 1)  /* HW status: commit completed before line 0 & old bank drained */
#define SPR_COMMIT_ACTIVE_BANK  (1u << 2)  /* HW status: active bank (0=Bank A, 1=Bank B) */
#define SPR_COMMIT_OLD_BUSY     (1u << 3)  /* HW status: 1=old bank still draining, 0=old bank idle/safe */

/* =========================================================================
 * 2. 16-Byte Sprite Descriptor Structure (Fast-RAM, DESC_REV = 3)
 * ========================================================================= */
#define SPR_DESC_REV            3
#define MAX_SPRITE_DESCRIPTORS  4096

#pragma pack(push, 1)
typedef struct SpriteDesc {
    /* 64-Bit Word 0 (Offset +$00 .. +$07) */
    int16_t  y_pos;             /* +$00: Start scanline (-4096 .. +4095) */
    int16_t  x_pos;             /* +$02: Start column   (-4096 .. +4095) */
    uint8_t  y_height_lo;       /* +$04: Lower 8 bits of 11-bit height (1..2047; 0=Sentinel) */
    uint8_t  x_width256;        /* +$05: Width in 256-bit (32-byte) bursts (1..64) */
    uint8_t  prio;              /* +$06: Priority (1..255; 0=inactive/skip) */
    uint8_t  pal_offset_alpha;  /* +$07: PAL_OFFSET for Fmt 0..14; SPR_ALPHA for Fmt 15..17 */

    /* 64-Bit Word 1 (Offset +$08 .. +$0F) */
    uint32_t data_ptr_raw;      /* +$08: [31:5] Base addr, [4]=0, [3]=FORMAT[4], [2:0]=HEIGHT[10:8] */
    uint8_t  format_flags;      /* +$0C: [7:4] FORMAT_LO[3:0], [3:0] FLAGS */
    uint8_t  x_scale;           /* +$0D: Fixed-point 2.6 ($40 = 1.0x; $10=4x zoom .. $FF=0.25x shrink) */
    uint8_t  y_scale;           /* +$0E: Fixed-point 2.6 ($40 = 1.0x; $10=4x zoom .. $FF=0.25x shrink) */
    uint8_t  step_blend_ctrl;   /* +$0F: Bit 7: CUSTOM_STEP, Bit 6: CLUT_MODE, Bits [5:4]: BLEND_MODE */
} SpriteDesc_t;
#pragma pack(pop)

/* Flags in format_flags [3:0] */
#define SPR_FLAG_H_FLIP         (1u << 0)  /* Horizontal mirror */
#define SPR_FLAG_V_FLIP         (1u << 1)  /* Vertical mirror */
#define SPR_FLAG_SMOOTH_X       (1u << 2)  /* 24-bit linear RGB horizontal interpolation */
#define SPR_FLAG_PRIO_GE        (1u << 3)  /* Priority >= instead of > on tie */

/* Blend Modes in step_blend_ctrl [5:4] */
#define SPR_BLEND_OPAQUE        (0u << 4)  /* 00: Normal / Opaque overwrite */
#define SPR_BLEND_ADDITIVE      (1u << 4)  /* 01: Additive min(255, S + D) (thruster flames/lasers) */
#define SPR_BLEND_50_50         (2u << 4)  /* 10: 50/50 Translucent (S + D) >> 1 (canopy glass/shadow) */
#define SPR_BLEND_ALPHA         (3u << 4)  /* 11: Full 8-bit Alpha: D + alpha*(S - D)/256 */

/* Step / Mode Control in step_blend_ctrl */
#define SPR_CTRL_CLUT_MODE      (1u << 6)  /* 1 = Direct Palette CLUT; 0 = HAM mode */
#define SPR_CTRL_CUSTOM_STEP    (1u << 7)  /* 1 = Use sprite custom step multiplier; 0 = global */

/* All 19 Supported Pack Formats (FORMAT 0..18) */
#define SPR_FMT_HAM04_64PX      0   /* HAM04, 64 px/burst */
#define SPR_FMT_HAM03_42PX      1   /* HAM03, 42.6 px/burst */
#define SPR_FMT_HAM06_03_64PX   2   /* 6-3-4-3-6-3-4-3, 64 px/burst (Standard) */
#define SPR_FMT_HAM05_51PX      3   /* HAM05, 51.2 px/burst */
#define SPR_FMT_HAM06_42PX      4   /* HAM06, 42.6 px/burst */
#define SPR_FMT_HAM08_32PX      5   /* HAM08, 32 px/burst */
#define SPR_FMT_HAM06_04_48PX   6   /* 6-4-6-4, 48 px/burst */
#define SPR_FMT_HAM05_04_53PX   7   /* 5-4-5-4, 53.3 px/burst */
#define SPR_FMT_HAM06_05_46PX   8   /* 6-5-6-5, 46.5 px/burst */
#define SPR_FMT_HAM08_06_36PX   9   /* 8-6-8-6, 36.5 px/burst */
#define SPR_FMT_HAM08_06X4_40PX 10  /* 8-6-6-6-6, 40 px/burst */
#define SPR_FMT_HAM08_05_40PX   11  /* 8-5-8-6-5, 40 px/burst */
#define SPR_FMT_CLUT256_32PX    12  /* 8-8-8-8, 32 px/burst (Direct 256-color palette) */
#define SPR_FMT_HAM12_12_686    13  /* 12-6-8-6, 32 px/burst (HAM12 anchor + HAM06/08) */
#define SPR_FMT_HAM12_12_5555   14  /* 12-5-5-5-5, 40 px/burst (HAM12 anchor + 4x HAM05) */
#define SPR_FMT_HAM16_12X4      15  /* 16-12-12-12-12, 20 px/burst (100% palette-free) */
#define SPR_FMT_HAM16_DIRECT    16  /* 16-16, 16 px/burst (Pure HAM16 palette-free) */
#define SPR_FMT_RGB16_HIGHCOLOR 17  /* 16-16 Direct HighColor (RGB565 / RGB555 $8000=black) */
#define SPR_FMT_ARGB32_DIRECT   18  /* 32-bit ARGB8888 TrueColor (8 px/burst, per-pixel alpha) */

/* =========================================================================
 * 3. Helper Macros to initialize a SpriteDesc
 * ========================================================================= */
#define SPR_INIT_DESC(desc, _x, _y, _w_bursts, _height, _prio, _fmt, _addr, _flags, _xscale, _yscale, _blend) do { \
    (desc)->x_pos = (int16_t)(_x); \
    (desc)->y_pos = (int16_t)(_y); \
    (desc)->y_height_lo = (uint8_t)((_height) & 0xFF); \
    (desc)->x_width256  = (uint8_t)(_w_bursts); \
    (desc)->prio        = (uint8_t)(_prio); \
    (desc)->pal_offset_alpha = 0; \
    (desc)->data_ptr_raw = (((uint32_t)(_addr)) & 0xFFFFFFE0u) \
                         | ((((uint32_t)(_fmt) >> 4) & 1u) << 3) \
                         | ((((uint32_t)(_height) >> 8) & 7u)); \
    (desc)->format_flags = (uint8_t)((((_fmt) & 0x0F) << 4) | ((_flags) & 0x0F)); \
    (desc)->x_scale = (uint8_t)(_xscale); \
    (desc)->y_scale = (uint8_t)(_yscale); \
    (desc)->step_blend_ctrl = (uint8_t)(_blend); \
} while(0)

#define SPR_SENTINEL(desc) do { \
    (desc)->y_height_lo = 0; \
    (desc)->data_ptr_raw &= ~7u; /* height[10:8] = 0 -> total height = 0 */ \
} while(0)

/* =========================================================================
 * 4. Inline Functions for Amiga C Programs
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
 * Performs an atomic VBlank Bank-Commit 4-phase handshake.
 * Sets SPR_COMMIT_REQ, waits for hardware SPR_COMMIT_ACK (guaranteeing
 * old bank is fully drained and safe to modify), then clears REQ and
 * waits for HW to drop ACK, rearming the single-shot latch.
 */
static inline void SprCommitConfig(void) {
    REG_SPR_COMMIT = SPR_COMMIT_REQ;
    while (!(REG_SPR_COMMIT & SPR_COMMIT_ACK)) {
        /* Busy wait until hardware confirms commit before line 0 and old bank drained */
    }
    REG_SPR_COMMIT = 0; /* Clear REQ to complete handshake */
    while (REG_SPR_COMMIT & SPR_COMMIT_ACK) {
        /* Wait for HW to drop ACK and return to ARMED state */
    }
}

#ifdef __cplusplus
}
#endif

#endif /* NANOMIG_SPRITE_ENGINE_H */
