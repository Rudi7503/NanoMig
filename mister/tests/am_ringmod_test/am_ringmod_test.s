; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Hardware AM-Modulation & Ringmodulation Test
;
; Kickstart 1.3 kompatibel (dos.library Output/Write/Delay)
;
; Testet die modularen Hardware-Kanalverknuepfungen der Audio-Erweiterung:
;
;   PHASE A (5 Sekunden): AM-Modulation (Tremolo)
;     - Kanal 0: 4-Hz Sinus-LFO (v_mute_mix = 1 -> stummgeschaltet im Master-Mix)
;     - Kanal 1: 440-Hz Sinuston (v_mod_mode = 01 -> Amplitudenmodulation)
;     - Hoer-Ergebnis: Glasklares, 4-mal pro Sekunde pulsierendes Tremolo.
;
;   PAUSE (1,5 Sekunden):
;     - Absolute Stille
;
;   PHASE B (5 Sekunden): Ringmodulation (Vier-Quadranten-Produkt)
;     - Kanal 0: 440-Hz Sinus (Träger, v_mute_mix = 1)
;     - Kanal 1: 330-Hz Sinus (v_mod_mode = 10 -> Ringmodulation)
;     - Hoer-Ergebnis: Futuristischer metallischer Sci-Fi-Klang (770 Hz und 110 Hz).
;
; Assembler: vasmm68k_mot -Fhunk -o am_ringmod_test.o am_ringmod_test.s
; Linker:    vlink -bamigahunk -x -Bstatic -o am_ringmod_test am_ringmod_test.o
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

CTRL_16BIT      EQU $0001       ; Bit 0: 16-Bit Modus
CTRL_MOD_AM     EQU $0800       ; Bit 11: Modus 01 = AM-Modulation (Tremolo)
CTRL_MOD_RING   EQU $1000       ; Bit 12: Modus 10 = Ringmodulation
CTRL_MUTE_MIX   EQU $2000       ; Bit 13: Im Master-Mix stummschalten (reiner Modulator)

