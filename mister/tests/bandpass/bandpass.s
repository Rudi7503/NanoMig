; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Bandpasskette bis 1 kHz
;
;   ch0      Rechteck 200 Hz, beide Kanaele, Vollaussteuerung
;   ch1..31  Bandpass 1 kHz, Quelle = Vorgaenger nach Filter
;
; Die 5. Harmonische des Rechtecks liegt exakt bei 1000 Hz. Der Bandpass
; holt sie heraus, der Ausgang muss ein Sinus bei 1 kHz sein.
;
; Nachweis ohne Frequenzanalyse, nur Nulldurchgaenge:
;   1024 Samples bei 48 kHz = 21,33 ms  ->  21,33 Perioden  ->  42,7 Wechsel
;   Sinus 1 kHz   rund 42
;   Rauschen      rund 500
;   Stille        0
;
;   gruen = 38 bis 48 Wechsel   (Sinus 1 kHz, Bandpass arbeitet)
;   rot   = ausserhalb
;
; Hoerbar: ein klarer 1-kHz-Ton.
;
; Assembler: vasmm68k_mot -Fhunk -o bandpass.o bandpass.s
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

        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7
.Setup:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        MOVE.L  #BandpassData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        MOVE.W  #BANDPASS_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #BQ_B0,AUD_BQ_B0(A0)
        MOVE.W  #BQ_B1,AUD_BQ_B1(A0)
        MOVE.W  #BQ_B2,AUD_BQ_B2(A0)
        MOVE.W  #BQ_A1,AUD_BQ_A1(A0)
        MOVE.W  #BQ_A2,AUD_BQ_A2(A0)
        CMPA.L  #AUDIO_EXT_BASE,A0
        BEQ.S   .Root
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER|CTRL_CHAIN_POST),AUD_CTRL(A0)
        BRA.S   .Next
.Root:
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER),AUD_CTRL(A0)
.Next:
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Setup

        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7
.Run:
        MOVE.W  #$0001,AUD_CMD(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Run

        LEA     AUDIO_EXT_BASE,A0
        LEA     VOICE_STRIDE*31(A0),A0
        MOVE.W  #$8080,AUD_VOL(A0)          ; nur ch31 hoerbar

        BSR     Settle

; ------------------------------------------------------------------
; Nulldurchgaenge im linken Kanal zaehlen
; ------------------------------------------------------------------
        MOVE.W  #$0017,AUD_CAP
.WaitA: MOVE.W  AUD_CAP,D1
        BTST    #1,D1
        BEQ.S   .WaitA

        LEA     AUD_BUF_A,A1
        MOVE.W  #1023,D0
        MOVEQ   #0,D2                       ; Wechselzaehler
        MOVE.W  (A1),D3                     ; erstes Sample als Vorzeichen
        ADDQ.L  #4,A1
        EXT.L   D3
.Scan:  MOVE.W  (A1),D4
        ADDQ.L  #4,A1
        EXT.L   D4
        EOR.L   D3,D4                       ; Vorzeichen vergleichen
        BPL.S   .Same
        ADDQ.W  #1,D2
.Same:  MOVE.W  -2(A1),D3                   ; aktuelles Sample als neues Vorzeichen
        EXT.L   D3
        DBRA    D0,.Scan
        MOVE.W  #$0000,AUD_CAP

; gruen bei 38 bis 48 Wechseln
        MOVE.W  #$0F00,D1                   ; rot
        CMP.W   #38,D2
        BLT.S   .Show
        CMP.W   #48,D2
        BGT.S   .Show
        MOVE.W  #$00F0,D1                   ; gruen
.Show:  MOVE.W  D1,COLOR00

Loop:   BRA.S   Loop

; ------------------------------------------------------------------
Settle:
        MOVE.L  #500000,D0
.SL:    DBRA    D0,.SL
        RTS

        EVEN
        INCLUDE "bandpass_data.i"

        END
