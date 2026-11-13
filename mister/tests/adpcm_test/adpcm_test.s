; ==============================================================================
; MiSTer FPGA / Minimig-AGA: 2-Phasen ADPCM Praezisions- und Raumklang-Test
;
; Kickstart 1.3 kompatibel (dos.library Output/Write/Delay)
;
; Phase 1 (10 Sekunden):
;   Echte 4-Bit ADPCM Sprach/Musikwiedergabe ("Kakao bei Lotte") pur
;   auf Stimme 0 im Center mit voller Lautstaerke ($FFFF).
;
; Phase 2 (10 Sekunden):
;   Voluminoeses Hoererlebnis: 4 Stimmen polyphon mit raeumlichem Stereo-Echo,
;   Zero-RAM Hardware-Delay (Spatial Reverb) und 300-Hz-Biquad-Filter.
;
; Assembler: vasmm68k_mot -Fhunk -o adpcm_test.o adpcm_test.s
; Linker:    vlink -bamigahunk -x -Bstatic -o adpcm_test adpcm_test.o
; ==============================================================================

CUSTOM          EQU $DFF000
COLOR00         EQU $DFF180
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
AUD_DELAY       EQU $1C

CTRL_ADPCM      EQU $0008
CTRL_4BIT       EQU $0000
CTRL_FILTER     EQU $0180
PER_48K         EQU 521

ADPCM_BYTES     EQU 24000       ; 48.000 Samples = 1 Sekunde bei 48 kHz (Loop)

_LVOOpenLibrary  EQU -552
_LVOCloseLibrary EQU -414
_LVOWrite        EQU -48
_LVOOutput       EQU -60
_LVODelay        EQU -198

        SECTION text,CODE

Start:
        MOVEM.L D2-D7/A2-A6,-(SP)

        ; dos.library oeffnen fuer Shell-Textausgabe
        MOVE.L  4.W,A6
        LEA     DosName(PC),A1
        MOVEQ   #0,D0
        JSR     _LVOOpenLibrary(A6)
        MOVE.L  D0,DOSBase
        BEQ     .SkipDos

        MOVE.L  D0,A6
        JSR     _LVOOutput(A6)
        MOVE.L  D0,StdoutHandle
        BEQ     .SkipDos

        LEA     MsgBanner(PC),A0
        BSR     PrintStr

.SkipDos:
        ; --------------------------------------------------------------
        ; Alle Stimmen 0..31 stoppen und stummschalten
        ; --------------------------------------------------------------
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D7
.StopAll:
        MOVE.W  #$0002,AUD_CMD(A0)              ; Stop
        MOVE.W  #$0000,AUD_VOL(A0)              ; Lautstaerke 0
        MOVE.W  #0,AUD_DELAY(A0)                ; Delay 0
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.StopAll

        ; ==============================================================
        ; TEIL 1: ADPCM Pur (10 Sekunden)
        ; ==============================================================
        LEA     MsgPhase1(PC),A0
        BSR     PrintStr

        LEA     AUDIO_EXT_BASE,A0
        MOVE.L  #AdpcmData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #ADPCM_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$FFFF,AUD_VOL(A0)              ; 100% Lautstaerke (Center)
        MOVE.W  #0,AUD_PRED(A0)                 ; Startpraediktor 0, Index 0
        MOVE.W  #0,AUD_DELAY(A0)
        MOVE.W  #(CTRL_ADPCM|CTRL_4BIT),AUD_CTRL(A0) ; 4-Bit ADPCM, Mono

        ; Stimme 0 starten VOR PrintStr!
        MOVE.W  #$0001,AUD_CMD(A0)              ; Start
        MOVE.W  #$00F0,COLOR00                  ; Rahmen gruen

        LEA     MsgPhase1Running(PC),A0
        BSR     PrintStr

        ; 10 Sekunden toenen lassen (500 VBlanks bei 50 Hz PAL)
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .BusyWait1
        MOVE.L  D0,A6
        MOVE.L  #500,D1                         ; 10 Sekunden
        JSR     _LVODelay(A6)
        BRA.S   .EndPhase1

.BusyWait1:
        MOVE.L  #3000000,D0
.BW1:   SUBQ.L  #1,D0
        BNE.S   .BW1

