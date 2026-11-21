; ==============================================================================
; MiSTer FPGA / Minimig-AGA: 32-Kanal Filterbank & Spektral-Sweeper (Vocoder-Test)
;
; Kickstart 1.3 kompatibel (dos.library Output/Write/Delay)
;
; Ablauf:
;   Kanal 0 spielt das ADPCM-Lied (48 kHz, "Kakao bei Lotte").
;   Kanäle 1..31 greifen per Pre-Filter-Kaskade (AUD_CTRL = $0380) direkt das
;   ungefilterte Signal von Kanal 0 ab (0% zusätzlicher DMA-Traffic).
;   Jeder der 32 Kanäle besitzt einen eigenen Biquad-Bandpass (50 Hz bis 16 kHz).
;
; Ablauf-Phasen:
;   1. Sweep-Effekt: Kanäle 0 bis 31 nacheinander solo aufdrehen (Frequenz-Wah-Wah).
;   2. Outside-In Aufbau: Kanäle abwechselnd von außen nach innen zuschalten:
;      Kanal 31 (16 kHz), 0 (50 Hz), 30, 1, 29, 2 ... mit jeweils 100 ms Pause,
;      bis alle 32 Bänder das volle Frequenzspektrum bilden (2 Sek. Haltezeit).
;   3. Outside-In Abbau: In genau derselben Reihenfolge wieder im 100 ms-Takt
;      abschalten, bis wieder Stille herrscht.
;
; Assembler: vasmm68k_mot -Fhunk -o filterbank_sweep.o filterbank_sweep.s
; Linker:    vlink -bamigahunk -x -Bstatic -o filterbank_sweep filterbank_sweep.o
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

CTRL_ADPCM      EQU $0008       ; Bit 3: ADPCM Decoder aktiv
CTRL_FILTER     EQU $0180       ; Bit 8+7: Dual Biquad DSP aktiv
CTRL_CHAIN_PRE  EQU $0200       ; Bit 9: Pre-Filter-Kaskade von Stimme N-1

PER_48K         EQU 521         ; 48 kHz
ADPCM_BYTES     EQU 24000       ; 48.000 Samples = 1 Sekunde Loop

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

        ; 2. Zunaechst alle 32 Stimmen stoppen und Lautstaerke auf 0
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.StopAll:
        MOVE.W  #$0002,AUD_CMD(A0)              ; Stop
        MOVE.W  #$0000,AUD_VOL(A0)              ; Stumm
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.StopAll

        ; 3. Biquad-Koeffizienten fuer alle 32 Bandpaesse laden
        LEA     AUDIO_EXT_BASE,A0
        LEA     FilterBankCoeffs(PC),A1
        MOVEQ   #31,D0
