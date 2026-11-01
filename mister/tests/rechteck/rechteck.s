; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Rechteck durch 32 Tiefpaesse
;
; Beweist, dass die Filterkette die Oberschwingungen entfernt.
;
;   ch0      Rechteck 200 Hz, beide Kanaele, Vollaussteuerung
;   ch1..31  Tiefpass 300 Hz, Quelle = Vorgaenger nach Filter
;
; Nach 32 Stufen ist aus dem Rechteck ein Sinus bei 200 Hz geworden.
; Nachgewiesen ueber die Amplitudeverteilung:
;
;   Rechteck  fast alle Samples liegen am Anschlag   -> rund 100 Prozent
;   Sinus     nur die Naehe der Extrema              -> rund  50 Prozent
;
; Schwelle 75 Prozent:
;   gruen = darunter, also Sinus, Filter arbeitet
;   rot   = darueber, also noch eckig, Filter greift nicht
;
; Hoerbar: ein weicher Sinus bei 200 Hz, leise.
;
; Assembler: vasmm68k_mot -Fhunk -o rechteck.o rechteck.s
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
AUD_BQ_B0       EQU $10
AUD_BQ_B1       EQU $12
AUD_BQ_B2       EQU $14
AUD_BQ_A1       EQU $16
AUD_BQ_A2       EQU $18
AUD_CMD         EQU $1A

AUD_CAP         EQU $DFF802
AUD_BUF_A       EQU $DF8000

CTRL_16BIT      EQU $0001
CTRL_STEREO     EQU $0004
CTRL_FILTER     EQU $0180
CTRL_CHAIN_POST EQU $0200

PER_48K         EQU 521
NUM_VOICES      EQU 32

        SECTION text,CODE

Start:
        MOVE.L  A7,A5
        LEA     CUSTOM,A0
        MOVE.W  #$0200,DMACON(A0)

; ------------------------------------------------------------------
; Alle Stimmen vorbereiten
; ------------------------------------------------------------------
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7
.Setup:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        MOVE.L  #RechteckData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #RECHTECK_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #BQ_B0,AUD_BQ_B0(A0)
        MOVE.W  #BQ_B1,AUD_BQ_B1(A0)
        MOVE.W  #BQ_B2,AUD_BQ_B2(A0)
        MOVE.W  #BQ_A1,AUD_BQ_A1(A0)
        MOVE.W  #BQ_A2,AUD_BQ_A2(A0)
        TST.W   D7
        BNE.S   .Chain
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER),AUD_CTRL(A0)
        BRA.S   .Next
.Chain:
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER|CTRL_CHAIN_POST),AUD_CTRL(A0)
.Next:
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Setup

; ------------------------------------------------------------------
; Starten, dann nur die letzte Stufe hoerbar
; ------------------------------------------------------------------
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7
.Run:
        MOVE.W  #$0001,AUD_CMD(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Run

        LEA     AUDIO_EXT_BASE,A0
        LEA     VOICE_STRIDE*31(A0),A0
        MOVE.W  #$8080,AUD_VOL(A0)          ; nur ch31

        BSR     Settle

; ------------------------------------------------------------------
; Auswertung: Spitzenwert, dann Anteil der Samples nahe am Anschlag
; ------------------------------------------------------------------
        BSR     Peak                            ; D5 = Spitzenwert
        MOVE.L  D5,D6
        MULU    #7,D6
        DIVU    #10,D6                          ; D6 = 70 Prozent von D5

        MOVE.W  #$0017,AUD_CAP
.WaitA: MOVE.W  AUD_CAP,D1
        BTST    #1,D1
        BEQ.S   .WaitA

        LEA     AUD_BUF_A,A1
        MOVE.W  #1023,D0
        MOVEQ   #0,D2                           ; Zaehler ueber der Schwelle
.Count: MOVE.W  (A1)+,D3
        ADDQ.L  #2,A1
        EXT.L   D3
        BPL.S   .Pos
        NEG.L   D3
.Pos:   CMP.L   D6,D3
        BLE.S   .NextC
        ADDQ.W  #1,D2
.NextC: DBRA    D0,.Count
        MOVE.W  #$0000,AUD_CAP

; gruen, wenn weniger als 75 Prozent der Samples am Anschlag liegen
        MOVE.W  #$0F00,D1                       ; rot
        CMP.W   #768,D2
        BCC.S   .Show
        MOVE.W  #$00F0,D1                       ; gruen
.Show:  MOVE.W  D1,COLOR00

Loop:   BRA.S   Loop

; ------------------------------------------------------------------
Settle:
        MOVE.L  #400000,D0
.SL:    DBRA    D0,.SL
        RTS

; ------------------------------------------------------------------
; Peak: groesster Betrag im linken Kanal eines Capture-Blocks
; Rueckgabe D5
; ------------------------------------------------------------------
Peak:
        MOVE.W  #$0017,AUD_CAP
.Wait:  MOVE.W  AUD_CAP,D1
        BTST    #1,D1
        BEQ.S   .Wait
        LEA     AUD_BUF_A,A1
        MOVE.W  #1023,D0
        MOVEQ   #0,D5
.Scan:  MOVE.W  (A1)+,D3
        ADDQ.L  #2,A1
        EXT.L   D3
        BPL.S   .P
        NEG.L   D3
.P:     CMP.L   D5,D3
        BLE.S   .N
        MOVE.L  D3,D5
.N:     DBRA    D0,.Scan
        MOVE.W  #$0000,AUD_CAP
        RTS

        EVEN
        INCLUDE "rechteck_data.i"

        END
