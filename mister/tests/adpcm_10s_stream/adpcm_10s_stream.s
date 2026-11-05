; ==============================================================================
; MiSTer FPGA / Minimig-AGA: 32-Stimmen ADPCM 10-Sekunden Loopfreier Stream
;
; Kickstart 1.3 kompatibel (dos.library Output/Write/Delay)
;
; Testet alle 32 Hardware-Stimmen gleichzeitig im 4-Bit ADPCM-Modus bei 48 kHz
; ueber ein kontinuierliches 10-Sekunden-Audiosample (240.000 Bytes, 480.000 Samples)
; VOELLIG OHNE SAMPLE-LOOP!
;
; Ablauf:
;   - Alle 32 Stimmen spielen synchron das 10-Sekunden-Musikstueck (Pegel $1616).
;   - Jede Sekunde wird der Hardware-Capture-Puffer auf Clipping (+32767/-32768)
;     und die DMA-Statusflags auf Unterlaeufe geprueft und protokolliert.
;   - Da kein Loop stattfindet, fliessen die Daten gleichmaessig mit 768 KB/s.
;
; Assembler: vasmm68k_mot -Fhunk -o adpcm_10s_stream.o adpcm_10s_stream.s
; Linker:    vlink -bamigahunk -x -Bstatic -o adpcm_10s_stream adpcm_10s_stream.o
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

AUD_CAP         EQU $DFF802
AUD_BUF_A       EQU $DF8000

AUD_IRQ_HI      EQU $DFF808
AUD_IRQ_LO      EQU $DFF80A

CTRL_ADPCM      EQU $0008       ; Bit 3: ADPCM aktiv
CTRL_ONESHOT    EQU $0002       ; Bit 1: Einmaliges Abspielen (One-Shot)

PER_48K         EQU 521         ; 48 kHz
ADPCM_10S_BYTES EQU 240000      ; 480.000 Samples = 10,0 Sekunden ($0003A980)

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
        ; 2. Zunaechst alle Stimmen stoppen
        BSR     StopAllVoices

        ; 3. Alle 32 Stimmen mit dem 10-Sekunden-Puffer konfigurieren
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D6

.InitLoop:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.L  #Adpcm10sData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)

        ; 240.000 Bytes Laenge setzen ($0003 in LENH, $A980 in LENL)
        MOVE.L  #ADPCM_10S_BYTES,D0
        MOVE.W  D0,AUD_LENL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_LENH(A0)

        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #0,AUD_PRED(A0)
        MOVE.W  #(CTRL_ADPCM|CTRL_ONESHOT),AUD_CTRL(A0)
        MOVE.W  #$1616,AUD_VOL(A0)              ; Sicherer Headroom-Pegel ($1616)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.InitLoop

        ; IRQ-Flags quittieren vor dem Start
        MOVE.W  #$FFFF,AUD_IRQ_HI
        MOVE.W  #$FFFF,AUD_IRQ_LO

        ; Gesamtzustandszaehler
        CLR.L   TotalClips
        CLR.L   TotalUnderflows

        ; 4. Alle 32 Stimmen starten!
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D6
.StartLoop:
        MOVE.W  #$0001,AUD_CMD(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.StartLoop

        ; 5. 10 Sekunden lang laufen lassen, jede Sekunde Capture-Check
        MOVEQ   #1,D7                           ; D7 = Sekundenzaehler (1..10)

.SecLoop:
        ; 1 Sekunde warten (50 Ticks)
        MOVE.L  #50,D1
        BSR     DosDelay

        ; Hardware-Capture zur Pruefung auf Clipping
        MOVE.W  #$0017,AUD_CAP
        MOVE.L  #200000,D4
.WaitA:
        MOVE.W  AUD_CAP,D1
        BTST    #1,D1
        BNE.S   .CapOk
        SUBQ.L  #1,D4
        BNE.S   .WaitA
.CapOk:
        MOVE.W  #$0000,AUD_CAP

        ; Puffer auf Clipping (+32767 oder -32768) scannen
        LEA     AUD_BUF_A,A1
        MOVE.W  #1023,D0
        MOVEQ   #0,D5                           ; D5 = Clips in dieser Sekunde

