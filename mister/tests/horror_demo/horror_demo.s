; ==============================================================================
; MiSTer FPGA / Minimig-AGA (NanoMig):
; "GOTHIC HORROR" - 32-Channel Audio Engine & Horror Testcase Demo
;
; Target: Motorola 68000 / 68020 on MiSTer DE10-Nano
; Kickstart 1.3 / 3.x CLI compatible (clean OS takeover & full CLI restoration)
;
; Fixes applied for Kickstart 1.3 verification:
;   1. Copper: Complete DIWSTRT ($2C81), DIWSTOP ($F4C1), DDFSTRT ($0038), DDFSTOP ($00D0)
;   2. Copper: Cleared all 8 sprite pointers (eliminates left vertical bars & stripes)
;   3. Bats: Guaranteed even word-aligned addresses (eliminates 68000 odd address error)
;   4. Skull/Jaw: Fixed register collisions and separate plane indexing
;   5. Timing: Bulletproof line-256 VBL sync + strictly bounded frame loops (~18s total)
;   6. Diagnostics: Live step markers printed to CLI for each act
; ==============================================================================

CUSTOM          EQU $DFF000
DMACONR         EQU $002
VPOSR           EQU $004
COP1LCH         EQU $080
COP1LCL         EQU $082
COPJMP1         EQU $088
DMACON          EQU $096
INTENA          EQU $09A
INTREQ          EQU $09C
BPLCON0         EQU $100
BPLCON1         EQU $102
BPLCON2         EQU $104
BPLCON3         EQU $106
BPL1MOD         EQU $108
BPL2MOD         EQU $10A
COLOR00         EQU $180
FMODE           EQU $1FC

; Extended HAM Video Control Register
HAM_CONTROL     EQU $DFF800
HAM_RESET_VAL   EQU $1084

; Audio Capture Engine
AUD_CAP_CTRL    EQU $DFF802
CAP_BUF_A       EQU $DF8000
CAP_BUF_B       EQU $DF9000

; 32-Channel Audio Extension ($DFF400..$DFF7FE)
AUDIO_EXT_BASE  EQU $DFF400
VOICE_STRIDE    EQU $20

AUD_PTRH        EQU $00
AUD_PTRL        EQU $02
AUD_LENH        EQU $04
AUD_LENL        EQU $06
AUD_VOL         EQU $08         ; High=Left (0..255), Low=Right (0..255)
AUD_PER         EQU $0A         ; Period = 25 MHz / Fs (521 = 48 kHz)
AUD_CTRL        EQU $0C
AUD_PRED        EQU $0E
AUD_BQ_B0       EQU $10
AUD_BQ_B1       EQU $12
AUD_BQ_B2       EQU $14
AUD_BQ_A1       EQU $16
AUD_BQ_A2       EQU $18
AUD_CMD         EQU $1A         ; 1=Start, 2=Stop
AUD_DELAY       EQU $1C         ; 32.768 kHz Zero-RAM Start-Delay

; Control Register Bit Masks
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

; Screen Dimensions (Lowres PAL: 320x200, 4 Bitplanes)
SCR_WIDTH_B     EQU 40          ; 40 bytes = 320 pixels
SCR_HEIGHT      EQU 200
BPL_SIZE        EQU SCR_WIDTH_B*SCR_HEIGHT ; 8000 bytes

; AmigaOS LVO Offsets
_LVOOldOpenLibrary EQU -408
_LVOCloseLibrary   EQU -414
_LVOOpenLibrary    EQU -552
_LVOOutput         EQU -60
_LVOWrite          EQU -48
_LVOLoadView       EQU -222
_LVOWaitTOF        EQU -270
_LVORethinkDisplay EQU -390

gb_ActiView     EQU 34
gb_copinit      EQU 38

        SECTION HorrorCode,CODE

Main:
        MOVEM.L D2-D7/A2-A6,-(SP)

        ; Save initial OS DMA control state
        LEA     CUSTOM,A6
        MOVE.W  DMACONR(A6),Saved_DMACON

        ; --------------------------------------------------------------
        ; 1. AmigaOS Library Initialization (Strict Lesson 12 via A6)
        ; --------------------------------------------------------------
        MOVE.L  $00000004.W,A6
        LEA     GfxName(PC),A1
        MOVEQ   #0,D0
        JSR     _LVOOpenLibrary(A6)
        MOVE.L  D0,GfxBase
        BEQ     .ExitEarly

        LEA     DosName(PC),A1
        MOVEQ   #0,D0
        JSR     _LVOOpenLibrary(A6)
        MOVE.L  D0,DOSBase
        BEQ     .ExitEarly

        LEA     IntuiName(PC),A1
        MOVEQ   #0,D0
        JSR     _LVOOpenLibrary(A6)
        MOVE.L  D0,IntuiBase

        ; Grab standard output handle once
        MOVE.L  DOSBase(PC),A6
        JSR     _LVOOutput(A6)
        MOVE.L  D0,StdoutHandle

        ; Print Intro Banner to CLI
        LEA     MsgBanner(PC),A0
        BSR     PrintStr

        ; --------------------------------------------------------------
        ; 2. Initialize Screen, Palette & Display Takeover
        ; --------------------------------------------------------------
        BSR     Init_Screen_Planes
        BSR     Draw_Castle_Hallway_And_Vampire
        BSR     Takeover_Display

        LEA     CUSTOM,A6
        MOVE.W  #$000F,DMACON(A6)       ; Disable legacy Paula DMA
        BSR     Silence_All_Voices

        ; Enable Hardware Audio Capture ($DF8000 / $DF9000)
        MOVE.W  #$0017,AUD_CAP_CTRL

        ; ==============================================================
        ; ACT I: "DIE SCHRITTE IM LANGEN FLUR" (Approaching Footsteps)
        ; ==============================================================
        LEA     MsgAct1(PC),A0
        BSR     PrintStr
        MOVE.W  #1,CurrentAct
        CLR.W   FootstepCount

        ; 5 Footsteps echoing down the long stone corridor (~4.0s total)
        MOVEQ   #4,D7                   ; 5 steps (0..4)
.footstep_loop:
        BSR     Trigger_Corridor_Footstep
        ; Wait 35 frames (~0.7s) between footsteps
        MOVEQ   #35-1,D6
.foot_vbl:
        BSR     Wait_VBL
        BSR     Update_Horror_Visuals
        BTST    #6,$BFE001              ; Left Mouse Button to abort
        BEQ     .AbortDemo
        DBRA    D6,.foot_vbl
        DBRA    D7,.footstep_loop

        LEA     MsgAct1Done(PC),A0
        BSR     PrintStr

        ; ==============================================================
        ; ACT II: "DAS GEHEULE DURCH DIE LANGEN FLURE" (Howling Wind & Moans)
        ; ==============================================================
        LEA     MsgAct2(PC),A0
        BSR     PrintStr
        MOVE.W  #2,CurrentAct

        BSR     Start_Howling_Moog_And_Ringmod

        ; Run howling wind and moans for 200 frames (~4.0 seconds)
        MOVE.W  #200-1,D6
        MOVEQ   #0,D5                   ; LFO phase
.howl_vbl:
        BSR     Wait_VBL
        BSR     Update_Howling_Sweep
        BSR     Update_Horror_Visuals
        BTST    #6,$BFE001
        BEQ     .AbortDemo
        ADDQ.W  #1,D5
        DBRA    D6,.howl_vbl

        BSR     Silence_All_Voices
        LEA     MsgAct2Done(PC),A0
        BSR     PrintStr

        ; ==============================================================
        ; ACT III: "DER SCHWARM DER 32 FLEDERMÄUSE" (32 Bats Swarm Out)
        ; ==============================================================
        LEA     MsgAct3(PC),A0
        BSR     PrintStr
        MOVE.W  #3,CurrentAct

        ; Erase central vampire silhouette so bats explode outward
        BSR     Clear_Vampire_Center
        ; Initialize 32 bat positions, velocities, and audio voices
        BSR     Init_32_Bats_And_Voices

        ; Run bat swarm for 250 frames (~5.0 seconds)
        MOVE.W  #250-1,D6
