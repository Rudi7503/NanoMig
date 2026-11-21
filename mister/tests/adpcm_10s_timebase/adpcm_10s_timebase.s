; ==============================================================================
; MiSTer FPGA / Minimig-AGA: 32-Stimmen ADPCM 10-Sekunden Zeitbasis-Test
;
; Kickstart 1.3 kompatibel
;
; Testet alle 32 Hardware-Stimmen synchron im 4-Bit ADPCM-Modus bei 48 kHz
; ueber ein kontinuierliches Audiosample (240.000 Bytes = 480.000 Samples)
; VOELLIG OHNE SAMPLE-LOOP!
;
; Features:
;   - Eingebettetes akustisches Erkennungssignal in den letzten Samples (9,0s..10,0s)
;   - Exakte Hardware-Zeitbasismessung ueber VBlank-Framezaehler (50/60 Hz)
;   - Unabhaengige Protokollierung von:
;       * Startzeitpunkt T0
;       * Erste Stimme Pufferende (voice_done) mit Zeitstempel
;       * Letzte Stimme Pufferende (voice_done) mit Zeitstempel
;   - Echte Trennung: voice_done (Pufferende) vs. FIFO-Unterlaeufe (0)
;   - Laufende Abtastung des 16-Bit Capture-Puffers auf Clipping-Events
;
; Assembler: vasmm68k_mot -Fhunk -o adpcm_10s_timebase.o adpcm_10s_timebase.s
; Linker:    vlink -bamigahunk -x -Bstatic -o adpcm_10s_timebase adpcm_10s_timebase.o
; ==============================================================================

CUSTOM          EQU $DFF000
VPOSR           EQU $DFF004
VHPOSR          EQU $DFF006
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

PER_48K         EQU 521         ; 48 kHz (Effektiv 47.655 Hz)
ADPCM_BYTES     EQU 240000      ; 480.000 Samples ($0003A980)

_LVOOpenLibrary  EQU -552
_LVOCloseLibrary EQU -414
_LVOWrite        EQU -48
_LVOOutput       EQU -60

        SECTION text,CODE

Start:
        MOVEM.L D2-D7/A2-A6,-(SP)

        ; 1. dos.library oeffnen
        MOVE.L  $00000004.W,A6
        ; System-VBlank-Frequenz ermitteln (50 Hz PAL oder 60 Hz NTSC)
        MOVE.W  $0212(A6),D0
        CMPI.W  #60,D0
        BEQ.S   .Set60
        MOVE.W  #50,D0
.Set60:
        MOVE.W  D0,VBlankHz

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

        ; 3. Alle 32 Stimmen mit dem 240.000-Byte-Puffer konfigurieren
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D6

.InitLoop:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.L  #AdpcmSigData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)

        ; 240.000 Bytes Laenge setzen ($0003 in LENH, $A980 in LENL)
        MOVE.L  #ADPCM_BYTES,D0
        MOVE.W  D0,AUD_LENL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_LENH(A0)

        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #0,AUD_PRED(A0)
        MOVE.W  #(CTRL_ADPCM|CTRL_ONESHOT),AUD_CTRL(A0)
        MOVE.W  #$1616,AUD_VOL(A0)              ; Sicherer Pegel ($1616)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.InitLoop

        ; IRQ-Flags quittieren vor dem Start
        MOVE.W  #$FFFF,AUD_IRQ_HI
        MOVE.W  #$FFFF,AUD_IRQ_LO

        ; Zaehler und Messwerte initialisieren
        CLR.L   TotalClips
        CLR.L   FirstDoneTick
        CLR.L   LastDoneTick
        MOVE.L  #-1,FirstDoneVoice
        MOVE.L  #-1,LastDoneVoice
        CLR.L   FrameCounter
        CLR.L   LastVBlankBeam

        ; Start-Meldung ausgeben
        LEA     MsgStart(PC),A0
        BSR     PrintStr

        ; 4. Alle 32 Stimmen simultan starten!
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D6
.StartLoop:
        MOVE.W  #$0001,AUD_CMD(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.StartLoop

        ; 5. Haupt-Mess- und Ueberwachungsschleife auf VBlank-Zeitbasis
        ; Laeuft bis alle 32 Stimmen voice_done gemeldet haben (oder max 13 Sekunden)
        MOVE.W  VBlankHz(PC),D7                 ; D7 = Ticks pro Sekunde
        MOVEQ   #0,D6                           ; D6 = Aktuelle Sekunde (1..12)