PER_48K         EQU 521         ; 48 kHz
SINE_BYTES      EQU 96000       ; 48.000 Samples à 16 Bit (1 Sekunde Loop)

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
        ; Alle Stimmen stoppen
        BSR     StopAllVoices

        ; ==============================================================
        ; TEIL 1: AM-MODULATION (TREMOLO) - 5 SEKUNDEN
        ; ==============================================================
        LEA     MsgPhaseA(PC),A0
        BSR     PrintStr

        ; Kanal 0: 4-Hz Sinus LFO (Stumm im Master-Mix)
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.L  #SineLfo4Data,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.L  #SINE_BYTES,D0
        MOVE.W  D0,AUD_LENL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$8080,AUD_VOL(A0)
        MOVE.W  #(CTRL_16BIT|CTRL_MUTE_MIX),AUD_CTRL(A0) ; Stumm im Mix!

        ; Kanal 1: 440-Hz Sinuston (AM-Modulation durch Kanal 0)
        LEA     VOICE_STRIDE(A0),A0
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.L  #Sine440Data,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.L  #SINE_BYTES,D0
        MOVE.W  D0,AUD_LENL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$3030,AUD_VOL(A0)                      ; Angenehmer Pegel
        MOVE.W  #(CTRL_16BIT|CTRL_MOD_AM),AUD_CTRL(A0)  ; AM aktiv!

        ; Starten: Modulator zuerst, dann Träger
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0001,AUD_CMD(A0)
        NOP
        LEA     VOICE_STRIDE(A0),A0
        MOVE.W  #$0001,AUD_CMD(A0)

        ; 5 Sekunden spielen lassen (250 Ticks)
        MOVE.L  #250,D1
        BSR     DosDelay

        ; Stimmen stoppen
        BSR     StopAllVoices

        ; ==============================================================
        ; PAUSE: 1,5 SEKUNDEN STILLE
        ; ==============================================================
        LEA     MsgPause(PC),A0
        BSR     PrintStr
        MOVE.L  #75,D1
        BSR     DosDelay

        ; ==============================================================
        ; TEIL 2: RINGMODULATION (440 Hz x 330 Hz) - 5 SEKUNDEN
        ; ==============================================================
        LEA     MsgPhaseB(PC),A0
        BSR     PrintStr

        ; Kanal 0: 440-Hz Sinus (Träger, stumm im Mix)
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.L  #Sine440Data,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.L  #SINE_BYTES,D0
        MOVE.W  D0,AUD_LENL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$8080,AUD_VOL(A0)
        MOVE.W  #(CTRL_16BIT|CTRL_MUTE_MIX),AUD_CTRL(A0)

        ; Kanal 1: 330-Hz Sinus (Ringmodulation durch Kanal 0)
        LEA     VOICE_STRIDE(A0),A0
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.L  #Sine330Data,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.L  #SINE_BYTES,D0
        MOVE.W  D0,AUD_LENL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$3030,AUD_VOL(A0)
        MOVE.W  #(CTRL_16BIT|CTRL_MOD_RING),AUD_CTRL(A0) ; Ringmodulation aktiv!

        ; Starten: Modulator zuerst, dann Träger
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0001,AUD_CMD(A0)
        NOP
        LEA     VOICE_STRIDE(A0),A0
        MOVE.W  #$0001,AUD_CMD(A0)

        ; 5 Sekunden spielen lassen (250 Ticks)
        MOVE.L  #250,D1
        BSR     DosDelay

        ; Stimmen stoppen
        BSR     StopAllVoices

        ; Abschlussmeldung ausgeben
        LEA     MsgDone(PC),A0
        BSR     PrintStr

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
; Unterroutine: StopAllVoices
; ------------------------------------------------------------------
StopAllVoices:
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.SLoop:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        MOVE.W  #0,AUD_CTRL(A0)
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
; Texte & Konstanten
; ------------------------------------------------------------------
DosName:        DC.B    "dos.library",0
MsgBanner:      DC.B    10,"==================================================",10
                DC.B    "*** HARDWARE AM- & RINGMODULATION TEST ***",10
                DC.B    "Plattform: MiSTer FPGA / Minimig-AGA Audio-Ext",10
                DC.B    "==================================================",10,10,0
MsgPhaseA:      DC.B    "[Phase A] AM-Modulation (Tremolo) aktiv (5 Sekunden)...",10
                DC.B    "  Kanal 0: 4-Hz Sinus-LFO (stumm im Mix)",10
                DC.B    "  Kanal 1: 440-Hz Ton (moduliert mit Kanal 0)",10
                DC.B    "  Erwartung: Gleichmaessig pulsierendes 4-Hz Tremolo.",10,10,0
MsgPause:       DC.B    "[Pause] 1,5 Sekunden Stille...",10,10,0
MsgPhaseB:      DC.B    "[Phase B] Ringmodulation (Sci-Fi Metallklang) aktiv (5 Sekunden)...",10
                DC.B    "  Kanal 0: 440-Hz Sinus (stumm im Mix)",10
                DC.B    "  Kanal 1: 330-Hz Sinus (moduliert mit Kanal 0)",10
                DC.B    "  Erwartung: Charakteristischer Glocken-/Metallklang (770 Hz / 110 Hz).",10,10,0
MsgDone:        DC.B    "==================================================",10
                DC.B    "am_ringmod_test: Beide Phasen erfolgreich beendet (RC: 0).",10
                DC.B    "==================================================",10,10,0

                EVEN
DOSBase:        DC.L    0
StdoutHandle:   DC.L    0

; ------------------------------------------------------------------
; Chip-RAM Audiodaten (16-Bit Mono Sinuswellen à 96.000 Bytes)
; ------------------------------------------------------------------
                EVEN
                SECTION chip_data,DATA_C
Sine440Data:    INCBIN  "sine_440_1s.bin"
SineLfo4Data:   INCBIN  "sine_lfo4_1s.bin"
Sine330Data:    INCBIN  "sine_330_1s.bin"

                END
