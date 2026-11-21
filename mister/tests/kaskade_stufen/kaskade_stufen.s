; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Kaskaden-Stufentest (1, 2, 4, 8, 16 Stufen)
;
; Kickstart 1.3 kompatibel (dos.library Output/Write/Delay)
; Misst schrittweise:
;   - 1 Stufe  (Stimme 0)
;   - 2 Stufen (Stimme 0 -> 1)
;   - 4 Stufen (Stimme 0 -> 3)
;   - 8 Stufen (Stimme 0 -> 7)
;   - 16 Stufen (Stimme 0 -> 15)
;
; Schreibt fuer JEDE Stufe Min/Max, Peak, Peak-to-Peak und erste 8 Roh-Samples
; in die Konsole und laesst den Ton jeweils 2 Sekunden toenen.
;
; Assembler: vasmm68k_mot -Fhunk -o kaskade_stufen.o kaskade_stufen.s
; Linker:    vlink -bamigahunk -x -Bstatic -o kaskade_stufen kaskade_stufen.o
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
AUD_BQ_B0       EQU $10
AUD_BQ_B1       EQU $12
AUD_BQ_B2       EQU $14
AUD_BQ_A1       EQU $16
AUD_BQ_A2       EQU $18
AUD_CMD         EQU $1A

AUD_CAP         EQU $DFF802
AUD_BUF_A       EQU $DF8000

CTRL_16BIT      EQU $0001
CTRL_STEREO     EQU $0004
CTRL_FILTER     EQU $0180
CTRL_CHAIN_POST EQU $0400

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
        ; Hauptschleife ueber die Stufen-Tabelle (1, 2, 4, 8, 16)
        LEA     StageTable(PC),A4

.StageLoop:
        MOVE.W  (A4)+,D7                        ; D7 = Anzahl Stufen (z.B. 1, 2, 4, 8, 16)
        BEQ     .AllDone                        ; 0 = Tabellenende

        ; Banner fuer aktuelle Stufe ausgeben
        LEA     MsgStageHdr(PC),A0
        BSR     PrintStr
        MOVE.W  D7,D0
        ANDI.L  #$FFFF,D0
        BSR     PrintDec
        LEA     MsgNewline(PC),A0
        BSR     PrintStr

        ; 1. Alle 32 Stimmen stoppen und stummschalten
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.StopAll:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.StopAll

        ; 2. Stimmen 0 .. (D7-1) vorbereiten
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  D7,D6                           ; Schleifenzaehler = D7
        SUBQ.W  #1,D6
        MOVEQ   #0,D5                           ; D5 = Aktueller Stimmen-Index (0..)

.SetupVoice:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)              ; Standardmaessig stumm
        MOVE.L  #RechteckData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #BQ_B0,AUD_BQ_B0(A0)
        MOVE.W  #BQ_B1,AUD_BQ_B1(A0)
        MOVE.W  #BQ_B2,AUD_BQ_B2(A0)
        MOVE.W  #BQ_A1,AUD_BQ_A1(A0)
        MOVE.W  #BQ_A2,AUD_BQ_A2(A0)

        TST.W   D5
        BNE.S   .SlaveVoice

        ; Root Voice (Stimme 0: Spielt DMA-Puffer)
        MOVE.W  #RECHTECK_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER),AUD_CTRL(A0)
        BRA.S   .CheckEndVoice

.SlaveVoice:
        ; Folge-Stimme (Kaskadiert vom Vorgaenger)
        MOVE.W  #0,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER|CTRL_CHAIN_POST),AUD_CTRL(A0)

.CheckEndVoice:
        ; Ist dies die letzte Stimme der Kette? -> Dann 100% Lautstaerke!
        MOVE.W  D7,D1
        SUBQ.W  #1,D1
        CMP.W   D1,D5
        BNE.S   .NextVoice
        MOVE.W  #$FFFF,AUD_VOL(A0)              ; Volle Lautstaerke auf Endstufe

.NextVoice:
        LEA     VOICE_STRIDE(A0),A0
        ADDQ.W  #1,D5
        DBRA    D6,.SetupVoice

        ; 3. Stimmen 0 .. (D7-1) starten
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  D7,D6
        SUBQ.W  #1,D6
.StartRun:
        MOVE.W  #$0001,AUD_CMD(A0)              ; Start
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.StartRun

        ; Einschwingen lassen (~50 ms)
        MOVE.L  #150000,D0
.SLoop: SUBQ.L  #1,D0
        BNE.S   .SLoop

        ; 4. Hardware-Capture Block A
        MOVE.W  #$0017,AUD_CAP
        MOVE.L  #500000,D4
.WaitA:
        MOVE.W  AUD_CAP,D1
        BTST    #1,D1
        BNE.S   .CapOk
        SUBQ.L  #1,D4
        BNE.S   .WaitA
        BRA     .CapTimeout

.CapOk:
        MOVE.W  #$0000,AUD_CAP                  ; Capture aus

        ; 5. Min- und Max-Werte scannen
        LEA     AUD_BUF_A,A1
        MOVE.W  #1023,D0
        MOVE.W  (A1)+,D1
        ADDQ.L  #2,A1
        EXT.L   D1
        MOVE.L  D1,D2                           ; D2 = Min
        MOVE.L  D1,D3                           ; D3 = Max
        SUBQ.W  #1,D0

