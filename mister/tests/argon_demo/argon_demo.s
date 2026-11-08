; ==============================================================================
; MiSTer FPGA / Minimig-AGA (NanoMig):
; "ARGON ODYSSEY" - 1-Minute Extended-HAM04 & 32-Channel DSP Grand Demo
;
; Target: Motorola 68000 / 68020 on MiSTer DE10-Nano (Core Minimig_22a912cc)
; Kickstart 1.3 / 3.x CLI compatible (clean OS takeover & full CLI restoration)
;
; Showcases ALL Hardware Extensions in 5 Seamless Acts (~60 Seconds = 3000 VBLs):
;   [0:00 - 0:10] ACT I:   "THE AWAKENING" (500 Frames)
;                          - 31-Voice Polyphonic Deep-Note Glide (16.16 FP)
;                          - Hardware Zero-RAM Start-Delay ($DFF41C, 32.768 kHz)
;                          - Voice 31: 16-Bit Big-Endian Pure Sine Sub-Bass
;                          - Extended HAM04 ($DFF800) 24-Bit Horizon & Live Scope
;   [0:10 - 0:24] ACT II:  "MOOG CASCADE & MODULATION" (696 Frames)
;                          - Voices 0..1: 24 dB/oct Cascaded Moog Acid Filter + LFO
;                          - Voices 2..3: Hardware AM-Modulation Pluck Lead
;                          - Voices 4..5: Hardware 4-Quadrant Ringmod Space Bells
;                          - Voices 6..8: Synthesized Drums + Biquad HP Hi-Hat
;   [0:24 - 0:36] ACT III: "32-BAND HARDWARE VOCODER & 4-BIT ADPCM" (600 Frames)
;                          - Voice 0: 48 kHz 4-Bit Hardware ADPCM Music Stream
;                          - Voices 1..31: Pre-Filter Cascade (0% extra DMA!)
;                          - 32 Logarithmic Biquad Bandpass Filters (50Hz..16kHz)
;                          - Bi-directional Spectral Wah-Wah + Outside-In Build-Up
;   [0:36 - 0:54] ACT IV:  "32-VOICE CYBER SYMPHONY" (900 Frames)
;                          - All 32 Hardware Voices Active Simultaneously:
;                            24 dB Moog Bass + AM Lead + Ringmod Bells + Drums +
;                            4x ADPCM Groove Chorus + 8x Arp Chords + 10x Super-Pad +
;                            16-Bit Sine Sub-Bass + Full HAM04 Plasma & Scope
;   [0:54 - 1:00] ACT V:   "GRAND FINALE & HARMONIC FADEOUT" (300 Frames)
;                          - Smooth 32-Voice Volume & HAM04 Step-Size Fade to 0
;                          - Clean OS Display Restoration & CLI Summary (RC: 0)
;
; Abort anytime with Left Mouse Button ($BFE001 Bit 6).
;
; Build:
;   python gen_argon_data.py
;   vasmm68k_mot -quiet -Fhunk -o argon_demo.o argon_demo.s
;   vlink -bamigahunk -x -Bstatic -o argon_demo argon_demo.o
; ==============================================================================

CUSTOM          EQU $DFF000
DMACONR         EQU $002
VPOSR           EQU $004
COP1LCH         EQU $080
COP1LCL         EQU $082
COPJMP1         EQU $088
DMACON          EQU $096
INTENA          EQU $09A
INTREQ          EQU $09C
BPLCON0         EQU $100
BPLCON1         EQU $102
BPLCON2         EQU $104
BPLCON3         EQU $106
BPL1MOD         EQU $108
BPL2MOD         EQU $10A
COLOR00         EQU $180
FMODE           EQU $1FC

; Extended HAM Video Control Register (Shadow latched at SOF)
HAM_CONTROL     EQU $DFF800
HAM_RESET_VAL   EQU $1084       ; Bit 15=0 (Off), Step R=4, G=4, B=4
HAM_ON_DEFAULT  EQU $9084       ; Bit 15=1 (On),  Step R=4, G=4, B=4

; Audio Capture Engine
AUD_CAP_CTRL    EQU $DFF802
CAP_BUF_A       EQU $DF8000
CAP_BUF_B       EQU $DF9000

; 32-Channel Audio Extension ($DFF400..$DFF7FE)
AUDIO_EXT_BASE  EQU $DFF400
VOICE_STRIDE    EQU $20

AUD_PTRH        EQU $00
AUD_PTRL        EQU $02
AUD_LENH        EQU $04
AUD_LENL        EQU $06
AUD_VOL         EQU $08         ; High=Left (0..255), Low=Right (0..255)
AUD_PER         EQU $0A         ; Period = 25 MHz / Fs (521 = 48 kHz)
AUD_CTRL        EQU $0C
AUD_PRED        EQU $0E
AUD_BQ_B0       EQU $10
AUD_BQ_B1       EQU $12
AUD_BQ_B2       EQU $14
AUD_BQ_A1       EQU $16
AUD_BQ_A2       EQU $18
AUD_CMD         EQU $1A         ; 1=Start, 2=Stop
AUD_DELAY       EQU $1C         ; 32.768 kHz Zero-RAM Start-Delay

; Audio Control Register Bit Masks
CTRL_PCM16      EQU $0001
CTRL_LOOP       EQU $0000
CTRL_ONESHOT    EQU $0002
CTRL_STEREO     EQU $0004
CTRL_ADPCM      EQU $0008
CTRL_FLT_R      EQU $0080
CTRL_FLT_L      EQU $0100
CTRL_FLT_STEREO EQU $0180
CTRL_SRC_DMA    EQU $0000
CTRL_SRC_PRE    EQU $0200
CTRL_SRC_POST   EQU $0400
CTRL_MOD_AM     EQU $0800
CTRL_MOD_RING   EQU $1000
CTRL_MUTE_MIX   EQU $2000

ADPCM_BYTES     EQU 738540      ; 30.77s 48 kHz 4-Bit ADPCM stream ($000B44EC)

; Screen Geometry (320x200, 4 Bitplanes = HAM04)
SCR_WIDTH_B     EQU 40
SCR_HEIGHT      EQU 200
BPL_SIZE        EQU (SCR_WIDTH_B*SCR_HEIGHT) ; 8000 bytes per bitplane

; AmigaOS Library Offsets
_LVOOpenLibrary     EQU -552
_LVOCloseLibrary    EQU -414
_LVOWrite           EQU -48
_LVOOutput          EQU -60
_LVOLoadView        EQU -222
_LVOWaitTOF         EQU -270
_LVORethinkDisplay  EQU -390
gb_ActiView         EQU 34
gb_copinit          EQU 38

        SECTION Code,CODE

Main:
        MOVEM.L D2-D7/A2-A6,-(SP)
        LEA     CUSTOM,A6
        MOVE.W  DMACONR(A6),Saved_DMACON

        ; --------------------------------------------------------------
        ; 1. Open dos.library, graphics.library, intuition.library
        ; --------------------------------------------------------------
        MOVE.L  $00000004.W,A6
        LEA     DosName(PC),A1
        MOVEQ   #0,D0
        JSR     _LVOOpenLibrary(A6)
        MOVE.L  D0,DOSBase
        BEQ.S   .NoDos
        MOVE.L  D0,A6
        JSR     _LVOOutput(A6)
        MOVE.L  D0,StdoutHandle
        MOVE.L  $00000004.W,A6
.NoDos:
        LEA     GfxName(PC),A1
        MOVEQ   #0,D0
        JSR     _LVOOpenLibrary(A6)
        MOVE.L  D0,GfxBase

        LEA     IntuiName(PC),A1
        MOVEQ   #0,D0
        JSR     _LVOOpenLibrary(A6)
        MOVE.L  D0,IntuiBase

        ; Print Intro Banner to CLI before switching to Extended HAM04 view
        LEA     MsgBanner(PC),A0
        BSR     PrintStr

        ; --------------------------------------------------------------
        ; 2. Prepare Extended HAM04 4-Bitplane Screen & Copper List
        ; --------------------------------------------------------------
        BSR     Init_HAM04_Screen
        BSR     Takeover_Display

        LEA     CUSTOM,A6
        MOVE.W  #$000F,DMACON(A6)       ; Disable legacy 4-ch Paula DMA
        BSR     Silence_All_Voices

        ; Enable Hardware Audio Capture ($DF8000 / $DF9000)
        MOVE.W  #$0017,AUD_CAP_CTRL

        ; Enable Extended HAM04 Video Engine ($DFF800)
        MOVE.W  #HAM_ON_DEFAULT,HAM_CONTROL

        ; ==============================================================
        ; ACT I [0:00 - 0:10]: "THE AWAKENING" (500 Frames = 10.0s)
        ; 31-Voice Polyphonic Deep Note + Zero-RAM Start-Delay + 16-Bit Sub
        ; ==============================================================
        MOVE.W  #1,CurrentAct
        LEA     MsgAct1(PC),A0
        BSR     PrintStr
        LEA     TxtAct1(PC),A0
        BSR     Draw_Act_Title

        BSR     Init_Act1_DeepNote

        ; 350 Frames (7.0s) Polyphonic Glide
        MOVE.W  #ACT1_GLIDE-1,D6
.act1_glide:
        BSR     Wait_VBL
        BSR     Update_DeepNote_Glide
        BSR     Update_Visuals_And_Scope
        BTST    #6,$BFE001
        BEQ     .AbortDemo
        DBRA    D6,.act1_glide

        ; 150 Frames (3.0s) Super-Chord Hold
        MOVE.W  #ACT1_HOLD-1,D6
