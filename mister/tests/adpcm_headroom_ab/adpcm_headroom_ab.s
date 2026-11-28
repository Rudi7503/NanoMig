; ==============================================================================
; MiSTer FPGA / Minimig-AGA: 32-Stimmen ADPCM Headroom A/B-Vergleich
;
; Kickstart 1.3 kompatibel (dos.library Output/Write/Delay)
;
; Vergleicht 32 parallele ADPCM-Stimmen bei 48 kHz ueber 10 Sekunden:
;   - Phase A: Pegel $2020 pro Stimme (frueherer Testpegel)
;              Protokolliert jede Sekunde den Loop-Zeitpunkt
;   - Pause:   2 Sekunden Stille
;   - Phase B: Pegel $1616 pro Stimme (skalierter Headroom)
;              Protokolliert jede Sekunde den Loop-Zeitpunkt
;
; Ermoeglicht den direkten Nachweis, ob das Knacken an den Loop-Grenzen
; bei $2020 durch Mischer-Uebersteuerung entsteht und bei $1616 verschwindet.
;
; Assembler: vasmm68k_mot -Fhunk -o adpcm_headroom_ab.o adpcm_headroom_ab.s
; Linker:    vlink -bamigahunk -x -Bstatic -o adpcm_headroom_ab adpcm_headroom_ab.o
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
        ; PHASE A: 32 STIMMEN MIT PEGEL $2020 (10 SEKUNDEN)
        ; =============================================================
        LEA     MsgPhaseA(PC),A0
        BSR     PrintStr

        MOVE.W  #$2020,D5                       ; Pegel Phase A
        BSR     SetupAndRunPhase

        ; 2 Sekunden Pause zwischen den Phasen
        LEA     MsgPause(PC),A0
        BSR     PrintStr
        MOVE.L  #100,D1                         ; 100 Ticks = 2,0 Sekunden
        BSR     DosDelay

        ; =============================================================
        ; PHASE B: 32 STIMMEN MIT PEGEL $1616 (10 SEKUNDEN)
        ; =============================================================
        LEA     MsgPhaseB(PC),A0
        BSR     PrintStr

        MOVE.W  #$1616,D5                       ; Pegel Phase B
        BSR     SetupAndRunPhase

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
; Unterroutine: SetupAndRunPhase
; Eingabe: D5 = Lautstaerke je Stimme (z.B. $2020 oder $1616)
; ------------------------------------------------------------------
SetupAndRunPhase:
        ; 1. Alle Stimmen stoppen
        BSR     StopAllVoices

        ; 2. Alle 32 Stimmen konfigurieren
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D6
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
        MOVE.W  D5,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.InitLoop

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
                DC.B    "*** 32-STIMMEN ADPCM HEADROOM A/B-TEST (KICK 1.3) ***",10
                DC.B    "Vergleich: 10s bei $2020 vs. 10s bei $1616",10
                DC.B    "Sample: 48 kHz ADPCM, 1,0s Puffer, synchrone Loops",10
                DC.B    "==================================================",10,0
MsgPhaseA:      DC.B    10,">>> PHASE A: 32 Stimmen @ $2020 (10 Sekunden)...",10,0
MsgPause:       DC.B    10,"--- Pause: 2 Sekunden Stille ---",10,0
MsgPhaseB:      DC.B    10,">>> PHASE B: 32 Stimmen @ $1616 (10 Sekunden)...",10,0
MsgSecPrefix:   DC.B    "  Sekunde ",0
MsgSecMid:      DC.B    "/10  (Loop-Durchlauf #",0
MsgSecSuffix:   DC.B    ")",10,0
MsgDone:        DC.B    10,"adpcm_headroom_ab: Beide Phasen erfolgreich beendet (RC: 0).",10,10,0

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