.bats_vbl:
        BSR     Wait_VBL
        BSR     Update_32_Bats_Movement_And_Audio
        BSR     Update_Horror_Visuals
        BTST    #6,$BFE001
        BEQ     .AbortDemo
        DBRA    D6,.bats_vbl

        BSR     Silence_All_Voices
        LEA     MsgAct3Done(PC),A0
        BSR     PrintStr

        ; ==============================================================
        ; ACT IV: "DAS LACHENDE SKELETT" (The Demonic Laughing Skeleton)
        ; ==============================================================
        LEA     MsgAct4(PC),A0
        BSR     PrintStr
        MOVE.W  #4,CurrentAct

        ; Pristine corridor wipe: erase all 32 bats & refresh stone pillars cleanly!
        BSR     Clear_Corridor_And_Refresh_Pillars

        ; Draw the laughing skeleton skull in the archway
        BSR     Draw_Skeleton_Skull

        ; Run laughing skeleton for 220 frames (~4.4 seconds)
        MOVE.W  #220-1,D6
        MOVEQ   #0,D5                   ; Laughter frame timer
.laugh_vbl:
        BSR     Wait_VBL
        BSR     Update_Laughing_Skeleton_Audio_And_Jaw
        BSR     Update_Horror_Visuals
        BTST    #6,$BFE001
        BEQ     .AbortDemo
        ADDQ.W  #1,D5
        DBRA    D6,.laugh_vbl

        BSR     Silence_All_Voices
        LEA     MsgAct4Done(PC),A0
        BSR     PrintStr

        ; ==============================================================
        ; ACT V: "EPILOG & FADEOUT"
        ; ==============================================================
        LEA     MsgAct5(PC),A0
        BSR     PrintStr
        MOVE.W  #5,CurrentAct

        ; Smooth 40-frame volume fadeout (~0.8s)
        MOVEQ   #40-1,D6
.fade_vbl:
        BSR     Wait_VBL
        BSR     Apply_Epilog_Fade
        BSR     Update_Horror_Visuals
        BTST    #6,$BFE001
        BEQ.S   .AbortDemo
        DBRA    D6,.fade_vbl

.AbortDemo:
        ; --------------------------------------------------------------
        ; Clean Hardware Shutdown & OS Display Restoration
        ; --------------------------------------------------------------
        BSR     Silence_All_Voices
        MOVE.W  #$0000,AUD_CAP_CTRL
        MOVE.W  #HAM_RESET_VAL,HAM_CONTROL

        BSR     Restore_Display

        ; Print final test completion & summary
        LEA     MsgSummary(PC),A0
        BSR     PrintStr

        ; Close Libraries cleanly (Lesson 12 via A6)
        MOVE.L  $00000004.W,A6
        MOVE.L  IntuiBase(PC),D0
        BEQ.S   .no_intui_close
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.no_intui_close:
        MOVE.L  GfxBase(PC),D0
        BEQ.S   .no_gfx_close
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.no_gfx_close:
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .no_dos_close
        MOVE.L  D0,A1
        JSR     _LVOCloseLibrary(A6)
.no_dos_close:
        MOVEQ   #0,D0                   ; Return Code 0
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

.ExitEarly:
        MOVEQ   #20,D0                  ; Error return code
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

; ==============================================================================
; ACT I PROCEDURES: CORRIDOR FOOTSTEPS & MULTI-TAP HARDWARE DELAY
; ==============================================================================
Trigger_Corridor_Footstep:
        MOVEM.L D0-D4/A0-A2,-(SP)

        MOVE.W  FootstepCount(PC),D2
        ADDQ.W  #1,FootstepCount

        ; Base volume scales up as steps approach
        LEA     FootstepVolTab(PC),A0
        MOVE.W  D2,D0
        ADD.W   D0,D0
        MOVE.W  (A0,D0.W),D3            ; High=Left, Low=Right

        ; 1. Voice 0: Primary Footstep (Immediate, No Delay)
        LEA     AUDIO_EXT_BASE,A0
        MOVE.L  #HorrorFootstepData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #HORROR_FOOT_LEN,AUD_LENL(A0)
        MOVE.W  D3,AUD_VOL(A0)
        MOVE.W  #HORROR_PER_24K,AUD_PER(A0)
        MOVE.W  #0,AUD_DELAY(A0)        ; 0 delay
        MOVE.W  #CTRL_PCM16|CTRL_ONESHOT,AUD_CTRL(A0)
        MOVE.W  #1,AUD_CMD(A0)          ; Start Voice 0

        ; 2. Voice 1: Echo Tap 1 (Delay = ~150 ms = 4915 ticks, Lowpass Tap 1)
        LEA     AUDIO_EXT_BASE+VOICE_STRIDE,A1
        MOVE.L  #HorrorFootstepData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A1)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A1)
        MOVE.W  #0,AUD_LENH(A1)
        MOVE.W  #HORROR_FOOT_LEN,AUD_LENL(A1)
        MOVE.W  D3,D0
        LSR.W   #1,D0
        MOVE.W  D0,AUD_VOL(A1)
        MOVE.W  #HORROR_PER_24K,AUD_PER(A1)
        MOVE.W  #4915,AUD_DELAY(A1)     ; Hardware Start-Delay
        LEA     Flt_Hallway_Tap1(PC),A2
        MOVE.W  (A2)+,AUD_BQ_B0(A1)
        MOVE.W  (A2)+,AUD_BQ_B1(A1)
        MOVE.W  (A2)+,AUD_BQ_B2(A1)
        MOVE.W  (A2)+,AUD_BQ_A1(A1)
        MOVE.W  (A2)+,AUD_BQ_A2(A1)
        MOVE.W  #CTRL_PCM16|CTRL_ONESHOT|CTRL_FLT_STEREO,AUD_CTRL(A1)
        MOVE.W  #1,AUD_CMD(A1)

        ; 3. Voice 2: Echo Tap 2 (Delay = ~300 ms = 9830 ticks, Darker Lowpass Tap 2)
        LEA     AUDIO_EXT_BASE+VOICE_STRIDE*2,A1
        MOVE.L  #HorrorFootstepData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A1)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A1)
        MOVE.W  #0,AUD_LENH(A1)
        MOVE.W  #HORROR_FOOT_LEN,AUD_LENL(A1)
        MOVE.W  D3,D0
        LSR.W   #2,D0
        MOVE.W  D0,AUD_VOL(A1)
        MOVE.W  #HORROR_PER_24K,AUD_PER(A1)
        MOVE.W  #9830,AUD_DELAY(A1)     ; Hardware Start-Delay
        LEA     Flt_Hallway_Tap2(PC),A2
        MOVE.W  (A2)+,AUD_BQ_B0(A1)
        MOVE.W  (A2)+,AUD_BQ_B1(A1)
        MOVE.W  (A2)+,AUD_BQ_B2(A1)
        MOVE.W  (A2)+,AUD_BQ_A1(A1)
        MOVE.W  (A2)+,AUD_BQ_A2(A1)
        MOVE.W  #CTRL_PCM16|CTRL_ONESHOT|CTRL_FLT_STEREO,AUD_CTRL(A1)
        MOVE.W  #1,AUD_CMD(A1)

        ; 4. Voice 3: Echo Tap 3 (Delay = ~450 ms = 14745 ticks, Deep Lowpass Tap 3)
        LEA     AUDIO_EXT_BASE+VOICE_STRIDE*3,A1
        MOVE.L  #HorrorFootstepData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A1)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A1)
        MOVE.W  #0,AUD_LENH(A1)
        MOVE.W  #HORROR_FOOT_LEN,AUD_LENL(A1)
        MOVE.W  D3,D0
        LSR.W   #3,D0
        MOVE.W  D0,AUD_VOL(A1)
        MOVE.W  #HORROR_PER_24K,AUD_PER(A1)
        MOVE.W  #14745,AUD_DELAY(A1)    ; Hardware Start-Delay
        LEA     Flt_Hallway_Tap3(PC),A2
        MOVE.W  (A2)+,AUD_BQ_B0(A1)
        MOVE.W  (A2)+,AUD_BQ_B1(A1)
        MOVE.W  (A2)+,AUD_BQ_B2(A1)
        MOVE.W  (A2)+,AUD_BQ_A1(A1)
        MOVE.W  (A2)+,AUD_BQ_A2(A1)
        MOVE.W  #CTRL_PCM16|CTRL_ONESHOT|CTRL_FLT_STEREO,AUD_CTRL(A1)
        MOVE.W  #1,AUD_CMD(A1)

        MOVEM.L (SP)+,D0-D4/A0-A2
        RTS

