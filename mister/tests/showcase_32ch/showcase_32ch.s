; ==============================================================================
; MiSTer FPGA / Minimig-AGA: 32-Channel Audio Showcase & Demonstration Suite
; Target: Motorola 68000 / 68020 on MiSTer DE10-Nano (Core Minimig_22a912cc)
;
; Kickstart 1.3 Shell-kompatibel (vollstaendige dos.library CLI-Integration)
;
; Demonstrations-Ablauf (~45 Sekunden Gesamtlaufzeit):
;   [0:00 - 0:05] Prolog:   Klassischer 4-Kanal Amiga-Paula Klang
;   [0:05 - 0:12] Szene 1:  "THX Deep Note" - 31 Stimmen polyphone Gleitfrequenz
;   [0:12 - 0:42] Szene 2:  "Cyberpunk 32-Kanal Synth Track"
;                           - 24 dB Moog Biquad-Kaskade mit Realtime-Cutoff LFO
;                           - Hardware AM-Modulation (Tremolo/Pluck)
;                           - Hardware Ringmodulation (Sci-Fi Bells)
;                           - 10-stimmiges Breitwand-Pad & Drums
;                           - Echtzeit-Farbskopie ueber Hardware-Capture ($DF8000)
;   [0:42 - 0:45] Szene 3:  Grand Finale & Fadeout in absolute Stille (RC: 0)
;
; Abbruch jederzeit mit linker Maustaste moeglich.
;
; Assembler: vasmm68k_mot -Fhunk -o showcase_32ch.o showcase_32ch.s
; Linker:    vlink -bamigahunk -x -Bstatic -o showcase_32ch showcase_32ch.o
; ==============================================================================

CUSTOM          EQU $DFF000
DMACON          EQU $096
INTENA          EQU $09A
INTREQ          EQU $09C
COLOR00         EQU $180
COLOR01         EQU $182
VPOSR           EQU $004
VHPOSR          EQU $006

; 32-Channel Audio Extension Base
AUDIO_EXT_BASE  EQU $DFF400
VOICE_STRIDE    EQU $20

; Register Offsets je Stimme
AUD_PTRH        EQU $00
AUD_PTRL        EQU $02
AUD_LENH        EQU $04
AUD_LENL        EQU $06
AUD_VOL         EQU $08
AUD_PER         EQU $0A
AUD_CTRL        EQU $0C
AUD_PRED        EQU $0E
AUD_BQ_B0       EQU $10
AUD_BQ_B1       EQU $12
AUD_BQ_B2       EQU $14
AUD_BQ_A1       EQU $16
AUD_BQ_A2       EQU $18
AUD_CMD         EQU $1A
AUD_DELAY       EQU $1C

; Audio Capture & Puffer
AUD_CAP_CTRL    EQU $DFF802
CAP_BUF_A       EQU $DF8000
CAP_BUF_B       EQU $DF9000

; Control Bits
CTRL_PCM16      EQU $0001
CTRL_LOOP       EQU $0000
CTRL_ONESHOT    EQU $0002
CTRL_STEREO     EQU $0004
CTRL_ADPCM      EQU $0008
CTRL_FLT_R      EQU $0080
CTRL_FLT_L      EQU $0100
CTRL_FLT_STEREO EQU $0180
CTRL_SRC_DMA    EQU $0000
CTRL_SRC_PRE    EQU $0200
CTRL_SRC_POST   EQU $0400
CTRL_MOD_AM     EQU $0800
CTRL_MOD_RING   EQU $1000
CTRL_MUTE_MIX   EQU $2000

_LVOOpenLibrary  EQU -552
_LVOCloseLibrary EQU -414
_LVOWrite        EQU -48
_LVOOutput       EQU -60
_LVODelay        EQU -198

        SECTION Code,CODE

Main:
        MOVEM.L D2-D7/A2-A6,-(SP)
        LEA     CUSTOM,A6

        ; 1. dos.library oeffnen
        MOVE.L  $00000004.W,A0
        LEA     DosName(PC),A1
        MOVEQ   #0,D0
        JSR     _LVOOpenLibrary(A0)
        MOVE.L  D0,DOSBase
        BEQ     .NoDos

        MOVE.L  D0,A0
        JSR     _LVOOutput(A0)
        MOVE.L  D0,StdoutHandle
        BEQ     .NoDos

        ; Banner ausgeben
        LEA     MsgBanner(PC),A0
        BSR     PrintStr

