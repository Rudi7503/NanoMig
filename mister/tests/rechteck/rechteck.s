; ==============================================================================
; MiSTer FPGA / Minimig-AGA: Rechteck durch 32 Tiefpaesse (Diagnose-Version)
;
; Beweist, dass die Filterkette die Oberschwingungen entfernt.
; Mit mehrstufiger optischer Farbdiagnose fuer Toby & Tobys KI.
;
;   ch0      Rechteck 200 Hz, beide Kanaele, Vollaussteuerung
;   ch1..31  Tiefpass 300 Hz, Quelle = Vorgaenger nach Filter
;
; Farbcode-Bedeutung:
;   BLAU     (Default WB): Programm wurde von AmigaOS nicht gestartet
;   GELB     ($0FF0): Programm laeuft! Initialisierung Stimmen 0..31
;   MAGENTA  ($0F0F): Setup beendet, Stimmen gestartet
;   CYAN     ($00FF): Settle-Phase aktiv. HIER MUSS DER 200-HZ-TON TOENEN!
;   WEISS    ($0FFF): Hardware-Capture laeuft (wartet auf Block A)
;   SCHWARZ  ($0000): TIMEOUT! Capture-Hardware wurde nach 1s nicht fertig
;   ROT      ($0F00): Capture fertig, aber STILLE (Spitzenwert = 0)
;   ORANGE   ($0F80): Capture fertig, Signal vorhanden, aber ungefiltertes RECHTECK
;   GRUEN    ($00F0): TEST BESTANDEN! Harmonischer Sinus digital verifiziert!
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
CTRL_CHAIN_POST EQU $0400

PER_48K         EQU 521
NUM_VOICES      EQU 32

        SECTION text,CODE

Start:
        MOVE.L  A7,A5

        ; STUFE 1: GELB ($0FF0) = Start erreicht, CPU laeuft!
        MOVE.W  #$0FF0,COLOR00

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
        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #BQ_B0,AUD_BQ_B0(A0)
        MOVE.W  #BQ_B1,AUD_BQ_B1(A0)
        MOVE.W  #BQ_B2,AUD_BQ_B2(A0)
        MOVE.W  #BQ_A1,AUD_BQ_A1(A0)
        MOVE.W  #BQ_A2,AUD_BQ_A2(A0)
        CMPA.L  #AUDIO_EXT_BASE,A0
        BEQ.S   .Root
        MOVE.W  #0,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER|CTRL_CHAIN_POST),AUD_CTRL(A0)
        BRA.S   .Next
.Root:
        MOVE.W  #RECHTECK_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #(CTRL_16BIT|CTRL_STEREO|CTRL_FILTER),AUD_CTRL(A0)
.Next:
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D7,.Setup

        ; STUFE 2: MAGENTA ($0F0F) = Setup beendet, Stimmen starten
        MOVE.W  #$0F0F,COLOR00

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

        ; STUFE 3: CYAN ($00FF) = Stimmen gestartet, Audio laeuft (Settle-Phase)!
        ; HIER MUSS DER 200-HZ-TON ZU HOEREN SEIN!
        MOVE.W  #$00FF,COLOR00
        BSR     Settle

; ------------------------------------------------------------------
; Auswertung: Ein einziger Capture-Durchlauf fuer Block A mit Timeout
; ------------------------------------------------------------------
        ; STUFE 4: WEISS ($0FFF) = Capture aktiv, warte auf Block A (normal ~21 ms)
        MOVE.W  #$0FFF,COLOR00
        MOVE.W  #$0017,AUD_CAP

        MOVE.L  #1000000,D4                 ; Timeout ~1-2 Sekunden
.WaitA:
        MOVE.W  #$0FFF,COLOR00              ; Weiterschreiben gegen Copper
        MOVE.W  AUD_CAP,D1
        BTST    #1,D1
        BNE.S   .Captured
        SUBQ.L  #1,D4
        BNE.S   .WaitA

        ; TIMEOUT! Hardware-Capture meldete Block A nicht voll -> SCHWARZ ($0000)
.Timeout:
        MOVE.W  #$0000,COLOR00
        BRA.S   .Timeout

.Captured:
        ; 1. Spitzenwert in Block A ermitteln
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

        ; Wenn kein Signal gemessen wurde (Spitzenwert 0): ROT ($0F00)
        TST.W   D5
        BEQ.S   .FailSilent

        ; Schwelle: 70 Prozent vom Spitzenwert
        MOVE.L  D5,D6
        MULU    #7,D6
        DIVU    #10,D6
        ANDI.L  #$FFFF,D6

        ; 2. Anzahl Samples ueber Schwelle zaehlen
        LEA     AUD_BUF_A,A1
        MOVE.W  #1023,D0
        MOVEQ   #0,D2
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

        ; Auswertung:
        ; gruen ($00F0), wenn weniger als 75% der Samples am Anschlag liegen
        ; orange ($0F80), wenn noch Rechteck (Filter dämpft nicht)
        MOVE.W  #$0F80,D1                   ; orange = Signal da, aber noch Rechteck
        CMP.W   #768,D2
        BCC.S   .Show
        MOVE.W  #$00F0,D1                   ; gruen = Sinus, Filterung erfolgreich!
        BRA.S   .Show

.FailSilent:
        MOVE.W  #$0F00,D1                   ; rot = Stille, kein Signal im Capture-Puffer

.Show:
.Loop:  MOVE.W  D1,COLOR00
        BRA.S   .Loop

; ------------------------------------------------------------------
Settle:
        MOVE.L  #400000,D0
.SL:    MOVE.W  #$00FF,COLOR00              ; Cyan waehrend Settle
        SUBQ.L  #1,D0
        BNE.S   .SL
        RTS

        EVEN
        INCLUDE "rechteck_data.i"

        END