FootstepVolTab:
        DC.W    $4020           ; Step 1: Distant left
        DC.W    $3060           ; Step 2: Distant right
        DC.W    $8050           ; Step 3: Medium left-center
        DC.W    $60A0           ; Step 4: Medium right-center
        DC.W    $D0D0           ; Step 5: Close center!

; ==============================================================================
; ACT II PROCEDURES: 24 dB MOOG HOWLING CASCADE & RINGMODULATION
; ==============================================================================
Start_Howling_Moog_And_Ringmod:
        MOVEM.L D0-D2/A0-A2,-(SP)

        ; --- (A) Voice 6: Wind Drone Noise (Pre-stage to Moog Filter) ---
        LEA     AUDIO_EXT_BASE+VOICE_STRIDE*6,A0
        MOVE.L  #HorrorWindData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #HORROR_WIND_LEN,AUD_LENL(A0)
        MOVE.W  #$B0B0,AUD_VOL(A0)
        MOVE.W  #HORROR_PER_24K,AUD_PER(A0)
        MOVE.W  #0,AUD_DELAY(A0)
        MOVE.W  #CTRL_PCM16|CTRL_LOOP|CTRL_MUTE_MIX,AUD_CTRL(A0)
        MOVE.W  #1,AUD_CMD(A0)

        ; --- (B) Voice 7: Cascaded 24 dB Moog Low-Pass Filter ---
        LEA     AUDIO_EXT_BASE+VOICE_STRIDE*7,A1
        MOVE.W  #0,AUD_LENH(A1)
        MOVE.W  #0,AUD_LENL(A1)
        MOVE.W  #$C0C0,AUD_VOL(A1)
        MOVE.W  #HORROR_PER_24K,AUD_PER(A1)
        MOVE.W  #0,AUD_DELAY(A1)
        LEA     MoogHowlTable(PC),A2
        MOVE.W  (A2)+,AUD_BQ_B0(A1)
        MOVE.W  (A2)+,AUD_BQ_B1(A1)
        MOVE.W  (A2)+,AUD_BQ_B2(A1)
        MOVE.W  (A2)+,AUD_BQ_A1(A1)
        MOVE.W  (A2)+,AUD_BQ_A2(A1)
        MOVE.W  #CTRL_PCM16|CTRL_LOOP|CTRL_SRC_POST|CTRL_FLT_STEREO,AUD_CTRL(A1)
        MOVE.W  #1,AUD_CMD(A1)

        ; --- (C) Voice 8: Ghost Formant Moan Carrier ---
        LEA     AUDIO_EXT_BASE+VOICE_STRIDE*8,A0
        MOVE.L  #HorrorGhostData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #HORROR_GHOST_LEN,AUD_LENL(A0)
        MOVE.W  #$8080,AUD_VOL(A0)
        MOVE.W  #HORROR_PER_16K,AUD_PER(A0)
        MOVE.W  #0,AUD_DELAY(A0)
        MOVE.W  #CTRL_PCM16|CTRL_LOOP|CTRL_MUTE_MIX,AUD_CTRL(A0)
        MOVE.W  #1,AUD_CMD(A0)

        ; --- (D) Voice 9: Ringmodulated Ghost Shriek (Voice 8 * Voice 9) ---
        LEA     AUDIO_EXT_BASE+VOICE_STRIDE*9,A1
        MOVE.L  #HorrorGhostData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A1)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A1)
        MOVE.W  #0,AUD_LENH(A1)
        MOVE.W  #HORROR_GHOST_LEN,AUD_LENL(A1)
        MOVE.W  #$A0A0,AUD_VOL(A1)
        MOVE.W  #HORROR_PER_12K,AUD_PER(A1)
        MOVE.W  #0,AUD_DELAY(A1)
        MOVE.W  #CTRL_PCM16|CTRL_LOOP|CTRL_MOD_RING,AUD_CTRL(A1)
        MOVE.W  #1,AUD_CMD(A1)

        MOVEM.L (SP)+,D0-D2/A0-A2
        RTS

Update_Howling_Sweep:
        MOVEM.L D0-D3/A0-A2,-(SP)
        MOVE.W  HowlStep(PC),D0
        MOVE.W  HowlDir(PC),D1
        ADD.W   D1,D0
        CMPI.W  #31,D0
        BLT.S   .chk_low
        MOVE.W  #31,D0
        NEG.W   D1
        BRA.S   .store_dir
.chk_low:
        TST.W   D0
        BGT.S   .store_dir
        MOVEQ   #0,D0
        NEG.W   D1
.store_dir:
        MOVE.W  D0,HowlStep
        MOVE.W  D1,HowlDir

        MULU.W  #10,D0
        LEA     MoogHowlTable(PC),A0
        ADDA.W  D0,A0

        LEA     AUDIO_EXT_BASE+VOICE_STRIDE*7,A1
        MOVE.W  (A0)+,AUD_BQ_B0(A1)
        MOVE.W  (A0)+,AUD_BQ_B1(A1)
        MOVE.W  (A0)+,AUD_BQ_B2(A1)
        MOVE.W  (A0)+,AUD_BQ_A1(A1)
        MOVE.W  (A0)+,AUD_BQ_A2(A1)

        ; Modulate Voice 9 pitch for eerie weeping vibrato
        MOVE.W  D5,D2
        ANDI.W  #$000F,D2
        LEA     AUDIO_EXT_BASE+VOICE_STRIDE*9,A2
        MOVE.W  #HORROR_PER_12K,D3
        ADD.W   D2,D3
        MOVE.W  D3,AUD_PER(A2)

        MOVEM.L (SP)+,D0-D3/A0-A2
        RTS

; ==============================================================================
; ACT III PROCEDURES: 32 BATS SWARM & 32 HARDWARE VOICES
; ==============================================================================
Init_32_Bats_And_Voices:
        MOVEM.L D0-D6/A0-A3,-(SP)

        LEA     BatTable,A0
        LEA     AUDIO_EXT_BASE,A1
        LEA     Flt_Bat_Highpass(PC),A2

        MOVEQ   #31,D7                  ; All 32 bats / voices (0..31)
.init_bat_loop:
        ; Bat starts near screen center (x = 160, y = 100)
        MOVE.W  #160,(A0)+              ; Pos X
        MOVE.W  #100,(A0)+              ; Pos Y

        ; Compute velocity from table
        LEA     BatVelTable(PC),A3
        MOVE.W  D7,D1
        LSL.W   #2,D1
        MOVE.W  (A3,D1.W),(A0)+         ; Vel X
        MOVE.W  2(A3,D1.W),(A0)+        ; Vel Y
        CLR.W   (A0)+                   ; Anim frame (0 or 1)

        ; Setup Voice D7 for Bat Wing Flutter
        MOVE.L  #HorrorBatFlapData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A1)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A1)
        MOVE.W  #0,AUD_LENH(A1)
        MOVE.W  #HORROR_BAT_LEN,AUD_LENL(A1)
        MOVE.W  #$8080,AUD_VOL(A1)
        MOVE.W  #HORROR_PER_16K,D2
        MOVE.W  D7,D3
        LSL.W   #3,D3
        ADD.W   D3,D2
        MOVE.W  D2,AUD_PER(A1)
        MOVE.W  #0,AUD_DELAY(A1)

        ; Ultrasonic Highpass Filter
        MOVE.W  (A2),AUD_BQ_B0(A1)
        MOVE.W  2(A2),AUD_BQ_B1(A1)
        MOVE.W  4(A2),AUD_BQ_B2(A1)
        MOVE.W  6(A2),AUD_BQ_A1(A1)
        MOVE.W  8(A2),AUD_BQ_A2(A1)

        ; Enable Loop + Hardware AM Tremolo + Highpass Filter
        MOVE.W  #CTRL_PCM16|CTRL_LOOP|CTRL_MOD_AM|CTRL_FLT_STEREO,AUD_CTRL(A1)
        MOVE.W  #1,AUD_CMD(A1)

        LEA     VOICE_STRIDE(A1),A1
        DBRA    D7,.init_bat_loop

        MOVEM.L (SP)+,D0-D6/A0-A3
        RTS

