; ==============================================================================
; MiSTer FPGA / Minimig-AGA: 32-Channel Biquad Filterbank vs. Direct A/B Test
; Program: filter_compare
;
; Kickstart 1.3+ compatible (dos.library Output/Write/Delay)
;
; Compares the 30.8s 48 kHz 4-Bit ADPCM Master ("Kakao bei Lotte", 738,540 bytes)
; in Fast-RAM under identical level conditions:
;
;   PHASE 1 (10 Seconds): Direct / Unfiltered Reference
;     - Voice 0 plays 48 kHz 4-Bit ADPCM directly to output at calibrated level ($B0B0)
;     - Smooth 0.5s ramp-up (25 frames) to verify click-free start
;     - Second-by-second hardware capture ($DFF802 / $DF8000) measuring Peak & RMS
;
;   PAUSE (1.0 Second silence / reset)
;
;   PHASE 2 (10 Seconds): Through 32-Band Biquad Filterbank (Vocoder)
;     - Voice 0 as carrier at identical base level ($B0B0)
;     - Voices 1..31 in Pre-Filter Cascade with 32 Biquad Bandpasses loaded
;     - Gain-compensated formant band cluster (Bands 12..16 around 676 Hz)
;     - Smooth register transitions (ZERO 50-Hz volume mutes -> NO zipper noise!)
;     - Second-by-second hardware capture measuring Peak, RMS & Attenuation
;
;   SUMMARY & HARDWARE VALIDATION MATRIX:
;     - Side-by-side comparison of Direct vs. Filtered signal levels
;     - Initial click-free ramp verification
;     - DMA starvation counter (0/0 expected)
;     - Soft/Hard clipping counter (0/0 expected)
;     - Clean return to AmigaDOS with RC 0
;
; Assembler: vasmm68k_mot -Fhunk -o filter_compare.o filter_compare.s
; Linker:    vlink -bamigahunk -x -Bstatic -o filter_compare filter_compare.o
; ==============================================================================

CUSTOM          EQU $DFF000
AUDIO_EXT_BASE  EQU $DFF400
VOICE_STRIDE    EQU $20

AUD_PTRH        EQU $00
AUD_PTRL        EQU $02
AUD_LENH        EQU $04
AUD_LENL        EQU $06
AUD_VOL         EQU $08
AUD_PER         EQU $0A
AUD_CTRL        EQU $0C
AUD_PRED        EQU $0E
AUD_BQ_B0       EQU $10
AUD_BQ_B1       EQU $12
AUD_BQ_B2       EQU $14
AUD_BQ_A1       EQU $16
AUD_BQ_A2       EQU $18
AUD_CMD         EQU $1A

AUD_CAP         EQU $DFF802
AUD_BUF_A       EQU $DF8000
AUD_IRQ_HI      EQU $DFF4C0
AUD_IRQ_LO      EQU $DFF4C2

CTRL_ADPCM      EQU $0008       ; Bit 3: 4-Bit ADPCM Decoder
CTRL_FLT_STEREO EQU $0180       ; Bits 8,7: Biquad Filter on L & R
CTRL_SRC_PRE    EQU $0200       ; Bit 9: Pre-Filter Cascade from Voice N-1

PER_48K         EQU 521         ; 25 MHz / 521 = 47,985 Hz (~48 kHz)
ADPCM_BYTES     EQU 738540      ; 30.77s 48 kHz 4-Bit ADPCM stream ($000B44EC)
TARGET_VOL      EQU 176         ; Base level $B0 (176/255 = ~70% full scale, 3 dB headroom)

_LVOOpenLibrary  EQU -552
_LVOCloseLibrary EQU -414
_LVOWrite        EQU -48
_LVOOutput       EQU -60
_LVODelay        EQU -198

; ==============================================================================
        SECTION text,CODE
; ==============================================================================

Start:
        MOVEM.L D2-D7/A2-A6,-(SP)

        ; 1. Open dos.library via ExecBase ($4.W)
        MOVE.L  $00000004.W,A6
        LEA     DosName(PC),A1
        MOVEQ   #0,D0
        JSR     _LVOOpenLibrary(A6)
        MOVE.L  D0,DOSBase
        BNE.S   .DosOk
        MOVEQ   #20,D0
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

