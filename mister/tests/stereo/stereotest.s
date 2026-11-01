; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Stereo-Nachweis fuer die 32-Stimmen-Erweiterung
;
; Zweck: pruefen, ob die Kanaltrennung auf echter Hardware arbeitet.
;   links  440 Hz, rechts 880 Hz, gleiche Amplitude, ein Sample im Loop.
;
; Erwartung beim Hoeren:
;   links 440 Hz, rechts 880 Hz  -> Kanaltrennung arbeitet
;   beide Seiten gleich          -> Demux defekt (beide bekommen denselben Wert)
;   nur eine Seite               -> ein Kanal fehlt
;
; Assembler: vasmm68k_mot -Fhunk -o stereotest.o stereotest.s
; ==============================================================================

CUSTOM          EQU $DFF000
DMACON          EQU $096
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

; AUD_CTRL Bits: 0 = 16 Bit PCM, 2 = Stereo, 7 = Filter rechts, 8 = Filter links
CTRL_16BIT      EQU $0001
CTRL_STEREO     EQU $0004

; Periodenteiler: 25 MHz / 48 kHz = 521
PER_48K         EQU 521

        SECTION text,CODE

Start:
        MOVE.L  A7,A5                   ; eigenes Programm, kein System
        LEA     CUSTOM,A0
        MOVE.W  #$0200,DMACON(A0)       ; Audio-DMA an

        LEA     AUDIO_EXT_BASE,A0       ; Stimme 0

        MOVE.W  #$0002,AUD_CMD(A0)      ; erst stoppen
        NOP

        LEA     StereoData,A1
        MOVE.L  A1,D0
        MOVE.W  D0,AUD_PTRL(A0)         ; untere 16 Bit der Adresse
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)         ; obere 8 Bit

        MOVE.W  #STEREO_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)

        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$8080,AUD_VOL(A0)      ; links und rechts volle Lautstaerke

        ; 16-Bit PCM, Stereo, ohne Filter: isoliert die Kanaltrennung
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO),AUD_CTRL(A0)

        MOVE.W  #$0001,AUD_CMD(A0)      ; Start

Loop:
        BRA.S   Loop

        EVEN
        INCLUDE "stereotest_data.i"

        END