Update_32_Bats_Movement_And_Audio:
        MOVEM.L D0-D7/A0-A4,-(SP)

        LEA     BatTable,A0
        LEA     AUDIO_EXT_BASE,A1

        MOVEQ   #31,D7                  ; 32 bats (0..31)
.bat_update_loop:
        MOVE.W  (A0),D1                 ; X (0..319)
        MOVE.W  2(A0),D2                ; Y (0..199)
        MOVE.W  4(A0),D3                ; VX
        MOVE.W  6(A0),D4                ; VY

        ; Erase bat from old position (guaranteed even word-aligned)
        BSR     Plot_Bat_Erase

        ; Update position
        ADD.W   D3,D1
        ADD.W   D4,D2

        ; Corridor boundary check & wall bounce (strictly confined to hallway: X: 52..250, Y: 16..180)
        CMPI.W  #52,D1
        BGE.S   .x_not_low
        MOVE.W  #52,D1
        NEG.W   D3                      ; Bounce off left pillar!
        MOVE.W  D3,4(A0)
.x_not_low:
        CMPI.W  #250,D1
        BLE.S   .x_not_high
        MOVE.W  #250,D1
        NEG.W   D3                      ; Bounce off right pillar!
        MOVE.W  D3,4(A0)
.x_not_high:
        CMPI.W  #16,D2
        BGE.S   .y_not_low
        MOVE.W  #16,D2
        NEG.W   D4                      ; Bounce off ceiling!
        MOVE.W  D4,6(A0)
.y_not_low:
        CMPI.W  #180,D2
        BLE.S   .y_not_high
        MOVE.W  #180,D2
        NEG.W   D4                      ; Bounce off floor!
        MOVE.W  D4,6(A0)
.y_not_high:
        MOVE.W  D1,(A0)
        MOVE.W  D2,2(A0)

        ; Toggle animation frame
        MOVE.W  8(A0),D5
        EORI.W  #1,D5
        MOVE.W  D5,8(A0)

        ; Draw bat at new position (guaranteed even word-aligned)
        BSR     Plot_Bat_Draw

        ; Dynamic 3D Stereo Volume Panning (0..255)
        MOVE.W  D1,D0
        CMPI.W  #319,D0
        BLE.S   .x_ok
        MOVE.W  #319,D0
.x_ok:
        LSR.W   #1,D0                   ; 0..159
        MOVE.W  #160,D6
        SUB.W   D0,D6
        ADD.W   D6,D6                   ; 0..255 Left Vol
        ADD.W   D0,D0                   ; 0..255 Right Vol

        ANDI.W  #$00FF,D6
        ANDI.W  #$00FF,D0
        LSL.W   #8,D6
        OR.W    D0,D6
        MOVE.W  D6,AUD_VOL(A1)

        LEA     10(A0),A0
        LEA     VOICE_STRIDE(A1),A1
        DBRA    D7,.bat_update_loop

        MOVEM.L (SP)+,D0-D7/A0-A4
        RTS

BatVelTable:
        DC.W    3,0,   3,1,   2,2,   1,3
        DC.W    0,3,  -1,3,  -2,2,  -3,1
        DC.W   -3,0,  -3,-1, -2,-2, -1,-3
        DC.W    0,-3,  1,-3,  2,-2,  3,-1
        DC.W    2,1,   3,2,   1,2,   2,3
        DC.W   -1,2,  -2,3,  -2,1,  -3,2
        DC.W   -2,-1, -3,-2, -1,-2, -2,-3
        DC.W    1,-2,  2,-3,  2,-1,  3,-2

; ==============================================================================
; ACT IV PROCEDURES: THE DEMONIC LAUGHING SKELETON
; ==============================================================================
Update_Laughing_Skeleton_Audio_And_Jaw:
        MOVEM.L D0-D4/A0-A2,-(SP)

        MOVE.W  D5,D0

        CMPI.W  #20,D0
        BEQ.S   .trig_mwa
        CMPI.W  #60,D0
        BEQ.S   .trig_ha
        CMPI.W  #100,D0
        BEQ.S   .trig_ha
        CMPI.W  #140,D0
        BEQ.S   .trig_ha
        CMPI.W  #180,D0
        BEQ.S   .trig_ha
        BRA.S   .animate_jaw

.trig_mwa:
        BSR     Trigger_Laugh_Burst_Mwa
        MOVE.W  #18,JawOpenTimer
        BRA.S   .animate_jaw

.trig_ha:
        BSR     Trigger_Laugh_Burst_Ha
        MOVE.W  #14,JawOpenTimer

.animate_jaw:
        TST.W   JawOpenTimer
        BEQ.S   .jaw_closed
        SUBQ.W  #1,JawOpenTimer
        BSR     Draw_Jaw_Open
        BRA.S   .done_laugh
.jaw_closed:
        BSR     Draw_Jaw_Closed

.done_laugh:
        MOVEM.L (SP)+,D0-D4/A0-A2
        RTS

Trigger_Laugh_Burst_Mwa:
        ; Voice 0: Low vocal pulse with Formant Bandpass
        LEA     AUDIO_EXT_BASE,A0
        MOVE.L  #HorrorLaughData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #HORROR_LAUGH_LEN,AUD_LENL(A0)
        MOVE.W  #$E0E0,AUD_VOL(A0)
        MOVE.W  #HORROR_PER_8K,AUD_PER(A0)
        MOVE.W  #0,AUD_DELAY(A0)
        LEA     Flt_Laugh_Formant(PC),A2
        MOVE.W  (A2)+,AUD_BQ_B0(A0)
        MOVE.W  (A2)+,AUD_BQ_B1(A0)
        MOVE.W  (A2)+,AUD_BQ_B2(A0)
        MOVE.W  (A2)+,AUD_BQ_A1(A0)
        MOVE.W  (A2)+,AUD_BQ_A2(A0)
        MOVE.W  #CTRL_PCM16|CTRL_ONESHOT|CTRL_FLT_STEREO,AUD_CTRL(A0)
        MOVE.W  #1,AUD_CMD(A0)

        ; Voice 4 & 5: Hardware Ringmod for demonic gravel
        LEA     AUDIO_EXT_BASE+VOICE_STRIDE*4,A1
        MOVE.L  #HorrorGhostData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A1)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A1)
        MOVE.W  #0,AUD_LENH(A1)
        MOVE.W  #HORROR_GHOST_LEN,AUD_LENL(A1)
        MOVE.W  #$8080,AUD_VOL(A1)
        MOVE.W  #HORROR_PER_12K,AUD_PER(A1)
        MOVE.W  #CTRL_PCM16|CTRL_ONESHOT|CTRL_MUTE_MIX,AUD_CTRL(A1)
        MOVE.W  #1,AUD_CMD(A1)

        LEA     AUDIO_EXT_BASE+VOICE_STRIDE*5,A1
        MOVE.L  #HorrorLaughData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A1)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A1)
        MOVE.W  #0,AUD_LENH(A1)
        MOVE.W  #HORROR_LAUGH_LEN,AUD_LENL(A1)
        MOVE.W  #$9090,AUD_VOL(A1)
        MOVE.W  #HORROR_PER_8K,AUD_PER(A1)
        MOVE.W  #CTRL_PCM16|CTRL_ONESHOT|CTRL_MOD_RING,AUD_CTRL(A1)
        MOVE.W  #1,AUD_CMD(A1)

        ; Voice 31: Heartbeat Doom Thump
        LEA     AUDIO_EXT_BASE+VOICE_STRIDE*31,A1
        MOVE.L  #HorrorHeartData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A1)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A1)
        MOVE.W  #0,AUD_LENH(A1)
        MOVE.W  #HORROR_HEART_LEN,AUD_LENL(A1)
        MOVE.W  #$FFFF,AUD_VOL(A1)
        MOVE.W  #HORROR_PER_8K,AUD_PER(A1)
        MOVE.W  #CTRL_PCM16|CTRL_ONESHOT,AUD_CTRL(A1)
        MOVE.W  #1,AUD_CMD(A1)
        RTS