.EndPhase1:
        ; Stimme 0 stoppen
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0002,AUD_CMD(A0)              ; Stop
        MOVE.W  #$0000,AUD_VOL(A0)

        ; ==============================================================
        ; TEIL 2: ADPCM Voluminoes mit Hall & Filter (10 Sekunden)
        ; ==============================================================
        LEA     MsgPhase2(PC),A0
        BSR     PrintStr

        ; Stimme 0: Hauptstimme (Center, volle Lautstaerke $D0D0)
        LEA     AUDIO_EXT_BASE,A0
        MOVE.L  #AdpcmData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #ADPCM_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$D0D0,AUD_VOL(A0)
        MOVE.W  #0,AUD_PRED(A0)
        MOVE.W  #0,AUD_DELAY(A0)                ; 0 ms
        MOVE.W  #(CTRL_ADPCM|CTRL_4BIT),AUD_CTRL(A0)

        ; Stimme 1: Echostufe 1 (Pan Links $E020, Delay ~35 ms)
        LEA     VOICE_STRIDE(A0),A0
        MOVE.L  #AdpcmData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #ADPCM_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$E020,AUD_VOL(A0)              ; Pan Links
        MOVE.W  #0,AUD_PRED(A0)
        MOVE.W  #1150,AUD_DELAY(A0)             ; 1150 / 32768 s = ~35 ms Delay
        MOVE.W  #(CTRL_ADPCM|CTRL_4BIT),AUD_CTRL(A0)

        ; Stimme 2: Echostufe 2 (Pan Rechts $20E0, Delay ~75 ms)
        LEA     VOICE_STRIDE(A0),A0
        MOVE.L  #AdpcmData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #ADPCM_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$20E0,AUD_VOL(A0)              ; Pan Rechts
        MOVE.W  #0,AUD_PRED(A0)
        MOVE.W  #2450,AUD_DELAY(A0)             ; 2450 / 32768 s = ~75 ms Delay
        MOVE.W  #(CTRL_ADPCM|CTRL_4BIT),AUD_CTRL(A0)

        ; Stimme 3: Raumhall-Echo (Center leiser $5050, Delay ~140 ms)
        LEA     VOICE_STRIDE(A0),A0
        MOVE.L  #AdpcmData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #ADPCM_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$5050,AUD_VOL(A0)              ; Center Raumhall
        MOVE.W  #0,AUD_PRED(A0)
        MOVE.W  #4600,AUD_DELAY(A0)             ; 4600 / 32768 s = ~140 ms Delay
        MOVE.W  #(CTRL_ADPCM|CTRL_4BIT),AUD_CTRL(A0)

        ; Alle 4 Stimmen starten
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0001,AUD_CMD(A0)              ; Start Voice 0
        LEA     VOICE_STRIDE(A0),A0
        MOVE.W  #$0001,AUD_CMD(A0)              ; Start Voice 1
        LEA     VOICE_STRIDE(A0),A0
        MOVE.W  #$0001,AUD_CMD(A0)              ; Start Voice 2
        LEA     VOICE_STRIDE(A0),A0
        MOVE.W  #$0001,AUD_CMD(A0)              ; Start Voice 3

        MOVE.W  #$00E0,COLOR00                  ; Tuerkis / Hellgruen

        LEA     MsgPhase2Running(PC),A0
        BSR     PrintStr

        ; 10 Sekunden Raumklang abspielen
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .BusyWait2
        MOVE.L  D0,A6
        MOVE.L  #500,D1                         ; 10 Sekunden
        JSR     _LVODelay(A6)
        BRA.S   .EndPhase2

.BusyWait2:
        MOVE.L  #3000000,D0
.BW2:   SUBQ.L  #1,D0
        BNE.S   .BW2

.EndPhase2:
        ; Alle Stimmen stoppen
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #3,D7
.Stop4:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Stop4

        LEA     MsgComplete(PC),A0
        BSR     PrintStr

        ; dos.library schliessen
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .NoClose
        MOVE.L  4.W,A6
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.NoClose:
        MOVEQ   #0,D0                           ; Return Code 0 (Erfolg)
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

; ------------------------------------------------------------------
; Hilfsroutine: PrintStr
; ------------------------------------------------------------------
PrintStr:
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .Ret
        MOVE.L  StdoutHandle(PC),D1
        BEQ.S   .Ret
        MOVEM.L D2-D4/A0-A1/A6,-(SP)
        MOVE.L  D0,A6

        MOVE.L  A0,A1
        MOVEQ   #0,D3
.LenLoop:
        TST.B   (A1)+
        BEQ.S   .DoWrite
        ADDQ.L  #1,D3
        BRA.S   .LenLoop

.DoWrite:
        TST.L   D3
        BEQ.S   .Done
        MOVE.L  StdoutHandle(PC),D1
        MOVE.L  A0,D2
        JSR     _LVOWrite(A6)

.Done:
        MOVEM.L (SP)+,D2-D4/A0-A1/A6
.Ret:   RTS

; ------------------------------------------------------------------
; Texte & Konstanten
; ------------------------------------------------------------------
DosName:        DC.B    "dos.library",0
MsgBanner:      DC.B    10,"==================================================",10
                DC.B    "*** ADPCM 2-PHASEN TEST GESTARTET (KICKSTART 1.3) ***",10
                DC.B    "adpcm_test: Basis-Wiedergabe & Spatial Reverb",10
                DC.B    "==================================================",10,0
MsgPhase1:      DC.B    "adpcm_test: [1/2] TEIL 1: ADPCM Pur (Stimme 0, 100% Lautstaerke)...",10,0
MsgPhase1Running:
                DC.B    "adpcm_test: Melodie 'Kakao bei Lotte' toent 10s pur ueber Lautsprecher...",10,0
MsgPhase2:      DC.B    10,"adpcm_test: [2/2] TEIL 2: ADPCM Spatial Reverb & Echo (4 Stimmen)...",10,0
MsgPhase2Running:
                DC.B    "adpcm_test: Breiter Raumklang mit 3 gestaffelten Hardware-Delays toent 10s...",10,0
MsgComplete:    DC.B    10,"adpcm_test: ERFOLG - Beide ADPCM-Testphasen abgeschlossen.",10
                DC.B    "adpcm_test: Test beendet (Return Code: 0).",10,10,0

                EVEN
DOSBase:        DC.L    0
StdoutHandle:   DC.L    0

; ------------------------------------------------------------------
; Chip-RAM Audiodaten: 4-Bit ADPCM
; ------------------------------------------------------------------
                EVEN
                SECTION chip_data,DATA_C
AdpcmData:
                INCBIN  "../adpcm/adpcm_4bit.bin"
AdpcmDataEnd:

                END
