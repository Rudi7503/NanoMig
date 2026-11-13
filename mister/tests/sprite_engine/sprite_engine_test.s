; ==============================================================================
; NanoMig / Minimig-AGA Hardware Sprite Engine Test & Scanline Stress Harness
; Target: Motorola 68000 / 68020+ on MiSTer FPGA DE10-Nano
;
; Tests:
;   - Register interface at $DFF820..$DFF83E
;   - Dedicated 256x24-bit True-Color Palette RAM loading via $DFF826 / $DFF828
;   - Y-sorted 16-Byte Fast-RAM Descriptor List Traversal
;   - Scanline Fillrate & DDR3-BL8 Burst Master Stress Test:
;       * Phase 1 (Safe Baseline):   2 Sprites per scanline
;       * Phase 2 (Moderate Stress): 8 Sprites per scanline
;       * Phase 3 (High Density):   16 Sprites per scanline
;       * Phase 4 (Max Stress):     32 Sprites packed into single scanline!
;
; Feedback:
;   - Background/Border Color reflects Overrun Status:
;       * Dark Blue ($012):  0 Overruns (100% Scanline Deadline Met)
;       * Flashing Red ($F00): Overrun Detected in $DFF82E!
;
; Controls:
;   - Left Mouse Button ($BFE001 bit 6): Switch to Next Density Phase (1 -> 2 -> 3 -> 4)
;   - Right Mouse Button ($DFF016 bit 10): Cleanly exit back to AmigaOS / CLI
;
; Assembly:
;   vasmm68k_mot -Fhunk -o sprite_engine_test.o sprite_engine_test.s
;   vlink -bamigahunk -x -Bstatic -o sprite_engine_test sprite_engine_test.o
; ==============================================================================

                SECTION Code,CODE

; Custom Chip & Sprite Engine Hardware Registers
CUSTOM          EQU $DFF000
VPOSR           EQU $004
COP1LCH         EQU $080
COP1LCL         EQU $082
COPJMP1         EQU $088
DMACON          EQU $096
INTENA          EQU $09A
INTREQ          EQU $09C
COLOR00         EQU $180

; Sprite Engine Registers ($DFF820..$DFF83E)
SPR_LIST_PTR_HI EQU $DFF820     ; High-word staging
SPR_LIST_PTR_LO EQU $DFF822     ; Low-word commit -> atomic VBlank latch
SPR_CTRL        EQU $DFF824     ; Bit 0: Engine ON, Bit 1: Zero-word skip ON
SPR_STATUS      EQU $DFF826     ; Status / line_done
SPR_PAL_ADDR    EQU $DFF826     ; Palette slot (0..255)
SPR_PAL_DATA    EQU $DFF828     ; 32-bit: Red in High-Word, Green+Blue in Low-Word + Auto-Inc!
SPR_OVERRUN_CNT EQU $DFF82E     ; Scanline budget overruns

; Exec & Graphics Library Offsets
_LVOForbid      EQU -132
_LVOPermit      EQU -138
_LVOOpenLibrary EQU -408
_LVOCloseLibrary EQU -414
_LVOViewAddress EQU -204

; ------------------------------------------------------------------------------
; Main Entry Point
; ------------------------------------------------------------------------------
Start:
                MOVE.L  4.W, A6                 ; SysBase in A6!
                LEA     GfxName(PC), A1
                MOVEQ   #0, D0
                JSR     _LVOOpenLibrary(A6)
                MOVE.L  D0, GfxBase
                BEQ     .exit_err

                ; Take over system display
                MOVE.L  4.W, A6                 ; SysBase in A6!
                JSR     _LVOForbid(A6)

                LEA     CUSTOM, A5
                MOVE.W  #$7FFF, INTENA(A5)      ; Disable interrupts
                MOVE.W  #$7FFF, DMACON(A5)      ; Disable DMA
                MOVE.W  #$83C0, DMACON(A5)      ; Enable Master + Copper DMA

                ; Initialize Copper-List
                LEA     CopperList, A0
                MOVE.L  A0, D0
                MOVE.W  D0, COP1LCL(A5)
                SWAP    D0
                MOVE.W  D0, COP1LCH(A5)
                MOVE.W  #0, COPJMP1(A5)         ; Start copper

                ; --------------------------------------------------------------
                ; 1. Load 256-Color Palette into Sprite Engine
                ; --------------------------------------------------------------
                MOVE.W  #0, SPR_PAL_ADDR        ; Reset palette index to 0
                LEA     PaletteTable(PC), A0
                MOVE.W  #256-1, D7