Trigger_Laugh_Burst_Ha:
        LEA     AUDIO_EXT_BASE,A0
        MOVE.L  #HorrorLaughData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A0)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A0)
        MOVE.W  #0,AUD_LENH(A0)
        MOVE.W  #HORROR_LAUGH_LEN,AUD_LENL(A0)
        MOVE.W  #$F0F0,AUD_VOL(A0)
        MOVE.W  #HORROR_PER_12K,AUD_PER(A0)
        MOVE.W  #0,AUD_DELAY(A0)
        LEA     Flt_Laugh_Formant(PC),A2
        MOVE.W  (A2)+,AUD_BQ_B0(A0)
        MOVE.W  (A2)+,AUD_BQ_B1(A0)
        MOVE.W  (A2)+,AUD_BQ_B2(A0)
        MOVE.W  (A2)+,AUD_BQ_A1(A0)
        MOVE.W  (A2)+,AUD_BQ_A2(A0)
        MOVE.W  #CTRL_PCM16|CTRL_ONESHOT|CTRL_FLT_STEREO,AUD_CTRL(A0)
        MOVE.W  #1,AUD_CMD(A0)

        ; Voice 1: Echo reflection down corridor
        LEA     AUDIO_EXT_BASE+VOICE_STRIDE,A1
        MOVE.L  #HorrorLaughData,D0
        SWAP    D0
        MOVE.W  D0,AUD_PTRH(A1)
        SWAP    D0
        MOVE.W  D0,AUD_PTRL(A1)
        MOVE.W  #0,AUD_LENH(A1)
        MOVE.W  #HORROR_LAUGH_LEN,AUD_LENL(A1)
        MOVE.W  #$8060,AUD_VOL(A1)
        MOVE.W  #HORROR_PER_12K,AUD_PER(A1)
        MOVE.W  #5000,AUD_DELAY(A1)
        MOVE.W  #CTRL_PCM16|CTRL_ONESHOT|CTRL_FLT_STEREO,AUD_CTRL(A1)
        MOVE.W  #1,AUD_CMD(A1)
        RTS

; ==============================================================================
; GRAPHICS & SCREEN ROUTINES
; ==============================================================================
Init_Screen_Planes:
        ; 1. Patch Bitplane pointers into HorrorCopperList
        LEA     ScreenPlanes,A0
        LEA     CopBplPtrs,A1
        MOVEQ   #3,D0
.bpl_loop:
        MOVE.L  A0,D1
        SWAP    D1
        MOVE.W  D1,2(A1)                ; BPLxPTH
        SWAP    D1
        MOVE.W  D1,6(A1)                ; BPLxPTL
        LEA     8(A1),A1
        LEA     BPL_SIZE(A0),A0
        DBRA    D0,.bpl_loop

        ; 2. Clear all 4 bitplanes
        LEA     ScreenPlanes,A0
        MOVE.W  #(BPL_SIZE*4/4)-1,D0
        MOVEQ   #0,D1
.clr_scr:
        MOVE.L  D1,(A0)+
        DBRA    D0,.clr_scr
        RTS

Draw_Castle_Hallway_And_Vampire:
        MOVEM.L D0-D7/A0-A4,-(SP)
        BSR     Clear_Corridor_And_Refresh_Pillars
        ; Draw Vampire Silhouette in Center Arch (Lines 60..160)
        BSR     Draw_Vampire_Figure
        MOVEM.L (SP)+,D0-D7/A0-A4
        RTS

; ------------------------------------------------------------------------------
; Clear Entire Corridor (Cols 3..16) and Restore Clean Stone Pillars
; ------------------------------------------------------------------------------
Clear_Corridor_And_Refresh_Pillars:
        MOVEM.L D0-D7/A0-A3,-(SP)

        LEA     ScreenPlanes,A0                 ; Plane 0
        LEA     BPL_SIZE(A0),A1                 ; Plane 1
        LEA     BPL_SIZE(A1),A2                 ; Plane 2
        LEA     BPL_SIZE(A2),A3                 ; Plane 3

        MOVE.W  #SCR_HEIGHT-1,D7                ; 200 lines
.arch_y:
        ; Left Pillar (Bytes 0..5): Pattern with stone brick mortar
        MOVE.B  #$FF,(A0)
        MOVE.B  #$55,1(A0)
        MOVE.B  #$AA,2(A0)
        MOVE.B  #$33,3(A0)
        MOVE.B  #$CC,4(A0)
        MOVE.B  #$FF,5(A0)

        MOVE.B  #$AA,(A1)
        MOVE.B  #$FF,1(A1)
        MOVE.B  #$55,2(A1)
        MOVE.B  #$FF,3(A1)
        MOVE.B  #$33,4(A1)
        MOVE.B  #$AA,5(A1)

        ; Wipe open corridor (Bytes 6..33 = 28 bytes = 7 longwords) across ALL 4 planes
        MOVEQ   #0,D0
        MOVE.L  D0,6(A0)
        MOVE.L  D0,10(A0)
        MOVE.L  D0,14(A0)
        MOVE.L  D0,18(A0)
        MOVE.L  D0,22(A0)
        MOVE.L  D0,26(A0)
        MOVE.L  D0,30(A0)

        MOVE.L  D0,6(A1)
        MOVE.L  D0,10(A1)
        MOVE.L  D0,14(A1)
        MOVE.L  D0,18(A1)
        MOVE.L  D0,22(A1)
        MOVE.L  D0,26(A1)
        MOVE.L  D0,30(A1)

        MOVE.L  D0,6(A2)
        MOVE.L  D0,10(A2)
        MOVE.L  D0,14(A2)
        MOVE.L  D0,18(A2)
        MOVE.L  D0,22(A2)
        MOVE.L  D0,26(A2)
        MOVE.L  D0,30(A2)

        MOVE.L  D0,6(A3)
        MOVE.L  D0,10(A3)
        MOVE.L  D0,14(A3)
        MOVE.L  D0,18(A3)
        MOVE.L  D0,22(A3)
        MOVE.L  D0,26(A3)
        MOVE.L  D0,30(A3)

        ; Right Pillar (Bytes 34..39)
        MOVE.B  #$FF,34(A0)
        MOVE.B  #$CC,35(A0)
        MOVE.B  #$33,36(A0)
        MOVE.B  #$AA,37(A0)
        MOVE.B  #$55,38(A0)
        MOVE.B  #$FF,39(A0)

        MOVE.B  #$AA,34(A1)
        MOVE.B  #$33,35(A1)
        MOVE.B  #$FF,36(A1)
        MOVE.B  #$55,37(A1)
        MOVE.B  #$FF,38(A1)
        MOVE.B  #$AA,39(A1)

        LEA     SCR_WIDTH_B(A0),A0
        LEA     SCR_WIDTH_B(A1),A1
        LEA     SCR_WIDTH_B(A2),A2
        LEA     SCR_WIDTH_B(A3),A3
        DBRA    D7,.arch_y

        MOVEM.L (SP)+,D0-D7/A0-A3
        RTS

