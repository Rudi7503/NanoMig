; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Isolierter Tontest (Stimme 0 direkt)
;
; Kickstart 1.3 kompatibel (dos.library Output/Write)
; Spielt 200 Hz Rechteckschwingung auf Stimme 0 mit 100% Lautstaerke ($FFFF)
; OHNE Filter, OHNE Kaskadierung, OHNE Capture.
;
; Assembler: vasmm68k_mot -Fhunk -o ton_test.o ton_test.s
; Linker:    vlink -bamigahunk -x -Bstatic -o ton_test ton_test.o
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
AUD_CMD         EQU $1A

CTRL_16BIT      EQU $0001
CTRL_STEREO     EQU $0004

PER_48K         EQU 521

_LVOOpenLibrary  EQU -552
_LVOCloseLibrary EQU -414
_LVOWrite        EQU -48
_LVOOutput       EQU -60
_LVODelay        EQU -198

        SECTION text,CODE

Start:
        MOVEM.L D2-D7/A2-A6,-(SP)

        ; dos.library oeffnen fuer Shell-Textausgabe
        MOVE.L  4.W,A6                          ; ExecBase
        LEA     DosName(PC),A1
        MOVEQ   #0,D0                           ; Version 0 (Kickstart 1.2+)
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
        ; 1. Alle Stimmen stoppen und stummschalten
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D7
.StopAll:
        MOVE.W  #$0002,AUD_CMD(A0)              ; Stop
        MOVE.W  #$0000,AUD_VOL(A0)              ; Lautstaerke 0
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.StopAll

        ; 2. Stimme 0 vorbereiten: 200 Hz Rechteck, 100% Lautstaerke ($FFFF)
        LEA     AUDIO_EXT_BASE,A0
        MOVE.L  #RechteckData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #RECHTECK_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$FFFF,AUD_VOL(A0)              ; 100% Links + 100% Rechts!
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO),AUD_CTRL(A0) ; Ungefiltert, Stereo

        LEA     MsgPlaying(PC),A0
        BSR     PrintStr

        ; 3. Stimme 0 starten
        MOVE.W  #$0001,AUD_CMD(A0)              ; Start
        MOVE.W  #$00F0,COLOR00                  ; Rahmen gruen

        ; 4. Fuer ca. 5 Sekunden toenen lassen (250 Ticks via dos.library Delay)
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .BusyWait
        MOVE.L  D0,A6
        MOVE.L  #250,D1                         ; 250 Ticks = 5 Sekunden (50 Hz PAL)
        JSR     _LVODelay(A6)
        BRA.S   .StopAudio

.BusyWait:
        MOVE.L  #1500000,D0
.BLoop: SUBQ.L  #1,D0
        BNE.S   .BLoop

.StopAudio:
        ; 5. Stimme 0 stoppen
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0002,AUD_CMD(A0)              ; Stop
        MOVE.W  #$0000,AUD_VOL(A0)

        LEA     MsgDone(PC),A0
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
; Hilfsroutine: PrintStr (String in A0 via dos.library Write ausgeben)
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
; Texte & Variablen
; ------------------------------------------------------------------
DosName:        DC.B    "dos.library",0
MsgBanner:      DC.B    10,"==================================================",10
                DC.B    "*** TON-TEST GESTARTET (KICKSTART 1.3) ***",10
                DC.B    "ton_test: Stimme 0 Direktausgabe (ungefiltert)",10
                DC.B    "==================================================",10,0
MsgPlaying:     DC.B    "ton_test: Stimme 0 gestartet auf 200 Hz mit 100% Lautstaerke ($FFFF).",10
                DC.B    "ton_test: Ton sollte jetzt fuer 5 Sekunden laut aus Boxen/HDMI toenen...",10,0
MsgDone:        DC.B    "ton_test: Test beendet, Stimme 0 gestoppt (Return Code: 0).",10,10,0

                EVEN
DOSBase:        DC.L    0
StdoutHandle:   DC.L    0

; ------------------------------------------------------------------
; Chip-RAM Audiodaten
; ------------------------------------------------------------------
                EVEN
                SECTION chip_data,DATA_C
                INCLUDE "../rechteck/rechteck_data.i"

                END