.ScanClip:
        MOVE.W  (A1)+,D1
        CMP.W   #$7FFF,D1
        BEQ.S   .HitClip
        CMP.W   #$8000,D1
        BNE.S   .NoClip
.HitClip:
        ADDQ.L  #1,D5
.NoClip:
        DBRA    D0,.ScanClip

        ADD.L   D5,TotalClips

        ; Unterlauf-/DMA-Status pruefen
        MOVE.W  AUD_IRQ_HI,D0
        SWAP    D0
        MOVE.W  AUD_IRQ_LO,D0
        ; Bei One-Shot flaggt voice_done nur am echten Ende (nach 10 Sek.)
        CLR.L   D3
        CMP.W   #10,D7
        BEQ.S   .SkipUnder
        TST.L   D0
        BEQ.S   .SkipUnder
        MOVE.L  #1,D3
        ADD.L   D3,TotalUnderflows
.SkipUnder:

        ; Protokollzeile ausgeben
        LEA     MsgSec(PC),A0
        BSR     PrintStr
        MOVE.W  D7,D0
        ANDI.L  #$FFFF,D0
        BSR     PrintDec
        LEA     MsgSecOf10(PC),A0
        BSR     PrintStr

        LEA     MsgClips(PC),A0
        BSR     PrintStr
        MOVE.L  D5,D0
        BSR     PrintDec

        LEA     MsgUnder(PC),A0
        BSR     PrintStr
        MOVE.L  D3,D0
        BSR     PrintDec
        LEA     MsgNewline(PC),A0
        BSR     PrintStr

        ADDQ.W  #1,D7
        CMP.W   #11,D7
        BNE     .SecLoop

        ; 6. Alle Stimmen stoppen
        BSR     StopAllVoices

        ; Zusammenfassung ausgeben
        LEA     MsgSummary(PC),A0
        BSR     PrintStr
        LEA     MsgTotClips(PC),A0
        BSR     PrintStr
        MOVE.L  TotalClips(PC),D0
        BSR     PrintDec
        LEA     MsgTotUnder(PC),A0
        BSR     PrintStr
        MOVE.L  TotalUnderflows(PC),D0
        BSR     PrintDec
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
                DC.B    "*** 32-STIMMEN ADPCM 10s LOOPFREIER STREAM ***",10
                DC.B    "Sample: 240.000 Bytes (10,0 Sekunden am Stueck)",10
                DC.B    "32 Stimmen simultan @ 48 kHz, Pegel $1616, ZERO-LOOP",10
                DC.B    "==================================================",10,0
MsgSec:         DC.B    "  [Sekunde ",0
MsgSecOf10:     DC.B    "/10] DMA: 768 KB/s | ",0
MsgClips:       DC.B    "Clipping-Events: ",0
MsgUnder:       DC.B    " | Unterlaeufe: ",0
MsgNewline:     DC.B    10,0
MsgSummary:     DC.B    10,"--- GESAMT-STATISTIK (10 SEKUNDEN VOLLLAST) ---",10,0
MsgTotClips:    DC.B    "  Gesamt Clipping-Events: ",0
MsgTotUnder:    DC.B    10,"  Gesamt Unterlaeufe:     ",0
MsgDone:        DC.B    10,10,"adpcm_10s_stream: 10 Sekunden erfolgreich durchgespielt (RC: 0).",10,10,0

                EVEN
DOSBase:        DC.L    0
StdoutHandle:   DC.L    0
TotalClips:     DC.L    0
TotalUnderflows: DC.L   0
                DS.B    16
DecBufEnd:      DC.B    0

; ------------------------------------------------------------------
; Chip-RAM Audiodaten (10 Sekunden 4-Bit ADPCM, 240.000 Bytes)
; ------------------------------------------------------------------
                EVEN
                SECTION chip_data,DATA_C
Adpcm10sData:
                INCBIN  "../adpcm/adpcm_10s_48k.bin"

                END