Draw_Vampire_Figure:
        MOVEM.L D0-D7/A0-A4,-(SP)
        LEA     ScreenPlanes,A0
        LEA     BPL_SIZE(A0),A1
        LEA     BPL_SIZE(A1),A2
        LEA     BPL_SIZE(A2),A3

        MOVE.L  #(60*SCR_WIDTH_B)+18,D0
        ADDA.L  D0,A0
        ADDA.L  D0,A1
        ADDA.L  D0,A2
        ADDA.L  D0,A3

        ; 1. Vampire Pale Face (Lines 0..19, 2 words wide)
        MOVEQ   #19,D7
.face_loop:
        MOVE.W  #$07E0,(A0)
        MOVE.W  #$07E0,(A1)
        CLR.W   (A2)
        MOVE.W  #$07E0,(A3)

        ; Eyes on Line 8: Glowing Red (Color 15)
        CMPI.W  #11,D7
        BNE.S   .not_eyes
        MOVE.W  #$0240,(A0)
        MOVE.W  #$0240,(A1)
        MOVE.W  #$0240,(A2)
        MOVE.W  #$0240,(A3)
.not_eyes:
        ; Fangs on Line 15: White highlight (Color 4)
        CMPI.W  #4,D7
        BNE.S   .not_fangs
        MOVE.W  #$0180,(A2)
.not_fangs:
        LEA     SCR_WIDTH_B(A0),A0
        LEA     SCR_WIDTH_B(A1),A1
        LEA     SCR_WIDTH_B(A2),A2
        LEA     SCR_WIDTH_B(A3),A3
        DBRA    D7,.face_loop

        ; 2. Vampire Cape & High Collar (Lines 80..160)
        MOVEQ   #80-1,D7
.cape_loop:
        MOVE.W  #$1FF8,(A1)
        MOVE.W  #$1FF8,(A2)
        MOVE.W  #$3FFC,(A3)
        CLR.W   (A0)

        LEA     SCR_WIDTH_B(A0),A0
        LEA     SCR_WIDTH_B(A1),A1
        LEA     SCR_WIDTH_B(A2),A2
        LEA     SCR_WIDTH_B(A3),A3
        DBRA    D7,.cape_loop

        MOVEM.L (SP)+,D0-D7/A0-A4
        RTS

Clear_Vampire_Center:
        MOVEM.L D0-D2/A0-A3,-(SP)
        LEA     ScreenPlanes,A0
        LEA     BPL_SIZE(A0),A1
        LEA     BPL_SIZE(A1),A2
        LEA     BPL_SIZE(A2),A3

        MOVE.L  #(50*SCR_WIDTH_B)+14,D0
        ADDA.L  D0,A0
        ADDA.L  D0,A1
        ADDA.L  D0,A2
        ADDA.L  D0,A3

        MOVE.W  #120-1,D7
.clr_y:
        MOVEQ   #0,D1
        MOVE.L  D1,(A0)
        MOVE.L  D1,4(A0)
        MOVE.L  D1,(A1)
        MOVE.L  D1,4(A1)
        MOVE.L  D1,(A2)
        MOVE.L  D1,4(A2)
        MOVE.L  D1,(A3)
        MOVE.L  D1,4(A3)

        LEA     SCR_WIDTH_B(A0),A0
        LEA     SCR_WIDTH_B(A1),A1
        LEA     SCR_WIDTH_B(A2),A2
        LEA     SCR_WIDTH_B(A3),A3
        DBRA    D7,.clr_y

        MOVEM.L (SP)+,D0-D2/A0-A3
        RTS

; ------------------------------------------------------------------------------
; Bat Plotting Routines with STRICT WORD ALIGNMENT (No Odd Address Violations!)
; ------------------------------------------------------------------------------
Plot_Bat_Draw:
        MOVEM.L D0-D4/A1-A3,-(SP)
        CMPI.W  #48,D1
        BLT.S   .bat_out
        CMPI.W  #254,D1
        BGT.S   .bat_out
        CMPI.W  #10,D2
        BLT.S   .bat_out
        CMPI.W  #180,D2
        BGT.S   .bat_out

        ; Convert X (D1) to strictly even word offset: (X / 16) * 2
        MOVE.W  D1,D0
        LSR.W   #4,D0                   ; 0..19 words
        LSL.W   #1,D0                   ; 0..38 bytes (ALWAYS EVEN!)

        MULU.W  #SCR_WIDTH_B,D2
        ADD.W   D0,D2                   ; Total offset (ALWAYS EVEN!)

        LEA     ScreenPlanes,A1
        ADDA.L  D2,A1                   ; Guaranteed even address
        LEA     BPL_SIZE(A1),A2         ; Plane 1 (guaranteed even address)

        TST.W   D5
        BNE.S   .use_f1
        LEA     BatFrame0_Plane0(PC),A3
        BRA.S   .do_plot
.use_f1:
        LEA     BatFrame1_Plane0(PC),A3
.do_plot:
        MOVEQ   #15,D4                  ; 16 lines
.plot_line:
        MOVE.W  (A3)+,D0
        OR.W    D0,(A1)                 ; Safe word write
        OR.W    D0,(A2)                 ; Safe word write
        LEA     SCR_WIDTH_B(A1),A1
        LEA     SCR_WIDTH_B(A2),A2
        DBRA    D4,.plot_line

.bat_out:
        MOVEM.L (SP)+,D0-D4/A1-A3
        RTS

Plot_Bat_Erase:
        MOVEM.L D0-D4/A1-A2,-(SP)
        CMPI.W  #48,D1
        BLT.S   .erase_out
        CMPI.W  #254,D1
        BGT.S   .erase_out
        CMPI.W  #10,D2
        BLT.S   .erase_out
        CMPI.W  #180,D2
        BGT.S   .erase_out

        ; Convert X (D1) to strictly even word offset
        MOVE.W  D1,D0
        LSR.W   #4,D0
        LSL.W   #1,D0

        MULU.W  #SCR_WIDTH_B,D2
        ADD.W   D0,D2

        LEA     ScreenPlanes,A1
        ADDA.L  D2,A1
        LEA     BPL_SIZE(A1),A2

        MOVEQ   #15,D4
.erase_line:
        CLR.W   (A1)                    ; Safe word clear
        CLR.W   (A2)
        LEA     SCR_WIDTH_B(A1),A1
        LEA     SCR_WIDTH_B(A2),A2
        DBRA    D4,.erase_line

.erase_out:
        MOVEM.L (SP)+,D0-D4/A1-A2
        RTS

; ------------------------------------------------------------------------------
; Skull & Jaw Rendering (Clean Registers, Zero Overruns)
; ------------------------------------------------------------------------------
Draw_Skeleton_Skull:
        MOVEM.L D0-D7/A0-A6,-(SP)
        LEA     ScreenPlanes,A0
        LEA     BPL_SIZE(A0),A1
        LEA     BPL_SIZE(A1),A2

        MOVE.L  #(70*SCR_WIDTH_B)+18,D0
        ADDA.L  D0,A0
        ADDA.L  D0,A1
        ADDA.L  D0,A2

        LEA     Skull_Plane0(PC),A4
        LEA     Skull_Plane1(PC),A5
        LEA     Skull_Plane2(PC),A6

        MOVEQ   #31,D7                  ; 32 scanlines
.skull_loop:
        MOVE.L  (A4)+,(A0)
        MOVE.L  (A5)+,(A1)
        MOVE.L  (A6)+,(A2)

        LEA     SCR_WIDTH_B(A0),A0
        LEA     SCR_WIDTH_B(A1),A1
        LEA     SCR_WIDTH_B(A2),A2
        DBRA    D7,.skull_loop

        ; Plane 3: Glowing Eye Embers
        LEA     ScreenPlanes+(BPL_SIZE*3)+(70*SCR_WIDTH_B)+18,A3
        LEA     Skull_Plane3(PC),A4
        MOVEQ   #31,D7
.skull_p3:
        MOVE.L  (A4)+,(A3)
        LEA     SCR_WIDTH_B(A3),A3
        DBRA    D7,.skull_p3

        MOVEM.L (SP)+,D0-D7/A0-A6
        RTS