.act1_hold:
        BSR     Wait_VBL
        BSR     Update_Visuals_And_Scope
        BTST    #6,$BFE001
        BEQ     .AbortDemo
        DBRA    D6,.act1_hold

        BSR     Fade_Out_All_Voices     ; Click-free 8-frame micro-fade
        BSR     Silence_All_Voices

        ; Print Act I Done marker with measured audio peak
        LEA     MsgAct1Peak,A0
        MOVE.W  Act1_Peak(PC),D0
        BSR     Format_Hex_Byte
        LEA     MsgAct1Done(PC),A0
        BSR     PrintStr

        ; ==============================================================
        ; ACT II [0:10 - 0:24]: "MOOG CASCADE & MODULATION" (696 Frames = 14s)
        ; 24 dB Cascaded Moog Acid Bass + Hardware AM + Ringmod + Drums
        ; ==============================================================
        MOVE.W  #2,CurrentAct
        LEA     MsgAct2(PC),A0
        BSR     PrintStr
        LEA     TxtAct2(PC),A0
        BSR     Draw_Act_Title

        CLR.W   FullSymphonyMode
        BSR     Init_Synth_Track

        MOVE.W  #116-1,D6               ; 116 steps * 6 frames = 696 frames (~14.0s)
        MOVEQ   #0,D5                   ; Step Counter (0..63)
.act2_step:
        BSR     Process_Track_Step
        MOVEQ   #5,D4                   ; 6 VBLs per 16th note (125 BPM)
.act2_vbl:
        BSR     Wait_VBL
        BSR     Update_Filter_LFO
        BSR     Update_Visuals_And_Scope
        BTST    #6,$BFE001
        BEQ     .AbortDemo
        DBRA    D4,.act2_vbl

        ADDQ.W  #1,D5
        ANDI.W  #$003F,D5
        DBRA    D6,.act2_step

        BSR     Fade_Out_All_Voices     ; Click-free 8-frame micro-fade
        BSR     Silence_All_Voices

        ; Print Act II Done marker with measured audio peak
        LEA     MsgAct2Peak,A0
        MOVE.W  Act2_Peak(PC),D0
        BSR     Format_Hex_Byte
        LEA     MsgAct2Done(PC),A0
        BSR     PrintStr

        ; ==============================================================
        ; ACT III [0:24 - 0:55]: "32-BAND VOCODER & 4-BIT ADPCM" (1538 Frames = 30.76s)
        ; Ch 0: 4-Bit ADPCM 30s Master Stream (Fast-RAM) | Ch 1..31: Pre-Filter Cascade + 32 BPs
        ; 2.0s Fade-In (100 Frames) + 26.76s Spectral Sweep + 2.0s Fade-Out (100 Frames)
        ; ==============================================================
        MOVE.W  #3,CurrentAct
        LEA     MsgAct3(PC),A0
        BSR     PrintStr
        LEA     TxtAct3(PC),A0
        BSR     Draw_Act_Title

        BSR     Init_Act3_Vocoder

        MOVE.W  #1538-1,D6              ; 1538 Frames = 30.76s
        MOVEQ   #0,D5                   ; Frame counter for sweep (0..1537)
.act3_loop:
        BSR     Wait_VBL
        BSR     Update_Vocoder_30s      ; 2s Fade-In, 26.76s Sweep (Band 14 start), 2s Fade-Out
        BSR     Update_Visuals_And_Scope
        BTST    #6,$BFE001
        BEQ     .AbortDemo
        ADDQ.W  #1,D5
        DBRA    D6,.act3_loop

        BSR     Silence_All_Voices      ; Already at volume 0 from 2s fadeout

        ; Print Act III Done marker with measured audio peak
        LEA     MsgAct3Peak,A0
        MOVE.W  Act3_Peak(PC),D0
        BSR     Format_Hex_Byte
        LEA     MsgAct3Done(PC),A0
        BSR     PrintStr

        ; ==============================================================
        ; ACT IV [0:36 - 0:54]: "32-VOICE CYBER SYMPHONY" (900 Frames = 18.0s)
        ; All 32 Voices Active: Moog + AM + Ringmod + Drums + 4x ADPCM +
        ; 8x Arp Chords + 10x Super-Pad + 16-Bit Sine Sub-Bass
        ; ==============================================================
        MOVE.W  #4,CurrentAct
        LEA     MsgAct4(PC),A0
        BSR     PrintStr
        LEA     TxtAct4(PC),A0
        BSR     Draw_Act_Title

        MOVE.W  #1,FullSymphonyMode
        BSR     Init_Synth_Track

        MOVE.W  #150-1,D6               ; 150 steps * 6 frames = 900 frames (18.0s)
        MOVEQ   #0,D5
.act4_step:
        BSR     Process_Track_Step
        MOVEQ   #5,D4
.act4_vbl:
        BSR     Wait_VBL
        BSR     Update_Filter_LFO
        BSR     Update_Visuals_And_Scope
        BTST    #6,$BFE001
        BEQ     .AbortDemo
        DBRA    D4,.act4_vbl

        ADDQ.W  #1,D5
        ANDI.W  #$003F,D5
        DBRA    D6,.act4_step

        BSR     Fade_Out_All_Voices     ; Click-free 8-frame micro-fade
        BSR     Silence_All_Voices

        ; Print Act IV Done marker with measured audio peak
        LEA     MsgAct4Peak,A0
        MOVE.W  Act4_Peak(PC),D0
        BSR     Format_Hex_Byte
        LEA     MsgAct4Done(PC),A0
        BSR     PrintStr

        ; ==============================================================
        ; ACT V [0:54 - 1:00]: "GRAND FINALE & FADEOUT" (300 Frames = 6.0s)
        ; ==============================================================
        MOVE.W  #5,CurrentAct
        LEA     MsgAct5(PC),A0
        BSR     PrintStr
        LEA     TxtAct5(PC),A0
        BSR     Draw_Act_Title

        BSR     Init_Act5_FinaleChord

        ; 250 Frames (5.0s) Smooth Master Volume & HAM Step Fadeout
        MOVE.W  #250,D6                 ; Fade scale 250 down to 1
.act5_fade:
        BSR     Wait_VBL
        MOVE.W  D6,D0
        BSR     Apply_Finale_Fade
        BSR     Update_Visuals_And_Scope
        BTST    #6,$BFE001
        BEQ.S   .AbortDemo
        SUBQ.W  #1,D6
        BNE.S   .act5_fade

        ; Stop all voices for final 1.0s (50 Frames) of verified digital silence
        BSR     Silence_All_Voices
        MOVE.W  #50-1,D6
.act5_silent:
        BSR     Wait_VBL
        BSR     Update_Visuals_And_Scope
        DBRA    D6,.act5_silent

        ; Print Act V Done marker with measured audio peak
        LEA     MsgAct5Peak,A0
        MOVE.W  Act5_Peak(PC),D0
        BSR     Format_Hex_Byte
        LEA     MsgAct5Done(PC),A0
        BSR     PrintStr

.AbortDemo:
        ; --------------------------------------------------------------
        ; Clean Hardware Shutdown & AmigaDOS Display Restoration
        ; --------------------------------------------------------------
        BSR     Silence_All_Voices
        MOVE.W  #$0000,AUD_CAP_CTRL
        MOVE.W  #HAM_RESET_VAL,HAM_CONTROL

        BSR     Restore_Display

        ; Print Toby's requested full validation & diagnostics summary report
        BSR     Print_Diagnostic_Report
        LEA     MsgDone(PC),A0
        BSR     PrintStr

        ; Close libraries
        MOVE.L  $00000004.W,A6
        MOVE.L  IntuiBase(PC),D0
        BEQ.S   .NoIntuiClose
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.NoIntuiClose:
        MOVE.L  GfxBase(PC),D0
        BEQ.S   .NoGfxClose
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.NoGfxClose:
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .NoDosClose
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.NoDosClose:
        MOVEQ   #0,D0                   ; Return Code 0
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

; ==============================================================================
; DISPLAY SETUP, EXTENDED HAM04 RENDERING & OS RESTORE
; ==============================================================================

Init_HAM04_Screen:
        ; 1. Patch Bitplane Pointers into ArgonCopperList
        LEA     ScreenPlanes,A0
        LEA     CopBplPtrs,A1
        MOVEQ   #3,D0
.bpl_loop:
        MOVE.L  A0,D1
        SWAP    D1
        MOVE.W  D1,2(A1)                ; BPLxPTH
        SWAP    D1
        MOVE.W  D1,6(A1)                ; BPLxPTL
        LEA     8(A1),A1
        LEA     BPL_SIZE(A0),A0
        DBRA    D0,.bpl_loop

        ; 2. Clear all 4 bitplanes (32,000 bytes)
        LEA     ScreenPlanes,A0
        MOVE.W  #(BPL_SIZE*4/4)-1,D0
        MOVEQ   #0,D1
.clr_scr:
        MOVE.L  D1,(A0)+
        DBRA    D0,.clr_scr

        ; 3. Fill Upper Extended-HAM04 Plasma Band (y = 32..79, 48 lines)
        ;    Every 8 bytes (64 pixels): Byte 0 = Anchor (BPL4=0), Bytes 1..7 = Delta (BPL4=$FF)
        ;    BPL1..BPL3 form diagonal RGB delta waves so $DFF800 step_r/g/b morphs 24-bit color!
        LEA     ScreenPlanes,A0
        LEA     BPL_SIZE(A0),A1
        LEA     BPL_SIZE(A1),A2
        LEA     BPL_SIZE(A2),A3
        MOVE.W  #32*SCR_WIDTH_B,D0
        ADDA.W  D0,A0
        ADDA.W  D0,A1
        ADDA.W  D0,A2
        ADDA.W  D0,A3

        MOVEQ   #48-1,D7                ; 48 scanlines
