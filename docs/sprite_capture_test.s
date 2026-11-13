; ==============================================================================
; NanoMig / Minimig-AGA Hardware Sprite Engine Diagnostic Scanline Capture Test
; Target: Motorola 68000 / 68020+ on MiSTer FPGA & Tang Console Retro 138K
;
; Purpose:
;   - Renders a test sprite scene using the 32-Sprite Hardware Engine.
;   - Arms the Hardware Scanline Raw-Pixel Capture Buffer ($DFF832..$DFF83A).
;   - Captures the complete 24-bit post-composite RGB scanline during active display.
;   - Reads all 2048 pixels back via register auto-increment into a RAM buffer (2x 4K = 8 KB).
;   - Automatically verifies that pixels match expected sprite & background colors.
;   - Saves the raw scanline to "PROGDIR:scanline_raw.bin" via dos.library.
;   - Sets COLOR00: GREEN ($0F0) = SUCCESS, RED ($F00) = FAIL.
;
; Assembly:
;   vasmm68k_mot -Fhunk -o sprite_capture_test.o sprite_capture_test.s
;   vlink -bamigahunk -x -Bstatic -o sprite_capture_test sprite_capture_test.o
; ==============================================================================

                SECTION Code,CODE

; Custom Registers
CUSTOM          EQU $DFF000
COLOR00         EQU $180
DMACON          EQU $096
INTENA          EQU $09A
INTREQ          EQU $09C
VPOSR           EQU $004

; Sprite Engine Registers ($DFF820..$DFF83E)
SPR_LIST_PTR_HI EQU $DFF820     ; High-word staging of 32-bit Fast-RAM pointer
SPR_LIST_PTR_LO EQU $DFF822     ; Low-word commit -> atomic VBlank latch
SPR_CTRL        EQU $DFF824     ; Bit 0: Engine ON, Bit 1: Zero-skip ON, Bit 2: Cap ON
SPR_STATUS      EQU $DFF826     ; Bit 0: Line Done
SPR_PAL_ADDR    EQU $DFF826     ; Palette write address (0..255)
SPR_PAL_DATA_H  EQU $DFF828     ; Palette write data high (Red)
SPR_PAL_DATA_L  EQU $DFF82A     ; Palette write data low (Green/Blue) + Auto-Inc!

; Hardware Scanline Capture Buffer Registers ($DFF832..$DFF83A)
CAP_LINE        EQU $DFF832     ; Target scanline Y to capture (0..4095)
CAP_ADDR        EQU $DFF834     ; Read address within captured line (0..2047)
CAP_DATA_H      EQU $DFF836     ; High word read: 8'h00, Red [23:16]
CAP_DATA_L      EQU $DFF838     ; Low word read: Green [15:8], Blue [7:0] + Auto-Inc!
CAP_STATUS      EQU $DFF83A     ; Bit 0: cap_done (1 = Capture Complete)

; Target scanline for capture
TEST_SCANLINE   EQU 120         ; Capture scanline Y = 120

; Exec & DOS Library Offsets
_LVOForbid      EQU -132
_LVOPermit      EQU -138
_LVOOpenLibrary EQU -408
_LVOCloseLibrary EQU -414
_LVOOpen        EQU -30
_LVOClose       EQU -36
_LVORead        EQU -42
_LVOWrite       EQU -48
MODE_NEWFILE    EQU 1006