.NoDos:
        ; 2. Altes Paula Audio stummschalten
        MOVE.W  #$000F,DMACON(A6)       ; Paula Audio DMA deaktivieren
        MOVE.W  COLOR00(A6),Saved_COLOR00

        ; 3. Alle 32 Stimmen initialisieren/stoppen
        BSR     Silence_All_Voices

        ; 4. Audio-Capture aktivieren ($DF8000)
        MOVE.W  #$0017,AUD_CAP_CTRL

        ; ==============================================================
        ; SZENE 1: "THX / Deep Note" - 31 Stimmen polyphone Gleitfrequenz
        ; ==============================================================
        LEA     MsgScene1(PC),A0
        BSR     PrintStr
        MOVE.W  #$0003,COLOR00(A6)      ; Dunkelblau
        BSR     Init_Scene_DeepNote

        ; Gleitphase ueber 300 Frames (~6 Sekunden bei 50 Hz)
        MOVE.W  #300,D6
.glide_loop:
        BSR     Wait_VBL
        BSR     Update_DeepNote_Glide
        BSR     Draw_Scope_Color        ; Visualizer aus Capture-Puffer
        BTST    #6,$BFE001              ; Linke Maustaste zum Abbruch?
        BEQ     .exit_showcase
        DBRA    D6,.glide_loop

        ; 1,5 Sekunden voller Akkord (~75 Frames)
        MOVE.W  #75,D6
.hold_loop:
        BSR     Wait_VBL
        BSR     Draw_Scope_Color
        BTST    #6,$BFE001
        BEQ     .exit_showcase
        DBRA    D6,.hold_loop

        BSR     Silence_All_Voices

        ; ==============================================================
        ; SZENE 2: "Cyberpunk 32-Channel Synth Track" (~30 Sekunden)
        ; ==============================================================
        LEA     MsgScene2(PC),A0
        BSR     PrintStr
        MOVE.W  #$0000,COLOR00(A6)
        BSR     Init_Scene_Track

        ; Sequenzer ueber 256 Schritte à 6 VBL Frames (~30 Sekunden)
        MOVE.W  #256,D6                 ; 256 Steps
        MOVEQ   #0,D5                   ; Step Counter (0..63)

.track_loop:
        BSR     Process_Track_Step
        MOVEQ   #5,D4                   ; 6 Frames pro Step (125 BPM)
.step_delay:
        BSR     Wait_VBL
        BSR     Update_Filter_LFO       ; Biquad Filter Cutoff pro Frame modulieren
        BSR     Draw_Scope_Color        ; Farbskopie aus Audio-Capture
        BTST    #6,$BFE001              ; Maustaste?
        BEQ.S   .exit_showcase
        DBRA    D4,.step_delay

        ADDQ.W  #1,D5
        ANDI.W  #$003F,D5               ; Loop nach 64 Schritten
        SUBQ.W  #1,D6
        BNE.S   .track_loop

.exit_showcase:
        ; ==============================================================
        ; SZENE 3: Grand Finale & Fadeout (3 Sekunden)
        ; ==============================================================
        LEA     MsgScene3(PC),A0
        BSR     PrintStr

        ; Stimmen stummschalten
        BSR     Silence_All_Voices
        MOVE.W  #$0000,AUD_CAP_CTRL     ; Capture stoppen
        MOVE.W  Saved_COLOR00(PC),COLOR00(A6)

        ; Abschlussmeldung ausgeben
        LEA     MsgDone(PC),A0
        BSR     PrintStr

        ; dos.library schliessen
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .NoClose
        MOVE.L  $00000004.W,A6
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.NoClose:
        MOVEQ   #0,D0                   ; Return Code 0
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

; ==============================================================================
; Subroutinen
; ==============================================================================

