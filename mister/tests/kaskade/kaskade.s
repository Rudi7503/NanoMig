; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Kaskadentest fuer die 32-Stimmen-Erweiterung
;
; Zweck: 32 Biquad-Stufen in Reihe, stereo, alles in einer Sampleperiode.
;   ch0  liest das Rauschen aus dem Speicher  (Quelle 00)
;   ch1..ch31 nehmen den Ausgang der Vorgaengerin (Quelle 10)
;
; Erwartung beim Hoeren:
;   sehr dunkles Rauschen, beide Seiten verschieden   -> Kaskade arbeitet
;   unveraendertes helles Rauschen                    -> Filter greift nicht
;   lautes Pfeifen / Brummen                          -> Kaskade schwingt
;   Stille                                            -> Kette ohne Einspeisung
;
; Wichtig: ch0 MUSS auf Quelle 00 stehen. Stehen alle 32 Stimmen auf 10,
; ist der Ring geschlossen und es wird nichts eingespeist.
;
; Assembler: vasmm68k_mot -Fhunk -o kaskade.o kaskade.s
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
AUD_BQ_B0       EQU $10
AUD_BQ_B1       EQU $12
AUD_BQ_B2       EQU $14
AUD_BQ_A1       EQU $16
AUD_BQ_A2       EQU $18
AUD_CMD         EQU $1A

CTRL_16BIT      EQU $0001
CTRL_STEREO     EQU $0004
CTRL_CHAIN_POST EQU $0200       ; Quelle 10 = Vorgaenger nach Filter

PER_48K         EQU 521
NUM_VOICES      EQU 32

        SECTION text,CODE

Start:
        MOVE.L  A7,A5
        LEA     CUSTOM,A0
        MOVE.W  #$0200,DMACON(A0)

; ------------------------------------------------------------------
; Alle 32 Stimmen konfigurieren
;   Lautstaerke 0 fuer alle, damit nichts summiert wird waehrend des Setups
; ------------------------------------------------------------------
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7

.Setup:
        MOVE.W  #$0002,AUD_CMD(A0)          ; STOP
        MOVE.W  #$0000,AUD_VOL(A0)
        MOVE.W  #$0000,AUD_CTRL(A0)

        MOVE.L  #KaskadeData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)

        MOVE.W  #KASKADE_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)

        MOVE.W  #PER_48K,AUD_PER(A0)

        ; Filterkoeffizienten, identisch fuer alle Stufen
        MOVE.W  #BQ_B0,AUD_BQ_B0(A0)
        MOVE.W  #BQ_B1,AUD_BQ_B1(A0)
        MOVE.W  #BQ_B2,AUD_BQ_B2(A0)
        MOVE.W  #BQ_A1,AUD_BQ_A1(A0)
        MOVE.W  #BQ_A2,AUD_BQ_A2(A0)

        ; Quelle und Filterfreigabe: ch0 eigene Quelle, alle anderen verkettet
        TST.W   D7
        BNE.S   .Chained
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|$0080|$0100),AUD_CTRL(A0)
        BRA.S   .Next
.Chained:
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_CHAIN_POST|$0080|$0100),AUD_CTRL(A0)
.Next:
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Setup

; ------------------------------------------------------------------
; Start: erst ch0, dann der Rest. Die Kette braucht eine Einspeisung.
; ------------------------------------------------------------------
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7
.Start:
        MOVE.W  #$0001,AUD_CMD(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Start

; Lautstaerke erst jetzt aufdrehen, damit der Einschwingvorgang nicht knallt
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7
.Vol:
        MOVE.W  #$4040,AUD_VOL(A0)          ; pro Stufe halbe Lautstaerke
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Vol

Loop:
        BRA.S   Loop

        EVEN
        INCLUDE "kaskade_data.i"

        END
