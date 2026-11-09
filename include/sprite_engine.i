* =========================================================================
* NanoMig / Minimig-AGA 32/64-Bit HAM, ARGB & HighColor Sprite Engine
* Motorola 68000 Assembly Include File (vasm / PhxAss / ASM-One)
* Architecture Spec Revision 3 (Commit a241f87 / 6d7fd28)
* =========================================================================

* -------------------------------------------------------------------------
* 1. Hardware Custom Register Offsets (relative to $DFF000 / CUSTOM Base)
* -------------------------------------------------------------------------
SPR_LIST_PTR    EQU $580    ; Long: Fast-RAM 32-byte-aligned Descriptor List Pointer
SPR_LIST_PTR_H  EQU $580    ; Word: High 16 bits of Descriptor Pointer
SPR_LIST_PTR_L  EQU $582    ; Word: Low 16 bits of Descriptor Pointer
SPR_CTRL        EQU $584    ; Word: Engine Control (Enable, Auto-Scan, Reset)
SPR_PAL_ADDR    EQU $586    ; Word: Palette RAM Address (0..255)
SPR_PAL_DATA_H  EQU $588    ; Word: Palette Data High: Red [7:0]
SPR_PAL_DATA_L  EQU $58A    ; Word: Palette Data Low: Green [15:8], Blue [7:0]
SPR_STEP_RGB    EQU $58C    ; Word: 4-Bit Steps: R[11:8], G[7:4], B[3:0] in 0..15
SPR_COMMIT      EQU $58E    ; Word: Commit Handshake (Bit 0: REQ, Bit 1: ACK, Bit 2: BANK)
SPR_MAX_BUSY    EQU $590    ; Word: Diagnostic: Max decoder busy cycles on a line
SPR_DMA_STALL   EQU $592    ; Word: Diagnostic: Total DMA memory wait cycles
SPR_OVERRUN_CNT EQU $594    ; Word: Diagnostic: Line budget overrun/timeout counter
SPR_CUR_Y       EQU $596    ; Word: Diagnostic: Current raster line in hardware

* Bits in SPR_CTRL ($DFF584)
SPRB_ENABLE     EQU 0       ; Enable Sprite Engine rendering
SPRB_AUTO_SCAN  EQU 1       ; Automatic Y-list traversal per scanline
SPRB_RESET      EQU 2       ; Reset pipeline and prefetch FIFOs

SPRF_ENABLE     EQU (1<<0)
SPRF_AUTO_SCAN  EQU (1<<1)
SPRF_RESET      EQU (1<<2)

* Bits in SPR_COMMIT ($DFF58E)
SPRB_COMMIT_REQ EQU 0       ; CPU request bit: commit shadow configuration
SPRB_COMMIT_ACK EQU 1       ; Hardware status bit: commit completed before line 0 & old bank drained
SPRB_ACTIVE_BNK EQU 2       ; Hardware status bit: active bank (0=Bank A, 1=Bank B)
SPRB_OLD_BUSY   EQU 3       ; Hardware status bit: 1=old bank draining, 0=old bank idle/safe

SPRF_COMMIT_REQ EQU (1<<0)
SPRF_COMMIT_ACK EQU (1<<1)
SPRF_ACTIVE_BNK EQU (1<<2)
SPRF_OLD_BUSY   EQU (1<<3)

* -------------------------------------------------------------------------
* 2. 16-Byte Sprite Descriptor Offsets (DESC_REV = 3)
* -------------------------------------------------------------------------
* Structure Size: 16 Bytes ($10)
* Alignment: Must be 32-byte aligned in Fast-RAM for 4x64-bit DDR3 burst!

spr_YPos        EQU 0       ; Word (int16): Start scanline (-4096..+4095)
spr_XPos        EQU 2       ; Word (int16): Start column (-4096..+4095)
spr_YHeightLo   EQU 4       ; Byte (uint8): Lower 8 bits of 11-bit height (1..2047; 0=Sentinel!)
spr_XWidth256   EQU 5       ; Byte (uint8): Width in 256-bit (32-byte) bursts (1..64)
spr_Prio        EQU 6       ; Byte (uint8): 8-bit Priority (1..255; 0=inactive)
spr_PalAlpha    EQU 7       ; Byte (uint8): PAL_OFFSET (Fmt 0..14) / SPR_ALPHA (Fmt 15..17)
spr_DataPtr     EQU 8       ; Long (uint32): [31:5] Aligned Addr, [4]=0, [3]=FMT[4], [2:0]=H[10:8]
spr_FmtFlags    EQU 12      ; Byte (uint8): [7:4] FORMAT_LO[3:0], [3:0] FLAGS
spr_XScale      EQU 13      ; Byte (uint8): 2.6 Fixed-Point ($40=1.0x; $10=4x zoom .. $FF=0.25x)
spr_YScale      EQU 14      ; Byte (uint8): 2.6 Fixed-Point ($40=1.0x; $10=4x zoom .. $FF=0.25x)
spr_StepBlend   EQU 15      ; Byte (uint8): Bit 7: CUSTOM_STEP, Bit 6: CLUT, Bits [5:4]: BLEND

SPR_DESC_SIZE   EQU 16