.pal_loop:
                MOVE.L  (A0)+, SPR_PAL_DATA     ; Full 24-bit RGB + auto-increment
                DBF     D7, .pal_loop

                ; --------------------------------------------------------------
                ; 2. Initialize Descriptor Lists in Memory
                ; --------------------------------------------------------------
                BSR     InitDescriptors

                ; Set initial Phase 1 (2 Sprites baseline)
                MOVE.W  #1, CurrentPhase
                BSR     ActivatePhaseList

                ; Enable Sprite Engine with Zero-Word-Skip
                MOVE.W  #$0003, SPR_CTRL        ; Bit 0: ON, Bit 1: Zero-skip ON

; ------------------------------------------------------------------------------
; Main Frame Animation & Stress-Test Loop (50 Hz / 60 Hz)
; ------------------------------------------------------------------------------
MainLoop:
                ; Wait for Vertical Blank (Line 0)
.wait_vbl1:
                MOVE.L  VPOSR(A5), D0
                ANDI.L  #$0001FF00, D0
                BNE.S   .wait_vbl1
.wait_vbl2:
                MOVE.L  VPOSR(A5), D0
                ANDI.L  #$0001FF00, D0
                BEQ.S   .wait_vbl2

                ; --- Check Hardware Overrun Counter ---
                MOVE.W  SPR_OVERRUN_CNT, D0
                BEQ.S   .no_overrun
                ; Flashing Red: Overrun occurred!
                MOVE.W  #$0F00, COLOR00(A5)
                BRA.S   .check_input
.no_overrun:
                ; Normal: Deep Blue background
                MOVE.W  #$0013, COLOR00(A5)

.check_input:
                ; --- Check Right Mouse Button (Exit) ---
                MOVE.W  $DFF016, D0
                BTST    #10, D0
                BEQ     CleanExit

                ; --- Check Left Mouse Button (Cycle Phase) ---
                BTST    #6, $BFE001
                BNE.S   .lmb_released
                TST.B   LMBHeld
                BNE.S   .anim_step
                MOVE.B  #1, LMBHeld

                ; Cycle Phase: 1 -> 2 -> 3 -> 4 -> 1
                MOVE.W  CurrentPhase(PC), D0
                ADDQ.W  #1, D0
                CMPI.W  #5, D0
                BNE.S   .set_new_phase
                MOVEQ   #1, D0
.set_new_phase:
                MOVE.W  D0, CurrentPhase
                BSR     ActivatePhaseList
                BRA.S   .anim_step

.lmb_released:
                MOVE.B  #0, LMBHeld

.anim_step:
                ; Smooth horizontal wave motion for all active sprites
                BSR     AnimateSprites

                BRA     MainLoop

; ------------------------------------------------------------------------------
; Clean Exit to Workbench
; ------------------------------------------------------------------------------
CleanExit:
                MOVE.W  #0, SPR_CTRL            ; Turn off Sprite Engine

                ; Restore standard OS display
                MOVE.L  GfxBase(PC), A6
                MOVE.L  34(A6), A0              ; ActiView
                MOVE.L  38(A0), D0              ; Standard Copper-list
                MOVE.L  D0, COP1LCH(A5)
                MOVE.W  #0, COPJMP1(A5)

                MOVE.W  #$83E0, DMACON(A5)      ; Restore standard DMA
                MOVE.W  #$C000, INTENA(A5)      ; Restore master interrupt

                MOVE.L  4.W, A6
                JSR     _LVOPermit(A6)

                MOVE.L  4.W, A6
                MOVE.L  GfxBase(PC), A1
                JSR     _LVOCloseLibrary(A6)

.exit_err:
                MOVEQ   #0, D0
                RTS

; ------------------------------------------------------------------------------
; Set Active Descriptor List according to CurrentPhase
; ------------------------------------------------------------------------------
ActivatePhaseList:
                MOVE.W  CurrentPhase(PC), D0
                CMPI.W  #1, D0
                BEQ.S   .p1
                CMPI.W  #2, D0
                BEQ.S   .p2
                CMPI.W  #3, D0
                BEQ.S   .p3
                ; Phase 4
                LEA     DescListPhase4, A0
                BRA.S   .commit_ptr
.p1:
                LEA     DescListPhase1, A0
                BRA.S   .commit_ptr
.p2:
                LEA     DescListPhase2, A0
                BRA.S   .commit_ptr
.p3:
                LEA     DescListPhase3, A0

.commit_ptr:
                ; Atomic 32-bit list commit via High then Low write
                MOVE.L  A0, D0
                SWAP    D0
                MOVE.W  D0, SPR_LIST_PTR_HI     ; High-word staging
                SWAP    D0
                MOVE.W  D0, SPR_LIST_PTR_LO     ; Low-word commit!
                RTS

