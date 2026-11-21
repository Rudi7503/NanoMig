; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Direktvergleich 16-Bit PCM vs. 4-Bit ADPCM
;
; Kickstart 1.3 kompatibel (dos.library Output/Write/Delay)
;
; Spielt dasselbe Musik-Sample ("Kakao bei Lotte", 48 kHz Mono) nacheinander
; ueber Stimme 0 ab:
;   Phase 1 (5 Sekunden): 16-Bit PCM unkomprimiert (96.000 Bytes, Referenz)
;   Pause (0,5 Sekunden Stille)
;   Phase 2 (5 Sekunden): 4-Bit ADPCM komprimiert (24.000 Bytes, 4:1 Datenreduktion)
;
; Assembler: vasmm68k_mot -Fhunk -o pcm_vs_adpcm.o pcm_vs_adpcm.s
; Linker:    vlink -bamigahunk -x -Bstatic -o pcm_vs_adpcm pcm_vs_adpcm.o
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
AUD_CMD         EQU $1A

CTRL_16BIT      EQU $0001       ; Bit 0: 16-Bit PCM Modus
CTRL_ADPCM      EQU $0008       ; Bit 3: 4-Bit ADPCM Decoder

PER_48K         EQU 521         ; 48 kHz
PCM_BYTES       EQU 96000       ; 48.000 Samples * 2 Bytes = 1 Sekunde
ADPCM_BYTES     EQU 24000       ; 48.000 Nibbles * 0.5 Bytes = 1 Sekunde

_LVOOpenLibrary  EQU -552
_LVOCloseLibrary EQU -414
_LVOWrite        EQU -48
_LVOOutput       EQU -60
_LVODelay        EQU -198

        SECTION text,CODE

Start:
        MOVEM.L D2-D7/A2-A6,-(SP)

        ; 1. dos.library oeffnen
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

        ; Banner ausgeben
        LEA     MsgBanner(PC),A0
        BSR     PrintStr

        ; Alle 32 Stimmen stoppen
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.StopAll:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.StopAll

        ; ==============================================================
        ; PHASE 1: 16-Bit PCM unkomprimiert (Referenz)
        ; ==============================================================
        LEA     MsgPhase1(PC),A0
        BSR     PrintStr

        LEA     AUDIO_EXT_BASE,A0
        MOVE.L  #PcmData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.L  #PCM_BYTES,D0
        MOVE.W  D0,AUD_LENL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$FFFF,AUD_VOL(A0)              ; 100% Lautstaerke Center
        MOVE.W  #CTRL_16BIT,AUD_CTRL(A0)        ; 16-Bit PCM Mono
        MOVE.W  #$0001,AUD_CMD(A0)              ; Start Stimme 0

        ; 5 Sekunden lang abspielen (250 Ticks)
        MOVE.L  #250,D1
        BSR     DosDelay

        ; Stimme 0 stoppen
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)

        ; 0,5 Sekunden Pause (25 Ticks)
        MOVE.L  #25,D1
        BSR     DosDelay

        ; ==============================================================
        ; PHASE 2: 4-Bit ADPCM komprimiert (4:1 Datenreduktion)
        ; ==============================================================
        LEA     MsgPhase2(PC),A0
        BSR     PrintStr

        LEA     AUDIO_EXT_BASE,A0
        MOVE.L  #AdpcmData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #ADPCM_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #0,AUD_PRED(A0)                 ; Startpraediktor 0, Index 0
        MOVE.W  #$FFFF,AUD_VOL(A0)              ; 100% Lautstaerke Center
        MOVE.W  #CTRL_ADPCM,AUD_CTRL(A0)        ; 4-Bit ADPCM Mono
        MOVE.W  #$0001,AUD_CMD(A0)              ; Start Stimme 0

        ; 5 Sekunden lang abspielen (250 Ticks)
        MOVE.L  #250,D1
        BSR     DosDelay

        ; Stimme 0 stoppen
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)

        ; ==============================================================
        ; Abschluss
        ; ==============================================================
        LEA     MsgDone(PC),A0
        BSR     PrintStr

        ; dos.library schliessen
        MOVE.L  DOSBase(PC),A1
        MOVE.L  $00000004.W,A6
        JSR     _LVOCloseLibrary(A6)

        MOVEQ   #0,D0
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

; ------------------------------------------------------------------
; Hilfsroutine: DosDelay
; ------------------------------------------------------------------
DosDelay:
        MOVEM.L D0-D1/A0-A1/A6,-(SP)
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .NoDos
        MOVE.L  D0,A6
        JSR     _LVODelay(A6)
.NoDos:
        MOVEM.L (SP)+,D0-D1/A0-A1/A6
        RTS

; ------------------------------------------------------------------
; Textausgabe ueber dos.library Write
; ------------------------------------------------------------------
PrintStr:
        MOVEM.L D0-D3/A0-A1/A6,-(SP)
        MOVE.L  StdoutHandle(PC),D1
        BEQ.S   .Exit
        MOVE.L  A0,D2
        MOVE.L  A0,A1
.LenLoop:
        TST.B   (A1)+
        BNE.S   .LenLoop
        SUBQ.L  #1,A1
        SUBA.L  A0,A1
        MOVE.L  A1,D3
        BEQ.S   .Exit
        MOVE.L  DOSBase(PC),A6
        JSR     _LVOWrite(A6)
.Exit:
        MOVEM.L (SP)+,D0-D3/A0-A1/A6
        RTS

; ------------------------------------------------------------------
; Daten
; ------------------------------------------------------------------
                EVEN
DosName:        DC.B    "dos.library",0
MsgBanner:      DC.B    10,"==================================================",10
                DC.B    "*** VERGLEICHSTEST: 16-BIT PCM vs. 4-BIT ADPCM ***",10
                DC.B    "Gleiches Audio-Sample ('Kakao bei Lotte', 48 kHz)",10
                DC.B    "==================================================",10,0
MsgPhase1:      DC.B    "[Phase 1/2] 16-Bit PCM unkomprimiert (96.000 Bytes, 5 Sek.)...",10,0
MsgPhase2:      DC.B    "[Phase 2/2] 4-Bit ADPCM komprimiert (24.000 Bytes, 5 Sek.)...",10,0
MsgDone:        DC.B    "*** Vergleichstest erfolgreich beendet! ***",10,10,0

                EVEN
DOSBase:        DC.L    0
StdoutHandle:   DC.L    0

; ------------------------------------------------------------------
; Chip-RAM Audiodaten
; ------------------------------------------------------------------
                EVEN
                SECTION chip_data,DATA_C
PcmData:
                INCBIN  "../adpcm/pcm_16bit_mono.bin"
                EVEN
AdpcmData:
                INCBIN  "../adpcm/adpcm_4bit.bin"

                END
