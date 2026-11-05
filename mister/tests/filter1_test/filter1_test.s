; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Isolierter 1-Stufen-Filtertest (Stimme 0 Tiefpass)
;
; Kickstart 1.3 kompatibel (dos.library Output/Write)
; Prueft EINE EINZELNE Biquad-Filterstufe (300 Hz Tiefpass auf Stimme 0)
; mit voller Lautstaerke ($FFFF), Hardware-Capture ($DF8000) und Rohdaten-Dump.
;
; Assembler: vasmm68k_mot -Fhunk -o filter1_test.o filter1_test.s
; Linker:    vlink -bamigahunk -x -Bstatic -o filter1_test filter1_test.o
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
        ; 1. Alle Stimmen 1..31 stoppen und stummschalten
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D7
.StopAll:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.StopAll

        ; 2. Stimme 0 mit Biquad-Filter initialisieren
        LEA     AUDIO_EXT_BASE,A0
        MOVE.L  #RechteckData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #RECHTECK_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #BQ_B0,AUD_BQ_B0(A0)
        MOVE.W  #BQ_B1,AUD_BQ_B1(A0)
        MOVE.W  #BQ_B2,AUD_BQ_B2(A0)
        MOVE.W  #BQ_A1,AUD_BQ_A1(A0)
        MOVE.W  #BQ_A2,AUD_BQ_A2(A0)
        MOVE.W  #$FFFF,AUD_VOL(A0)              ; 100% Lautstaerke Links & Rechts!
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER),AUD_CTRL(A0)

        ; 3. Stimme 0 starten
        MOVE.W  #$0001,AUD_CMD(A0)

        LEA     MsgStart(PC),A0
        BSR     PrintStr

        ; Kurz einschwingen lassen (~50 ms)
        MOVE.L  #150000,D0
.S1:    SUBQ.L  #1,D0
        BNE.S   .S1

        ; 4. Hardware-Capture starten & warten
        LEA     MsgCapture(PC),A0
        BSR     PrintStr

        MOVE.W  #$0017,AUD_CAP                  ; Capture Start (Block A & B, Run)
        MOVE.L  #500000,D4                      ; Timeout ~1s
.WaitA:
        MOVE.W  AUD_CAP,D1
        BTST    #1,D1
        BNE.S   .Captured
        SUBQ.L  #1,D4
        BNE.S   .WaitA

        ; Timeout!
        LEA     MsgTimeout(PC),A0
        BSR     PrintStr
        MOVE.W  #$0F00,COLOR00                  ; Rot
        MOVEQ   #20,D7
        BRA     .Exit

.Captured:
        MOVE.W  #$0000,AUD_CAP                  ; Capture aus
        LEA     MsgCapDone(PC),A0
        BSR     PrintStr

        ; 5. Min- und Max-Werte ermitteln (fuer DC-Pruefung und Peak)
        LEA     AUD_BUF_A,A1
        MOVE.W  #1023,D0
        MOVE.W  (A1)+,D1                        ; Erstes Sample
        ADDQ.L  #2,A1                           ; Rechtes Sample ueberspringen
        EXT.L   D1
        MOVE.L  D1,D4                           ; D4 = Min
        MOVE.L  D1,D5                           ; D5 = Max
        SUBQ.W  #1,D0

.ScanMinMax:
        MOVE.W  (A1)+,D1
        ADDQ.L  #2,A1
        EXT.L   D1
        CMP.L   D4,D1
        BGE.S   .NotMin
        MOVE.L  D1,D4
.NotMin:
        CMP.L   D5,D1
        BLE.S   .NotMax
        MOVE.L  D1,D5
.NotMax:
        DBRA    D0,.ScanMinMax

        ; Spitzenwert: Maximum aus |Min| und |Max|
        MOVE.L  D4,D2
        BPL.S   .MinP
        NEG.L   D2
.MinP:  MOVE.L  D5,D3
        BPL.S   .MaxP
        NEG.L   D3