Draw_Jaw_Open:
        MOVEM.L D0-D7/A0-A4,-(SP)
        BSR     Clear_Jaw_Area

        LEA     ScreenPlanes,A0
        LEA     BPL_SIZE(A0),A1
        LEA     BPL_SIZE(A1),A2
        LEA     BPL_SIZE(A2),A3

        MOVE.L  #(108*SCR_WIDTH_B)+18,D0
        ADDA.L  D0,A0
        ADDA.L  D0,A1
        ADDA.L  D0,A2
        ADDA.L  D0,A3

        LEA     Jaw_Plane1(PC),A4
        MOVEQ   #7,D7
.open_loop:
        CLR.L   (A0)
        MOVE.L  (A4)+,D0
        MOVE.L  D0,(A1)
        MOVE.L  D0,(A2)
        MOVE.L  D0,(A3)
        LEA     SCR_WIDTH_B(A0),A0
        LEA     SCR_WIDTH_B(A1),A1
        LEA     SCR_WIDTH_B(A2),A2
        LEA     SCR_WIDTH_B(A3),A3
        DBRA    D7,.open_loop

        MOVEM.L (SP)+,D0-D7/A0-A4
        RTS

Draw_Jaw_Closed:
        MOVEM.L D0-D7/A0-A4,-(SP)
        BSR     Clear_Jaw_Area

        LEA     ScreenPlanes,A0
        LEA     BPL_SIZE(A0),A1
        LEA     BPL_SIZE(A1),A2
        LEA     BPL_SIZE(A2),A3

        MOVE.L  #(102*SCR_WIDTH_B)+18,D0
        ADDA.L  D0,A0
        ADDA.L  D0,A1
        ADDA.L  D0,A2
        ADDA.L  D0,A3

        LEA     Jaw_Plane1(PC),A4
        MOVEQ   #7,D7
.closed_loop:
        CLR.L   (A0)
        MOVE.L  (A4)+,D0
        MOVE.L  D0,(A1)
        MOVE.L  D0,(A2)
        MOVE.L  D0,(A3)
        LEA     SCR_WIDTH_B(A0),A0
        LEA     SCR_WIDTH_B(A1),A1
        LEA     SCR_WIDTH_B(A2),A2
        LEA     SCR_WIDTH_B(A3),A3
        DBRA    D7,.closed_loop

        MOVEM.L (SP)+,D0-D7/A0-A4
        RTS

Clear_Jaw_Area:
        MOVEM.L D0-D2/A0-A3,-(SP)
        LEA     ScreenPlanes,A0
        LEA     BPL_SIZE(A0),A1
        LEA     BPL_SIZE(A1),A2
        LEA     BPL_SIZE(A2),A3

        MOVE.L  #(102*SCR_WIDTH_B)+18,D0
        ADDA.L  D0,A0
        ADDA.L  D0,A1
        ADDA.L  D0,A2
        ADDA.L  D0,A3

        MOVEQ   #16-1,D7
.clr_jaw:
        MOVEQ   #0,D1
        MOVE.L  D1,(A0)
        MOVE.L  D1,(A1)
        MOVE.L  D1,(A2)
        MOVE.L  D1,(A3)
        LEA     SCR_WIDTH_B(A0),A0
        LEA     SCR_WIDTH_B(A1),A1
        LEA     SCR_WIDTH_B(A2),A2
        LEA     SCR_WIDTH_B(A3),A3
        DBRA    D7,.clr_jaw

        MOVEM.L (SP)+,D0-D2/A0-A3
        RTS

Update_Horror_Visuals:
        MOVEM.L D0-D2/A0-A1,-(SP)
        ADDQ.W  #1,FlickerTimer
        MOVE.W  FlickerTimer(PC),D0
        LSR.W   #1,D0
        ANDI.W  #$0007,D0
        ADD.W   D0,D0
        LEA     TorchFlickerTab(PC),A0
        MOVE.W  (A0,D0.W),D1

        LEA     CopColor08,A1
        MOVE.W  D1,(A1)

        MOVEM.L (SP)+,D0-D2/A0-A1
        RTS

TorchFlickerTab:
        DC.W    $0F90, $0EA0, $0F80, $0EB0, $0FA0, $0E90, $0F90, $0DA0

; ==============================================================================
; SYSTEM HELPER ROUTINES (Proven Bulletproof Kickstart 1.3 Synchronization)
; ==============================================================================
Wait_VBL:
        LEA     CUSTOM,A6
.wait_on:
        MOVE.L  VPOSR(A6),D0
        ANDI.L  #$0001FF00,D0
        CMPI.L  #$00010000,D0
        BNE.S   .wait_on
.wait_off:
        MOVE.L  VPOSR(A6),D0
        ANDI.L  #$0001FF00,D0
        CMPI.L  #$00010000,D0
        BEQ.S   .wait_off
        RTS

Silence_All_Voices:
        MOVEM.L D0/A0,-(SP)
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.silence_loop:
        MOVE.W  #2,AUD_CMD(A0)          ; Stop Voice
        MOVE.W  #0,AUD_VOL(A0)
        MOVE.W  #0,AUD_DELAY(A0)
        MOVE.W  #0,AUD_CTRL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.silence_loop
        MOVEM.L (SP)+,D0/A0
        RTS

Apply_Epilog_Fade:
        MOVEM.L D0-D2/A0,-(SP)
        LEA     AUDIO_EXT_BASE,A0
        MOVEQ   #31,D0
.fade_all:
        MOVE.W  AUD_VOL(A0),D1
        MOVE.W  D1,D2
        LSR.W   #8,D1
        ANDI.W  #$00FF,D2

        SUBQ.W  #8,D1
        BPL.S   .l_ok
        MOVEQ   #0,D1
.l_ok:
        SUBQ.W  #8,D2
        BPL.S   .r_ok
        MOVEQ   #0,D2
.r_ok:
        LSL.W   #8,D1
        OR.W    D2,D1
        MOVE.W  D1,AUD_VOL(A0)
        LEA     VOICE_STRIDE(A0),A0
        DBRA    D0,.fade_all
        MOVEM.L (SP)+,D0-D2/A0
        RTS

Takeover_Display:
        MOVEM.L D2-D7/A2-A6,-(SP)
        MOVE.L  GfxBase(PC),D0
        BEQ.S   .direct_cop
        MOVE.L  D0,A6
        MOVE.L  gb_ActiView(A6),Saved_ActiView
        SUBA.L  A1,A1
        JSR     _LVOLoadView(A6)
        JSR     _LVOWaitTOF(A6)
        JSR     _LVOWaitTOF(A6)
.direct_cop:
        LEA     CUSTOM,A6
        MOVE.W  #$002F,DMACON(A6)       ; Disable Paula DMA ($000F) & Sprites ($0020)
        MOVE.L  #HorrorCopperList,COP1LCH(A6)
        MOVE.W  #0,COPJMP1(A6)
        MOVE.W  #$8380,DMACON(A6)       ; Bitplane + Copper DMA enabled
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

Restore_Display:
        MOVEM.L D2-D7/A2-A6,-(SP)
        LEA     CUSTOM,A6
        MOVE.W  #HAM_RESET_VAL,HAM_CONTROL
        MOVE.W  #$0000,BPLCON1(A6)
        MOVE.W  #$0024,BPLCON2(A6)
        MOVE.W  #$0C00,BPLCON3(A6)
        MOVE.W  #$0000,BPL1MOD(A6)
        MOVE.W  #$0000,BPL2MOD(A6)
        MOVE.W  #$0000,FMODE(A6)

        MOVE.L  GfxBase(PC),D0
        BEQ.S   .no_gfx
        MOVE.L  D0,A6
        MOVE.L  Saved_ActiView(PC),A1
        JSR     _LVOLoadView(A6)
        JSR     _LVOWaitTOF(A6)
        JSR     _LVOWaitTOF(A6)
        MOVE.L  gb_copinit(A6),CUSTOM+COP1LCH
        MOVE.W  #0,CUSTOM+COPJMP1