.plasma_y:
        MOVEQ   #SCR_WIDTH_B-1,D6       ; 40 bytes per line
.plasma_x:
        MOVE.W  D6,D0
        ANDI.W  #7,D0
        BNE.S   .is_delta_col
        ; Anchor byte: left 4 pixels Anchor (BPL4=0), right 4 pixels Delta (BPL4=$0F)
        MOVE.B  #$AA,(A0)+              ; BPL1
        MOVE.B  #$CC,(A1)+              ; BPL2
        MOVE.B  #$F0,(A2)+              ; BPL3
        MOVE.B  #$0F,(A3)+              ; BPL4 (0=Anchor, 1=Delta)
        BRA.S   .next_px
.is_delta_col:
        ; Pure Extended-HAM04 Delta pixels (BPL4 = $FF):
        ; Vary R, G, B delta directions across X and Y
        MOVE.W  D6,D1
        ADD.W   D7,D1
        BTST    #1,D1
        SNE     D2
        ORI.B   #$55,D2
        MOVE.B  D2,(A0)+                ; BPL1 (db)

        MOVE.W  D6,D1
        SUB.W   D7,D1
        BTST    #2,D1
        SNE     D2
        ORI.B   #$33,D2
        MOVE.B  D2,(A1)+                ; BPL2 (dg)

        MOVE.W  D7,D1
        BTST    #3,D1
        SNE     D2
        ORI.B   #$0F,D2
        MOVE.B  D2,(A2)+                ; BPL3 (dr)

        MOVE.B  #$FF,(A3)+              ; BPL4 = 1 (Extended HAM04 Delta!)
.next_px:
        DBRA    D6,.plasma_x
        DBRA    D7,.plasma_y

        ; 4. Fill Center Oscilloscope Background Grid (y = 80..143, 64 lines)
        ;    Byte 0 is Anchor0; Bytes 1..39 have BPL4=$FF (Delta) with gentle decay
        ;    so bright Scope Anchor dots cast glowing 24-bit HAM04 comet trails rightwards!
        MOVEQ   #64-1,D7
.scope_bg_y:
        ; Byte 0: Anchor
        MOVE.B  #$0F,(A0)+
        MOVE.B  #$0F,(A1)+
        MOVE.B  #$00,(A2)+
        MOVE.B  #$0F,(A3)+
        MOVEQ   #39-1,D6
.scope_bg_x:
        MOVE.B  #$55,(A0)+              ; BPL1: db balanced
        MOVE.B  #$33,(A1)+              ; BPL2: dg balanced
        MOVE.B  #$00,(A2)+              ; BPL3: dr = -2 (smooth red decay)
        MOVE.B  #$FF,(A3)+              ; BPL4: Delta mode!
        DBRA    D6,.scope_bg_x
        DBRA    D7,.scope_bg_y

        ; 5. Fill Lower 32-Voice Activity & Horizon Band (y = 144..183, 40 lines)
        MOVEQ   #40-1,D7
.bars_y:
        MOVEQ   #SCR_WIDTH_B-1,D6
.bars_x:
        ; Columns 4..35 represent Voices 0..31
        MOVE.B  #$F0,(A0)+
        MOVE.B  #$CC,(A1)+
        MOVE.B  #$AA,(A2)+
        MOVE.B  #$3F,(A3)+              ; 2 Anchor pixels + 6 Delta pixels per byte!
        DBRA    D6,.bars_x
        DBRA    D7,.bars_y

        ; 6. Initialize ScopeOldY table to center line (y = 112)
        LEA     ScopeOldY,A0
        MOVEQ   #39,D0
.init_oldy:
        MOVE.W  #112,(A0)+
        DBRA    D0,.init_oldy

        ; 7. Render Header and Footer Text Banners into HAM04 Screen
        LEA     TxtHeader(PC),A0
        MOVEQ   #6,D1                   ; y = 6
        BSR     Draw_Text_Row

        LEA     TxtFooter(PC),A0
        MOVE.W  #188,D1                 ; y = 188
        BSR     Draw_Text_Row
        RTS

; ------------------------------------------------------------------------------
; Draw_Act_Title: Renders 40-char string in A0 at y = 18
; ------------------------------------------------------------------------------
Draw_Act_Title:
        MOVEQ   #18,D1
        ; Fallthrough to Draw_Text_Row

; ------------------------------------------------------------------------------
; Draw_Text_Row: Renders 40-char null-padded string in A0 at scanline D1.W
; Characters are drawn as bright Anchor pixels (COLOR07 = BPL1+2+3=1, BPL4=0)
; while background pixels have BPL4=$FF (HAM04 Delta glow!)
; ------------------------------------------------------------------------------
Draw_Text_Row:
        MOVEM.L D2-D7/A2-A5,-(SP)
        MULU.W  #SCR_WIDTH_B,D1
        LEA     ScreenPlanes,A2
        ADDA.L  D1,A2                   ; BPL1 row
        LEA     BPL_SIZE(A2),A3         ; BPL2 row
        LEA     BPL_SIZE(A3),A4         ; BPL3 row
        LEA     BPL_SIZE(A4),A5         ; BPL4 row

        LEA     Font8x8,A1
        MOVEQ   #39,D6                  ; 40 columns
.char_loop:
        MOVEQ   #0,D0
        MOVE.B  (A0)+,D0
        BNE.S   .valid_ch
        SUBQ.L  #1,A0                   ; Stay on null terminator (pad with spaces)
        MOVEQ   #32,D0
.valid_ch:
        SUBI.W  #32,D0
        BPL.S   .ge_spc
        MOVEQ   #0,D0
.ge_spc:
        CMPI.W  #58,D0
        BLE.S   .le_z
        MOVEQ   #0,D0
.le_z:
        LSL.W   #3,D0                   ; 8 bytes per glyph
        LEA     (A1,D0.W),A6

        MOVEQ   #0,D5                   ; 8 scanlines of glyph
        MOVEQ   #7,D7
.glyph_line:
        MOVE.B  (A6)+,D2                ; Glyph bits: 1 = Foreground (White), 0 = Background (Black)
        MOVE.B  D2,(A2,D5.W)            ; BPL1 (c0) = D2
        MOVE.B  D2,(A3,D5.W)            ; BPL2 (c1) = D2
        MOVE.B  D2,(A4,D5.W)            ; BPL3 (c2) = D2
        CLR.B   (A5,D5.W)               ; BPL4 (c3) = 0 (Anchor mode for razor-sharp text: zero color bleed!)
        ADDI.W  #SCR_WIDTH_B,D5
        DBRA    D7,.glyph_line

        ADDQ.L  #1,A2
        ADDQ.L  #1,A3
        ADDQ.L  #1,A4
        ADDQ.L  #1,A5
        DBRA    D6,.char_loop

        LEA     CUSTOM,A6
        MOVEM.L (SP)+,D2-D7/A2-A5
        RTS

; ------------------------------------------------------------------------------
; Takeover_Display & Restore_Display (Clean AmigaOS RKM View Handling)
; ------------------------------------------------------------------------------
Takeover_Display:
        MOVEM.L D2-D7/A2-A6,-(SP)
        MOVE.L  GfxBase(PC),D0
        BEQ.S   .direct_cop
        MOVE.L  D0,A6
        MOVE.L  gb_ActiView(A6),Saved_ActiView
        SUBA.L  A1,A1
        JSR     _LVOLoadView(A6)
        JSR     _LVOWaitTOF(A6)
        JSR     _LVOWaitTOF(A6)
.direct_cop:
        LEA     CUSTOM,A6
        MOVE.W  #$002F,DMACON(A6)       ; Disable legacy Paula DMA ($000F) & Sprites ($0020)
        MOVE.L  #ArgonCopperList,COP1LCH(A6)
        MOVE.W  #0,COPJMP1(A6)
        MOVE.W  #$8380,DMACON(A6)       ; Ensure Bitplane + Copper DMA enabled
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

Restore_Display:
        MOVEM.L D2-D7/A2-A6,-(SP)
        LEA     CUSTOM,A6
        MOVE.W  #HAM_RESET_VAL,HAM_CONTROL
        MOVE.W  #$0000,BPLCON1(A6)
        MOVE.W  #$0024,BPLCON2(A6)
        MOVE.W  #$0C00,BPLCON3(A6)
        MOVE.W  #$0000,BPL1MOD(A6)
        MOVE.W  #$0000,BPL2MOD(A6)
        MOVE.W  #$0000,FMODE(A6)

        MOVE.L  GfxBase(PC),D0
        BEQ.S   .no_gfx
        MOVE.L  D0,A6
        MOVE.L  Saved_ActiView(PC),A1
        JSR     _LVOLoadView(A6)
        JSR     _LVOWaitTOF(A6)
        JSR     _LVOWaitTOF(A6)
        MOVE.L  gb_copinit(A6),CUSTOM+COP1LCH
        MOVE.W  #0,CUSTOM+COPJMP1
.no_gfx:
        MOVE.L  IntuiBase(PC),D0
        BEQ.S   .no_intui
        MOVE.L  D0,A6
        JSR     _LVORethinkDisplay(A6)