.ScanMM:
        MOVE.W  (A1)+,D1
        ADDQ.L  #2,A1
        EXT.L   D1
        CMP.L   D2,D1
        BGE.S   .NotMin
        MOVE.L  D1,D2
.NotMin:
        CMP.L   D3,D1
        BLE.S   .NotMax
        MOVE.L  D1,D3
.NotMax:
        DBRA    D0,.ScanMM

        ; Min / Max ausgeben
        LEA     MsgMinMax(PC),A0
        BSR     PrintStr
        MOVE.L  D2,D0
        BSR     PrintSignedDec
        LEA     MsgTo(PC),A0
        BSR     PrintStr
        MOVE.L  D3,D0
        BSR     PrintSignedDec

        ; Peak-to-Peak (Max - Min)
        LEA     MsgPkPk(PC),A0
        BSR     PrintStr
        MOVE.L  D3,D0
        SUB.L   D2,D0
        BSR     PrintSignedDec
        LEA     MsgNewline(PC),A0
        BSR     PrintStr

        ; Erste 8 Rohsamples ausgeben
        LEA     MsgSamples(PC),A0
        BSR     PrintStr
        LEA     AUD_BUF_A,A1
        MOVEQ   #7,D6
.DumpLoop:
        MOVE.W  (A1)+,D0
        ADDQ.L  #2,A1
        EXT.L   D0
        BSR     PrintSignedDec
        LEA     MsgSpace(PC),A0
        BSR     PrintStr
        DBRA    D6,.DumpLoop
        LEA     MsgNewline(PC),A0
        BSR     PrintStr

        ; 2 Sekunden abspielen lassen
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .NoDelay
        MOVE.L  D0,A6
        MOVE.L  #100,D1                         ; 100 Ticks = 2 Sekunden
        JSR     _LVODelay(A6)
.NoDelay:
        BRA     .StageLoop

.CapTimeout:
        LEA     MsgTimeout(PC),A0
        BSR     PrintStr
        BRA     .StageLoop

.AllDone:
        ; Am Ende alle Stimmen stoppen
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.FinStop:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.FinStop

        LEA     MsgDone(PC),A0
        BSR     PrintStr

        ; dos.library schliessen
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .NoClose
        MOVE.L  4.W,A6
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.NoClose:
        MOVEQ   #0,D0
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
; Hilfsroutine: PrintSignedDec
; ------------------------------------------------------------------
PrintSignedDec:
        TST.L   D0
        BPL.S   .Pos
        NEG.L   D0
        MOVEM.L D0/A0,-(SP)
        LEA     MsgMinus(PC),A0
        BSR     PrintStr
        MOVEM.L (SP)+,D0/A0
.Pos:   BRA     PrintDec

; ------------------------------------------------------------------
; Hilfsroutine: PrintDec
; ------------------------------------------------------------------
PrintDec:
        MOVEM.L D0-D4/A0-A2,-(SP)
        LEA     DecBufEnd(PC),A0
        CLR.B   (A0)
        MOVE.L  D0,D1
        MOVE.L  #10,D2
.DLoop:
        MOVE.L  D1,D3
        CLR.W   D1
        SWAP    D1
        DIVU    D2,D1
        MOVE.W  D1,D4
        SWAP    D4
        SWAP    D1
        MOVE.W  D3,D1
        DIVU    D2,D1
        MOVE.W  D1,D4
        SWAP    D1
        ADDI.B  #'0',D1
        MOVE.B  D1,-(A0)
        MOVE.L  D4,D1
        BNE.S   .DLoop
        BSR     PrintStr
        MOVEM.L (SP)+,D0-D4/A0-A2
        RTS

; ------------------------------------------------------------------
; Texte & Konstanten
; ------------------------------------------------------------------
DosName:        DC.B    "dos.library",0
MsgBanner:      DC.B    10,"==================================================",10
                DC.B    "*** KASKADEN-FEINMESSUNG GESTARTET (KICK 1.3) ***",10
                DC.B    "Messung: 1, 2, 4, 8, 12, 16, 17..22, 24, 28, 32 Stufen",10
                DC.B    "==================================================",10,0
MsgStageHdr:    DC.B    10,"--- TESTE KASKADE MIT STUFEN: ",0
MsgMinMax:      DC.B    "  Min / Max     = ",0
MsgTo:          DC.B    " bis ",0
MsgPkPk:        DC.B    "  (Pk-Pk = ",0
MsgSamples:     DC.B    ")",10,"  Erste 8 Werte = ",0
MsgTimeout:     DC.B    "  FEHLER: Timeout bei Capture!",10,0
MsgDone:        DC.B    10,"kaskade_stufen: Alle Stufen erfolgreich durchgemessen (Return Code: 0).",10,10,0
MsgNewline:     DC.B    10,0
MsgMinus:       DC.B    "-",0
MsgSpace:       DC.B    " ",0

                EVEN
StageTable:     DC.W    1, 2, 4, 8, 12, 16, 17, 18, 19, 20, 21, 22, 24, 28, 32, 0 ; Feinstufen

                EVEN
DOSBase:        DC.L    0
StdoutHandle:   DC.L    0
                DS.B    16
DecBufEnd:      DC.B    0

; ------------------------------------------------------------------
; Chip-RAM Audiodaten
; ------------------------------------------------------------------
                EVEN
                SECTION chip_data,DATA_C
                INCLUDE "../rechteck/rechteck_data.i"

                END