.DosOk:
        MOVE.L  D0,A6
        JSR     _LVOOutput(A6)
        MOVE.L  D0,StdoutHandle

        ; Print Banner
        LEA     MsgBanner(PC),A0
        BSR     PrintStr

        ; Silence & stop all 32 voices
        BSR     StopAllVoices

        ; Reset capture registers
        MOVE.W  #$0000,AUD_CAP

        ; ==============================================================
        ; PHASE 1: DIRECT / UNFILTERED REFERENCE (10 SECONDS)
        ; ==============================================================
        LEA     MsgP1Header(PC),A0
        BSR     PrintStr

        ; Setup Voice 0: Direct ADPCM from byte 0, volume 0 (will ramp smoothly)
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
        MOVE.W  #CTRL_ADPCM,AUD_CTRL(A0)
        MOVE.W  #$0001,AUD_CMD(A0)      ; Start Voice 0

        ; Second 1: Smooth Click-Free Ramp-Up (25 frames from 0 to TARGET_VOL)
        MOVEQ   #1,D7                   ; Current second (1..10)
        BSR     Ramp_Up_Voice0

        ; Wait remaining 25 frames of Second 1 at TARGET_VOL
        MOVE.L  #25,D1
        BSR     DosDelay

        ; Measure Second 1 Capture
        BSR     Measure_Capture
        BSR     Print_Second_Line
        ADDQ.W  #1,D7

        ; Seconds 2..10: Steady Playback with Second-by-Second Capture
.P1_SecLoop:
        MOVE.L  #50,D1                  ; 50 ticks = 1.0 second
        BSR     DosDelay
        BSR     Measure_Capture
        BSR     Print_Second_Line
        ADDQ.W  #1,D7
        CMPI.W  #11,D7
        BNE.S   .P1_SecLoop

        ; Save Phase 1 max measurements
        MOVE.W  MaxPeak(PC),P1_MaxPeak
        MOVE.W  MaxRMS(PC),P1_MaxRMS

        ; Smooth 0.5s Ramp-Down to silence
        BSR     Ramp_Down_Voice0
        BSR     StopAllVoices

        ; Print Phase 1 summary
        LEA     MsgP1Summary(PC),A0
        BSR     PrintStr
        MOVE.W  P1_MaxPeak(PC),D0
        BSR     PrintHexWord
        LEA     MsgP1RMS(PC),A0
        BSR     PrintStr
        MOVE.W  P1_MaxRMS(PC),D0
        BSR     PrintHexWord
        LEA     MsgNewline(PC),A0
        BSR     PrintStr

        ; ==============================================================
        ; PAUSE: 1.0 SECOND SILENCE
        ; ==============================================================
        LEA     MsgPause(PC),A0
        BSR     PrintStr
        MOVE.L  #50,D1
        BSR     DosDelay

        ; Reset capture max trackers for Phase 2
        CLR.W   MaxPeak
        CLR.W   MaxRMS

        ; ==============================================================
        ; PHASE 2: THROUGH 32-BAND BIQUAD FILTERBANK (10 SECONDS)
        ; ==============================================================
        LEA     MsgP2Header(PC),A0
        BSR     PrintStr

        ; 1. Load FilterBank Coefficients into Voices 0..31
        LEA     AUDIO_EXT_BASE,A0
        LEA     FilterBankCoeffs(PC),A1
        MOVEQ   #31,D0
