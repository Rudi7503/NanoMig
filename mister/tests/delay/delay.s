; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Startverzoegerung und Lautstaerkeabfall
;
; Alle 32 Stimmen spielen dasselbe 200-ms-Rechteck (200 Hz), aber:
;   ch0  startet sofort
;   ch1  nach  10 ms
;   ch2  nach  20 ms
;   ...
;   ch31 nach 310 ms
;
; Jede Stufe hat 90 Prozent der Lautstaerke der vorigen.
; Ab Stufe 24 wird nicht weiter abgesenkt, damit das Ende hoerbar bleibt.
;
; Erwartung: 32 Echos im 10-ms-Raster, jedes leiser als das vorige.
;   gleichmaessig abklingendes Echo        -> Verzoegerung und Lautstaerke ok
;   alle Stimmen gleichzeitig              -> Verzoegerung wirkt nicht
;   nur ein Ton ohne Echos                 -> nur ch0 gestartet
;   Echos ohne Abschwaechung               -> Lautstaerke wirkt nicht
;
; Assembler: vasmm68k_mot -Fhunk -o delay.o delay.s
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
AUD_DELAY       EQU $1C
AUD_CMD         EQU $1A

AUD_CAP         EQU $DFF802
AUD_BUF_A       EQU $DF8000

CTRL_16BIT      EQU $0001
CTRL_STEREO     EQU $0004
CTRL_ONESHOT    EQU $0002        ; nach dem Ende in IDLE

PER_48K         EQU 521
NUM_VOICES      EQU 32

        SECTION text,CODE

Start:
        MOVE.L  A7,A5
        LEA     CUSTOM,A0
        MOVE.W  #$0200,DMACON(A0)
        MOVE.W  #$0000,COLOR00                  ; schwarz, kein Farbtest

; ------------------------------------------------------------------
; Alle Stimmen konfigurieren. Lautstaerke faellt um 10 Prozent je Stufe,
; ab Stufe 24 bleibt sie stehen (sonst waere das Ende unhoerbar).
; ------------------------------------------------------------------
        LEA     AUDIO_EXT_BASE,A0
        LEA     DelayTable,A2                   ; Verzoegerungswerte
        MOVEQ   #NUM_VOICES-1,D7
        MOVE.W  #128,D6                         ; Startlautstaerke
.Setup:
        MOVE.W  #$0002,AUD_CMD(A0)              ; STOP
        MOVE.W  #$0000,AUD_VOL(A0)

        MOVE.L  #DelayData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #DELAY_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_ONESHOT),AUD_CTRL(A0)

        MOVE.W  (A2)+,AUD_DELAY(A0)             ; Verzoegerung eintragen

        MOVE.W  D6,D5
        LSL.W   #8,D5
        MOVE.B  D6,D5                            ; links und rechts gleich
        MOVE.W  D5,AUD_VOL(A0)

        ; 90 Prozent fuer die naechste Stufe, aber nicht unter 24
        CMP.W   #24,D6
        BLS.S   .Keep
        MULU    #9,D6
        DIVU    #10,D6
.Keep:
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Setup

; ------------------------------------------------------------------
; Starten. ch0 ohne Verzoegerung, alle anderen mit ihrem Wert.
; ------------------------------------------------------------------
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7
.Run:
        MOVE.W  #$0001,AUD_CMD(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Run

; ------------------------------------------------------------------
; Farbanzeige: nach 500 ms sollten mehrere Stimmen laufen, nach 2 s
; wieder alle still sein (One-Shot).
; ------------------------------------------------------------------
        MOVE.L  #1500000,D0
.W1:    DBRA    D0,.W1
        MOVE.W  #$00F0,D1                       ; gruen: Echos laufen
        MOVE.W  D1,COLOR00

        MOVE.L  #4500000,D0
.W2:    DBRA    D0,.W2
        MOVE.W  #$000F,D1                       ; blau: Ende erreicht
        MOVE.W  D1,COLOR00

Loop:   BRA.S   Loop

        EVEN
        INCLUDE "delay_data.i"

; Verzoegerungswerte als Worttabelle, damit die Schleife sie einfach liest
        EVEN
DelayTable:
        dc.w    DELAY_0,DELAY_1,DELAY_2,DELAY_3,DELAY_4,DELAY_5,DELAY_6,DELAY_7
        dc.w    DELAY_8,DELAY_9,DELAY_10,DELAY_11,DELAY_12,DELAY_13,DELAY_14,DELAY_15
        dc.w    DELAY_16,DELAY_17,DELAY_18,DELAY_19,DELAY_20,DELAY_21,DELAY_22,DELAY_23
        dc.w    DELAY_24,DELAY_25,DELAY_26,DELAY_27,DELAY_28,DELAY_29,DELAY_30,DELAY_31

        END
