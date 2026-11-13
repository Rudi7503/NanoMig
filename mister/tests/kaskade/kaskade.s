; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Kaskadentest mit Selbstpruefung
;
; 32 Biquad-Stufen in Reihe, stereo, alles in einer Sampleperiode.
;   ch0  liest das Rauschen aus dem Speicher   (Quelle 00)
;   ch1..ch31 nehmen den Ausgang der Vorgaengerin (Quelle 10)
;
; Ablauf:
;   Phase A  Filter aus, nur ch0 hoerbar      -> Referenz, helles Rauschen
;   Phase B  Filter an,  nur ch31 hoerbar     -> Kaskadenausgang
;   Vergleich der Pegel, Ergebnis als Farbe.
;
;   gruen = Kaskade daempft deutlich  (Filter arbeitet)
;   rot   = beide Pegel gleich        (Filter greift nicht)
;
; Zusaetzlich hoerbar: erst helles Rauschen, dann sehr dunkles.
; Pfeifen oder Brummen in Phase B waere ein Schwingen der Kaskade.
;
; Assembler: vasmm68k_mot -Fhunk -o kaskade.o kaskade.s
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
CTRL_FILTER     EQU $0180        ; Filter links und rechts
CTRL_CHAIN_POST EQU $0200        ; Quelle 10 = Vorgaenger nach Filter

PER_48K         EQU 521
NUM_VOICES      EQU 32

        SECTION text,CODE

Start:
        MOVE.L  A7,A5
        LEA     CUSTOM,A0
        MOVE.W  #$0200,DMACON(A0)

; ------------------------------------------------------------------
; Koeffizienten und Puffer fuer alle 32 Stimmen setzen, noch gestoppt
; ------------------------------------------------------------------
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7
.Setup:
        MOVE.W  #$0002,AUD_CMD(A0)
        MOVE.W  #$0000,AUD_VOL(A0)
        MOVE.L  #KaskadeData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        CMPA.L  #AUDIO_EXT_BASE,A0
        BEQ.S   .SetupRoot
        MOVE.W  #0,AUD_LENL(A0)
        BRA.S   .SetupLenDone
.SetupRoot:
        MOVE.W  #KASKADE_BYTES,AUD_LENL(A0)
.SetupLenDone:
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #BQ_B0,AUD_BQ_B0(A0)
        MOVE.W  #BQ_B1,AUD_BQ_B1(A0)
        MOVE.W  #BQ_B2,AUD_BQ_B2(A0)
        MOVE.W  #BQ_A1,AUD_BQ_A1(A0)
        MOVE.W  #BQ_A2,AUD_BQ_A2(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Setup

; ------------------------------------------------------------------
; Phase A: Filter aus, nur ch0 hoerbar -> Referenzpegel
; ------------------------------------------------------------------
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7
.A_Ctrl:
        CMPA.L  #AUDIO_EXT_BASE,A0
        BEQ.S   .A_Root
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_CHAIN_POST),AUD_CTRL(A0)
        BRA.S   .A_Next
.A_Root:
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO),AUD_CTRL(A0)
.A_Next:
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.A_Ctrl

        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0001,AUD_CMD(A0)              ; alle starten
        MOVEQ   #0,D7
.A_Start:
        LEA     VOICE_STRIDE(A0),A0
        MOVE.W  #$0001,AUD_CMD(A0)
        ADDQ.W  #1,D7
        CMP.W   #NUM_VOICES-1,D7
        BNE.S   .A_Start

        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$8080,AUD_VOL(A0)              ; nur ch0 hoerbar
        BSR     Settle
        BSR     Measure                          ; D4 = Pegel A
        MOVE.L  D4,D5

; ------------------------------------------------------------------
; Phase B: Filter an, nur ch31 hoerbar -> Kaskadenausgang
; ------------------------------------------------------------------
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #NUM_VOICES-1,D7
.B_Ctrl:
        CMPA.L  #AUDIO_EXT_BASE,A0
        BEQ.S   .B_Root
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER|CTRL_CHAIN_POST),AUD_CTRL(A0)
        BRA.S   .B_Next
.B_Root:
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER),AUD_CTRL(A0)
.B_Next:
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.B_Ctrl

        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0000,AUD_VOL(A0)              ; ch0 stumm
        LEA     VOICE_STRIDE*31(A0),A0
        MOVE.W  #$8080,AUD_VOL(A0)              ; nur ch31 hoerbar

        BSR     Settle
        BSR     Measure                          ; D4 = Pegel B

; gruen, wenn die Kaskade auf weniger als ein Viertel daempft
        MOVE.W  #$0F00,D1                        ; rot
        LSL.L   #2,D4                            ; 4 * Pegel B
        CMP.L   D5,D4
        BCC.S   .Show
        MOVE.W  #$00F0,D1                        ; gruen
.Show:  MOVE.W  #$0000,AUD_CAP
Loop:   MOVE.W  D1,COLOR00
        BRA.S   Loop

; ------------------------------------------------------------------
; Settle: kurz warten, damit die Kette einschwingt
; ------------------------------------------------------------------
Settle:
        MOVE.L  #200000,D0
.SL:    DBRA    D0,.SL
        RTS

; ------------------------------------------------------------------
; Measure: Capture starten, Block A abwarten, Summe der Betraege
; Rueckgabe: D4 = Summe ueber 1024 linke Samples
; ------------------------------------------------------------------
Measure:
        MOVE.W  #$0017,AUD_CAP                   ; Capture an, Flags loeschen
.WaitA: MOVE.W  AUD_CAP,D1
        BTST    #1,D1
        BEQ.S   .WaitA

        LEA     AUD_BUF_A,A1
        MOVE.W  #1023,D0
        MOVEQ   #0,D4
.Sum:   MOVE.W  (A1)+,D3                         ; linker Kanal, dann rechter
        ADDQ.L  #2,A1
        EXT.L   D3
        BPL.S   .Pos
        NEG.L   D3
.Pos:   ADD.L   D3,D4
        DBRA    D0,.Sum
        RTS

        EVEN
        INCLUDE "kaskade_data.i"

        END