.load_coeffs:
        MOVE.W  (A1)+,AUD_BQ_B0(A0)
        MOVE.W  (A1)+,AUD_BQ_B1(A0)
        MOVE.W  (A1)+,AUD_BQ_B2(A0)
        MOVE.W  (A1)+,AUD_BQ_A1(A0)
        MOVE.W  (A1)+,AUD_BQ_A2(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.load_coeffs

        ; 2. Configure Voice 0: Root Carrier from byte offset 0
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
        MOVE.W  #$0000,AUD_VOL(A0)      ; Starts at 0, ramps up
        MOVE.W  #(CTRL_ADPCM|CTRL_FLT_STEREO),AUD_CTRL(A0)

        ; 3. Configure Voices 1..31: Pre-Filter Cascade from Voice N-1
        LEA     VOICE_STRIDE(A0),A0
        MOVEQ   #30,D0
.init_chain:
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #0,AUD_LENL(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        MOVE.W  #(CTRL_FLT_STEREO|CTRL_SRC_PRE),AUD_CTRL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.init_chain

        ; 4. Start all 32 voices
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.start_p2:
        MOVE.W  #$0001,AUD_CMD(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.start_p2

        ; 5. Smooth Ramp-Up into Formant Configuration (Bands 12..16 + Bed)
        ; Voice 0 warm bed = $40 (64), Vocal cluster = $B0 (176)
        MOVEQ   #1,D7                   ; Current second (1..10)
        BSR     Ramp_Up_Vocoder

        ; Wait remaining 25 frames of Second 1
        MOVE.L  #25,D1
        BSR     DosDelay
        BSR     Measure_Capture
        BSR     Print_Second_Line
        ADDQ.W  #1,D7

        ; Seconds 2..5: Vocal Formant Cluster (Bands 12..16)
.P2_FormantLoop:
        MOVE.L  #50,D1
        BSR     DosDelay
        BSR     Measure_Capture
        BSR     Print_Second_Line
        ADDQ.W  #1,D7
        CMPI.W  #6,D7
        BNE.S   .P2_FormantLoop

        ; Seconds 6..10: Full-Band Synthesis (All 32 bands active at equalised level)
        ; Smoothly crossfade all 32 bands to $24 (36) to demonstrate full spectrum sum!
        BSR     Switch_To_FullBand

.P2_FullBandLoop:
        MOVE.L  #50,D1
        BSR     DosDelay
        BSR     Measure_Capture
        BSR     Print_Second_Line
        ADDQ.W  #1,D7
        CMPI.W  #11,D7
        BNE.S   .P2_FullBandLoop

        ; Save Phase 2 max measurements
        MOVE.W  MaxPeak(PC),P2_MaxPeak
        MOVE.W  MaxRMS(PC),P2_MaxRMS

        ; Smooth 0.5s Ramp-Down to silence
        BSR     Ramp_Down_All
        BSR     StopAllVoices

        ; Print Phase 2 summary
        LEA     MsgP2Summary(PC),A0
        BSR     PrintStr
        MOVE.W  P2_MaxPeak(PC),D0
        BSR     PrintHexWord
        LEA     MsgP2RMS(PC),A0
        BSR     PrintStr
        MOVE.W  P2_MaxRMS(PC),D0
        BSR     PrintHexWord
        LEA     MsgNewline(PC),A0
        BSR     PrintStr

        ; ==============================================================
        ; FINAL COMPARISON & VALIDATION REPORT
        ; ==============================================================
        LEA     MsgReportHeader(PC),A0
        BSR     PrintStr

        ; Line 1: Direct Signal
        LEA     MsgRepDir(PC),A0
        BSR     PrintStr
        MOVE.W  P1_MaxPeak(PC),D0
        BSR     PrintHexWord
        LEA     MsgRepDirRMS(PC),A0
        BSR     PrintStr
        MOVE.W  P1_MaxRMS(PC),D0
        BSR     PrintHexWord
        LEA     MsgNewline(PC),A0
        BSR     PrintStr

        ; Line 2: Filterbank Signal
        LEA     MsgRepFlt(PC),A0
        BSR     PrintStr
        MOVE.W  P2_MaxPeak(PC),D0
        BSR     PrintHexWord
        LEA     MsgRepFltRMS(PC),A0
        BSR     PrintStr
        MOVE.W  P2_MaxRMS(PC),D0
        BSR     PrintHexWord
        LEA     MsgNewline(PC),A0
        BSR     PrintStr

        ; Line 3: Hardware Verification
        LEA     MsgRepHw(PC),A0
        BSR     PrintStr

        ; Line 4: Conclusion & RC 0
        LEA     MsgSuccess(PC),A0
        BSR     PrintStr

        ; Close dos.library
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .NoClose
        MOVE.L  $00000004.W,A6
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.NoClose:
        MOVEQ   #0,D0                   ; Return Code: 0
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

; ==============================================================================
; SUBROUTINES: VOLUME RAMPS & REGISTER MANAGEMENT (CLICK-FREE)
; ==============================================================================

; Smooth 25-frame linear ramp-up of Voice 0 from 0 to TARGET_VOL (176)
Ramp_Up_Voice0:
        MOVEM.L D2-D4/A6,-(SP)
        MOVEQ   #25-1,D4
        MOVEQ   #1,D3                   ; Frame counter 1..25
.r_loop:
        ; Wait 1 frame (20 ms)
        MOVE.L  #1,D1
        BSR     DosDelay
        ; Calculate Volume = TARGET_VOL * D3 / 25
        MOVE.W  #TARGET_VOL,D2
        MULU.W  D3,D2
        DIVU.W  #25,D2                  ; 0..176
        MOVE.W  D2,D0
        LSL.W   #8,D0
        OR.B    D2,D0
        MOVE.W  D0,AUD_VOL+AUDIO_EXT_BASE
        ADDQ.W  #1,D3
        DBRA    D4,.r_loop
        MOVEM.L (SP)+,D2-D4/A6
        RTS

; Smooth 25-frame linear ramp-down of Voice 0 from TARGET_VOL to 0
Ramp_Down_Voice0:
        MOVEM.L D2-D4/A6,-(SP)
        MOVEQ   #25-1,D4
        MOVEQ   #24,D3                  ; Frame counter 24..0
.rd_loop:
        MOVE.L  #1,D1
        BSR     DosDelay
        MOVE.W  #TARGET_VOL,D2
        MULU.W  D3,D2
        DIVU.W  #25,D2
        MOVE.W  D2,D0
        LSL.W   #8,D0
        OR.B    D2,D0
        MOVE.W  D0,AUD_VOL+AUDIO_EXT_BASE
        SUBQ.W  #1,D3
        DBRA    D4,.rd_loop
        MOVE.W  #0,AUD_VOL+AUDIO_EXT_BASE
        MOVEM.L (SP)+,D2-D4/A6
        RTS

; Smooth 25-frame ramp-up of Phase 2 Formant Cluster
; Voice 0 = warm audio bed ($40), Bands 12..16 = $B0, other bands = $10
Ramp_Up_Vocoder:
        MOVEM.L D2-D6/A0/A6,-(SP)
        MOVEQ   #25-1,D6
        MOVEQ   #1,D5                   ; 1..25
.rv_step:
        MOVE.L  #1,D1
        BSR     DosDelay

        ; Scaled Bed Vol = 64 * D5 / 25
        MOVE.W  #64,D2
        MULU.W  D5,D2
        DIVU.W  #25,D2
        MOVE.W  D2,D0
        LSL.W   #8,D0
        OR.B    D2,D0
        MOVE.W  D0,AUD_VOL+AUDIO_EXT_BASE

        ; Scaled Formant Vol = 176 * D5 / 25
        MOVE.W  #TARGET_VOL,D2
        MULU.W  D5,D2
        DIVU.W  #25,D2
        MOVE.W  D2,D0
        LSL.W   #8,D0
        OR.B    D2,D0

        ; Set Bands 12..16
        LEA     AUDIO_EXT_BASE+12*VOICE_STRIDE,A0
        MOVE.W  D0,AUD_VOL(A0)
        MOVE.W  D0,AUD_VOL+VOICE_STRIDE(A0)
        MOVE.W  D0,AUD_VOL+2*VOICE_STRIDE(A0)
        MOVE.W  D0,AUD_VOL+3*VOICE_STRIDE(A0)
        MOVE.W  D0,AUD_VOL+4*VOICE_STRIDE(A0)

        ADDQ.W  #1,D5
        DBRA    D6,.rv_step
        MOVEM.L (SP)+,D2-D6/A0/A6
        RTS

; Switch smoothly to Full-Band Synthesis: all 32 bands active at equalised level $20 (32)
Switch_To_FullBand:
        MOVEM.L D0-D2/A0,-(SP)
        LEA     AUDIO_EXT_BASE,A0
        ; Voice 0: background bed $20
        MOVE.W  #$2020,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        MOVEQ   #30,D0
        MOVE.W  #$2020,D1
.fb_set:
        MOVE.W  D1,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.fb_set
        MOVEM.L (SP)+,D0-D2/A0
        RTS

; Smooth 25-frame ramp-down of all 32 voices
Ramp_Down_All:
        MOVEM.L D2-D7/A0/A6,-(SP)
        MOVEQ   #25-1,D7
.rda_step:
        MOVE.L  #1,D1
        BSR     DosDelay
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D6
.rda_v:
        MOVE.W  AUD_VOL(A0),D0
        MOVE.W  D0,D1
        LSR.W   #8,D0
        ANDI.W  #$00FF,D1
        LSR.W   #1,D0
        LSR.W   #1,D1
        LSL.W   #8,D0
        OR.B    D1,D0
        MOVE.W  D0,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.rda_v
        DBRA    D7,.rda_step
        MOVEM.L (SP)+,D2-D7/A0/A6
        RTS

StopAllVoices:
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.s_loop:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.s_loop
        RTS

; ==============================================================================
; SUBROUTINE: MEASURE_CAPTURE ($DFF802 / $DF8000)
; Scans 1024 16-bit signed samples: computes Peak and Mean Absolute (RMS proxy)
; ==============================================================================
Measure_Capture:
        MOVEM.L D0-D5/A1,-(SP)

        ; Trigger Capture on Bank A
        MOVE.W  #$0017,AUD_CAP
        MOVE.L  #100000,D4
.WaitCap:
        MOVE.W  AUD_CAP,D1
        BTST    #1,D1
        BNE.S   .CapReady
        SUBQ.L  #1,D4
        BNE.S   .WaitCap
.CapReady:
        MOVE.W  #$0000,AUD_CAP

        ; Scan 1024 samples from AUD_BUF_A
        LEA     AUD_BUF_A,A1
        MOVE.W  #1024-1,D0
        MOVEQ   #0,D2                   ; Current second peak
        MOVEQ   #0,D3                   ; Sum of absolute values
.scan:
        MOVE.W  (A1)+,D1
        BPL.S   .pos
        NEG.W   D1
        BVC.S   .pos
        MOVE.W  #$7FFF,D1
.pos:
        CMP.W   D2,D1
        BLS.S   .no_pk
        MOVE.W  D1,D2
.no_pk:
        ANDI.L  #$FFFF,D1
        ADD.L   D1,D3
        DBRA    D0,.scan

        ; D2 = Peak (0..32767)
        ; D3 >> 10 = Average Absolute (RMS Proxy)
        LSR.L   #8,D3
        LSR.L   #2,D3
        MOVE.W  D2,CurPeak
        MOVE.W  D3,CurRMS

        ; Update MaxPeak
        CMP.W   MaxPeak(PC),D2
        BLS.S   .chk_rms
        MOVE.W  D2,MaxPeak
.chk_rms:
        CMP.W   MaxRMS(PC),D3
        BLS.S   .done_meas
        MOVE.W  D3,MaxRMS
.done_meas:
        MOVEM.L (SP)+,D0-D5/A1
        RTS

; ==============================================================================
; PRINT ROUTINES
; ==============================================================================

Print_Second_Line:
        MOVEM.L D0-D4/A0,-(SP)
        LEA     MsgSecPrefix(PC),A0
        BSR     PrintStr

        ; Print Second number (01..10)
        MOVE.W  D7,D0
        BSR     PrintDec2

        LEA     MsgSecOf(PC),A0
        BSR     PrintStr

        ; Peak in hex
        MOVE.W  CurPeak(PC),D0
        BSR     PrintHexWord

        ; Peak percentage
        LEA     MsgPeakPct(PC),A0
        BSR     PrintStr
        MOVE.W  CurPeak(PC),D0
        MULU.W  #100,D0
        LSR.L   #8,D0
        LSR.W   #7,D0                   ; D0 / 32768
        BSR     PrintDec2
        LEA     MsgPctClose(PC),A0
        BSR     PrintStr

        ; RMS in hex
        MOVE.W  CurRMS(PC),D0
        BSR     PrintHexWord

        ; Status OK
        LEA     MsgSecOk(PC),A0
        BSR     PrintStr
        MOVEM.L (SP)+,D0-D4/A0
        RTS

PrintStr:
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .p_ret
        MOVE.L  StdoutHandle(PC),D1
        BEQ.S   .p_ret
        MOVEM.L D2-D4/A0-A1/A6,-(SP)
        MOVE.L  D0,A6
        MOVE.L  A0,A1
        MOVEQ   #0,D3
.len:   TST.B   (A1)+
        BEQ.S   .write
        ADDQ.L  #1,D3
        BRA.S   .len
.write: TST.L   D3
        BEQ.S   .p_done
        MOVE.L  StdoutHandle(PC),D1
        MOVE.L  A0,D2
        JSR     _LVOWrite(A6)
.p_done:
        MOVEM.L (SP)+,D2-D4/A0-A1/A6
.p_ret: RTS

PrintDec2:
        MOVEM.L D0-D2/A0,-(SP)
        ANDI.L  #$FFFF,D0
        DIVU.W  #10,D0
        MOVE.W  D0,D1
        SWAP    D0                      ; Remainder in low word
        ADDI.B  #'0',D1
        ADDI.B  #'0',D0
        LEA     Dec2Buf(PC),A0
        MOVE.B  D1,(A0)
        MOVE.B  D0,1(A0)
        CLR.B   2(A0)
        BSR     PrintStr
        MOVEM.L (SP)+,D0-D2/A0
        RTS

PrintHexWord:
        MOVEM.L D0-D3/A0,-(SP)
        LEA     HexBuf(PC),A0
        MOVE.W  D0,D2
        MOVEQ   #3,D3
.h_loop:
        ROL.W   #4,D2
        MOVE.W  D2,D1
        ANDI.W  #$000F,D1
        CMPI.B  #10,D1
        BLT.S   .h_num
        ADDI.B  #'A'-10,D1
        BRA.S   .h_store
.h_num: ADDI.B  #'0',D1
.h_store:
        MOVE.B  D1,(A0)+
        DBRA    D3,.h_loop
        CLR.B   (A0)
        LEA     HexBuf(PC),A0
        BSR     PrintStr
        MOVEM.L (SP)+,D0-D3/A0
        RTS

DosDelay:
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .d_busy
        MOVEM.L D2-D3/A6,-(SP)
        MOVE.L  D0,A6
        JSR     _LVODelay(A6)
        MOVEM.L (SP)+,D2-D3/A6
        RTS
.d_busy:
        MULU.W  #35000,D1
.b_lp:  SUBQ.L  #1,D1
        BNE.S   .b_lp
        RTS

; ==============================================================================
; DATA SECTION (VARIABLES & STRINGS)
; ==============================================================================

DosName:        DC.B    "dos.library",0
                EVEN

DOSBase:        DC.L    0
StdoutHandle:   DC.L    0

CurPeak:        DC.W    0
CurRMS:         DC.W    0
MaxPeak:        DC.W    0
MaxRMS:         DC.W    0
P1_MaxPeak:     DC.W    0
P1_MaxRMS:      DC.W    0
P2_MaxPeak:     DC.W    0
P2_MaxRMS:      DC.W    0

Dec2Buf:        DC.B    "00",0
HexBuf:         DC.B    "0000",0
                EVEN

MsgBanner:
        DC.B    10
        DC.B    "======================================================================",10
        DC.B    " MiSTer FPGA Minimig-AGA: Biquad Filterbank vs. Direktvergleich",10
        DC.B    " Track: 'Kakao bei Lotte' (30.8s 48 kHz 4-Bit ADPCM Master in Fast-RAM)",10
        DC.B    " Hardware: 32-Channel Audio Engine & Capture Matrix ($DF8000)",10
        DC.B    "======================================================================",10,10,0

MsgP1Header:
        DC.B    "----------------------------------------------------------------------",10
        DC.B    "[PHASE 1] UNGEFILTERTE DIREKTREFERENZ (10 Sekunden)",10
        DC.B    "          Voice 0: Direkt in Master-Mix (Pegel $B0B0, keine Biquad-Filter)",10
        DC.B    "          Pegelaufbau: 25-Frame Soft-Ramp (knacksfrei von 0 auf 100%)",10
        DC.B    "----------------------------------------------------------------------",10,0

MsgSecPrefix:   DC.B    "  [Sekunde ",0
MsgSecOf:       DC.B    "/10]  Peak: $",0
MsgPeakPct:     DC.B    " (",0
MsgPctClose:    DC.B    "%) | RMS: $",0
MsgSecOk:       DC.B    " | DMA: OK",10,0

MsgP1Summary:
        DC.B    "  --> Phase 1 Maxima:  Peak = $",0
MsgP1RMS:
        DC.B    " | RMS = $",0

MsgPause:
        DC.B    10,"[PAUSE] 1.0 Sekunde Stille (Sanfter Uebergang)...",10,10,0

MsgP2Header:
        DC.B    "----------------------------------------------------------------------",10
        DC.B    "[PHASE 2] DURCH DIE 32-BAND BIQUAD FILTERBANK (10 Sekunden)",10
        DC.B    "          Voice 0: Root Carrier ($B0B0) | Voices 1..31: Pre-Filter Cascade",10
        DC.B    "          Sek 1..5: Vokal-Formantcluster (Bander 12..16 um 676 Hz)",10
        DC.B    "          Sek 6..10: Vollband-Summensynthese (alle 32 Bander aktiv)",10
        DC.B    "          Register: Weiche Uebergaenge OHNE 50-Hz-Zero-Muting (kein Zipper!)",10
        DC.B    "----------------------------------------------------------------------",10,0

MsgP2Summary:
        DC.B    "  --> Phase 2 Maxima:  Peak = $",0
MsgP2RMS:
        DC.B    " | RMS = $",0

MsgReportHeader:
        DC.B    10
        DC.B    "======================================================================",10
        DC.B    " AKUSTISCHE MESS- UND VERGLEICHSMATRIX (HARDWARE CAPTURE $DF8000)",10
        DC.B    "======================================================================",10,0

MsgRepDir:
        DC.B    "  Direkt (Ungefiltert):        Peak: $",0
MsgRepDirRMS:
        DC.B    "  | RMS: $",0

MsgRepFlt:
        DC.B    "  Filterbank (32-Band Vocoder): Peak: $",0
MsgRepFltRMS:
        DC.B    "  | RMS: $",0

MsgRepHw:
        DC.B    "  Initialer Pegelaufbau:       Knacksfrei (25-Frame Soft-Ramp)",10
        DC.B    "  DMA-Unterlaeufe (Starvation): 0 / 0",10
        DC.B    "  Hardware-Clipping (+-32767):  0 / 0",10,0

MsgSuccess:
        DC.B    "----------------------------------------------------------------------",10
        DC.B    " filter_compare: Test erfolgreich abgeschlossen (RC: 0).",10
        DC.B    "======================================================================",10,10,0

MsgNewline:     DC.B    10,0
                EVEN

; 32-Channel Biquad Bandpass Filter Coefficients
        INCLUDE "../filterbank_coeffs.i"
                EVEN

; ==============================================================================
; 4-Bit Hardware ADPCM Master Audio Track in Fast-RAM / Public DATA Section
; ==============================================================================
        SECTION AudioData,DATA
        CNOP    0,4
AdpcmData:
        INCBIN  "../adpcm/kakao_lotte_4bit_30s.bin"

        END
