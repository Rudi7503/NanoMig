; ==============================================================================
; MiSTer FPGA / Minimig-AGA: 32-Kanal 16-Bit Stereo 48 kHz Stresstest (stress_48k)
;
; Kickstart 1.3 kompatibel (dos.library Output/Write/Delay)
;
; Startet alle 32 Hardware-Stimmen gleichzeitig im 16-Bit Stereo PCM Modus
; bei 48 kHz. Jede Stimme liest 4 Bytes je Sample (16-Bit Links + 16-Bit Rechts).
;
; Datenrate:
;   32 Stimmen * 48.000 Samples/s * 4 Bytes = 6.144.000 Bytes/s (~6,14 MB/s)
;   Reiner kontinuierlicher Audio-DMA Durchsatz aus dem Chip-RAM / SDRAM!
;
; Spieldauer: 10 Sekunden
;
; Assembler: vasmm68k_mot -Fhunk -o stress_48k.o stress_48k.s
; Linker:    vlink -bamigahunk -x -Bstatic -o stress_48k stress_48k.o
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
AUD_CMD         EQU $1A

CTRL_16BIT      EQU $0001       ; Bit 0: 16-Bit PCM
CTRL_STEREO     EQU $0004       ; Bit 2: Stereo Interleaved

PER_48K         EQU 521         ; 48 kHz

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

        ; 2. Zunaechst alle 32 Stimmen stoppen
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.StopAll:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.StopAll

        ; 3. Alle 32 Stimmen auf 16-Bit Stereo 48 kHz konfigurieren
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D6
.InitVoices:
        MOVE.L  #RechteckData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #RECHTECK_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO),AUD_CTRL(A0)
        ; Headroom fuer 32 Stimmen: $2020 pro Stimme
        MOVE.W  #$2020,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.InitVoices

        ; 4. Alle 32 Stimmen starten!
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D6
.StartVoices:
        MOVE.W  #$0001,AUD_CMD(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D6,.StartVoices

        LEA     MsgRunning(PC),A0
        BSR     PrintStr

        ; 5. 10 Sekunden lang unter Maximallast laufen lassen (500 Ticks)
        MOVE.L  #500,D1
        BSR     DosDelay

        ; 6. Alle Stimmen stoppen
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
        MOVE.L  DOSBase(PC),A1
        MOVE.L  $00000004.W,A6
        JSR     _LVOCloseLibrary(A6)

        MOVEQ   #0,D0
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

; ------------------------------------------------------------------
; Hilfsroutine: DosDelay
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
        MOVE.L  A0,D2
        MOVE.L  A0,A1
.LenLoop:
        TST.B   (A1)+
        BNE.S   .LenLoop
        SUBQ.L  #1,A1
        SUBA.L  A0,A1
        MOVE.L  A1,D3
        BEQ.S   .Exit
        MOVE.L  DOSBase(PC),A6
        JSR     _LVOWrite(A6)
.Exit:
        MOVEM.L (SP)+,D0-D3/A0-A1/A6
        RTS

; ------------------------------------------------------------------
; Daten
; ------------------------------------------------------------------
                EVEN
DosName:        DC.B    "dos.library",0
MsgBanner:      DC.B    10,"==================================================",10
                DC.B    "*** 32-KANAL 16-BIT STEREO 48 KHZ STRESSTEST ***",10
                DC.B    "Maximale Speicherlast: ~6,14 MB/s Audio-DMA Durchsatz",10
                DC.B    "==================================================",10,0
MsgRunning:     DC.B    "32 Stimmen mit 16-Bit Stereo @ 48 kHz laufen 10 Sek...",10,0
MsgDone:        DC.B    "*** 48 kHz 32-Kanal Stresstest erfolgreich beendet! ***",10,10,0

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