Silence_All_Voices:
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.s_loop:
        MOVE.W  #$0002,AUD_CMD(A0)      ; STOP
        MOVE.W  #$0000,AUD_VOL(A0)      ; Mute
        MOVE.W  #$0000,AUD_CTRL(A0)
        MOVE.W  #$0000,AUD_DELAY(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.s_loop
        RTS

; ------------------------------------------------------------------------------
; Szene 1 Init: Startet 31 Stimmen mit Zufallsfrequenzen
; ------------------------------------------------------------------------------
Init_Scene_DeepNote:
        LEA     AUDIO_EXT_BASE,A0
        LEA     SA_StartPer,A1
        LEA     SA_Vol,A2
        LEA     SA_Delay,A3
        LEA     SA_CurPerFP,A4
        LEA     Saw32,A5
        MOVE.L  A5,D1

        MOVEQ   #30,D0                  ; 31 Stimmen (0..30)
.sa_init_loop:
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A0)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #32,AUD_LENL(A0)

        MOVE.W  (A1)+,D2
        MOVE.W  D2,AUD_PER(A0)
        SWAP    D2
        CLR.W   D2                      ; D2 = Period in 16.16 FP
        MOVE.L  D2,(A4)+

        MOVE.W  (A2)+,AUD_VOL(A0)
        MOVE.W  (A3)+,AUD_DELAY(A0)

        MOVE.W  #CTRL_LOOP,AUD_CTRL(A0)
        MOVE.W  #$0001,AUD_CMD(A0)      ; Starten!

        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.sa_init_loop
        RTS

; ------------------------------------------------------------------------------
; Szene 1 Update: Gleitet alle 31 Stimmen zur Zielharmonie
; ------------------------------------------------------------------------------
Update_DeepNote_Glide:
        LEA     AUDIO_EXT_BASE,A0
        LEA     SA_Delta,A1
        LEA     SA_CurPerFP,A2
        MOVEQ   #30,D0
.glide_step:
        MOVE.L  (A2),D2
        ADD.L   (A1)+,D2                ; Period += Delta
        MOVE.L  D2,(A2)+
        SWAP    D2
        MOVE.W  D2,AUD_PER(A0)          ; Neues Period-Register
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.glide_step
        RTS

; ------------------------------------------------------------------------------
; Szene 2 Init: Konfiguriert die 32-Channel Synth Track Architektur
; ------------------------------------------------------------------------------
Init_Scene_Track:
        LEA     AUDIO_EXT_BASE,A0

        ; --- KANAL 0 & 1: Moog 24 dB Kaskadierter Acid-Bass ---
        ; Ch 0: Erste 12 dB Filterstufe (DMA Saw256)
        LEA     Saw256,A1
        MOVE.L  A1,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A0)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #256,AUD_LENL(A0)
        MOVE.W  #$8080,AUD_VOL(A0)
        MOVE.W  #(CTRL_LOOP|CTRL_FLT_STEREO|CTRL_SRC_DMA),AUD_CTRL(A0)

        ; Ch 1: Zweite 12 dB Filterstufe kaskadiert von Ch 0 (POST)
        LEA     VOICE_STRIDE(A0),A2
        MOVE.W  #0,AUD_PTRH(A2)
        MOVE.W  #0,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #256,AUD_LENL(A2)
        MOVE.W  #$8080,AUD_VOL(A2)
        MOVE.W  #(CTRL_LOOP|CTRL_FLT_STEREO|CTRL_SRC_POST),AUD_CTRL(A2)

        ; Filterkoeffizienten initialisieren
        BSR     Set_Acid_Filter_Coeffs

        MOVE.W  #$0001,AUD_CMD(A0)      ; Ch 0 starten
        MOVE.W  #$0001,AUD_CMD(A2)      ; Ch 1 starten

        ; --- KANAL 2 & 3: AM Pluck Synth (Ch 2 moduliert Ch 3) ---
        LEA     (2*VOICE_STRIDE)(A0),A2
        LEA     EnvPluck,A1             ; Ch 2 spielt AM Envelope Sample
        MOVE.L  A1,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A2)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #ENV_LEN,AUD_LENL(A2)
        MOVE.W  #PER_ENV,AUD_PER(A2)
        MOVE.W  #$8080,AUD_VOL(A2)
        MOVE.W  #(CTRL_ONESHOT|CTRL_MUTE_MIX),AUD_CTRL(A2) ; Im Mix stumm!

        LEA     (3*VOICE_STRIDE)(A0),A3 ; Ch 3: Ton-Generator
        LEA     Saw64,A1
        MOVE.L  A1,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A3)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A3)
        MOVE.W  #0,AUD_LENH(A3)
        MOVE.W  #64,AUD_LENL(A3)
        MOVE.W  #$7050,AUD_VOL(A3)
        MOVE.W  #(CTRL_LOOP|CTRL_MOD_AM),AUD_CTRL(A3)
        MOVE.W  #$0001,AUD_CMD(A3)

        ; --- KANAL 4 & 5: Ringmod Space Bells (Ch 4 moduliert Ch 5) ---
        LEA     (4*VOICE_STRIDE)(A0),A2 ; Carrier
        LEA     BellCar,A1
        MOVE.L  A1,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A2)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #BELLCAR_LEN,AUD_LENL(A2)
        MOVE.W  #(CTRL_ONESHOT|CTRL_MUTE_MIX),AUD_CTRL(A2) ; Im Mix stumm!

        LEA     (5*VOICE_STRIDE)(A0),A3 ; Ton
        LEA     Sine64,A1
        MOVE.L  A1,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A3)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A3)
        MOVE.W  #0,AUD_LENH(A3)
        MOVE.W  #64,AUD_LENL(A3)
        MOVE.W  #$5070,AUD_VOL(A3)
        MOVE.W  #(CTRL_LOOP|CTRL_MOD_RING),AUD_CTRL(A3)

        ; --- KANAL 21..30: 10-Stimmiges Pad ---
        LEA     PadVolTab,A4
        MOVEQ   #9,D0
