* =========================================================================
* NanoMig / Minimig-AGA 32/64-Bit HAM, ARGB & HighColor Sprite Engine
* Motorola 68000 Assembly Include File (vasm / PhxAss / ASM-One)
* Architecture Spec Revision 4.1
* Native VBlank Pointer Latching (Amiga Standard: NULL = OFF)
* =========================================================================

* -------------------------------------------------------------------------
* 1. Hardware Custom Register Offsets (relative to $DFF000 / CUSTOM Base)
* -------------------------------------------------------------------------
SPR_LIST_PTR    EQU $580    ; Long: W = Atomic Pending VBlank pointer; R = Active rendering pointer
SPR_LIST_PTR_H  EQU $580    ; Word: High 16 bits of Pointer (Staging only, no shadow commit)
SPR_LIST_PTR_L  EQU $582    ; Word: Low 16 bits of Pointer (Atomically bundles HI+LO into shadow)
SPR_CTRL        EQU $584    ; Word: Engine Control (Bit 2: Reset)
SPR_PAL_ADDR    EQU $586    ; Word: Palette RAM Address (0..255)
SPR_PAL_DATA_H  EQU $588    ; Word: Palette Data High: Red [7:0]
SPR_PAL_DATA_L  EQU $58A    ; Word: Palette Data Low: Green [15:8], Blue [7:0]
SPR_MAX_BUSY    EQU $590    ; Word: Diagnostic: Max decoder busy cycles on a line
SPR_DMA_STALL   EQU $592    ; Word: Diagnostic: Total DMA memory wait cycles
SPR_OVERRUN_CNT EQU $594    ; Word: Diagnostic: Line budget overrun/timeout counter
SPR_CUR_Y       EQU $596    ; Word: Diagnostic: Current raster line in hardware

* Bits in SPR_CTRL ($DFF584)
SPRB_RESET      EQU 2       ; Reset pipeline and prefetch FIFOs
SPRF_RESET      EQU (1<<2)

* -------------------------------------------------------------------------
* 2. 16-Byte Sprite Descriptor Offsets (DESC_REV = 4)
* -------------------------------------------------------------------------
* Structure Size: 16 Bytes ($10)
* Alignment: Must be 32-byte aligned in Fast-RAM for 4x64-bit DDR3 burst!
* Note: Sort by comparing signed Word spr_YPos, and on match compare signed Word spr_XPos!

spr_YPos        EQU 0       ; Word (int16): Start scanline (-4096..+4095) [Wort-aligned]
spr_XPos        EQU 2       ; Word (int16): Start column   (-4096..+4095) [Wort-aligned]
spr_DataPtr     EQU 4       ; Long (uint32): Clean 32-bit Fast-RAM Pointer (32-byte aligned)
spr_Height      EQU 8       ; Word (uint16): Scanline height (1..2047; 0=Sentinel!)
spr_Width       EQU 10      ; Byte (uint8): Width in 256-bit (32-byte) bursts (1..64)
spr_Format      EQU 11      ; Byte (uint8): Format (0..7 CLUT, 8..14 HAM, 15 RGB16, 16 ARGB32)
spr_Prio        EQU 12      ; Byte (uint8): 8-bit Priority (1..255; 0=inactive)
spr_Alpha       EQU 13      ; Byte (uint8): Global Alpha (Fmt 13..16) / PAL_OFFSET (Fmt 0..12)
spr_Ctrl        EQU 14      ; Word (uint16): Scale, Flip, Smooth, Blend-Mode, Prio-GE

SPR_DESC_SIZE   EQU 16

* Binary Scale Factors in spr_Ctrl [2:0] (X_SCALE) and [5:3] (Y_SCALE)
SPR_SCALE_1X    EQU 0       ; 1:1 Normal
SPR_SCALE_2X    EQU 1       ; 2x Zoom (Pixel doubling)
SPR_SCALE_4X    EQU 2       ; 4x Zoom (Pixel quadrupling)
SPR_SCALE_HALF  EQU 3       ; 1/2 Subsampling (Every 2nd pixel)
SPR_SCALE_QUART EQU 4       ; 1/4 Subsampling (Every 4th pixel)