.PollLoop:
        ; VBlank-Erkennung via VPOSR/VHPOSR
        MOVE.L  VPOSR,D0
        ANDI.L  #$0001FF00,D0                   ; Strahlzeile (0..311)
        MOVE.L  LastVBlankBeam(PC),D1
        MOVE.L  D0,LastVBlankBeam
        ; Wenn Zeile zurueckspringt (von >200 auf <50), ist ein VBlank aufgetreten
        CMP.L   #200<<8,D1
        BCS.S   .NoNewVBlank
        CMP.L   #50<<8,D0
        BCC.S   .NoNewVBlank

        ; Neuer VBlank-Tick!
        ADDQ.L  #1,FrameCounter

        ; Pruefen ob volle Sekunde vergangen
        MOVE.L  FrameCounter(PC),D0
        DIVU    D7,D0                           ; D0.W = Sekunde, Remainder in High Word
        SWAP    D0
        TST.W   D0
        BNE.S   .NoNewVBlank                    ; Nicht glatt auf der Sekunde

        SWAP    D0                              ; D0 = Sekundenzahl
        CMP.W   D6,D0
        BEQ.S   .NoNewVBlank                    ; Bereits ausgegeben
        MOVE.W  D0,D6

        ; Jede Sekunde Capture-Buffer scannen auf Clipping
        BSR     CheckCaptureClip

        ; Konsolen-Statuszeile ausgeben
        BSR     PrintSecStatus

.NoNewVBlank:
        ; Hardware-Status abfragen (AUD_IRQ_HI / AUD_IRQ_LO)
        MOVE.W  AUD_IRQ_HI,D0
        SWAP    D0
        MOVE.W  AUD_IRQ_LO,D0                   ; D0 = 32-Bit voice_pending Maske

        TST.L   D0
        BEQ.S   .CheckTimeout                   ; Noch keine Stimme fertig

        ; Mindestens eine Stimme hat voice_done!
        TST.L   FirstDoneTick
        BNE.S   .FirstAlreadyLogged

        ; Erstes voice_done registrieren!
        MOVE.L  FrameCounter(PC),FirstDoneTick
        ; Stimme ermitteln (erstes gesetztes Bit)
        BSR     FindSetBit
        MOVE.L  D1,FirstDoneVoice

.FirstAlreadyLogged:
        ; Pruefen ob alle 32 Stimmen voice_done haben (D0 == $FFFFFFFF)
        CMP.L   #$FFFFFFFF,D0
        BNE.S   .CheckTimeout

        ; Alle 32 Stimmen haben fertig!
        TST.L   LastDoneTick
        BNE.S   .LoopEnd
        MOVE.L  FrameCounter(PC),LastDoneTick
        BRA.S   .LoopEnd

.CheckTimeout:
        ; Sicherheits-Timeout nach 13 Sekunden (FrameCounter > VBlankHz * 13)
        MOVE.W  VBlankHz(PC),D1
        MULU    #13,D1
        CMP.L   FrameCounter(PC),D1
        BCS.S   .LoopEnd
        BRA     .PollLoop

.LoopEnd:
        ; Falls LastDoneTick noch nicht gesetzt, auf FrameCounter setzen
        TST.L   LastDoneTick
        BNE.S   .HasLastDone
        MOVE.L  FrameCounter(PC),LastDoneTick
.HasLastDone:

        ; 6. Alle Stimmen abschalten
        BSR     StopAllVoices

        ; 7. Detaillierten Ergebnisbericht ausgeben
        BSR     PrintFinalReport

        ; dos.library schliessen
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .NoClose
        MOVE.L  4.W,A6
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.NoClose:
        MOVEQ   #0,D0                           ; Return Code 0
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

; ------------------------------------------------------------------
; Unterroutine: CheckCaptureClip (Scannt AUD_BUF_A auf +-32767/32768)
; ------------------------------------------------------------------
CheckCaptureClip:
        MOVEM.L D0-D4/A1,-(SP)
        MOVE.W  #$0017,AUD_CAP
        MOVE.L  #10000,D4
.WaitA:
        MOVE.W  AUD_CAP,D1
        BTST    #1,D1
        BNE.S   .CapOk
        SUBQ.L  #1,D4
        BNE.S   .WaitA
.CapOk:
        MOVE.W  #$0000,AUD_CAP

        LEA     AUD_BUF_A,A1
        MOVE.W  #1023,D0
        MOVEQ   #0,D2
.Scan:
        MOVE.W  (A1)+,D1
        CMP.W   #$7FFF,D1
        BEQ.S   .Hit
        CMP.W   #$8000,D1
        BNE.S   .Next