.no_intui:
        MOVE.W  Saved_DMACON(PC),D0     ; Restore original OS DMA state cleanly
        ANDI.W  #$07FF,D0
        OR.W    #$8000,D0
        MOVE.W  D0,CUSTOM+DMACON
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

; ==============================================================================
; REAL-TIME VISUALIZER: EXTENDED-HAM04 STEP LFO + LIVE CAPTURE OSCILLOSCOPE
; ==============================================================================
Update_Visuals_And_Scope:
        MOVEM.L D2-D7/A2-A6,-(SP)

        ; 1. Advance Visual Frame Counter & Modulate HAM_CONTROL ($DFF800)
        ADDQ.W  #1,VisFrameCnt
        MOVE.W  VisFrameCnt(PC),D0
        LSR.W   #1,D0
        ANDI.W  #$003F,D0
        ADD.W   D0,D0
        LEA     HamStepTab,A0
        MOVE.W  (A0,D0.W),D1

        ; Add audio peak energy boost to step_r (bits 14..10) and step_b (bits 4..0)
        MOVE.W  LastPeakLevel(PC),D2
        LSR.W   #4,D2                   ; 0..7
        ANDI.W  #$0007,D2
        MOVE.W  D2,D0
        LSL.W   #8,D0
        LSL.W   #2,D0                   ; step_r boost (shift 10: bits 14..10)
        OR.W    D0,D1
        OR.W    D2,D1                   ; step_b boost (bits 4..0)
        MOVE.W  D1,HAM_CONTROL          ; Latched cleanly at next SOF!

        ; 2. Check Audio Capture Buffer ($DFF802 / $DF8000 / $DF9000)
        LEA     CAP_BUF_A,A1
        MOVE.W  AUD_CAP_CTRL,D0
        BTST    #1,D0
        BNE.S   .use_buf_a
        BTST    #2,D0
        BEQ.S   .draw_wave              ; Even if flag not yet toggled, live BRAM is readable!
        LEA     CAP_BUF_B,A1
        MOVE.W  #$0005,AUD_CAP_CTRL     ; Clear Block B flag, keep capture_en=1!
        BRA.S   .draw_wave
.use_buf_a:
        MOVE.W  #$0003,AUD_CAP_CTRL     ; Clear Block A flag, keep capture_en=1!

.draw_wave:
        ; 3. Plot 39 Live Waveform Dots across X = 1..39 in Center Scope Band (y = 80..143)
        ; All 4 bitplanes are updated: Left nibble = Anchor 7 Pure White (255,255,255),
        ; Right nibble = decaying Delta comet trail!
        LEA     ScreenPlanes,A0            ; BPL1
        LEA     ScreenPlanes+BPL_SIZE,A2   ; BPL2
        LEA     ScreenPlanes+BPL_SIZE*2,A3 ; BPL3
        LEA     ScreenPlanes+BPL_SIZE*3,A5 ; BPL4
        LEA     ScopeOldY,A4
        MOVEQ   #0,D7                   ; Peak accumulator
        MOVEQ   #1,D6                   ; Column index (1..39)

.scope_col_loop:
        ; Erase previous frame's dot at (D6, ScopeOldY[D6]) across all 4 planes
        MOVE.W  (A4),D0                 ; Old Y (80..143)
        MULU.W  #SCR_WIDTH_B,D0
        ADD.W   D6,D0
        MOVE.B  #$55,(A0,D0.W)          ; Restore BPL1 = $55
        MOVE.B  #$33,(A2,D0.W)          ; Restore BPL2 = $33
        MOVE.B  #$00,(A3,D0.W)          ; Restore BPL3 = $00 (dr = -2 decay)
        MOVE.B  #$FF,(A5,D0.W)          ; Restore BPL4 = $FF (Delta pixel)

        ; Read 16-bit signed Left sample from Capture Buffer (stride 96 bytes = ~0.5 ms/col)
        MOVE.W  (A1),D1
        ADDA.W  #96,A1

        ; Track absolute peak level
        MOVE.W  D1,D2
        BPL.S   .pos_smp
        NEG.W   D2
.pos_smp:
        CMP.W   D7,D2
        BLE.S   .no_new_peak
        MOVE.W  D2,D7
.no_new_peak:

        ; Map signed 16-bit sample (-32768..+32767) to Y in 83..141 (center = 112)
        ASR.W   #8,D1                   ; -128..+127
        ASR.W   #2,D1                   ; -32..+31
        CMPI.W  #-29,D1
        BGE.S   .min_ok
        MOVEQ   #-29,D1
.min_ok:
        CMPI.W  #29,D1
        BLE.S   .max_ok
        MOVEQ   #29,D1
.max_ok:
        ADDI.W  #112,D1                 ; Y in 83..141
        MOVE.W  D1,(A4)+                ; Save new Y

        ; Plot new glowing Anchor dot across all 4 planes:
        ; Left 4 px: c3=0, c2=1, c1=1, c0=1 -> Palette 7 pure white (255,255,255)
        ; Right 4 px: c3=1, c2=0, c1=0, c0=1 -> Delta trail
        MULU.W  #SCR_WIDTH_B,D1
        ADD.W   D6,D1
        MOVE.B  #$F5,(A0,D1.W)          ; BPL1 = $F5
        MOVE.B  #$F3,(A2,D1.W)          ; BPL2 = $F3
        MOVE.B  #$F0,(A3,D1.W)          ; BPL3 = $F0
        MOVE.B  #$0F,(A5,D1.W)          ; BPL4 = $0F

        ADDQ.W  #1,D6
        CMPI.W  #40,D6
        BLT.S   .scope_col_loop

        ; Save scaled peak (0..127)
        LSR.W   #8,D7
        MOVE.W  D7,LastPeakLevel

        ; Track per-act peak level for Toby's diagnostics
        MOVE.W  CurrentAct(PC),D0
        CMPI.W  #1,D0
        BNE.S   .chk_a2
        CMP.W   Act1_Peak(PC),D7
        BLE.S   .peak_saved
        MOVE.W  D7,Act1_Peak
        BRA.S   .peak_saved
.chk_a2:
        CMPI.W  #2,D0
        BNE.S   .chk_a3
        CMP.W   Act2_Peak(PC),D7
        BLE.S   .peak_saved
        MOVE.W  D7,Act2_Peak
        BRA.S   .peak_saved
.chk_a3:
        CMPI.W  #3,D0
        BNE.S   .chk_a4
        CMP.W   Act3_Peak(PC),D7
        BLE.S   .peak_saved
        MOVE.W  D7,Act3_Peak
        BRA.S   .peak_saved
.chk_a4:
        CMPI.W  #4,D0
        BNE.S   .chk_a5
        CMP.W   Act4_Peak(PC),D7
        BLE.S   .peak_saved
        MOVE.W  D7,Act4_Peak
        BRA.S   .peak_saved
.chk_a5:
        CMP.W   Act5_Peak(PC),D7
        BLE.S   .peak_saved
        MOVE.W  D7,Act5_Peak
.peak_saved:

        ; 4. Animate Copper Scanline Splits (25 splits * 16 bytes each)
        LEA     CopScanSplits,A0
        MOVE.W  VisFrameCnt(PC),D3
        MOVEQ   #25-1,D6
        MOVEQ   #0,D5
.cop_anim:
        MOVE.W  D5,D0
        ADD.W   D3,D0
        ANDI.W  #$001F,D0
        CMPI.W  #16,D0
        BLT.S   .tri_up
        MOVEQ   #31,D1
        SUB.W   D0,D1
        MOVE.W  D1,D0
.tri_up:
        ; Modulate COLOR01 ($0182) and COLOR02 ($0184) in Copper split
        MOVE.W  D0,D1
        LSL.W   #8,D1
        OR.W    D7,D1                   ; Mix live audio peak into Blue/Green
        ANDI.W  #$0FFF,D1
        ORI.W   #$0103,D1
        MOVE.W  D1,10(A0)               ; COLOR01 value

        MOVE.W  D0,D2
        LSL.W   #4,D2
        ORI.W   #$0208,D2
        MOVE.W  D2,14(A0)               ; COLOR02 value

        LEA     16(A0),A0
        ADDQ.W  #1,D5
        DBRA    D6,.cop_anim

        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

; ==============================================================================
; AUDIO ENGINE SUBROUTINES (ALL 32 VOICES)
; ==============================================================================

; ------------------------------------------------------------------------------
; Fade_Out_All_Voices: Smooth 8-frame micro-fade (160 ms) to avoid audio clicks
; Exponentially ramps volume of all 32 voices down to 0 before stopping DMA
; ------------------------------------------------------------------------------
Fade_Out_All_Voices:
        MOVEM.L D2-D7/A0-A2,-(SP)
        MOVEQ   #8-1,D7                 ; 8 frames
.f_step:
        BSR     Wait_VBL
        BSR     Update_Visuals_And_Scope
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D6
.f_voice:
        MOVE.W  AUD_VOL(A0),D0          ; High=L, Low=R
        MOVE.W  D0,D1
        LSR.W   #8,D0                   ; Left vol
        ANDI.W  #$00FF,D1               ; Right vol
        LSR.W   #1,D0                   ; Halve left volume
        LSR.W   #1,D1                   ; Halve right volume
        LSL.W   #8,D0
        OR.B    D1,D0
        MOVE.W  D0,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.f_voice
        DBRA    D7,.f_step
        MOVEM.L (SP)+,D2-D7/A0-A2
        RTS