* Flags in spr_Ctrl [15:6]
SPRF_H_FLIP     EQU (1<<6)  ; Horizontal mirror
SPRF_V_FLIP     EQU (1<<7)  ; Vertical mirror
SPRF_SMOOTH_X   EQU (1<<8)  ; 24-bit linear RGB horizontal interpolation
SPR_BLEND_NORM  EQU (0<<9)  ; 00: Normal / Opaque
SPR_BLEND_ADD   EQU (1<<9)  ; 01: Additive min(255, S + D) (flames/lasers)
SPR_BLEND_5050  EQU (2<<9)  ; 10: 50/50 Translucent (S + D) >> 1 (canopy glass/shadows)
SPR_BLEND_ALPHA EQU (3<<9)  ; 11: Full 8-bit Alpha: D + alpha*(S - D)/256
SPRF_PRIO_GE    EQU (1<<11) ; Priority >= instead of > on tie

* Supported Pack Formats (FORMAT 0..16)
FMT_CLUT01      EQU 0       ; 1-bit CLUT (2 colors, 256 px/burst, 0 pad)
FMT_CLUT02      EQU 1       ; 2-bit CLUT (4 colors, 128 px/burst, 0 pad)
FMT_CLUT03      EQU 2       ; 3-bit CLUT (8 colors, 85 px/burst, 1 pad @ bit 0)
FMT_CLUT04      EQU 3       ; 4-bit CLUT (16 colors, 64 px/burst, 0 pad)
FMT_CLUT05      EQU 4       ; 5-bit CLUT (32 colors, 51 px/burst, 1 pad @ bit 0)
FMT_CLUT06      EQU 5       ; 6-bit CLUT (64 colors/EHB, 42 px/burst, 4 pad @ bits [3:0])
FMT_CLUT07      EQU 6       ; 7-bit CLUT (128 colors, 36 px/burst, 4 pad @ bits [3:0])
FMT_CLUT08      EQU 7       ; 8-bit CLUT (256 colors, 32 px/burst, 0 pad)
FMT_HAM04_64    EQU 8       ; HAM04, 64 px/burst
FMT_HAM06_03_64 EQU 9       ; 6-3-4-3-6-3-4-3, 64 px/burst (Standard)
FMT_HAM08_32    EQU 10      ; 8-8-8-8, 32 px/burst
FMT_HAM12_12686 EQU 11      ; 12-6-8-6, 32 px/burst (HAM12 anchor + HAM06/08)
FMT_HAM12_12555 EQU 12      ; 12-5-5-5-5, 40 px/burst (HAM12 anchor + 4x HAM05)
FMT_HAM16_12X4  EQU 13      ; 16-12-12-12-12, 20 px/burst (100% palette-free)
FMT_HAM16_16    EQU 14      ; 16-16 Pure HAM16, 16 px/burst (palette-free)
FMT_RGB16_DIR   EQU 15      ; 16-16 Direct HighColor (RGB565 / RGB555 $8000=black)
FMT_ARGB32_DIR  EQU 16      ; 32-bit ARGB8888 TrueColor (8 px/burst, per-pixel alpha)
FMT_HAM12_5D     EQU 17      ; 12-5-5-5-5, 40 px/burst (HAM12 anchor + 4x ham5delta, palette-free)
FMT_HAM12_686_D  EQU 18      ; 12-6-8-6, 32 px/burst (HAM12 anchor + ham6delta/ham8delta, palette-free)
FMT_HAM08_D      EQU 19      ; 8-8-8-8, 32 px/burst (Pure ham8delta 4-level turbo, palette-free)

* -------------------------------------------------------------------------
* 3. Macro: Set Palette Entry ($DFF586 .. $DFF58A)
* Input: \1 = Custom Base (An), \2 = Slot (Dn), \3 = RGB24 (Dn: $00RRGGBB)
* -------------------------------------------------------------------------
SPR_SET_PALETTE MACRO
                MOVE.W  \2,SPR_PAL_ADDR(\1)     ; Set palette slot 0..255
                SWAP    \3                      ; Low word is now $00RR
                MOVE.W  \3,SPR_PAL_DATA_H(\1)   ; Write Red [7:0]
                SWAP    \3                      ; Restore: low word is $GGBB
                MOVE.W  \3,SPR_PAL_DATA_L(\1)   ; Write Green [15:8] and Blue [7:0]
                ENDM