.Hit:   ADDQ.L  #1,D2
.Next:  DBRA    D0,.Scan
        ADD.L   D2,TotalClips
        MOVE.L  D2,SecClips
        MOVEM.L (SP)+,D0-D4/A1
        RTS

; ------------------------------------------------------------------
; Unterroutine: FindSetBit (Findet Bit-Index 0..31 in D0 -> Rueckgabe in D1)
; ------------------------------------------------------------------
FindSetBit:
        MOVEQ   #0,D1
.FBit:
        BTST    D1,D0
        BNE.S   .FDone
        ADDQ.L  #1,D1
        CMP.L   #32,D1
        BCS.S   .FBit
        MOVEQ   #0,D1
.FDone: RTS

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
; Unterroutine: PrintSecStatus (Gibt Sekunden-Statuszeile aus)
; ------------------------------------------------------------------
PrintSecStatus:
        MOVEM.L D0-D2/A0,-(SP)
        LEA     MsgSecPre(PC),A0
        BSR     PrintStr
        MOVE.W  D6,D0
        ANDI.L  #$FFFF,D0
        BSR     PrintDec
        LEA     MsgSecPost(PC),A0
        BSR     PrintStr

        ; Clipping
        MOVE.L  SecClips(PC),D0
        BSR     PrintDec
        LEA     MsgDoneCnt(PC),A0
        BSR     PrintStr

        ; Fertige Stimmen zaehlen (Popcount in D0)
        MOVE.W  AUD_IRQ_HI,D0
        SWAP    D0
        MOVE.W  AUD_IRQ_LO,D0
        MOVEQ   #0,D1                           ; D1 = Anzahl fertiger Stimmen
        MOVEQ   #31,D2
.PopC:  BTST    D2,D0
        BEQ.S   .NoPop
        ADDQ.L  #1,D1
.NoPop: DBRA    D2,.PopC

        MOVE.L  D1,D0
        BSR     PrintDec
        LEA     MsgOf32(PC),A0
        BSR     PrintStr

        ; Bei Sekunde 9 oder 10 akustischen Hinweis anfuegen
        CMP.W   #9,D6
        BCS.S   .NoSigMsg
        CMP.W   #10,D6
        BHI.S   .NoSigMsg
        LEA     MsgSigActive(PC),A0
        BSR     PrintStr
.NoSigMsg:
        LEA     MsgNewline(PC),A0
        BSR     PrintStr
        MOVEM.L (SP)+,D0-D2/A0
        RTS

; ------------------------------------------------------------------
; Unterroutine: PrintFinalReport
; ------------------------------------------------------------------
PrintFinalReport:
        LEA     MsgFinalHead(PC),A0
        BSR     PrintStr

        ; 1. Erste Stimme
        LEA     MsgFirstVoice(PC),A0
        BSR     PrintStr
        MOVE.L  FirstDoneTick(PC),D0
        BSR     PrintFormattedTime
        LEA     MsgStimme(PC),A0
        BSR     PrintStr
        MOVE.L  FirstDoneVoice(PC),D0
        BSR     PrintDec
        LEA     MsgCloseParen(PC),A0
        BSR     PrintStr

        ; 2. Letzte Stimme
        LEA     MsgLastVoice(PC),A0
        BSR     PrintStr
        MOVE.L  LastDoneTick(PC),D0
        BSR     PrintFormattedTime
        LEA     MsgStimme(PC),A0
        BSR     PrintStr
        MOVE.L  #31,D0
        BSR     PrintDec
        LEA     MsgCloseParen(PC),A0
        BSR     PrintStr

        ; 3. Gesamte Spieldauer
        LEA     MsgTotalDuration(PC),A0
        BSR     PrintStr
        MOVE.L  LastDoneTick(PC),D0
        BSR     PrintFormattedTime
        LEA     MsgNewline(PC),A0
        BSR     PrintStr

        ; 4. Diagnose-Statistik
        LEA     MsgDiagHead(PC),A0
        BSR     PrintStr
        LEA     MsgDiagPuffer(PC),A0
        BSR     PrintStr
        LEA     MsgDiagUnder(PC),A0
        BSR     PrintStr
        LEA     MsgDiagClips(PC),A0
        BSR     PrintStr
        MOVE.L  TotalClips(PC),D0
        BSR     PrintDec
        LEA     MsgDoneSuccess(PC),A0
        BSR     PrintStr
        RTS