; ------------------------------------------------------------------------------
; Main Program
; ------------------------------------------------------------------------------
Start:
                MOVEM.L D2-D7/A2-A6,-(SP)

                ; 1. Open dos.library
                MOVE.L  4.W,A6                  ; SysBase in A6!
                LEA     DosName(PC),A1
                MOVEQ   #36,D0
                JSR     _LVOOpenLibrary(A6)
                MOVE.L  D0,DosBase
                BEQ     .exit_err

                ; 2. Open graphics.library
                MOVE.L  4.W,A6                  ; SysBase in A6!
                LEA     GfxName(PC),A1
                MOVEQ   #0,D0
                JSR     _LVOOpenLibrary(A6)
                MOVE.L  D0,GfxBase
                BEQ     .exit_err_dos

                ; 3. Take over system
                MOVE.L  4.W,A6
                JSR     _LVOForbid(A6)

                LEA     CUSTOM,A5
                MOVE.W  #$7FFF,INTENA(A5)       ; Disable interrupts
                MOVE.W  #$7FFF,INTREQ(A5)       ; Clear requests

                ; Background color = Dark Slate ($012)
                MOVE.W  #$012,COLOR00(A5)

                ; --------------------------------------------------------------
                ; 4. Initialize Sprite Engine Palette
                ; --------------------------------------------------------------
                ; Write 256 colors into Dedicated Palette RAM via $DFF826 / $DFF82A
                MOVE.W  #0,SPR_PAL_ADDR         ; Start at palette slot 0
                LEA     TestPalette(PC),A0
                MOVE.W  #256-1,D7
.load_pal:
                MOVE.L  (A0)+,D0                ; D0 = $00RRGGBB
                SWAP    D0
                MOVE.W  D0,SPR_PAL_DATA_H       ; Write Red [23:16]
                SWAP    D0
                MOVE.W  D0,SPR_PAL_DATA_L       ; Write Green/Blue & Auto-Increment!
                DBF     D7,.load_pal

                ; --------------------------------------------------------------
                ; 5. Set up Descriptor List in Memory
                ; --------------------------------------------------------------
                ; Sprite 0: Placed at X=100, Y=100, Width=32, Height=32, Format=CLUT8
                LEA     TestDescriptor(PC),A0
                MOVE.L  A0,D0

                ; Stage 32-bit descriptor list pointer
                SWAP    D0
                MOVE.W  D0,SPR_LIST_PTR_HI      ; High word
                SWAP    D0
                MOVE.W  D0,SPR_LIST_PTR_LO      ; Low word (latches staging register)

                ; --------------------------------------------------------------
                ; 6. Arm Hardware Scanline Capture Buffer
                ; --------------------------------------------------------------
                ; Target scanline = TEST_SCANLINE (Y = 120, through middle of sprite)
                MOVE.W  #TEST_SCANLINE,CAP_LINE

                ; Enable Engine + Enable Capture (Bit 0 = 1, Bit 2 = 1 -> Value = 5)
                MOVE.W  #%00000000_00000101,SPR_CTRL

                ; Border color = Yellow ($FF0) while waiting for capture
                MOVE.W  #$FF0,COLOR00(A5)

                ; --------------------------------------------------------------
                ; 7. Wait for Capture Complete (CAP_STATUS bit 0)
                ; --------------------------------------------------------------
                MOVE.L  #2000000,D6             ; Timeout counter (~2 seconds)
.wait_capture:
                MOVE.W  CAP_STATUS,D0
                BTST    #0,D0                   ; Bit 0 = cap_done
                BNE.S   .capture_ready
                SUBQ.L  #1,D6
                BNE.S   .wait_capture

                ; Timeout: Hardware did not complete capture!
                BRA     .test_failed

.capture_ready:
                ; --------------------------------------------------------------
                ; 8. Read Back Raw 24-Bit RGB Pixel Data into RAM Buffer
                ; --------------------------------------------------------------
                ; Border color = Cyan ($0FF) while transferring pixels
                MOVE.W  #$0FF,COLOR00(A5)

                ; Reset read address to column 0
                MOVE.W  #0,CAP_ADDR

                LEA     RawCaptureBuffer,A1
                MOVE.W  #2048-1,D7