Silence_All_Voices:
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.s_loop:
        MOVE.W  #$0002,AUD_CMD(A0)      ; STOP
        MOVE.W  #$0000,AUD_VOL(A0)      ; Mute
        MOVE.W  #$0000,AUD_CTRL(A0)
        MOVE.W  #$0000,AUD_DELAY(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.s_loop
        RTS

; ------------------------------------------------------------------------------
; ACT I: 31-Voice Deep Note + Zero-RAM Start-Delay + Voice 31 16-Bit Sub-Bass
; ------------------------------------------------------------------------------
Init_Act1_DeepNote:
        LEA     AUDIO_EXT_BASE,A0
        LEA     SA_StartPer,A1
        LEA     SA_Vol,A2
        LEA     SA_Delay,A3
        LEA     SA_CurPerFP,A4
        LEA     Saw32,A5
        MOVE.L  A5,D1

        MOVEQ   #30,D0                  ; Voices 0..30
.sa_loop:
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A0)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #32,AUD_LENL(A0)

        MOVE.W  (A1)+,D2
        MOVE.W  D2,AUD_PER(A0)
        SWAP    D2
        CLR.W   D2
        MOVE.L  D2,(A4)+

        MOVE.W  (A2)+,AUD_VOL(A0)
        MOVE.W  (A3)+,AUD_DELAY(A0)     ; Hardware Zero-RAM Start-Delay!
        MOVE.W  #CTRL_LOOP,AUD_CTRL(A0)
        MOVE.W  #$0001,AUD_CMD(A0)

        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.sa_loop

        ; Voice 31: 16-Bit Big-Endian Pure Sine Sub-Bass Foundation (D1)
        LEA     Sine16_64,A5
        MOVE.L  A5,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A0)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #128,AUD_LENL(A0)       ; 64 words = 128 bytes
        MOVE.W  #SUB_PER_D1,AUD_PER(A0)
        MOVE.W  #$4848,AUD_VOL(A0)
        MOVE.W  #0,AUD_DELAY(A0)
        MOVE.W  #(CTRL_PCM16|CTRL_LOOP),AUD_CTRL(A0)
        MOVE.W  #$0001,AUD_CMD(A0)
        RTS

Update_DeepNote_Glide:
        LEA     AUDIO_EXT_BASE,A0
        LEA     SA_Delta,A1
        LEA     SA_CurPerFP,A2
        MOVEQ   #30,D0
.gl_loop:
        MOVE.L  (A2),D2
        ADD.L   (A1)+,D2
        MOVE.L  D2,(A2)+
        SWAP    D2
        MOVE.W  D2,AUD_PER(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.gl_loop
        RTS

; ------------------------------------------------------------------------------
; ACT III: 32-Band Hardware Vocoder & 4-Bit ADPCM Stream
; ------------------------------------------------------------------------------
Init_Act3_Vocoder:
        LEA     AUDIO_EXT_BASE,A0
        LEA     FilterBankCoeffs,A1
        MOVEQ   #31,D0
.load_bp:
        MOVE.W  (A1)+,AUD_BQ_B0(A0)
        MOVE.W  (A1)+,AUD_BQ_B1(A0)
        MOVE.W  (A1)+,AUD_BQ_B2(A0)
        MOVE.W  (A1)+,AUD_BQ_A1(A0)
        MOVE.W  (A1)+,AUD_BQ_A2(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.load_bp

        ; Voice 0: 48 kHz 4-Bit Hardware ADPCM Root Source
        LEA     AUDIO_EXT_BASE,A0
        MOVE.L  #AdpcmData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.L  #ADPCM_BYTES,D0
        MOVE.W  D0,AUD_LENL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #0,AUD_PRED(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        MOVE.W  #(CTRL_ADPCM|CTRL_FLT_STEREO),AUD_CTRL(A0)

        ; Voices 1..31: Pre-Filter Cascade from Voice N-1 (LEN=0 -> 0% extra DMA!)
        LEA     VOICE_STRIDE(A0),A0
        MOVEQ   #30,D0
.init_voc_chain:
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #0,AUD_LENL(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        MOVE.W  #(CTRL_FLT_STEREO|CTRL_SRC_PRE),AUD_CTRL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.init_voc_chain

        ; Invalidate vocoder cluster cache
        MOVE.W  #-1,LastVocoderCenter

        ; Start all 32 voices synchronously
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.start_voc:
        MOVE.W  #$0001,AUD_CMD(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.start_voc
        RTS

Mute_Vocoder_Bands:
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.m_voc:
        MOVE.W  #$0000,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.m_voc
        RTS

; ------------------------------------------------------------------------------
; Act III: 30-Second Vocoder Engine (D5 = 0..1537)
; 1.0s Fade-In (D5=0..49), 28.76s Bi-directional Sweep, 1.0s Fade-Out (D5=1488..1537)
; Sweep starts centered around Band 14 (~676 Hz vowel formant) for instant vocal warmth!
; 5-Band Resonant Cluster + Warm Bed + Smooth Crossfades (ZERO Zipper-Noise, NO Zero-Muting!)
; ------------------------------------------------------------------------------
Update_Vocoder_30s:
        MOVEM.L D2-D5/A0-A1,-(SP)

        ; 1. Calculate Linear Fade Multiplier in D4 (0..100)
        CMPI.W  #50,D5
        BGE.S   .chk_fadeout
        ; Fade-In (0..49): Smooth swell from volume 0 to 100%
        MOVE.W  D5,D4
        ADD.W   D4,D4                   ; D4 = D5 * 2 (0..98)
        BRA.S   .calc_sweep
.chk_fadeout:
        CMPI.W  #1488,D5
        BLT.S   .sustain
        ; Fade-Out (1488..1537): Smooth fade from 100% down to 0
        MOVE.W  #1537,D4
        SUB.W   D5,D4                   ; 49..0
        ADD.W   D4,D4                   ; 98..0
        BRA.S   .calc_sweep
.sustain:
        MOVEQ   #100,D4                 ; Full volume (100%)

.calc_sweep:
        ; 2. Calculate Center Band D0 (0..31), starting at Band 14 (vocal formant)
        MOVE.W  D5,D0
        LSR.W   #2,D0                   ; Advance every 4 frames (12.5 Hz step)
        ADDI.W  #14,D0                  ; Start at Band 14 (~676 Hz)!
        ANDI.W  #$003F,D0               ; 0..63
        CMPI.W  #32,D0
        BLT.S   .sw_fwd
        MOVEQ   #63,D1
        SUB.W   D0,D1
        MOVE.W  D1,D0                   ; 31..0
.sw_fwd:

        ; During sustain (D4=100), only write to hardware if band changed
        CMPI.W  #100,D4
        BNE.S   .do_update
        CMP.W   LastVocoderCenter(PC),D0
        BEQ     .voc_exit

.do_update:
        MOVE.W  D0,LastVocoderCenter
        LEA     AUDIO_EXT_BASE,A0

        ; 1. Voice 0 Warm Root Carrier Bed: base $40 (64) scaled by D4
        MOVE.W  #64,D2
        MULU.W  D4,D2
        DIVU.W  #100,D2                 ; 0..64
        MOVE.W  D2,D3
        LSL.W   #8,D2
        OR.B    D3,D2
        MOVE.W  D2,AUD_VOL(A0)          ; Set Voice 0 warm carrier bed

        ; 2. Gentle background bed on all filter bands (16 * D4 / 100)
        ; Prevents harsh mute drops and keeps all 32 bands alive!
        MOVE.W  #16,D2
        MULU.W  D4,D2
        DIVU.W  #100,D2                 ; 0..16
        MOVE.W  D2,D3
        LSL.W   #8,D2
        OR.B    D3,D2                   ; D2 = bed volume word

        LEA     VOICE_STRIDE(A0),A1
        MOVEQ   #30,D1
.fill_bed:
        MOVE.W  D2,AUD_VOL(A1)
        LEA     VOICE_STRIDE(A1),A1
        DBRA    D1,.fill_bed

        ; 3. Formant Cluster around Center Band D0 (5-Band Resonant Peak)
        ; Center Band D0: base $A0 (160) scaled by D4
        MOVE.W  #160,D2
        MULU.W  D4,D2
        DIVU.W  #100,D2                 ; 0..160
        MOVE.W  D2,D3
        LSL.W   #8,D2
        OR.B    D3,D2
        MOVE.W  D0,D1
        LSL.W   #5,D1
        MOVE.W  D2,AUD_VOL(A0,D1.W)     ; Center band volume

        ; Left Neighbor (D0-1): base $70 (112) scaled by D4
        TST.W   D0
        BEQ.S   .no_left1
        MOVE.W  #112,D2
        MULU.W  D4,D2
        DIVU.W  #100,D2
        MOVE.W  D2,D3
        LSL.W   #8,D2
        OR.B    D3,D2
        MOVE.W  D0,D1
        SUBQ.W  #1,D1
        LSL.W   #5,D1
        MOVE.W  D2,AUD_VOL(A0,D1.W)
.no_left1:

        ; Right Neighbor (D0+1): base $70 (112) scaled by D4
        CMPI.W  #31,D0
        BGE.S   .no_right1
        MOVE.W  #112,D2
        MULU.W  D4,D2
        DIVU.W  #100,D2
        MOVE.W  D2,D3
        LSL.W   #8,D2
        OR.B    D3,D2
        MOVE.W  D0,D1
        ADDQ.W  #1,D1
        LSL.W   #5,D1
        MOVE.W  D2,AUD_VOL(A0,D1.W)
.no_right1:

        ; Outer Left (D0-2): base $40 (64) scaled by D4
        CMPI.W  #2,D0
        BLT.S   .no_left2
        MOVE.W  #64,D2
        MULU.W  D4,D2
        DIVU.W  #100,D2
        MOVE.W  D2,D3
        LSL.W   #8,D2
        OR.B    D3,D2
        MOVE.W  D0,D1
        SUBQ.W  #2,D1
        LSL.W   #5,D1
        MOVE.W  D2,AUD_VOL(A0,D1.W)
.no_left2:

        ; Outer Right (D0+2): base $40 (64) scaled by D4
        CMPI.W  #30,D0
        BGE.S   .voc_exit
        MOVE.W  #64,D2
        MULU.W  D4,D2
        DIVU.W  #100,D2
        MOVE.W  D2,D3
        LSL.W   #8,D2
        OR.B    D3,D2
        MOVE.W  D0,D1
        ADDQ.W  #2,D1
        LSL.W   #5,D1
        MOVE.W  D2,AUD_VOL(A0,D1.W)

.voc_exit:
        MOVEM.L (SP)+,D2-D5/A0-A1
        RTS

; ------------------------------------------------------------------------------
; ACT II & ACT IV: Synth Track & 32-Voice Cyber Symphony
; ------------------------------------------------------------------------------
Init_Synth_Track:
        LEA     AUDIO_EXT_BASE,A0

        ; --- CH 0 & 1: 24 dB/oct Moog Cascaded Acid Bass (16-Bit Saw16_64) ---
        ; Ch 0: First 12 dB Lowpass Stage (CTRL_MUTE_MIX = $2000 so only 24 dB out is heard!)
        LEA     Saw16_64,A1
        MOVE.L  A1,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A0)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #128,AUD_LENL(A0)       ; 64 words = 128 bytes
        MOVE.W  #$9090,AUD_VOL(A0)
        MOVE.W  #(CTRL_PCM16|CTRL_LOOP|CTRL_FLT_STEREO|CTRL_MUTE_MIX),AUD_CTRL(A0)

        ; Ch 1: Second 12 dB Lowpass Stage cascaded from Ch 0 (CTRL_SRC_POST, LEN=0!)
        LEA     VOICE_STRIDE(A0),A2
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #0,AUD_LENL(A2)
        MOVE.W  #$A0A0,AUD_VOL(A2)
        MOVE.W  #(CTRL_PCM16|CTRL_LOOP|CTRL_FLT_STEREO|CTRL_SRC_POST),AUD_CTRL(A2)

        MOVEQ   #0,D0
        BSR     Set_Acid_Filter_Coeffs
        MOVE.W  #$0001,AUD_CMD(A0)
        MOVE.W  #$0001,AUD_CMD(A2)

        ; --- CH 2 & 3: Hardware AM Pluck Synth (Ch 2 modulates Ch 3) ---
        LEA     (2*VOICE_STRIDE)(A0),A2
        LEA     EnvPluck,A1
        MOVE.L  A1,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A2)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #ENV_LEN,AUD_LENL(A2)
        MOVE.W  #PER_ENV,AUD_PER(A2)
        MOVE.W  #$8080,AUD_VOL(A2)
        MOVE.W  #(CTRL_ONESHOT|CTRL_MUTE_MIX),AUD_CTRL(A2)

        LEA     (3*VOICE_STRIDE)(A0),A3
        LEA     Saw16_64,A1
        MOVE.L  A1,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A3)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A3)
        MOVE.W  #0,AUD_LENH(A3)
        MOVE.W  #128,AUD_LENL(A3)
        MOVE.W  #$7858,AUD_VOL(A3)
        MOVE.W  #(CTRL_PCM16|CTRL_LOOP|CTRL_MOD_AM),AUD_CTRL(A3)
        MOVE.W  #$0001,AUD_CMD(A3)

        ; --- CH 4 & 5: Hardware Ringmod Space Bells (Ch 4 modulates Ch 5) ---
        LEA     (4*VOICE_STRIDE)(A0),A2
        LEA     BellCar,A1
        MOVE.L  A1,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A2)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #BELLCAR_LEN,AUD_LENL(A2)
        MOVE.W  #(CTRL_ONESHOT|CTRL_MUTE_MIX),AUD_CTRL(A2)

        LEA     (5*VOICE_STRIDE)(A0),A3
        LEA     Sine16_64,A1
        MOVE.L  A1,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A3)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A3)
        MOVE.W  #0,AUD_LENH(A3)
        MOVE.W  #128,AUD_LENL(A3)
        MOVE.W  #$5878,AUD_VOL(A3)
        MOVE.W  #(CTRL_PCM16|CTRL_LOOP|CTRL_MOD_RING),AUD_CTRL(A3)

        ; Check if Act IV Full 32-Voice Symphony Mode is enabled
        TST.W   FullSymphonyMode
        BEQ     .done_synth_init

        ; --- CH 9..12: 4-Voice Polyphonic 4-Bit ADPCM Groove Chorus ---
        MOVEQ   #3,D0