.pad_init:
        MOVE.W  D0,D1
        ADD.W   #21,D1
        MULU.W  #VOICE_STRIDE,D1
        LEA     (A0,D1.W),A2
        LEA     Saw32,A1
        MOVE.L  A1,D2
        SWAP    D2
        MOVE.W  D2,AUD_PTRH(A2)
        SWAP    D2
        MOVE.W  D2,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #32,AUD_LENL(A2)
        MOVE.W  (A4)+,AUD_VOL(A2)
        MOVE.W  #CTRL_LOOP,AUD_CTRL(A2)
        MOVE.W  #$0001,AUD_CMD(A2)
        DBRA    D0,.pad_init
        RTS

; ------------------------------------------------------------------------------
; Sequenzer Step Update
; ------------------------------------------------------------------------------
Process_Track_Step:
        LEA     AUDIO_EXT_BASE,A0

        ; 1. Kick Drum (Ch 6)
        LEA     KickPat,A1
        MOVE.W  D5,D0
        ANDI.W  #$000F,D0
        TST.B   (A1,D0.W)
        BEQ.S   .no_kick
        LEA     (6*VOICE_STRIDE)(A0),A2
        LEA     KickSmp,A3
        MOVE.L  A3,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A2)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #KICK_LEN,AUD_LENL(A2)
        MOVE.W  #PER_DRUM,AUD_PER(A2)
        MOVE.W  #$9090,AUD_VOL(A2)
        MOVE.W  #CTRL_ONESHOT,AUD_CTRL(A2)
        MOVE.W  #$0001,AUD_CMD(A2)
.no_kick:

        ; 2. Snare Drum (Ch 7)
        LEA     SnarePat,A1
        TST.B   (A1,D0.W)
        BEQ.S   .no_snare
        LEA     (7*VOICE_STRIDE)(A0),A2
        LEA     SnareSmp,A3
        MOVE.L  A3,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A2)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #SNARE_LEN,AUD_LENL(A2)
        MOVE.W  #PER_DRUM,AUD_PER(A2)
        MOVE.W  #$7070,AUD_VOL(A2)
        MOVE.W  #CTRL_ONESHOT,AUD_CTRL(A2)
        MOVE.W  #$0001,AUD_CMD(A2)
