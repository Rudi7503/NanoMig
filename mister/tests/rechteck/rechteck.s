; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Rechteck durch 32 Tiefpaesse
;
; Mit echter AmigaDOS Shell-Textausgabe (kompatibel mit Kickstart 1.3 via dos.library Write)
; Schreibt ausfuehrliche Diagnose in die Konsole oder Logdatei (z.B. > RAM:test.log)
; und setzt zusaetzlich COLOR00 (Gruen = Bestanden, Rot = Fehler).
;
; Assembler: vasmm68k_mot -Fhunk -o rechteck.o rechteck.s
; Linker:    vlink -bamigahunk -x -Bstatic -o rechteck rechteck.o
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
NUM_VOICES      EQU 32

_LVOOpenLibrary  EQU -552
_LVOCloseLibrary EQU -414
_LVOWrite        EQU -48
_LVOOutput       EQU -60

        SECTION text,CODE

Start:
        MOVEM.L D2-D7/A2-A6,-(SP)

        ; --------------------------------------------------------------
        ; dos.library oeffnen fuer Shell-Textausgabe (Kickstart 1.3+)
        ; --------------------------------------------------------------
        MOVE.L  4.W,A6                          ; ExecBase
        LEA     DosName(PC),A1
        MOVEQ   #0,D0                           ; Beliebige Version (Kickstart 1.2, 1.3, 2.0, 3.x)
        JSR     _LVOOpenLibrary(A6)
        MOVE.L  D0,DOSBase
        BEQ     .SkipDosInit

        MOVE.L  D0,A6                           ; DOSBase
        JSR     _LVOOutput(A6)                  ; Standard Output Handle holen
        MOVE.L  D0,StdoutHandle
        BEQ     .SkipDosInit

        LEA     MsgBanner(PC),A0
        BSR     PrintStr

.SkipDosInit:
        ; --------------------------------------------------------------
        ; Stimmen 0..31 vorbereiten
        ; --------------------------------------------------------------
        LEA     MsgSetup(PC),A0
        BSR     PrintStr

        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7
.Setup:
        MOVE.W  #$0002,AUD_CMD(A0)              ; Stop
        MOVE.W  #$0000,AUD_VOL(A0)
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
        CMPA.L  #AUDIO_EXT_BASE,A0
        BEQ.S   .Root
        MOVE.W  #0,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER|CTRL_CHAIN_POST),AUD_CTRL(A0)
        BRA.S   .Next
.Root:
        MOVE.W  #RECHTECK_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER),AUD_CTRL(A0)
.Next:
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Setup

        ; --------------------------------------------------------------
        ; Stimmen starten & Settle
        ; --------------------------------------------------------------
        LEA     MsgStart(PC),A0
        BSR     PrintStr

        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7
.Run:
        MOVE.W  #$0001,AUD_CMD(A0)              ; Start
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Run

        LEA     AUDIO_EXT_BASE,A0
        LEA     VOICE_STRIDE*31(A0),A0
        MOVE.W  #$8080,AUD_VOL(A0)              ; Volle Lautstaerke Voice 31

        BSR     Settle

        ; --------------------------------------------------------------
        ; Hardware-Capture starten & warten mit Timeout
        ; --------------------------------------------------------------
        LEA     MsgCapture(PC),A0
        BSR     PrintStr

        MOVE.W  #$0017,AUD_CAP
        MOVE.L  #500000,D4                      ; Timeout-Zaehler (~1 Sekunde)
.WaitA:
        MOVE.W  AUD_CAP,D1
        BTST    #1,D1
        BNE.S   .Captured
        SUBQ.L  #1,D4
        BNE.S   .WaitA

        ; Timeout! Capture-Hardware meldet Block A nicht voll
        LEA     MsgTimeout(PC),A0
        BSR     PrintStr
        LEA     MsgExitErr(PC),A0
        BSR     PrintStr
        MOVE.W  #$0F00,COLOR00                  ; Rot
        MOVEQ   #20,D7                          ; RETURN_ERROR
        BRA     .Exit