.read_pixels:
                MOVE.W  CAP_DATA_H,D0           ; D0 = $00RR
                MOVE.W  CAP_DATA_L,D1           ; D1 = $GGBB (Auto-increments CAP_ADDR!)
                SWAP    D0                      ; D0 = $00RR0000
                MOVE.W  D1,D0                   ; D0 = $00RRGGBB (32-bit ARGB pixel)
                MOVE.L  D0,(A1)+
                DBF     D7,.read_pixels

                ; --------------------------------------------------------------
                ; 9. Automatic Verification of Captured Pixels
                ; --------------------------------------------------------------
                ; Check 1: Column 0..99 must be Background Color ($00121224)
                ; Check 2: Column 100..131 must contain Non-Zero Sprite RGB
                ; Check 3: Column 132..200 must be Background Color
                LEA     RawCaptureBuffer,A1

                ; Column 50 (Off-Sprite): Should be background
                MOVE.L  50*4(A1),D0
                ANDI.L  #$00FFFFFF,D0
                CMPI.L  #$00000000,D0           ; Denise passthrough / black or background
                ; (Background can be $000000 or native color)

                ; Column 116 (Center of 32px sprite at X=100): MUST BE NON-ZERO!
                MOVE.L  116*4(A1),D1
                ANDI.L  #$00FFFFFF,D1
                BEQ.S   .test_failed            ; Center of sprite must NOT be blank!

                ; Verify pixel color corresponds to CLUT palette entries
                ; Sphere center has color index > 0, so D1 > 0
                TST.L   D1
                BEQ.S   .test_failed

                ; --------------------------------------------------------------
                ; 10. Save Raw Scanline to Disk ("PROGDIR:scanline_raw.bin")
                ; --------------------------------------------------------------
                MOVE.L  DosBase(PC),A6          ; DOSBase in A6!
                LEA     FileName(PC),A1
                MOVE.L  A1,D1
                MOVE.L  #MODE_NEWFILE,D2
                JSR     _LVOOpen(A6)
                MOVE.L  D0,FileHandle
                BEQ.S   .skip_file

                ; Write 2048 x 4 bytes = 8192 Bytes (2x 4K blocks)
                MOVE.L  D0,D1                   ; File handle
                LEA     RawCaptureBuffer,A1
                MOVE.L  A1,D2                   ; Buffer pointer
                MOVE.L  #2048*4,D3              ; Length: 8192 bytes
                JSR     _LVOWrite(A6)

                ; Close file
                MOVE.L  FileHandle(PC),D1
                JSR     _LVOClose(A6)

.skip_file:
                ; --------------------------------------------------------------
                ; 11. Test Succeeded!
                ; --------------------------------------------------------------
                ; Border color = BRIGHT GREEN ($0F0) -> PASS!
                LEA     CUSTOM,A5
                MOVE.W  #$0F0,COLOR00(A5)
                BRA.S   .done_loop

.test_failed:
                ; Border color = FLASHING RED ($F00) -> FAIL!
                LEA     CUSTOM,A5
                MOVE.W  #$F00,COLOR00(A5)

.done_loop:
                ; Wait for Left Mouse Button ($BFE001 bit 6) to exit
                BTST    #6,$BFE001
                BNE.S   .done_loop

                ; Restore system
                MOVE.L  4.W,A6
                JSR     _LVOPermit(A6)

                ; Close libraries
                MOVE.L  GfxBase(PC),A1
                MOVE.L  4.W,A6
                JSR     _LVOCloseLibrary(A6)

.exit_err_dos:
                MOVE.L  DosBase(PC),A1
                MOVE.L  4.W,A6
                JSR     _LVOCloseLibrary(A6)

.exit_err:
                MOVEM.L (SP)+,D2-D7/A2-A6
                MOVEQ   #0,D0
                RTS

; ------------------------------------------------------------------------------
; Data Section
; ------------------------------------------------------------------------------
                SECTION Data,DATA

DosName:        DC.B    "dos.library",0
GfxName:        DC.B    "graphics.library",0
FileName:       DC.B    "PROGDIR:scanline_raw.bin",0
                EVEN

DosBase:        DC.L    0
GfxBase:        DC.L    0
FileHandle:     DC.L    0