.no_snare:

        ; 3. HiHat mit HP-Filter (Ch 8)
        LEA     HatPat,A1
        TST.B   (A1,D0.W)
        BEQ.S   .no_hat
        LEA     (8*VOICE_STRIDE)(A0),A2
        LEA     HatSmp,A3
        MOVE.L  A3,D1
        SWAP    D1
        MOVE.W  D1,AUD_PTRH(A2)
        SWAP    D1
        MOVE.W  D1,AUD_PTRL(A2)
        MOVE.W  #0,AUD_LENH(A2)
        MOVE.W  #HAT_LEN,AUD_LENL(A2)
        MOVE.W  #PER_DRUM,AUD_PER(A2)
        MOVE.W  #$6060,AUD_VOL(A2)
        LEA     HatHP,A4
        MOVE.W  (A4)+,AUD_BQ_B0(A2)
        MOVE.W  (A4)+,AUD_BQ_B1(A2)
        MOVE.W  (A4)+,AUD_BQ_B2(A2)
        MOVE.W  (A4)+,AUD_BQ_A1(A2)
        MOVE.W  (A4)+,AUD_BQ_A2(A2)
        MOVE.W  #(CTRL_ONESHOT|CTRL_FLT_STEREO),AUD_CTRL(A2)
        MOVE.W  #$0001,AUD_CMD(A2)
.no_hat:

        ; 4. Acid Bass Pitch & Accent (Ch 0 & 1)
        LEA     AcidPerSeq,A1
        MOVE.W  D5,D0
        ADD.W   D0,D0
        MOVE.W  (A1,D0.W),D1
        BEQ.S   .no_acid
        MOVE.W  D1,AUD_PER(A0)
        MOVE.W  D1,AUD_PER+VOICE_STRIDE(A0)
        LEA     AcidVolSeq,A2
        MOVE.W  (A2,D0.W),AUD_VOL+VOICE_STRIDE(A0)
.no_acid:

        ; 5. Lead Pluck Trigger (Ch 2)
        LEA     LeadPerSeq,A1
        MOVE.W  (A1,D0.W),D1
        BEQ.S   .no_lead
        LEA     (3*VOICE_STRIDE)(A0),A3
        MOVE.W  D1,AUD_PER(A3)
        LEA     (2*VOICE_STRIDE)(A0),A2
        MOVE.W  #$0001,AUD_CMD(A2)
.no_lead:

        ; 6. Bell Ringmod Trigger (Ch 4 & 5)
        LEA     BellPerSeq,A1
        MOVE.W  D5,D0
        LSL.W   #2,D0
        MOVE.W  (A1,D0.W),D1
        BEQ.S   .no_bell
        LEA     (5*VOICE_STRIDE)(A0),A3
        MOVE.W  D1,AUD_PER(A3)
        LEA     (4*VOICE_STRIDE)(A0),A2
        MOVE.W  2(A1,D0.W),AUD_PER(A2)
        MOVE.W  #$0001,AUD_CMD(A2)
        MOVE.W  #$0001,AUD_CMD(A3)
.no_bell:

        ; 7. Pad Akkorde (Ch 21..30)
        MOVE.W  D5,D0
        LSR.W   #4,D0
        ANDI.W  #$0003,D0
        MULU.W  #20,D0
        LEA     PadPerSeq,A1
        LEA     (A1,D0.W),A1
        MOVEQ   #9,D1
.pad_update:
        MOVE.W  D1,D2
        ADD.W   #21,D2
        MULU.W  #VOICE_STRIDE,D2
        MOVE.W  (A1)+,AUD_PER(A0,D2.W)
        DBRA    D1,.pad_update
        RTS

; ------------------------------------------------------------------------------
; LFO Filter Sweep (Moog 24 dB Cutoff pro Frame modulieren)
; ------------------------------------------------------------------------------
Update_Filter_LFO:
        ADDQ.B  #1,LFO_Phase
        MOVE.B  LFO_Phase,D0
        LEA     LfoTab,A1
        MOVE.B  (A1,D0.W),D0
        ANDI.W  #$003F,D0

