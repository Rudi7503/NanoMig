; ==============================================================================
; MiSTer FPGA / Minimig-AGA: AM-Modulation
;
; ch0  Traeger: 2-Hz-Sinus, als eine Periode gespeichert und langsam
;      abgespielt (PER 5208 -> 4,8 kHz, 2400 Samples -> 2 Hz)
; ch1  Ton: 440 Hz, dessen Lautstaerke dem Traeger folgt
;      (ctrl Bit 11 = Modus 01 = Amplitudenmodulation mit dem Ausgang
;       der vorigen Stimme)
;
; Erwartung: ein 440-Hz-Ton, der zweimal pro Sekunde lauter und leiser
; wird - ein gleichmaessiges Tremolo ueber die ganze Laufzeit.
;
;   gleichmaessiges Tremolo        -> AM arbeitet
;   gleichbleibend lauter Ton      -> Modus wirkt nicht, Lautstaerke konstant
;   gar kein Ton                   -> ch1 startet nicht
;   raues Brummen statt Tremolo    -> falscher Traeger oder falsche Periode
;
; Assembler: vasmm68k_mot -Fhunk -o am.o am.s
; ==============================================================================

CUSTOM          EQU $DFF000
DMACON          EQU $096
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
AUD_CMD         EQU $1A

CTRL_16BIT      EQU $0001
CTRL_STEREO     EQU $0004
CTRL_MOD_AM     EQU $0800        ; Bit 11: Modus 01, Amplitudenmodulation

        SECTION text,CODE

Start:
        MOVE.L  A7,A5
        LEA     CUSTOM,A0
        MOVE.W  #$0200,DMACON(A0)
        MOVE.W  #$0000,COLOR00

; ------------------------------------------------------------------
; ch0: Traeger
; ------------------------------------------------------------------
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.L  #AmCarrier,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #AM_CARRIER_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #AM_PER_CARRIER,AUD_PER(A0)
        MOVE.W  #$8080,AUD_VOL(A0)
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO),AUD_CTRL(A0)

; ------------------------------------------------------------------
; ch1: Ton mit Amplitudenmodulation
; ------------------------------------------------------------------
        LEA     VOICE_STRIDE(A0),A0
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.L  #AmTone,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #AM_TONE_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #AM_PER_TONE,AUD_PER(A0)
        MOVE.W  #$8080,AUD_VOL(A0)               ; Grundpegel, wird moduliert
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_MOD_AM),AUD_CTRL(A0)

; ------------------------------------------------------------------
; Starten: Traeger zuerst, damit er beim Start des Tons schon laeuft
; ------------------------------------------------------------------
        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0001,AUD_CMD(A0)
        NOP
        NOP
        LEA     VOICE_STRIDE(A0),A0
        MOVE.W  #$0001,AUD_CMD(A0)

        MOVE.W  #$00F0,COLOR00                   ; gruen: laeuft

Loop:   BRA.S   Loop

        EVEN
        INCLUDE "am_data.i"

        END