.Captured:
        LEA     MsgCapDone(PC),A0
        BSR     PrintStr

        ; 1. Spitzenwert in Block A ermitteln
        LEA     AUD_BUF_A,A1
        MOVE.W  #1023,D0
        MOVEQ   #0,D5
.Scan:  MOVE.W  (A1)+,D3
        ADDQ.L  #2,A1
        EXT.L   D3
        BPL.S   .P
        NEG.L   D3
.P:     CMP.L   D5,D3
        BLE.S   .N
        MOVE.L  D3,D5
.N:     DBRA    D0,.Scan

        ; Spitzenwert ausgeben
        LEA     MsgPeak(PC),A0
        BSR     PrintStr
        MOVE.L  D5,D0
        BSR     PrintDec
        LEA     MsgNewline(PC),A0
        BSR     PrintStr

        ; Pruefen, ob ueberhaupt Signalpegel anliegt
        TST.W   D5
        BNE.S   .HasSignal

        ; Stille!
        LEA     MsgSilent(PC),A0
        BSR     PrintStr
        LEA     MsgExitErr(PC),A0
        BSR     PrintStr
        MOVE.W  #$0F00,COLOR00                  ; Rot
        MOVEQ   #20,D7                          ; RETURN_ERROR
        BRA     .Exit

.HasSignal:
        ; Schwelle: 70 Prozent vom Spitzenwert
        MOVE.L  D5,D6
        MULU    #7,D6
        DIVU    #10,D6
        ANDI.L  #$FFFF,D6

        ; 2. Anzahl Samples ueber Schwelle zaehlen
        LEA     AUD_BUF_A,A1
        MOVE.W  #1023,D0
        MOVEQ   #0,D2                           ; Zaehler ueber Schwelle
.Count: MOVE.W  (A1)+,D3
        ADDQ.L  #2,A1
        EXT.L   D3
        BPL.S   .Pos
        NEG.L   D3
.Pos:   CMP.L   D6,D3
        BLE.S   .NextC
        ADDQ.W  #1,D2
.NextC: DBRA    D0,.Count
        MOVE.W  #$0000,AUD_CAP                  ; Capture aus

        ; Sample-Anzahl ausgeben
        LEA     MsgSamples(PC),A0
        BSR     PrintStr
        MOVE.W  D2,D0
        ANDI.L  #$FFFF,D0
        BSR     PrintDec
        LEA     MsgOf1024(PC),A0
        BSR     PrintStr

        ; Bewertung:
        ; Weniger als 768 von 1024 (75%) -> Sinus -> BESTANDEN
        CMP.W   #768,D2
        BCC.S   .FailSquare

        ; BESTANDEN!
        LEA     MsgPass(PC),A0
        BSR     PrintStr
        LEA     MsgExitOk(PC),A0
        BSR     PrintStr
        MOVE.W  #$00F0,COLOR00                  ; Gruen
        MOVEQ   #0,D7                           ; RETURN_OK
        BRA.S   .Exit

.FailSquare:
        LEA     MsgFailSquare(PC),A0
        BSR     PrintStr
        LEA     MsgExitErr(PC),A0
        BSR     PrintStr
        MOVE.W  #$0F80,COLOR00                  ; Orange
        MOVEQ   #20,D7                          ; RETURN_ERROR

.Exit:
        ; dos.library schliessen
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .NoClose
        MOVE.L  4.W,A6
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.NoClose:
        MOVE.L  D7,D0                           ; Return Code an Shell (0=OK, 20=Fehler)
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