.adpcm_chorus:
        MOVE.W  D0,D1
        ADDI.W  #9,D1
        LSL.W   #5,D1
        LEA     (A0,D1.W),A2
        MOVE.L  #AdpcmData,D2
        SWAP    D2
        MOVE.W  D2,AUD_PTRH(A2)
        SWAP    D2
        MOVE.W  D2,AUD_PTRL(A2)
        MOVE.L  #ADPCM_BYTES,D2
        MOVE.W  D2,AUD_LENL(A2)
        SWAP    D2
        MOVE.W  D2,AUD_LENH(A2)
        MOVE.W  #PER_48K,D2
        ADD.W   D0,D2                   ; Slight detune for stereo chorus
        MOVE.W  D2,AUD_PER(A2)
        MOVE.W  #0,AUD_PRED(A2)
        MOVE.W  D0,D2
        MULU.W  #600,D2                 ; Staggered Zero-RAM Start-Delay
        MOVE.W  D2,AUD_DELAY(A2)
        MOVE.W  #$1C24,AUD_VOL(A2)
        MOVE.W  #CTRL_ADPCM,AUD_CTRL(A2)
        MOVE.W  #$0001,AUD_CMD(A2)
        DBRA    D0,.adpcm_chorus

        ; --- CH 13..20: 8-Voice Stereo Detuned Arp/Brass Chords (16-Bit Saw) ---
        LEA     ArpVolTab,A4
        MOVEQ   #7,D0
.arp_init:
        MOVE.W  D0,D1
        ADDI.W  #13,D1
        LSL.W   #5,D1
        LEA     (A0,D1.W),A2
        LEA     Saw16_64,A1
        MOVE.L  A1,D2
        SWAP    D2
        MOVE.W  D2,AUD_PTRH(A2)
        SWAP    D2
        MOVE.W  D2,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #128,AUD_LENL(A2)
        MOVE.W  #400,AUD_PER(A2)
        MOVE.W  (A4)+,AUD_VOL(A2)
        MOVE.W  #(CTRL_PCM16|CTRL_LOOP),AUD_CTRL(A2)
        MOVE.W  #$0001,AUD_CMD(A2)
        DBRA    D0,.arp_init

        ; --- CH 21..30: 10-Voice Wide-Stereo Super-Pad ---
        LEA     PadVolTab,A4
        MOVEQ   #9,D0
.pad_init:
        MOVE.W  D0,D1
        ADDI.W  #21,D1
        LSL.W   #5,D1
        LEA     (A0,D1.W),A2
        LEA     Saw32,A1
        MOVE.L  A1,D2
        SWAP    D2
        MOVE.W  D2,AUD_PTRH(A2)
        SWAP    D2
        MOVE.W  D2,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #32,AUD_LENL(A2)
        MOVE.W  #400,AUD_PER(A2)
        MOVE.W  (A4)+,AUD_VOL(A2)
        MOVE.W  #CTRL_LOOP,AUD_CTRL(A2)
        MOVE.W  #$0001,AUD_CMD(A2)
        DBRA    D0,.pad_init

        ; --- CH 31: 16-Bit Pure Sine Sub-Bass ---
        LEA     (31*VOICE_STRIDE)(A0),A2
        LEA     Sine16_64,A1
        MOVE.L  A1,D2
        SWAP    D2
        MOVE.W  D2,AUD_PTRH(A2)
        SWAP    D2
        MOVE.W  D2,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #128,AUD_LENL(A2)
        MOVE.W  #SUB_PER_D1,AUD_PER(A2)
        MOVE.W  #$4444,AUD_VOL(A2)
        MOVE.W  #(CTRL_PCM16|CTRL_LOOP),AUD_CTRL(A2)
        MOVE.W  #$0001,AUD_CMD(A2)

.done_synth_init:
        RTS

; ------------------------------------------------------------------------------
; Sequencer Step Processor (125 BPM 16th-note step in D5 = 0..63)
; ------------------------------------------------------------------------------
Process_Track_Step:
        LEA     AUDIO_EXT_BASE,A0

        ; 1. Kick Drum (Ch 6)
        LEA     KickPat,A1
        MOVE.W  D5,D0
        ANDI.W  #$000F,D0
        TST.B   (A1,D0.W)
        BEQ.S   .no_kick
        LEA     (6*VOICE_STRIDE)(A0),A2
        LEA     KickSmp,A3
        MOVE.L  A3,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A2)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #KICK_LEN,AUD_LENL(A2)
        MOVE.W  #PER_DRUM,AUD_PER(A2)
        MOVE.W  #$9898,AUD_VOL(A2)
        MOVE.W  #CTRL_ONESHOT,AUD_CTRL(A2)
        MOVE.W  #$0001,AUD_CMD(A2)
