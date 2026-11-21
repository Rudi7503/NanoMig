; ==============================================================================
; MiSTer FPGA / Minimig-AGA: ADPCM Stufen- & Skalierungstest (adpcm_stufen)
;
; Kickstart 1.3 kompatibel (dos.library Output/Write/Delay)
;
; Testet ADPCM-Wiedergabe (48 kHz) bei steigender Stimmenanzahl:
;   - Stufe 1:   1 Stimme  (Volle Lautstaerke $8080, 24 KB/s DMA-Last)
;   - Stufe 2:   8 Stimmen (Lautstaerke $3838, 192 KB/s DMA-Last)
;   - Stufe 3:  16 Stimmen (Lautstaerke $2424, 384 KB/s DMA-Last)
;   - Stufe 4:  24 Stimmen (Lautstaerke $1C1C, 576 KB/s DMA-Last)
;   - Stufe 5:  32 Stimmen (Lautstaerke $1616, 768 KB/s DMA-Last)
;
; Jede Stufe spielt 3 Sekunden lang dasselbe 4-Bit ADPCM Musiksample.
; Zeigt pro Stufe Stimmenanzahl, Pegel und DMA-Durchsatz in der Konsole an.
;
; Assembler: vasmm68k_mot -Fhunk -o adpcm_stufen.o adpcm_stufen.s
; Linker:    vlink -bamigahunk -x -Bstatic -o adpcm_stufen adpcm_stufen.o
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

CTRL_ADPCM      EQU $0008       ; Bit 3: ADPCM aktiv

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
        BEQ     .NoDos

        MOVE.L  D0,A6
        JSR     _LVOOutput(A6)
        MOVE.L  D0,StdoutHandle
        BEQ     .NoDos

        ; Banner ausgeben
        LEA     MsgBanner(PC),A0
        BSR     PrintStr

.NoDos:
        ; 2. Hauptschleife ueber die Stufen-Tabelle
        LEA     StageTable(PC),A4

.StageLoop:
        MOVE.W  (A4)+,D7                        ; D7 = Stimmenanzahl (1, 8, 16, 24, 32)
        BEQ     .AllDone                        ; 0 = Ende

        MOVE.W  (A4)+,D5                        ; D5 = Lautstaerke je Stimme (z.B. $8080, $3838)

        ; Alle 32 Stimmen stoppen
        BSR     StopAllVoices

        ; Pause vor jeder Stufe (25 Ticks = 500 ms)
        MOVE.L  #25,D1
        BSR     DosDelay

        ; Banner fuer aktuelle Stufe ausgeben
        LEA     MsgStageHdr(PC),A0
        BSR     PrintStr
        MOVE.W  D7,D0
        ANDI.L  #$FFFF,D0
        BSR     PrintDec

        LEA     MsgVol(PC),A0
        BSR     PrintStr
        MOVE.W  D5,D0
        ANDI.L  #$FFFF,D0
        BSR     PrintDec

        LEA     MsgDma(PC),A0
        BSR     PrintStr
        MOVE.W  D7,D0
        MULU    #24,D0                          ; D0 = Stimmen * 24 KB/s
        BSR     PrintDec
        LEA     MsgKbps(PC),A0
        BSR     PrintStr

        ; 3. Stimmen 0 .. (D7-1) vorbereiten
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  D7,D6
        SUBQ.W  #1,D6

.InitVoices:
        MOVE.W  #$0002,AUD_CMD(A0)              ; Sicherstellen: Gestoppt
        MOVE.L  #AdpcmData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #ADPCM_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #0,AUD_PRED(A0)
        MOVE.W  #CTRL_ADPCM,AUD_CTRL(A0)
        MOVE.W  D5,AUD_VOL(A0)                  ; Lautstaerke fuer diese Stufe
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.InitVoices

        ; 4. Stimmen 0 .. (D7-1) starten!
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  D7,D6
        SUBQ.W  #1,D6

.StartVoices:
        MOVE.W  #$0001,AUD_CMD(A0)              ; Start
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.StartVoices

        ; 5. 3 Sekunden lang abspielen (150 Ticks = 3.0 Sek.)
        MOVE.L  #150,D1
        BSR     DosDelay

        ; Stimmen stoppen
        BSR     StopAllVoices
        BRA     .StageLoop

.AllDone:
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
; Unterroutine: StopAllVoices (Stoppt alle 32 Stimmen)
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
; Eingabe: D1 = Anzahl Ticks (50 Ticks = 1 Sekunde)
; ------------------------------------------------------------------
DosDelay:
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .BusyLoop
        MOVEM.L D2-D3/A6,-(SP)
        MOVE.L  D0,A6
        JSR     _LVODelay(A6)
        MOVEM.L (SP)+,D2-D3/A6
        RTS

.BusyLoop:
        MULU    #35000,D1
.BLoop: SUBQ.L  #1,D1
        BNE.S   .BLoop
        RTS

; ------------------------------------------------------------------
; Unterroutine: PrintStr (String via dos.library ausgeben)
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
; Unterroutine: PrintDec (Dezimalzahl in D0 ausgeben)
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
; Texte & Tabellen
; ------------------------------------------------------------------
DosName:        DC.B    "dos.library",0
MsgBanner:      DC.B    10,"==================================================",10
                DC.B    "*** ADPCM STUFEN- & SKALIERUNGSTEST (KICK 1.3) ***",10
                DC.B    "Messung: 1, 8, 16, 24, 32 Stimmen bei 48 kHz",10
                DC.B    "Spieldauer: je 3 Sekunden mit Headroom-Skalierung",10
                DC.B    "==================================================",10,0
MsgStageHdr:    DC.B    10,">>> STUFE: ",0
MsgVol:         DC.B    " Stimmen  | Lautstaerke: $",0
MsgDma:         DC.B    " | DMA-Rate: ",0
MsgKbps:        DC.B    " KB/s",10,0
MsgDone:        DC.B    10,"adpcm_stufen: Alle Stufen erfolgreich abgespielt (RC: 0).",10,10,0

                EVEN
; Tabelle: DC.W Stimmenanzahl, Lautstaerke je Stimme
StageTable:
        DC.W    1,  $8080       ;  1 Stimme  (100% Vollaussteuerung, 24 KB/s)
        DC.W    8,  $3838       ;  8 Stimmen (192 KB/s)
        DC.W    16, $2424       ; 16 Stimmen (384 KB/s)
        DC.W    24, $1C1C       ; 24 Stimmen (576 KB/s)
        DC.W    32, $1616       ; 32 Stimmen (768 KB/s)
        DC.W    0,  0           ; Tabellenende

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