; ------------------------------------------------------------------
; Hilfsroutine: PrintStr (String in A0 via dos.library Write ausgeben)
; Funktioniert ab Kickstart 1.2 / 1.3 / 2.0 / 3.x
; Input: A0 = Zeiger auf Null-terminierten Textstring
; ------------------------------------------------------------------
PrintStr:
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .Ret
        MOVE.L  StdoutHandle(PC),D1
        BEQ.S   .Ret
        MOVEM.L D2-D4/A0-A1/A6,-(SP)
        MOVE.L  D0,A6

        ; Laenge ermitteln (Null-Terminator suchen)
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
        MOVE.L  StdoutHandle(PC),D1             ; BPTR file handle
        MOVE.L  A0,D2                           ; APTR buffer
        ; D3 = LONG length
        JSR     _LVOWrite(A6)

.Done:
        MOVEM.L (SP)+,D2-D4/A0-A1/A6
.Ret:   RTS

; ------------------------------------------------------------------
; Hilfsroutine: PrintDec (32-Bit-Zahl in D0 dezimal ausgeben)
; ------------------------------------------------------------------
PrintDec:
        MOVEM.L D0-D4/A0-A2,-(SP)
        LEA     DecBufEnd(PC),A0
        CLR.B   (A0)                            ; Null-Terminator
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
        SWAP    D1                              ; Rest = Ziffer
        ADDI.B  #'0',D1
        MOVE.B  D1,-(A0)
        MOVE.L  D4,D1
        BNE.S   .DLoop
        BSR     PrintStr
        MOVEM.L (SP)+,D0-D4/A0-A2
        RTS

; ------------------------------------------------------------------
Settle:
        MOVE.L  #300000,D0
.SL:    SUBQ.L  #1,D0
        BNE.S   .SL
        RTS

; ------------------------------------------------------------------
; Konstanten & Daten
; ------------------------------------------------------------------
DosName:        DC.B    "dos.library",0
MsgBanner:      DC.B    10,"==================================================",10
                DC.B    "*** RECHTECK TEST GESTARTET (KICKSTART 1.3) ***",10
                DC.B    "rechteck: 32-Stufen-Tiefpass Kaskadentest",10
                DC.B    "==================================================",10,0
MsgSetup:       DC.B    "rechteck: [1/4] Stimmen 0..31 initialisiert.",10,0
MsgStart:       DC.B    "rechteck: [2/4] Stimmen gestartet (200 Hz sollte toenen)...",10,0
MsgCapture:     DC.B    "rechteck: [3/4] Hardware-Capture ($DFF802) gestartet...",10,0
MsgTimeout:     DC.B    "rechteck: FEHLER - Timeout! Block A nach 1s nicht fertig.",10,0
MsgCapDone:     DC.B    "rechteck: [3/4] Capture fertig. Analysiere 1024 Samples...",10,0
MsgPeak:        DC.B    "rechteck: [4/4] Spitzenwert (Peak) = ",0
MsgSilent:      DC.B    "rechteck: FEHLER - Kein Signal! Spitzenwert ist 0.",10,0
MsgSamples:     DC.B    "rechteck: [4/4] Proben ueber 70% = ",0
MsgOf1024:      DC.B    " von 1024",10,0
MsgPass:        DC.B    "rechteck: ERFOLG - Sinuswelle nachgewiesen (<75%).",10
                DC.B    "rechteck: >>> TEST BESTANDEN <<<",10,0
MsgFailSquare:  DC.B    "rechteck: FEHLER - Ungefiltertes Signal! Noch Rechteck (>75%).",10,0
MsgExitOk:      DC.B    "rechteck: Test beendet (Return Code: 0).",10,10,0
MsgExitErr:     DC.B    "rechteck: Test abgebrochen (Return Code: 20).",10,10,0
MsgNewline:     DC.B    10,0

                EVEN
DOSBase:        DC.L    0
StdoutHandle:   DC.L    0
                DS.B    16
DecBufEnd:      DC.B    0

                EVEN
                SECTION chip_data,DATA_C
                INCLUDE "rechteck_data.i"

                END