.MaxP:  CMP.L   D2,D3
        BGE.S   .PeakD3
        MOVE.L  D2,D3
.PeakD3:
        ; D3 = Absoluter Spitzenwert
        LEA     MsgPeak(PC),A0
        BSR     PrintStr
        MOVE.L  D3,D0
        BSR     PrintDec
        LEA     MsgNewline(PC),A0
        BSR     PrintStr

        ; Min und Max ausgeben
        LEA     MsgMinMax(PC),A0
        BSR     PrintStr
        MOVE.L  D4,D0
        BSR     PrintSignedDec
        LEA     MsgComma(PC),A0
        BSR     PrintStr
        MOVE.L  D5,D0
        BSR     PrintSignedDec
        LEA     MsgNewline(PC),A0
        BSR     PrintStr

        ; Rohdaten der ersten 8 Samples ausgeben
        LEA     MsgRawSamples(PC),A0
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

        ; Pruefen auf DC-Offset (Min == Max)
        MOVE.L  D5,D0
        SUB.L   D4,D0                           ; D0 = Peak-to-Peak (Max - Min)
        CMP.L   #200,D0
        BGE.S   .IsAC

        ; Reines DC-Signal!
        LEA     MsgDCErr(PC),A0
        BSR     PrintStr
        MOVE.W  #$0F00,COLOR00                  ; Rot
        MOVEQ   #20,D7
        BRA.S   .Exit

.IsAC:
        ; Signal schwingt!
        LEA     MsgACSuccess(PC),A0
        BSR     PrintStr
        MOVE.W  #$00F0,COLOR00                  ; Gruen
        MOVEQ   #0,D7

        ; Stimme 0 noch 3 Sekunden toenen lassen, damit Toby zuhoeren kann
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .Exit
        MOVE.L  D0,A6
        MOVE.L  #150,D1                         ; 3 Sekunden (150 VBlanks)
        JSR     _LVODelay(A6)

.Exit:
        ; Stimme 0 stoppen
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)

        ; dos.library schliessen
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .NoClose
        MOVE.L  4.W,A6
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.NoClose:
        MOVE.L  D7,D0
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
; Hilfsroutine: PrintSignedDec (D0 = signed 32-bit)
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
; Hilfsroutine: PrintDec (D0 = unsigned 32-bit)
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
                DC.B    "*** 1-STUFEN FILTERTEST GESTARTET (KICKSTART 1.3) ***",10
                DC.B    "filter1: Stimme 0 mit 300 Hz Biquad Tiefpass",10
                DC.B    "==================================================",10,0
MsgStart:       DC.B    "filter1: Stimme 0 gestartet (100% Lautstaerke $FFFF, Filter an)...",10,0
MsgCapture:     DC.B    "filter1: Hardware-Capture ($DFF802) gestartet...",10,0
MsgTimeout:     DC.B    "filter1: FEHLER - Timeout! Block A nicht fertig.",10,0
MsgCapDone:     DC.B    "filter1: Capture fertig. Analysiere Samples...",10,0
MsgPeak:        DC.B    "filter1: Spitzenwert (Peak) = ",0
MsgMinMax:      DC.B    "filter1: Min / Max          = ",0
MsgRawSamples:  DC.B    "filter1: Erste 8 Samples    = ",0
MsgDCErr:       DC.B    "filter1: FEHLER - Reiner Gleichspannungspegel (DC)! Kein Tonsignal.",10,0
MsgACSuccess:   DC.B    "filter1: ERFOLG - Echtes Wechselsignal nachgewiesen (Peak-to-Peak > 200).",10
                DC.B    "filter1: Ton toent noch 3 Sekunden ueber Lautsprecher...",10,0
MsgNewline:     DC.B    10,0
MsgComma:       DC.B    " bis ",0
MsgMinus:       DC.B    "-",0
MsgSpace:       DC.B    " ",0

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
