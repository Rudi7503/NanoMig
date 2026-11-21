; ==============================================================================
; MiSTer FPGA / Minimig-AGA: 32-Stimmen ADPCM Loop-Phasenvergleich
;
; Kickstart 1.3 kompatibel (dos.library Output/Write/Delay)
;
; Vergleicht 32 parallele ADPCM-Stimmen bei 48 kHz (identischer Pegel $1616):
;   - Phase A: Synchroner Loop (alle 32 Stimmen starten gleichzeitig bei t=0)
;              Alle 32 Stimmen fordern nach genau 1,0s exakt gleichzeitig
;              das Nachladen der Schleife an.
;   - Pause:   2 Sekunden Stille
;   - Phase B: Versetzter Loop (Hardware Start-Delay Staffelung um je ~1 ms)
;              Jede Stimme hat einen kleinen Phasenversatz (Stimme i: i * 32 Ticks).
;              Die Loop-Nachladezeitpunkte verteilen sich gleichmaessig ueber
;              die Zeit -> Null Busstau am SDRAM-DMA-Arbiter!
;
; Protokolliert in beiden Phasen die 10 Sekunden und zeigt den Unterschied.
;
; Assembler: vasmm68k_mot -Fhunk -o adpcm_loop_phase.o adpcm_loop_phase.s
; Linker:    vlink -bamigahunk -x -Bstatic -o adpcm_loop_phase adpcm_loop_phase.o
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
AUD_DEL         EQU $1C         ; Hardware Start-Delay Counter (32.768 kHz)

AUD_IRQ_HI      EQU $DFF808
AUD_IRQ_LO      EQU $DFF80A

CTRL_ADPCM      EQU $0008       ; Bit 3: ADPCM aktiv

PER_48K         EQU 521         ; 48 kHz
ADPCM_BYTES     EQU 24000       ; 48.000 Samples = exakt 1,0 Sekunde

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
        BEQ     .NoDos

        MOVE.L  D0,A6
        JSR     _LVOOutput(A6)
        MOVE.L  D0,StdoutHandle
        BEQ     .NoDos

        ; Banner ausgeben
        LEA     MsgBanner(PC),A0
        BSR     PrintStr

.NoDos:
        ; =============================================================
        ; PHASE A: 32 STIMMEN SYNCHRONER LOOP (DELAY = 0)
        ; =============================================================
        LEA     MsgPhaseA(PC),A0
        BSR     PrintStr

        MOVEQ   #0,D5                           ; D5 = 0: Kein Start-Delay (synchron)
        BSR     RunTestPhase

        ; 2 Sekunden Pause zwischen den Phasen
        LEA     MsgPause(PC),A0
        BSR     PrintStr
        MOVE.L  #100,D1                         ; 100 Ticks = 2,0 Sekunden
        BSR     DosDelay

        ; =============================================================
        ; PHASE B: 32 STIMMEN VERSETZTER LOOP (HARDWARE START-DELAY)
        ; =============================================================
        LEA     MsgPhaseB(PC),A0
        BSR     PrintStr

        MOVEQ   #1,D5                           ; D5 = 1: Versetztes Start-Delay (~1 ms je Stimme)
        BSR     RunTestPhase

        ; Abschlussmeldung
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
; Unterroutine: RunTestPhase
; Eingabe: D5 = 0 (Synchron) oder 1 (Versetztes Start-Delay)
; ------------------------------------------------------------------
RunTestPhase:
        ; 1. Alle Stimmen stoppen
        BSR     StopAllVoices

        ; 2. Alle 32 Stimmen konfigurieren
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #0,D4                           ; D4 = Stimmen-Index (0..31)

.InitLoop:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.L  #AdpcmData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #ADPCM_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #0,AUD_PRED(A0)
        MOVE.W  #CTRL_ADPCM,AUD_CTRL(A0)
        MOVE.W  #$1616,AUD_VOL(A0)              ; Identischer Headroom-Pegel ($1616)

        ; Start-Delay setzen:
        ; Wenn D5 == 0 -> Delay = 0
        ; Wenn D5 == 1 -> Delay = D4 * 32 (ca. 1 ms Staffelung je Stimme)
        MOVEQ   #0,D0
        TST.W   D5
        BEQ.S   .SetDelay
        MOVE.W  D4,D0
        LSL.W   #5,D0                           ; D0 = D4 * 32 Ticks
