; ==============================================================================
; MiSTer FPGA / Minimig-AGA: ADPCM-Decoder-Test
;
; Spielt eine echte ADPCM-Datei aus dem Apollo-ADPCM-Projekt ab:
;   Kakao_bei_Lotte_Run17_4-Bit,Mono,LE.adpx
;   Header 21 Bytes, danach der Codestrom, LSB-first gepackt
;
; Hier liegen die ersten 24.000 Bytes = 48.000 Codes = 1,0 s bei 48 kHz.
; Der Bitstrom ist unveraendert uebernommen; unser Reservoir liest ebenfalls
; LSB-first, deshalb ist keine Umkodierung noetig.
;
; ctrl = $0008   Bit 3 = ADPCM, Bit 5:4 = 00 -> 4 Bit je Code, mono
; pred0 = 0      Startpraediktor und Startindex
;
; Erwartung: Hoerbar ist die Melodie. Klingt es wie Rauschen oder Zischen,
; stimmt die Bitpackung oder die Schrittweiten-Tabelle nicht.
; Die Datei laeuft in der Schleife.
;
; Assembler: vasmm68k_mot -Fhunk -o adpcm.o adpcm.s
; ==============================================================================

CUSTOM          EQU $DFF000
DMACON          EQU $096
COLOR00         EQU $DFF180
AUDIO_EXT_BASE  EQU $DFF400

AUD_PTRH        EQU $00
AUD_PTRL        EQU $02
AUD_LENH        EQU $04
AUD_LENL        EQU $06
AUD_VOL         EQU $08
AUD_PER         EQU $0A
AUD_CTRL        EQU $0C
AUD_PRED        EQU $0E
AUD_CMD         EQU $1A

CTRL_ADPCM      EQU $0008
CTRL_4BIT       EQU $0000        ; Bit 5:4 = 00
PER_48K         EQU 521

ADPCM_CODES     EQU 48000
ADPCM_BYTES     EQU ADPCM_CODES/2      ; 4 Bit je Code

        SECTION text,CODE

Start:
        MOVE.L  A7,A5
        LEA     CUSTOM,A0
        MOVE.W  #$0200,DMACON(A0)
        MOVE.W  #$0000,COLOR00

        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  #$0002,AUD_CMD(A0)          ; STOP

        MOVE.L  #AdpcmData,D0
        MOVE.W  D0,AUD_PTRL(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)

        MOVE.W  #ADPCM_BYTES,AUD_LENL(A0)
        MOVE.W  #0,AUD_LENH(A0)

        MOVE.W  #PER_48K,AUD_PER(A0)
        MOVE.W  #$8080,AUD_VOL(A0)
        MOVE.W  #0,AUD_PRED(A0)             ; Praediktor 0, Index 0
        MOVE.W  #(CTRL_ADPCM|CTRL_4BIT),AUD_CTRL(A0)

        MOVE.W  #$0001,AUD_CMD(A0)          ; Start
        MOVE.W  #$00F0,COLOR00               ; gruen: laeuft

Loop:   BRA.S   Loop

        EVEN
AdpcmData:
        INCBIN  "adpcm_4bit.bin"
AdpcmDataEnd:

        END