.LoadCoeffs:
        MOVE.W  (A1)+,AUD_BQ_B0(A0)
        MOVE.W  (A1)+,AUD_BQ_B1(A0)
        MOVE.W  (A1)+,AUD_BQ_B2(A0)
        MOVE.W  (A1)+,AUD_BQ_A1(A0)
        MOVE.W  (A1)+,AUD_BQ_A2(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.LoadCoeffs

        ; 4. Stimme 0 (Wurzel) konfigurieren: ADPCM Sample aus Chip-RAM
        LEA     AUDIO_EXT_BASE,A0
        MOVE.L  #AdpcmData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #ADPCM_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #0,AUD_PRED(A0)
        MOVE.W  #(CTRL_ADPCM|CTRL_FILTER),AUD_CTRL(A0) ; Eigene Quelle + Filter
        MOVE.W  #$0000,AUD_VOL(A0)              ; Startet stumm

        ; 5. Stimmen 1..31 konfigurieren: Pre-Filter-Kaskade von Vorgaenger
        LEA     VOICE_STRIDE(A0),A0
        MOVEQ   #30,D0
.InitCascade:
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #(CTRL_FILTER|CTRL_CHAIN_PRE),AUD_CTRL(A0) ; Kaskade von Stimme N-1
        MOVE.W  #$0000,AUD_VOL(A0)              ; Startet stumm
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.InitCascade

        ; 6. Alle 32 Stimmen gleichzeitig starten!
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.StartAll:
        MOVE.W  #$0001,AUD_CMD(A0)              ; Start
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.StartAll

        ; Kurze Einschwingzeit (100 ms)
        MOVE.L  #5,D1                           ; 5 Ticks = 100 ms
        BSR     DosDelay

        ; ==============================================================
        ; PHASE 1: Frequenz-Sweep (50 Hz bis 16 kHz)
        ; ==============================================================
        LEA     MsgPhase1(PC),A0
        BSR     PrintStr

        CLR.W   D7                              ; D7 = aktueller Kanal (0..31)
.SweepLoop:
        ; Aktuellen Kanal aufdrehen ($FFFF)
        MOVE.W  D7,D0
        BSR     GetVoiceAddr
        MOVE.W  #$FFFF,AUD_VOL(A0)

        ; Vorherigen Kanal stummschalten (falls D7 > 0)
        TST.W   D7
        BEQ.S   .NoPrev
        MOVE.W  D7,D0
        SUBQ.W  #1,D0
        BSR     GetVoiceAddr
        MOVE.W  #$0000,AUD_VOL(A0)
.NoPrev:
        ; 100 ms abspielen lassen (5 Ticks)
        MOVE.L  #5,D1
        BSR     DosDelay

        ADDQ.W  #1,D7
        CMPI.W  #32,D7
        BLT.S   .SweepLoop

        ; Letzten Kanal (31) ebenfalls stummschalten
        MOVEQ   #31,D0
        BSR     GetVoiceAddr
        MOVE.W  #$0000,AUD_VOL(A0)

        ; 500 ms Pause vor Phase 2
        MOVE.L  #25,D1                          ; 25 Ticks = 500 ms
        BSR     DosDelay

        ; ==============================================================
        ; PHASE 2: Outside-In Zuschalten (31, 0, 30, 1 ... jeweils 100 ms)
        ; ==============================================================
        LEA     MsgPhase2(PC),A0
        BSR     PrintStr

        LEA     OutsideInOrder(PC),A2
        MOVEQ   #31,D6                          ; 32 Schritte
.OnLoop:
        CLR.W   D0
        MOVE.B  (A2)+,D0                        ; Kanalnummer holen
        BSR     GetVoiceAddr
        MOVE.W  #$FFFF,AUD_VOL(A0)              ; Kanal aktivieren ($FFFF)

        ; 100 ms warten
        MOVE.L  #5,D1
        BSR     DosDelay

        DBRA    D6,.OnLoop

        ; Jetzt sind alle 32 Bänder voll aktiv!
        LEA     MsgFull(PC),A0
        BSR     PrintStr

        ; 2 Sekunden volles Spektrum genießen (100 Ticks)
        MOVE.L  #100,D1
        BSR     DosDelay

        ; ==============================================================
        ; PHASE 3: Outside-In Abschalten (gleiche Reihenfolge)
        ; ==============================================================
        LEA     MsgPhase3(PC),A0
        BSR     PrintStr

        LEA     OutsideInOrder(PC),A2
        MOVEQ   #31,D6                          ; 32 Schritte
.OffLoop:
        CLR.W   D0
        MOVE.B  (A2)+,D0                        ; Kanalnummer holen
        BSR     GetVoiceAddr
        MOVE.W  #$0000,AUD_VOL(A0)              ; Kanal stummschalten

        ; 100 ms warten
        MOVE.L  #5,D1
        BSR     DosDelay

        DBRA    D6,.OffLoop

        ; ==============================================================
        ; Abschluss: Alle Stimmen stoppen & Beenden
        ; ==============================================================
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.FinStop:
        MOVE.W  #$0002,AUD_CMD(A0)              ; Stop
        MOVE.W  #$0000,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.FinStop

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
; Hilfsroutine: GetVoiceAddr -- Berechnet Adresse von Stimme D0
; Eingang: D0 = Voice-Index (0..31)
; Ausgang: A0 = Zeiger auf Registerbasis der Stimme
; ------------------------------------------------------------------
GetVoiceAddr:
        ANDI.L  #$1F,D0
        LSL.L   #5,D0                           ; D0 * 32 (VOICE_STRIDE = $20)
        LEA     AUDIO_EXT_BASE,A0
        ADDA.L  D0,A0
        RTS

; ------------------------------------------------------------------
; Hilfsroutine: DosDelay
; Eingang: D1 = Anzahl Ticks (50 Ticks = 1 Sekunde)
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
        MOVE.L  A0,D2                           ; Buffer
        MOVE.L  A0,A1
.LenLoop:
        TST.B   (A1)+
        BNE.S   .LenLoop
        SUBQ.L  #1,A1
        SUBA.L  A0,A1
        MOVE.L  A1,D3                           ; Laenge
        BEQ.S   .Exit
        MOVE.L  DOSBase(PC),A6
        JSR     _LVOWrite(A6)
.Exit:
        MOVEM.L (SP)+,D0-D3/A0-A1/A6
        RTS

; ------------------------------------------------------------------
; Tabellen & Texte
; ------------------------------------------------------------------
                EVEN

; 32 Schritte Outside-In: 31, 0, 30, 1, 29, 2 ...
OutsideInOrder:
        DC.B    31,  0, 30,  1, 29,  2, 28,  3
        DC.B    27,  4, 26,  5, 25,  6, 24,  7
        DC.B    23,  8, 22,  9, 21, 10, 20, 11
        DC.B    19, 12, 18, 13, 17, 14, 16, 15

                EVEN
DosName:        DC.B    "dos.library",0
MsgBanner:      DC.B    10,"==================================================",10
                DC.B    "*** 32-KANAL FILTERBANK & SPECTRAL SWEEPER ***",10
                DC.B    "Minimig Audio-Ext: Pre-Filter Kaskade + 32 Biquads",10
                DC.B    "==================================================",10,0
MsgPhase1:      DC.B    "[Phase 1] Frequenz-Sweep 50 Hz -> 16 kHz (Kanale 0..31)...",10,0
MsgPhase2:      DC.B    "[Phase 2] Outside-In Aufbau (31, 0, 30, 1... 100ms Takt)...",10,0
MsgFull:        DC.B    "          -> Alle 32 Bander aktiv! Volles Spektrum (2 Sek)...",10,0
MsgPhase3:      DC.B    "[Phase 3] Outside-In Abbau (gleiche Reihenfolge, 100ms Takt)...",10,0
MsgDone:        DC.B    "*** Filterbank-Test erfolgreich abgeschlossen! ***",10,10,0

                EVEN
DOSBase:        DC.L    0
StdoutHandle:   DC.L    0

; ------------------------------------------------------------------
; Biquad Bandpass-Koeffizienten fuer alle 32 Kanaele
; ------------------------------------------------------------------
                EVEN
                INCLUDE "filterbank_coeffs.i"

; ------------------------------------------------------------------
; Chip-RAM Audiodaten (ADPCM Sample)
; ------------------------------------------------------------------
                EVEN
                SECTION chip_data,DATA_C
AdpcmData:
                INCBIN  "../adpcm/adpcm_4bit.bin"

                END