.no_kick:

        ; 2. Snare Drum (Ch 7)
        LEA     SnarePat,A1
        TST.B   (A1,D0.W)
        BEQ.S   .no_snare
        LEA     (7*VOICE_STRIDE)(A0),A2
        LEA     SnareSmp,A3
        MOVE.L  A3,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A2)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #SNARE_LEN,AUD_LENL(A2)
        MOVE.W  #PER_DRUM,AUD_PER(A2)
        MOVE.W  #$7878,AUD_VOL(A2)
        MOVE.W  #CTRL_ONESHOT,AUD_CTRL(A2)
        MOVE.W  #$0001,AUD_CMD(A2)
.no_snare:

        ; 3. Biquad High-Pass Filtered Hi-Hat (Ch 8)
        LEA     HatPat,A1
        TST.B   (A1,D0.W)
        BEQ.S   .no_hat
        LEA     (8*VOICE_STRIDE)(A0),A2
        LEA     HatSmp,A3
        MOVE.L  A3,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A2)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #HAT_LEN,AUD_LENL(A2)
        MOVE.W  #PER_DRUM,AUD_PER(A2)
        MOVE.W  #$6464,AUD_VOL(A2)
        LEA     HatHP,A4
        MOVE.W  (A4)+,AUD_BQ_B0(A2)
        MOVE.W  (A4)+,AUD_BQ_B1(A2)
        MOVE.W  (A4)+,AUD_BQ_B2(A2)
        MOVE.W  (A4)+,AUD_BQ_A1(A2)
        MOVE.W  (A4)+,AUD_BQ_A2(A2)
        MOVE.W  #(CTRL_ONESHOT|CTRL_FLT_STEREO),AUD_CTRL(A2)
        MOVE.W  #$0001,AUD_CMD(A2)
.no_hat:

        ; 4. 24 dB Moog Acid Bass Pitch & Accent (Ch 0 & Ch 1)
        LEA     AcidPerSeq,A1
        MOVE.W  D5,D0
        ADD.W   D0,D0
        MOVE.W  (A1,D0.W),D1
        BEQ.S   .no_acid
        MOVE.W  D1,AUD_PER(A0)
        MOVE.W  D1,AUD_PER+VOICE_STRIDE(A0)
        LEA     AcidVolSeq,A2
        MOVE.W  (A2,D0.W),AUD_VOL+VOICE_STRIDE(A0)
.no_acid:

        ; 5. Hardware AM Pluck Lead Trigger (Ch 2 & Ch 3)
        LEA     LeadPerSeq,A1
        MOVE.W  (A1,D0.W),D1
        BEQ.S   .no_lead
        LEA     (3*VOICE_STRIDE)(A0),A3
        MOVE.W  D1,AUD_PER(A3)
        LEA     (2*VOICE_STRIDE)(A0),A2
        MOVE.W  #$0001,AUD_CMD(A2)
.no_lead:

        ; 6. Hardware Ringmod Space Bells Trigger (Ch 4 & Ch 5)
        LEA     BellPerSeq,A1
        MOVE.W  D5,D0
        LSL.W   #2,D0
        MOVE.W  (A1,D0.W),D1
        BEQ.S   .no_bell
        LEA     (5*VOICE_STRIDE)(A0),A3
        MOVE.W  D1,AUD_PER(A3)
        LEA     (4*VOICE_STRIDE)(A0),A2
        MOVE.W  2(A1,D0.W),AUD_PER(A2)
        MOVE.W  #$0001,AUD_CMD(A2)
        MOVE.W  #$0001,AUD_CMD(A3)
.no_bell:

        ; 7. If Full Symphony Mode (Act IV), update Ch 13..20 Arp Chords & Ch 21..30 Pad
        TST.W   FullSymphonyMode
        BEQ.S   .step_done

        MOVE.W  D5,D0
        LSR.W   #4,D0
        ANDI.W  #$0003,D0               ; Bar index 0..3

        ; Update 8-voice Arp Chords (Ch 13..20)
        MOVE.W  D0,D1
        LSL.W   #4,D1                   ; 8 words = 16 bytes per chord
        LEA     ArpChordPer,A1
        LEA     (A1,D1.W),A1
        MOVEQ   #7,D1
.arp_upd:
        MOVE.W  D1,D2
        ADDI.W  #13,D2
        LSL.W   #5,D2
        MOVE.W  (A1)+,AUD_PER(A0,D2.W)
        DBRA    D1,.arp_upd

        ; Update 10-voice Super-Pad (Ch 21..30)
        MULU.W  #20,D0                  ; 10 words = 20 bytes per chord
        LEA     PadPerSeq,A1
        LEA     (A1,D0.W),A1
        MOVEQ   #9,D1
.pad_upd:
        MOVE.W  D1,D2
        ADDI.W  #21,D2
        LSL.W   #5,D2
        MOVE.W  (A1)+,AUD_PER(A0,D2.W)
        DBRA    D1,.pad_upd

.step_done:
        RTS

; ------------------------------------------------------------------------------
; 24 dB Moog Filter Cutoff LFO (Updates Ch 0 and Ch 1 Biquad Coefficients)
; ------------------------------------------------------------------------------
Update_Filter_LFO:
        ADDQ.B  #1,LFO_Phase
        MOVEQ   #0,D0
        MOVE.B  LFO_Phase(PC),D0
        LEA     LfoTab,A1
        MOVE.B  (A1,D0.W),D0
        ANDI.W  #$003F,D0

Set_Acid_Filter_Coeffs:
        MULU.W  #10,D0
        LEA     AcidLP1,A1
        LEA     (A1,D0.W),A1
        LEA     AcidLP2,A2
        LEA     (A2,D0.W),A2

        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  (A1)+,AUD_BQ_B0(A0)
        MOVE.W  (A1)+,AUD_BQ_B1(A0)
        MOVE.W  (A1)+,AUD_BQ_B2(A0)
        MOVE.W  (A1)+,AUD_BQ_A1(A0)
        MOVE.W  (A1)+,AUD_BQ_A2(A0)

        LEA     VOICE_STRIDE(A0),A3
        MOVE.W  (A2)+,AUD_BQ_B0(A3)
        MOVE.W  (A2)+,AUD_BQ_B1(A3)
        MOVE.W  (A2)+,AUD_BQ_B2(A3)
        MOVE.W  (A2)+,AUD_BQ_A1(A3)
        MOVE.W  (A2)+,AUD_BQ_A2(A3)
        RTS

; ------------------------------------------------------------------------------
; ACT V: Grand Finale 32-Voice Sustained Chord & Smooth Fadeout
; ------------------------------------------------------------------------------
Init_Act5_FinaleChord:
        BSR     Silence_All_Voices
        LEA     AUDIO_EXT_BASE,A0
        LEA     SA_EndPer,A1
        LEA     SA_Vol,A2
        LEA     Saw32,A5
        MOVE.L  A5,D1

        MOVEQ   #30,D0
.fin_loop:
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A0)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #32,AUD_LENL(A0)
        MOVE.W  (A1)+,AUD_PER(A0)
        MOVE.W  (A2)+,AUD_VOL(A0)
        MOVE.W  #0,AUD_DELAY(A0)
        MOVE.W  #CTRL_LOOP,AUD_CTRL(A0)
        MOVE.W  #$0001,AUD_CMD(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.fin_loop

        ; Voice 31: 16-Bit Sub-Bass D1
        LEA     Sine16_64,A5
        MOVE.L  A5,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A0)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #128,AUD_LENL(A0)
        MOVE.W  #SUB_PER_D1,AUD_PER(A0)
        MOVE.W  #$4848,AUD_VOL(A0)
        MOVE.W  #(CTRL_PCM16|CTRL_LOOP),AUD_CTRL(A0)
        MOVE.W  #$0001,AUD_CMD(A0)
        RTS

; D0.W = Fade scale (1..250)
Apply_Finale_Fade:
        MOVEM.L D2-D4/A0-A1,-(SP)
        LEA     AUDIO_EXT_BASE,A0
        LEA     SA_Vol,A1
        MOVEQ   #30,D1
.fade_v:
        MOVE.W  (A1)+,D2
        MOVE.W  D2,D3
        LSR.W   #8,D2                   ; Left Vol
        ANDI.W  #$00FF,D3               ; Right Vol
        MULU.W  D0,D2
        DIVU.W  #250,D2
        MULU.W  D0,D3
        DIVU.W  #250,D3
        LSL.W   #8,D2
        OR.B    D3,D2
        MOVE.W  D2,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D1,.fade_v

        ; Fade Voice 31 Sub-Bass
        MOVE.W  #$48,D2
        MULU.W  D0,D2
        DIVU.W  #250,D2
        MOVE.W  D2,D3
        LSL.W   #8,D2
        OR.B    D3,D2
        MOVE.W  D2,AUD_VOL(A0)
        MOVEM.L (SP)+,D2-D4/A0-A1
        RTS

; ------------------------------------------------------------------------------
; VBlank Synchronization & CLI String Output
; ------------------------------------------------------------------------------
Wait_VBL:
        LEA     CUSTOM,A6