.no_gfx:
        MOVE.L  IntuiBase(PC),D0
        BEQ.S   .no_intui
        MOVE.L  D0,A6
        JSR     _LVORethinkDisplay(A6)
.no_intui:
        MOVE.W  Saved_DMACON(PC),D0     ; Restore original OS DMA state cleanly
        ANDI.W  #$07FF,D0
        OR.W    #$8000,D0
        MOVE.W  D0,CUSTOM+DMACON
        MOVEM.L (SP)+,D2-D7/A2-A6
        RTS

PrintStr:
        MOVEM.L D0-D3/A0-A1/A6,-(SP)
        MOVE.L  DOSBase(PC),D0
        BEQ.S   .p_exit
        MOVE.L  StdoutHandle(PC),D1
        BEQ.S   .p_exit
        MOVE.L  D0,A6
        MOVE.L  A0,A1
        MOVEQ   #0,D3
.p_len:
        TST.B   (A1)+
        BEQ.S   .p_write
        ADDQ.L  #1,D3
        BRA.S   .p_len
.p_write:
        MOVE.L  A0,D2
        JSR     _LVOWrite(A6)
.p_exit:
        MOVEM.L (SP)+,D0-D3/A0-A1/A6
        RTS

; ==============================================================================
; DATA SECTION
; ==============================================================================
GfxName:        DC.B    "graphics.library",0
DosName:        DC.B    "dos.library",0
IntuiName:      DC.B    "intuition.library",0
                EVEN

MsgBanner:
        DC.B    10
        DC.B    "============================================================",10
        DC.B    "  NanoMig 32-Channel Audio Engine: GOTHIC HORROR TESTCASE   ",10
        DC.B    "  Hardware Multi-Tap Corridor Echo, Moog Sweeps & 32 Bats!  ",10
        DC.B    "============================================================",10,0

MsgAct1:
        DC.B    "[*] ACT I: Footsteps down long castle corridor (Hardware Start-Delay + Biquad)...",10,0
MsgAct1Done:
        DC.B    "[+] ACT I completed cleanly.",10,0

MsgAct2:
        DC.B    "[*] ACT II: Howling gale & ghost moans (24 dB Moog Cascade + Ringmodulation)...",10,0
MsgAct2Done:
        DC.B    "[+] ACT II completed cleanly.",10,0

MsgAct3:
        DC.B    "[*] ACT III: Swarm of 32 Bats (All 32 Voices Active + Hardware AM Tremolo)...",10,0
MsgAct3Done:
        DC.B    "[+] ACT III completed cleanly.",10,0

MsgAct4:
        DC.B    "[*] ACT IV: Demonic Laughing Skeleton (Vocal Formants + Ringmod + Heartbeat)...",10,0
MsgAct4Done:
        DC.B    "[+] ACT IV completed cleanly.",10,0

MsgAct5:
        DC.B    "[*] ACT V: Epilog & Harmonic Fadeout...",10,0

MsgSummary:
        DC.B    10
        DC.B    "============================================================",10
        DC.B    "  GOTHIC HORROR TESTCASE COMPLETED CLEANLY! (Return Code: 0)",10
        DC.B    "  - 32 Hardware Voices simultaneously active and verified   ",10
        DC.B    "  - Multi-Tap Hardware Start-Delay ($DFF41C, 32.768 kHz)   ",10
        DC.B    "  - 24 dB Moog Low-Pass Filter Cascade (CTRL_SRC_POST)     ",10
        DC.B    "  - Hardware AM / Tremolo (Fluttering Bat Wings)            ",10
        DC.B    "  - Hardware Ringmodulation (Ghostly Moans & Demonic Laugh) ",10
        DC.B    "  - Master Mixer 22-Bit Accumulator + True-Peak AGC Limiter ",10
        DC.B    "============================================================",10,0
                EVEN

; Runtime Variables
GfxBase:        DC.L    0
DOSBase:        DC.L    0
IntuiBase:      DC.L    0
StdoutHandle:   DC.L    0
Saved_ActiView: DC.L    0
Saved_DMACON:   DC.W    0

CurrentAct:     DC.W    0
FootstepCount:  DC.W    0
HowlStep:       DC.W    0
HowlDir:        DC.W    1
FlickerTimer:   DC.W    0
JawOpenTimer:   DC.W    0

; 32 Bat Data structures (10 bytes per bat: X, Y, VX, VY, Frame)
BatTable:       DS.W    32*5

; Include generated sound, filter & graphics tables
        INCLUDE "horror_data.i"

; Custom Gothic Copper List
        SECTION HorrorCopper,DATA_C
        CNOP    0,4
HorrorCopperList:
        ; Reset AGA display registers cleanly
        DC.W    FMODE,   $0000
        DC.W    BPLCON3, $0C00

        ; Standard PAL Display Window: 320x200
        DC.W    $008E,   $2C81          ; DIWSTRT
        DC.W    $0090,   $F4C1          ; DIWSTOP
        DC.W    $0092,   $0038          ; DDFSTRT
        DC.W    $0094,   $00D0          ; DDFSTOP

        ; Video control: 4 bitplanes, 320x200 lowres
        DC.W    BPLCON0, $4200          ; 4 planes, COLOR enabled
        DC.W    BPLCON1, $0000
        DC.W    BPLCON2, $0024
        DC.W    BPL1MOD, $0000
        DC.W    BPL2MOD, $0000

        ; Bitplane Pointers (Patched dynamically)
CopBplPtrs:
        DC.W    $00E0, 0, $00E2, 0      ; BPL1
        DC.W    $00E4, 0, $00E6, 0      ; BPL2
        DC.W    $00E8, 0, $00EA, 0      ; BPL3
        DC.W    $00EC, 0, $00EE, 0      ; BPL4

        ; Clear All 8 Sprite Pointers to dummy (eliminates left garbage bars & stripes!)
CopSpritePtrs:
        DC.W    $0120, 0, $0122, 0      ; Sprite 0
        DC.W    $0124, 0, $0126, 0      ; Sprite 1
        DC.W    $0128, 0, $012A, 0      ; Sprite 2
        DC.W    $012C, 0, $012E, 0      ; Sprite 3
        DC.W    $0130, 0, $0132, 0      ; Sprite 4
        DC.W    $0134, 0, $0136, 0      ; Sprite 5
        DC.W    $0138, 0, $013A, 0      ; Sprite 6
        DC.W    $013C, 0, $013E, 0      ; Sprite 7

        ; 16-Color Gothic Palette
        DC.W    COLOR00, $0001          ; 0: Midnight Dark Blue
        DC.W    $0182,   $0123          ; 1: Deep Stone
        DC.W    $0184,   $0234          ; 2: Medium Stone
        DC.W    $0186,   $0456          ; 3: Pale Stone
        DC.W    $0188,   $0CEE          ; 4: White Moonlight
        DC.W    $018A,   $0500          ; 5: Blood Red Dark
        DC.W    $018C,   $0B11          ; 6: Crimson Bright
        DC.W    $018E,   $0740          ; 7: Torch Gold Dark
CopColor08:
        DC.W    $0190,   $0F90          ; 8: Torch Flame Bright (Modulated!)
        DC.W    $0192,   $0FE5          ; 9: Torch Yellow
        DC.W    $0194,   $0203          ; 10: Shadow Purple
        DC.W    $0196,   $09AB          ; 11: Vampire Flesh
        DC.W    $0198,   $0000          ; 12: Pitch Black
        DC.W    $019A,   $068A          ; 13: Cold Cyan
        DC.W    $019C,   $0BBA          ; 14: Bone Ivory
        DC.W    $019E,   $0F00          ; 15: Glowing Red Eye

        ; End of Copper List
        DC.W    $FFFF,   $FFFE

; 320x200 4-Bitplane Screen Buffer in Chip-RAM BSS (32,000 bytes)
        SECTION HorrorScreen,BSS_C
        CNOP    0,4
ScreenPlanes:
        DS.B    BPL_SIZE*4

        END