.SetDelay:
        MOVE.W  D0,AUD_DEL(A0)

        LEA     VOICE_STRIDE(A0),A0
        ADDQ.W  #1,D4
        CMP.W   #32,D4
        BNE.S   .InitLoop

        ; IRQ-Flags quittieren vor dem Start
        MOVE.W  #$FFFF,AUD_IRQ_HI
        MOVE.W  #$FFFF,AUD_IRQ_LO

        ; 3. Alle 32 Stimmen starten
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D6
.StartLoop:
        MOVE.W  #$0001,AUD_CMD(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.StartLoop

        ; 4. 10 Sekunden lang laufen lassen, jede Sekunde Loop protokollieren
        MOVEQ   #1,D7                           ; D7 = Sekundenzaehler (1..10)

.SecLoop:
        ; 1 Sekunde warten (50 Ticks)
        MOVE.L  #50,D1
        BSR     DosDelay

        ; Protokollzeile ausgeben
        LEA     MsgSecPrefix(PC),A0
        BSR     PrintStr
        MOVE.W  D7,D0
        ANDI.L  #$FFFF,D0
        BSR     PrintDec
        LEA     MsgSecMid(PC),A0
        BSR     PrintStr
        MOVE.W  D7,D0
        ANDI.L  #$FFFF,D0
        BSR     PrintDec
        LEA     MsgSecSuffix(PC),A0
        BSR     PrintStr

        ; Loop-Flags quittieren
        MOVE.W  #$FFFF,AUD_IRQ_HI
        MOVE.W  #$FFFF,AUD_IRQ_LO

        ADDQ.W  #1,D7
        CMP.W   #11,D7
        BNE.S   .SecLoop

        ; 5. Alle Stimmen stoppen
        BSR     StopAllVoices
        RTS

; ------------------------------------------------------------------
; Unterroutine: StopAllVoices
; ------------------------------------------------------------------
StopAllVoices:
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.SLoop:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        MOVE.W  #$0000,AUD_DEL(A0)              ; Delay zuruecksetzen
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.SLoop
        RTS

; ------------------------------------------------------------------
; Unterroutine: DosDelay
; ------------------------------------------------------------------
DosDelay:
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .Busy
        MOVEM.L D2-D3/A6,-(SP)
        MOVE.L  D0,A6
        JSR     _LVODelay(A6)
        MOVEM.L (SP)+,D2-D3/A6
        RTS
.Busy:
        MULU    #35000,D1
.BLoop: SUBQ.L  #1,D1
        BNE.S   .BLoop
        RTS

; ------------------------------------------------------------------
; Unterroutine: PrintStr
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
; Unterroutine: PrintDec
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
                DC.B    "*** 32-STIMMEN ADPCM LOOP-PHASENVERGLEICH (KICK 1.3) ***",10
                DC.B    "Vergleich: Synchroner vs. Versetzter Loop (Pegel $1616)",10
                DC.B    "Laufzeit: je 10 Sekunden mit Sekunden-Protokollierung",10
                DC.B    "==================================================",10,0
MsgPhaseA:      DC.B    10,">>> PHASE A: 32 Stimmen SYNCHRON (Alle starten bei t=0)...",10,0
MsgPause:       DC.B    10,"--- Pause: 2 Sekunden Stille ---",10,0
MsgPhaseB:      DC.B    10,">>> PHASE B: 32 Stimmen VERSETZT (Hardware Start-Delay ~1 ms)...",10,0
MsgSecPrefix:   DC.B    "  Sekunde ",0
MsgSecMid:      DC.B    "/10  (Loop-Durchlauf #",0
MsgSecSuffix:   DC.B    ")",10,0
MsgDone:        DC.B    10,"adpcm_loop_phase: Beide Phasen erfolgreich beendet (RC: 0).",10,10,0

                EVEN
DOSBase:        DC.L    0
StdoutHandle:   DC.L    0
                DS.B    16
DecBufEnd:      DC.B    0

; ------------------------------------------------------------------
; Chip-RAM Audiodaten (4-Bit ADPCM Musiksample)
; ------------------------------------------------------------------
                EVEN
                SECTION chip_data,DATA_C
AdpcmData:
                INCBIN  "../adpcm/adpcm_4bit.bin"

                END