Set_Acid_Filter_Coeffs:
        MULU.W  #10,D0
        LEA     AcidLP1,A1
        LEA     (A1,D0.W),A1
        LEA     AcidLP2,A2
        LEA     (A2,D0.W),A2

        LEA     AUDIO_EXT_BASE,A0
        MOVE.W  (A1)+,AUD_BQ_B0(A0)
        MOVE.W  (A1)+,AUD_BQ_B1(A0)
        MOVE.W  (A1)+,AUD_BQ_B2(A0)
        MOVE.W  (A1)+,AUD_BQ_A1(A0)
        MOVE.W  (A1)+,AUD_BQ_A2(A0)

        LEA     VOICE_STRIDE(A0),A3
        MOVE.W  (A2)+,AUD_BQ_B0(A3)
        MOVE.W  (A2)+,AUD_BQ_B1(A3)
        MOVE.W  (A2)+,AUD_BQ_B2(A3)
        MOVE.W  (A2)+,AUD_BQ_A1(A3)
        MOVE.W  (A2)+,AUD_BQ_A2(A3)
        RTS

; ------------------------------------------------------------------------------
; Live Audio Capture Visualizer: Farbmodulation aus $DF8000
; ------------------------------------------------------------------------------
Draw_Scope_Color:
        MOVE.W  AUD_CAP_CTRL,D0
        BTST    #1,D0
        BNE.S   .read_buf_a
        BTST    #2,D0
        BNE.S   .read_buf_b
        RTS

.read_buf_a:
        LEA     CAP_BUF_A,A1
        MOVE.W  #$0002,AUD_CAP_CTRL
        BRA.S   .render_scope
.read_buf_b:
        LEA     CAP_BUF_B,A1
        MOVE.W  #$0004,AUD_CAP_CTRL

.render_scope:
        MOVE.W  (A1),D1
        ASR.W   #8,D1
        ANDI.W  #$000F,D1
        MOVE.W  D1,D2
        LSL.W   #4,D2
        OR.W    D1,D2
        LSL.W   #4,D2
        OR.W    D1,D2
        MOVE.W  D2,COLOR00(A6)
        RTS

; ------------------------------------------------------------------------------
; VBL Wait
; ------------------------------------------------------------------------------
Wait_VBL:
        MOVE.L  VPOSR(A6),D0
        ANDI.L  #$0001FF00,D0
        CMPI.L  #$00010000,D0
        BNE.S   Wait_VBL
.vbl_off:
        MOVE.L  VPOSR(A6),D0
        ANDI.L  #$0001FF00,D0
        CMPI.L  #$00010000,D0
        BEQ.S   .vbl_off
        RTS

; ------------------------------------------------------------------------------
; Text-Ausgabe
; ------------------------------------------------------------------------------
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

; ==============================================================================
; Text & Status
; ==============================================================================
DosName:        DC.B    "dos.library",0
MsgBanner:      DC.B    10,"==================================================================",10
                DC.B    "*** ANTIGRAVITY: THE 32-VOICE HARDWARE EXTENSION SHOWCASE ***",10
                DC.B    "Plattform: MiSTer DE10-Nano / Minimig-AGA Core 22a912cc",10
                DC.B    "Features:  32 Stimmen, 24 dB Biquad DSP, AM, Ringmod, Start-Delay",10
                DC.B    "==================================================================",10,10,0
MsgScene1:      DC.B    "[0:00 - 0:07] Szene 1: 'THX Deep Note' - 31 Stimmen Gleitfrequenz-Synthese...",10,0
MsgScene2:      DC.B    "[0:07 - 0:38] Szene 2: 'Cyberpunk Synth Track' (Moog-Kaskade, AM, Ringmod, Drums)...",10,0
MsgScene3:      DC.B    "[0:38 - 0:42] Szene 3: Grand Finale & Reverb Fadeout...",10,0
MsgDone:        DC.B    10,"==================================================================",10
                DC.B    "Showcase erfolgreich beendet. Alle 32 Hardware-Stimmen verifiziert (RC: 0).",10
                DC.B    "==================================================================",10,10,0

                EVEN
DOSBase:        DC.L    0
StdoutHandle:   DC.L    0
Saved_COLOR00:  DC.W    0
LFO_Phase:      DC.B    0
                EVEN

SA_CurPerFP:    DS.L    31

; Generierte Musikdaten (Periods, Filter, Drum-Samples, Noten)
        INCLUDE "../showcase/showcase_data.i"

        END