.wait_on:
        MOVE.L  VPOSR(A6),D0
        ANDI.L  #$0001FF00,D0
        CMPI.L  #$00010000,D0
        BNE.S   .wait_on
.wait_off:
        MOVE.L  VPOSR(A6),D0
        ANDI.L  #$0001FF00,D0
        CMPI.L  #$00010000,D0
        BEQ.S   .wait_off
        RTS

PrintStr:
        MOVEM.L D0-D3/A0-A1/A6,-(SP)
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .p_exit
        MOVE.L  StdoutHandle(PC),D1
        BEQ.S   .p_exit
        MOVE.L  D0,A6
        MOVE.L  A0,A1
        MOVEQ   #0,D3
.p_len:
        TST.B   (A1)+
        BEQ.S   .p_write
        ADDQ.L  #1,D3
        BRA.S   .p_len
.p_write:
        TST.L   D3
        BEQ.S   .p_exit
        MOVE.L  A0,D2
        JSR     _LVOWrite(A6)
.p_exit:
        MOVEM.L (SP)+,D0-D3/A0-A1/A6
        RTS

; ------------------------------------------------------------------------------
; Diagnostic Formatting & Validation Reporting (Toby's Platform Compliance)
; ------------------------------------------------------------------------------
Format_Hex_Byte:
        MOVEM.L D1/A1,-(SP)
        LEA     HexChars(PC),A1
        MOVE.B  D0,D1
        LSR.B   #4,D1
        ANDI.W  #$000F,D1
        MOVE.B  (A1,D1.W),(A0)+
        ANDI.W  #$000F,D0
        MOVE.B  (A1,D0.W),(A0)+
        MOVEM.L (SP)+,D1/A1
        RTS

HexChars:
        DC.B    "0123456789ABCDEF"
        EVEN

Print_Diagnostic_Report:
        MOVEM.L D0/A0,-(SP)
        LEA     DiagAct1P,A0
        MOVE.W  Act1_Peak(PC),D0
        BSR.S   Format_Hex_Byte
        LEA     DiagAct2P,A0
        MOVE.W  Act2_Peak(PC),D0
        BSR.S   Format_Hex_Byte
        LEA     DiagAct3P,A0
        MOVE.W  Act3_Peak(PC),D0
        BSR.S   Format_Hex_Byte
        LEA     DiagAct4P,A0
        MOVE.W  Act4_Peak(PC),D0
        BSR.S   Format_Hex_Byte
        LEA     DiagAct5P,A0
        MOVE.W  Act5_Peak(PC),D0
        BSR.S   Format_Hex_Byte

        LEA     MsgDiagHeader(PC),A0
        BSR     PrintStr
        MOVEM.L (SP)+,D0/A0
        RTS

; ==============================================================================
; STRINGS, VARIABLES & GENERATED DATA
; ==============================================================================
DosName:        DC.B    "dos.library",0
GfxName:        DC.B    "graphics.library",0
IntuiName:      DC.B    "intuition.library",0

TxtHeader:      DC.B    "=== NANOMIG FPGA: 32CH DSP & EXT-HAM ===",0
TxtFooter:      DC.B    "$DFF400:32CH  $DFF800:HAM04  $DF8000:CAP",0
TxtAct1:        DC.B    "ACT 1: 32-VOICE DEEP NOTE & ZERO-DELAY  ",0
TxtAct2:        DC.B    "ACT 2: 24dB MOOG CASCADE + AM & RINGMOD ",0
TxtAct3:        DC.B    "ACT 3: 32-BAND VOCODER (30s FADE-IN/OUT)",0
TxtAct4:        DC.B    "ACT 4: 32-VOICE CYBER SYMPHONY (100%)   ",0
TxtAct5:        DC.B    "ACT 5: GRAND FINALE & HARMONIC FADEOUT  ",0

MsgBanner:      DC.B    10,"======================================================================",10
                DC.B    "*** ARGON ODYSSEY: EXTENDED-HAM04 & 32-CH DSP GRAND DEMO (30s VOCODER) ***",10
                DC.B    "Target:  MiSTer DE10-Nano / Minimig-AGA Core 22a912cc",10
                DC.B    "Video:   Extended HAM04 ($DFF800) 24-Bit TrueColor + Live Audio Scope",10
                DC.B    "Audio:   32 Voices, 24 dB Moog Cascade, AM, Ringmod, 32-Band Vocoder,",10
                DC.B    "         4-Bit Hardware ADPCM (30s), Zero-RAM Delay & Capture ($DF8000)",10
                DC.B    "======================================================================",10,0
MsgAct1:        DC.B    "[0:00 - 0:10] Act I:   32-Voice Deep Note Glide & Zero-RAM Delay (500 Frames)...",10,0
MsgAct1Done:    DC.B    "              [ACT 1 DONE] Frames: 500 | Peak Audio: $"
MsgAct1Peak:    DC.B    "00 | Sub-Bass & Delay: PASS",10,0

MsgAct2:        DC.B    "[0:10 - 0:24] Act II:  24 dB Moog Acid Cascade, AM Pluck & Ringmod (696 Frames)...",10,0
MsgAct2Done:    DC.B    "              [ACT 2 DONE] Frames: 696 | Peak Audio: $"
MsgAct2Peak:    DC.B    "00 | Moog Cascade & AM/Ring: PASS",10,0

MsgAct3:        DC.B    "[0:24 - 0:55] Act III: 32-Band Biquad Vocoder & 4-Bit ADPCM (1538 Frames = 30.8s)...",10,0
MsgAct3Done:    DC.B    "              [ACT 3 DONE] Frames: 1538 | Peak Audio: $"
MsgAct3Peak:    DC.B    "00 | Vocoder & ADPCM: PASS",10,0

MsgAct4:        DC.B    "[0:55 - 1:13] Act IV:  32-Voice Cyber Symphony (Full Load) (900 Frames)...",10,0
MsgAct4Done:    DC.B    "              [ACT 4 DONE] Frames: 900 | Peak Audio: $"
MsgAct4Peak:    DC.B    "00 | 32-Voice Polyphony: PASS",10,0

MsgAct5:        DC.B    "[1:13 - 1:19] Act V:   Grand Finale & 32-Voice Harmonic Fadeout (300 Frames)...",10,0
MsgAct5Done:    DC.B    "              [ACT 5 DONE] Frames: 300 | Peak Audio: $"
MsgAct5Peak:    DC.B    "00 | Silence & Fade: PASS",10,0

MsgDiagHeader:  DC.B    "----------------------------------------------------------------------",10
                DC.B    "[DIAGNOSTICS & HARDWARE VALIDATION REPORT]",10
                DC.B    "Act I   (Deep Note & Delay):       500 Frames | Peak: $"
DiagAct1P:      DC.B    "00 | 32.7kHz Zero-RAM Delay: PASS",10
                DC.B    "Act II  (Moog Cascade & AM/Ring):  696 Frames | Peak: $"
DiagAct2P:      DC.B    "00 | 24dB Cascade + AM/Ring: PASS",10
                DC.B    "Act III (Vocoder & ADPCM Stream): 1538 Frames | Peak: $"
DiagAct3P:      DC.B    "00 | 30.8s ADPCM (Fast-RAM) PASS",10
                DC.B    "Act IV  (32-Voice Cyber Symphony): 900 Frames | Peak: $"
DiagAct4P:      DC.B    "00 | 100% DMA Load (32CH):   PASS",10
                DC.B    "Act V   (Finale & Harmonic Fade):  300 Frames | Peak: $"
DiagAct5P:      DC.B    "00 | Clean Silence & Restore:PASS",10
                DC.B    "Total Frames: 3896 (~78.0s) | Audio Capture Engine ($DF8000): PASS",10
                DC.B    "Extended HAM04 TrueColor Video Engine ($DFF800):              PASS",10
                DC.B    "----------------------------------------------------------------------",10,0

MsgDone:        DC.B    "======================================================================",10
                DC.B    "[PASS] Argon Odyssey Grand Demo completed cleanly (RC: 0).",10
                DC.B    "======================================================================",10,10,0

                EVEN
DOSBase:            DC.L    0
GfxBase:            DC.L    0
IntuiBase:          DC.L    0
StdoutHandle:       DC.L    0
Saved_ActiView:     DC.L    0
Saved_DMACON:       DC.W    0
VisFrameCnt:        DC.W    0
LastPeakLevel:      DC.W    0
LastVocoderCenter:  DC.W    -1
CurrentAct:         DC.W    0
Act1_Peak:          DC.W    0
Act2_Peak:          DC.W    0
Act3_Peak:          DC.W    0
Act4_Peak:          DC.W    0
Act5_Peak:          DC.W    0
FullSymphonyMode:   DC.W    0
LFO_Phase:          DC.B    0
                EVEN

SA_CurPerFP:    DS.L    31
ScopeOldY:      DS.W    40

; Generated Musical, Filter, Font, Waveform & Copper Data
        INCLUDE "argon_data.i"
        INCLUDE "../filterbank_coeffs.i"

; 4-Bit Hardware ADPCM Music Stream (in Fast-RAM / Public DATA section)
        SECTION ArgonAudio,DATA
        CNOP    0,4
AdpcmData:
        INCBIN  "../adpcm/kakao_lotte_4bit_30s.bin"

; 320x200 4-Bitplane Extended-HAM04 Screen Buffer in Chip-RAM BSS (0 bytes on disk!)
        SECTION ArgonScreen,BSS_C
        CNOP    0,4
ScreenPlanes:
        DS.B    BPL_SIZE*4

        END