* Descriptor Flags in spr_FmtFlags [3:0]
SPRF_H_FLIP     EQU (1<<0)  ; Horizontal mirror
SPRF_V_FLIP     EQU (1<<1)  ; Vertical mirror
SPRF_SMOOTH_X   EQU (1<<2)  ; 24-bit linear RGB horizontal interpolation
SPRF_PRIO_GE    EQU (1<<3)  ; Priority >= instead of > on tie

* Hardware Blend Modes in spr_StepBlend [5:4]
SPR_BLEND_NORM  EQU (0<<4)  ; 00: Normal / Opaque
SPR_BLEND_ADD   EQU (1<<4)  ; 01: Additive Blending min(255, S + D) (flames/lasers)
SPR_BLEND_5050  EQU (2<<4)  ; 10: 50/50 Translucent (S + D) >> 1 (canopy glass/shadows)
SPR_BLEND_ALPHA EQU (3<<4)  ; 11: Full 8-bit Alpha: D + alpha*(S - D)/256

* Step / Mode Bits in spr_StepBlend
SPRF_CLUT_MODE  EQU (1<<6)  ; 1 = Direct Palette CLUT; 0 = HAM mode
SPRF_CUST_STEP  EQU (1<<7)  ; 1 = Custom sprite step multiplier; 0 = global

* All 19 Supported Pack Formats (FORMAT 0..18)
FMT_HAM04_64    EQU 0       ; 4-4-4-4-4-4-4-4, 64 px/burst
FMT_HAM03_42    EQU 1       ; 3-3-3-3-3-3-3-3, 42.6 px/burst
FMT_HAM06_03_64 EQU 2       ; 6-3-4-3-6-3-4-3, 64 px/burst (Standard)
FMT_HAM05_51    EQU 3       ; 5-5-5-5-5-5, 51.2 px/burst
FMT_HAM06_42    EQU 4       ; 6-6-6-6-6, 42.6 px/burst
FMT_HAM08_32    EQU 5       ; 8-8-8-8, 32 px/burst
FMT_HAM06_04_48 EQU 6       ; 6-4-6-4, 48 px/burst
FMT_HAM05_04_53 EQU 7       ; 5-4-5-4, 53.3 px/burst
FMT_HAM06_05_46 EQU 8       ; 6-5-6-5, 46.5 px/burst
FMT_HAM08_06_36 EQU 9       ; 8-6-8-6, 36.5 px/burst
FMT_HAM08_X4_40 EQU 10      ; 8-6-6-6-6, 40 px/burst
FMT_HAM08_05_40 EQU 11      ; 8-5-8-6-5, 40 px/burst
FMT_CLUT256_32  EQU 12      ; 8-8-8-8 Direct 256-color palette, 32 px/burst
FMT_HAM12_12686 EQU 13      ; 12-6-8-6, 32 px/burst (HAM12 anchor + HAM06/08)
FMT_HAM12_12555 EQU 14      ; 12-5-5-5-5, 40 px/burst (HAM12 anchor + 4x HAM05)
FMT_HAM16_12X4  EQU 15      ; 16-12-12-12-12, 20 px/burst (100% palette-free)
FMT_HAM16_16    EQU 16      ; 16-16 Pure HAM16, 16 px/burst (palette-free)
FMT_RGB16_DIR   EQU 17      ; 16-16 Direct HighColor (RGB565 / RGB555 $8000=black)
FMT_ARGB32_DIR  EQU 18      ; 32-bit ARGB8888 TrueColor (8 px/burst, per-pixel alpha)

* -------------------------------------------------------------------------
* 3. Macro: Set Palette Entry ($DFF586 .. $DFF58A)
* Input: \1 = Custom Base (An), \2 = Slot (Dn), \3 = RGB24 (Dn: $00RRGGBB)
* -------------------------------------------------------------------------
SPR_SET_PALETTE MACRO
                MOVE.W  \2,SPR_PAL_ADDR(\1)     ; Set palette slot 0..255
                ROL.L   #8,\3                   ; Rotate: R in low byte
                MOVE.B  \3,SPR_PAL_DATA_H+1(\1) ; Write Red byte
                ROL.L   #8,\3                   ; Rotate: G in low byte
                MOVE.B  \3,SPR_PAL_DATA_L(\1)   ; Write Green byte
                ROL.L   #8,\3                   ; Rotate: B in low byte
                MOVE.B  \3,SPR_PAL_DATA_L+1(\1) ; Write Blue byte
                ROL.L   #8,\3                   ; Restore original Dn ($00RRGGBB)
                ENDM

* -------------------------------------------------------------------------
* 4. Helper Routine: Atomic VBlank Bank-Commit Handshake
* In: A5 = $DFF000 (Custom Base)
* Note: Keeps A6 intact for AmigaOS Library calls!
* -------------------------------------------------------------------------
SprCommitBank:
                MOVE.W  #SPRF_COMMIT_REQ,SPR_COMMIT(A5) ; Request bank commit
.wait_ack:
                BTST    #SPRB_COMMIT_ACK,SPR_COMMIT+1(A5) ; Test ACK bit in low byte
                BEQ.S   .wait_ack                       ; Wait until hardware signals ACK (old_bank_safe)
                CLR.W   SPR_COMMIT(A5)                  ; Clear REQ bit
.wait_rearm:
                BTST    #SPRB_COMMIT_ACK,SPR_COMMIT+1(A5)
                BNE.S   .wait_rearm                     ; Wait until hardware clears ACK (rearmed)
                RTS