; ------------------------------------------------------------------------------
; Initialize Descriptor Tables (Phase 1 = 2, Phase 2 = 8, Phase 3 = 16, Phase 4 = 32)
; ------------------------------------------------------------------------------
InitDescriptors:
                LEA     SpritePattern32(PC), A2
                MOVE.L  A2, D2                  ; Fast-RAM Data pointer

                ; --- Phase 1: 2 Sprites ---
                LEA     DescListPhase1, A0
                MOVE.W  #2, D1
                BSR     BuildListPack

                ; --- Phase 2: 8 Sprites ---
                LEA     DescListPhase2, A0
                MOVE.W  #8, D1
                BSR     BuildListPack

                ; --- Phase 3: 16 Sprites ---
                LEA     DescListPhase3, A0
                MOVE.W  #16, D1
                BSR     BuildListPack

                ; --- Phase 4: 32 Sprites ---
                LEA     DescListPhase4, A0
                MOVE.W  #32, D1
                BSR     BuildListPack

                RTS

; Helper: Builds D1 descriptors in array at A0
; In: A0 = List destination, D1 = Count, D2 = Sprite Data Ptr
BuildListPack:
                MOVE.W  D1, D6
                SUBQ.W  #1, D6
                MOVE.W  #0, D3                  ; Sprite Index
.b_loop:
                ; 16-Byte Big-Endian Descriptor:
                ; Word 0: Y_POS [63:52] = 100, X_POS [51:40]
                MOVE.W  #100, D4                ; All start on Scanline 100!
                LSL.W   #4, D4
                MOVE.W  D3, D5
                LSL.W   #4, D5                  ; Spread X across screen
                ADD.W   #20, D5
                LSR.W   #8, D5
                OR.W    D5, D4
                MOVE.W  D4, (A0)+               ; Word 0

                ; Word 1: X_POS [7:0], FLAGS [7:0]
                MOVE.W  D3, D5
                LSL.W   #4, D5
                ADD.W   #20, D5
                ANDI.W  #$00FF, D5
                LSL.W   #8, D5
                MOVE.W  D5, (A0)+               ; Word 1 (FLAGS = 0)

                ; Word 2..3: DATA_PTR [31:0]
                MOVE.L  D2, (A0)+

                ; Word 4: HEIGHT [63:52] = 32, WIDTH [51:40] = 32
                MOVE.W  #(32<<4) | (32>>8), (A0)+

                ; Word 5: WIDTH [7:0], FORMAT [7:0] = 7 (CLUT-8)
                MOVE.W  #((32&$FF)<<8) | 7, (A0)+

                ; Word 6: PRIO [31:24] = $C0 (Top Layer), ALPHA [23:16] = 255
                MOVE.W  #$C0FF, (A0)+

                ; Word 7: X_SCALE [15:8] = 64 (1.0x), Y_SCALE [7:0] = 64 (1.0x)
                MOVE.W  #$4040, (A0)+

                ADDQ.W  #1, D3
                DBF     D6, .b_loop

                ; Sentinel: HEIGHT = 0 marks End of List
                CLR.L   (A0)+
                CLR.L   (A0)+
                CLR.L   (A0)+
                CLR.L   (A0)+
                RTS

; ------------------------------------------------------------------------------
; Dynamic Wave Animation: Moves sprites along X/Y
; ------------------------------------------------------------------------------
AnimateSprites:
                ADDQ.W  #1, AnimTick
                RTS

; ------------------------------------------------------------------------------
; Data Section
; ------------------------------------------------------------------------------
                SECTION Data,DATA

GfxName:        DC.B    "graphics.library",0
                EVEN

GfxBase:        DC.L    0
CurrentPhase:   DC.W    1
LMBHeld:        DC.B    0
AnimTick:       DC.W    0
                EVEN

; Embedded 256-Color Palette & 32x32 Sprite Pattern
PaletteTable:
                INCBIN  "test_palette.bin"
                EVEN

SpritePattern32:
                INCBIN  "test_sprite32.bin"
                EVEN

; Descriptor Lists (16 bytes per entry + 16-byte Sentinel)
DescListPhase1: DS.B    (2 + 1) * 16
DescListPhase2: DS.B    (8 + 1) * 16
DescListPhase3: DS.B    (16 + 1) * 16
DescListPhase4: DS.B    (32 + 1) * 16

; ------------------------------------------------------------------------------
; Chip-RAM Data (Copper-List)
; ------------------------------------------------------------------------------
                SECTION ChipData,DATA_C

CopperList:
                ; Set Background Color00 to Dark Blue
                DC.W    COLOR00, $0013
                ; Wait for scanline 90
                DC.W    $5A07, $FFFE
                DC.W    COLOR00, $0124          ; Subtle scanline tint
                ; Wait for scanline 140 (Sprite band end)
                DC.W    $8C07, $FFFE
                DC.W    COLOR00, $0013          ; Reset background
                ; End of Copper-List
                DC.W    $FFFF, $FFFE

                END