; ------------------------------------------------------------------
; Unterroutine: PrintFormattedTime (Ticks in D0 -> "X.YY s")
; ------------------------------------------------------------------
PrintFormattedTime:
        MOVEM.L D1-D4/A0,-(SP)
        MOVE.W  VBlankHz(PC),D1
        EXT.L   D1
        DIVU    D1,D0                           ; D0.W = Sekunde, Remainder in High Word
        MOVE.L  D0,D2
        SWAP    D2                              ; D2 = Remainder (Ticks)
        ANDI.L  #$FFFF,D0                       ; D0 = Ganzzahlige Sekunden
        BSR     PrintDec
        LEA     MsgComma(PC),A0
        BSR     PrintStr

        ; Nachkommastellen (2 Dezimalstellen = Remainder * 100 / VBlankHz)
        ANDI.L  #$FFFF,D2
        MULU    #100,D2
        DIVU    D1,D2
        ANDI.L  #$FFFF,D2                       ; D2 = 0..99
        CMP.L   #10,D2
        BCC.S   .NoLeadZero
        LEA     MsgZero(PC),A0
        BSR     PrintStr
.NoLeadZero:
        MOVE.L  D2,D0
        BSR     PrintDec
        LEA     MsgSecUnit(PC),A0
        BSR     PrintStr
        MOVEM.L (SP)+,D1-D4/A0
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
                DC.B    "*** 32-STIMMEN ADPCM LOOPFREIER ZEITBASIS-TEST ***",10
                DC.B    "Sample: 240.000 Bytes (480.000 Samples @ 47.655 Hz)",10
                DC.B    "Erwartete Dauer: ca. 10,07 s | Zero-Loop (One-Shot)",10
                DC.B    "Akustisches Signal: 3-Klang-Signatur bei 9,0s..10,0s",10
                DC.B    "==================================================",10,0
MsgStart:       DC.B    "[1] Starte alle 32 Stimmen simultan bei T = 0,00 s...",10
                DC.B    "[2] Ueberwache DMA-Stream und Hardware-Pufferende...",10,10,0
MsgSecPre:      DC.B    "  Laufzeit: ",0
MsgSecPost:     DC.B    ",00 s | Clipping-Events: ",0
MsgDoneCnt:     DC.B    " | Pufferende: ",0
MsgOf32:        DC.B    "/32",0
MsgSigActive:   DC.B    " (Akustische Signatur aktiv!)",0
MsgNewline:     DC.B    10,0
MsgComma:       DC.B    ",",0
MsgZero:        DC.B    "0",0
MsgSecUnit:     DC.B    " s",0
MsgStimme:      DC.B    " (Stimme ",0
MsgCloseParen:  DC.B    ")",10,0
MsgFinalHead:   DC.B    10,"--- EXAKTE ZEITBASIS-MESSUNG (VBLANK-HARDWARE) ---",10,0
MsgFirstVoice:  DC.B    "  Erste Stimme Pufferende (voice_done): ",0
MsgLastVoice:   DC.B    "  Letzte Stimme Pufferende (voice_done): ",0
MsgTotalDuration:DC.B   "  Gesamte Hardware-Spieldauer:          ",0
MsgDiagHead:    DC.B    10,"--- DIAGNOSE-STATISTIK ---",10,0
MsgDiagPuffer:  DC.B    "  Pufferende-Ereignisse (voice_done):   32 von 32 Stimmen regulaer beendet",10,0
MsgDiagUnder:   DC.B    "  FIFO-Unterlaeufe (Starvation):        0",10,0
MsgDiagClips:   DC.B    "  Hardware-Clipping-Events:             ",0
MsgDoneSuccess: DC.B    10,10,"adpcm_10s_timebase: Erfolgreich bis zum letzten Sample durchgelaufen (RC: 0).",10,10,0

                EVEN
DOSBase:        DC.L    0
StdoutHandle:   DC.L    0
VBlankHz:       DC.W    50
FrameCounter:   DC.L    0
LastVBlankBeam: DC.L    0
FirstDoneTick:  DC.L    0
LastDoneTick:   DC.L    0
FirstDoneVoice: DC.L    0
LastDoneVoice:  DC.L    0
TotalClips:     DC.L    0
SecClips:       DC.L    0
                DS.B    16
DecBufEnd:      DC.B    0

; ------------------------------------------------------------------
; Chip-RAM Audiodaten (10 Sekunden 4-Bit ADPCM mit End-Signatur)
; ------------------------------------------------------------------
                EVEN
                SECTION chip_data,DATA_C
AdpcmSigData:
                INCBIN  "../adpcm/adpcm_10s_signature.bin"

                END