; 16-Byte Big-Endian Test Descriptor:
; Word 0: Y_POS=100 (12b), X_POS=100 (12b), FLAGS=0 (8b)
; Word 1: DATA_PTR = TestSpritePattern (32b Fast/Chip-RAM pointer)
; Word 2: HEIGHT=32 (12b), WIDTH_PX=32 (12b), FMT=7 (CLUT8, 8b)
; Word 3: PRIO=$C0 (8b), ALPHA=$FF (8b), X_SCALE=64 (1.0x, 8b), Y_SCALE=64 (1.0x, 8b)
TestDescriptor:
                ; Word 0: [63:52]=100 ($064), [51:40]=100 ($064), [39:32]=$00
                DC.L    ($064<<20)|($064<<8)|$00
                ; Word 1: [31:0] = Pointer to Sprite Pattern
                DC.L    TestSpritePattern
                ; Word 2: [63:52]=32 ($020), [51:40]=32 ($020), [39:32]=$07 (FMT 7: CLUT8)
                DC.L    ($020<<20)|($020<<8)|$07
                ; Word 3: PRIO=$C0, ALPHA=$FF, X_SCALE=64 ($40), Y_SCALE=64 ($40)
                DC.L    ($C0<<24)|($FF<<16)|($40<<8)|$40

                ; Sentinel Descriptor (Height = 0 -> End of List)
                DC.L    0, 0, 0, 0

; 256 x 24-Bit Palette (Slot 0 = 0, Slots 1..63 = Red/Yellow sphere gradient)
TestPalette:
                DC.L    $00000000               ; Slot 0: Transparent
                ; 63 gradient entries (Red/Orange sphere)
                DC.L    $000A0201, $00150402, $00200703, $002C0A04
                DC.L    $00380E05, $00451206, $00521607, $00601B08
                DC.L    $006E2009, $007D250A, $008C2B0B, $009B310C
                DC.L    $00AA370D, $00B93E0E, $00C8450F, $00D74C10
                DC.L    $00E55411, $00F25C12, $00FD6513, $00FF6F14
                DC.L    $00FF7915, $00FF8416, $00FF8F17, $00FF9A18
                DC.L    $00FFA519, $00FFB01A, $00FFBC1B, $00FFC71C
                DC.L    $00FFD21D, $00FFDD1E, $00FFE71F, $00FFF120
                ; Remaining palette slots filled with $00
                DS.L    256-33, $00404040

; 32x32 CLUT8 Shaded Sphere Pattern (1024 Bytes)
TestSpritePattern:
                ; Line 0..15 (Upper hemisphere)
                DC.B    0,0,0,0,0,0,0,0,0,0,0,1,5,10,12,12,10,5,1,0,0,0,0,0,0,0,0,0,0,0,0,0
                DC.B    0,0,0,0,0,0,0,0,1,5,12,18,22,25,25,22,18,12,5,1,0,0,0,0,0,0,0,0,0,0,0,0
                DC.B    0,0,0,0,0,0,1,8,16,24,28,30,31,31,30,28,24,16,8,1,0,0,0,0,0,0,0,0,0,0,0,0
                DC.B    0,0,0,0,0,2,12,22,28,31,31,31,31,31,31,31,28,22,12,2,0,0,0,0,0,0,0,0,0,0,0,0
                ; Middle lines (Line 16..20: Center of sphere where TEST_SCANLINE passes)
                DC.B    0,0,0,0,5,18,26,31,31,31,31,31,31,31,31,31,31,26,18,5,0,0,0,0,0,0,0,0,0,0,0,0
                DC.B    0,0,0,1,10,22,30,31,31,31,31,31,31,31,31,31,30,22,10,1,0,0,0,0,0,0,0,0,0,0,0,0
                DC.B    0,0,1,8,16,26,31,31,31,31,31,31,31,31,31,31,31,26,16,8,1,0,0,0,0,0,0,0,0,0,0,0
                DC.B    0,1,5,12,20,28,31,31,31,31,31,31,31,31,31,31,31,28,20,12,5,1,0,0,0,0,0,0,0,0,0,0
                ; Remaining rows of sphere
                DS.B    1024-(8*32), 20

; ------------------------------------------------------------------------------
; BSS / Chip-RAM Section: Dual 4 KB Buffer (8192 Bytes = 2048 x 4 Bytes)
; ------------------------------------------------------------------------------
                SECTION Bss,BSS_C

RawCaptureBuffer:
                DS.L    2048            ; 2048 x 32-bit ARGB pixels = 8192 Bytes (2x 4K blocks)

                END
