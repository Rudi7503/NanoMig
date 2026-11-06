# NanoMig Extended Hardware Demo Specification
## Das ultimative Entwickler-Briefing für das KI-Modell (Argon)

> **Zweck dieses Dokuments:**  
> Diese Spezifikation dient als vollständige, fehlerfreie Vorlage für ein hochentwickeltes KI-Modell (z. B. Anthropic Claude / Argon), um ein spektakuläres Amiga-Showcase-Demo in M68000-Assembler (VASM) zu schreiben, das die revolutionären **Extended-HAM-** und **32-Kanal-Audio-Erweiterungen** des Minimig-AGA / NanoMig Cores voll ausreizt.

---

## 1. Warum unsere Hardware-Ergänzungen einzigartig sind

Klassische Amiga-Demos leiden unter einem fundamentalen Flaschenhals: **Dem geteilten Chip-RAM-Bus (7 MHz)**.  
Wenn 6 bis 8 Bitplanes für TrueColor-Grafik angezeigt werden, bricht die DMA-Bandbreite für Blitter und Audio ein. Bei normalem 8-Bit-Paula-Audio teilen sich 4 Stimmen die wenigen Zyklen mit hörbarem Rauschen.

**Unsere Architektur löst all diese Limitierungen hardwaremäßig auf:**

1. **Zero-Bus-Impact 32-Kanal Audio (Option 2 DMA):**
   * Die Audio-DMA greift über einen eigenen 114-MHz-Master **direkt auf das DDR3-Fast-RAM** zu.
   * **Ergebnis:** 32 Stimmen mit 16-Bit / 48 kHz laufen mit **0 % Belastung des Chip-Busses**! Der Chip-Bus steht zu 100 % für Denise, Copper und Blitter zur Verfügung.
2. **Extended HAM Video Pipeline ($DFF800):**
   * Anstelle des trägen klassischen HAM8 ermöglicht unsere differentielle Sättigungs-Engine **24-Bit TrueColor-Gradients mit nur 3 bis 5 Bitplanes (HAM03, HAM04, HAM05)**!
   * Dies spart über 50 % bis 62 % der Video-DMA-Bandbreite ein.
   * **Copper-Modulation:** Die Copper-List kann pro Scanline die Schrittweiten (`step_r`, `step_g`, `step_b`) modifizieren – das erzeugt spektakuläre Plasma- und Chrom-Verläufe ohne ein einziges Pixel im RAM neu zu berechnen!
3. **Hardware-Synthesizer auf dem FPGA:**
   * Jede Stimme verfügt über ein eigenes 12 dB/Oktave Biquad IIR DSP-Filter.
   * Durch **Kaskadierung (`v_input_src = 10`)** wird das gefilterte Signal von Stimme $N-1$ in Stimme $N$ geleitet: Ein echter, analog klingender **24 dB Moog-Synthesizer** mit Resonanz!
   * **Hardware AM-Tremolo & Ringmodulation** zwischen Stimmen für metallische Sci-Fi-Klänge und Bells ohne CPU-Overhead.
4. **Geschlossener Audio-Video-Regelkreis (Live Colorscope über $DF8000):**
   * Das fertige Stereo-Mix-Signal kann latenzfrei aus dem internen Ringpuffer bei `$DF8000` ausgelesen werden. Die Grafik pulsiert absolut lippensynchron im Takt der Bassline.

---

## 2. Speicher- und Register-Architektur

### 2.1 Überblick über den Custom-Chip-Bereich

| Adressbereich | Funktion |
| :--- | :--- |
| **`$DFF400 .. $DFF7FE`** | **32 Stimmen Audio-Register** (32 Stimmen $\times$ 32 Bytes) |
| **`$DFF800`** | **`HAM_CONTROL`** – Extended HAM Video Steuerung (Shadow-Register) |
| **`$DFF802`** | **`CAP_CTRL`** – Audio Capture Steuerung & Status |
| **`$DFF804 .. $DFF80A`** | **`AUDINTENA` / `AUDINTREQ`** – Globales 32-Stimmen Audio-Interrupt-Interface |
| **`$DF8000 .. $DF8FFF`** | **Audio Capture Puffer A** (4096 Bytes = 1024 interleaved 16-Bit Stereo-Samples) |
| **`$DF9000 .. $DF9FFF`** | **Audio Capture Puffer B** (4096 Bytes = 1024 interleaved 16-Bit Stereo-Samples) |

---

### 2.2 Register-Layout pro Audio-Stimme ($DFF400 + [Stimme \times 32]$)

Jede der 32 Stimmen belegt 16 Wörter (32 Bytes). Basisadresse Stimme $n = \$DFF400 + (n \times \$20)$:

| Offset | Register | Zugriff | Standard | Beschreibung |
| :---: | :--- | :---: | :---: | :--- |
| `+$00` | `AUDxPTRH` | W | `$0000` | Sample-Startzeiger High-Word (Bits 31..16) |
| `+$02` | `AUDxPTRL` | W | `$0000` | Sample-Startzeiger Low-Word (Bits 15..1, Bit 0 = 0) |
| `+$04` | `AUDxLENH` | W | `$0000` | Pufferlänge High in Words (Bits 31..16) – **Volle 32-Bit DMA!** |
| `+$06` | `AUDxLENL` | W | `$0000` | Pufferlänge Low in Words (Bits 15..0 in 16-Bit Wörtern) |
| **`+$08`** | **`AUDxVOL`**  | W | `$0000` | **Lautstärke:** High-Byte = Links (0..255), Low-Byte = Rechts (0..255) |
| **`+$0A`** | **`AUDxPER`**  | W | `$0100` | **Abtastperiode:** Farbtakt-Teiler ($f_s = 3.546.895 / \text{PER}$, 744 = 47.655 Hz / 48 kHz) |
| `+$0C` | `AUDxCTRL` | W | `$0000` | Steuerregister (Format, Filter, Kaskadierung, Modulation, Mute) |
| `+$0E` | `AUDxPRED` | W | `$0000` | ADPCM Prädiktor Initialwert & Index |
| `+$10` | `AUDxB0`   | R/W | `$4000` | Biquad Koeffizient $b_0$ (Q2.14 vorzeichenbehaftet, `$4000` = 1.0) |
| `+$12` | `AUDxB1`   | R/W | `$0000` | Biquad Koeffizient $b_1$ (Q2.14) |
| `+$14` | `AUDxB2`   | R/W | `$0000` | Biquad Koeffizient $b_2$ (Q2.14) |
| `+$16` | `AUDxA1`   | R/W | `$0000` | Biquad Koeffizient $a_1$ (Q2.14) |
| `+$18` | `AUDxA2`   | R/W | `$0000` | Biquad Koeffizient $a_2$ (Q2.14) |
| `+$1A` | `AUDxCMD`  | R/W | `$0000` | Bit 0: Start (`1`), Bit 1: Stop (`1`) |
| `+$1C` | `AUDxDEL`  | W   | `$0000` | Zero-RAM Start-Delay (in 32.768-kHz-Ticks, bis 2,0 s) |
| `+$1E` | `AUDxSTAT` | R   | `$0000` | Status (Bit 0: Delaying, Bit 1: Prefill, Bit 2: Playing) |

> [!IMPORTANT]
> **Byte-Reihenfolge (Endianness):**  
> Sämtliche 16-Bit Audiosamples müssen im **Motorola Big-Endian Format** vorliegen (High-Byte vor Low-Byte).  
> **16-Bit Word-Zählung bei AUDxLEN:**  
> Die Pufferlänge wird in **16-Bit-Wörtern** angegeben: $\text{AUDxLEN} = \text{Dateigröße in Bytes} / 2$.

---

### 2.3 Exakte Bitbelegung des Steuerregisters `AUDxCTRL` (`+$0C`)

| Bit(s) | Maske | Name | Bedeutung |
| :---: | :---: | :--- | :--- |
| `0` | `$0001` | `CTRL_PCM16` | `1` = 16-Bit Linear Signed PCM, `0` = 8-Bit Signed PCM |
| `1` | `$0002` | `CTRL_ONESHOT` | `1` = One-Shot Buffer (stoppt am Ende), `0` = Endlos-Loop |
| `2` | `$0004` | `CTRL_STEREO` | `1` = Interleaved Stereo (Wort 0 = Links, Wort 1 = Rechts), `0` = Mono |
| `3` | `$0008` | `CTRL_ADPCM` | `1` = Hardware ADPCM Dekompression aktiv |
| `5..4`| `$0030` | `CTRL_BPS` | ADPCM Modus: `00` = 4-Bit Standard, `01` = 2-Bit, `10` = 5-Bit Hybrid |
| `7` | `$0080` | `CTRL_FLT_R` | Biquad DSP Filter für rechten Kanal aktiv |
| `8` | `$0100` | `CTRL_FLT_L` | Biquad DSP Filter für linken Kanal aktiv (`$0180` = Stereo-Filter) |
| `10..9`| `$0600` | `v_input_src` | **Signalquelle:**<br>`00` = DMA / RAM<br>`01` = Pre-Filter Signal von Stimme $N-1$<br>`10` = **Post-Filter Signal von Stimme $N-1$ (Moog 24 dB Kaskade!)** |
| `12..11`| `$1800` | `v_mod_mode` | **Modulation:**<br>`00` = Aus<br>`01` = **AM / Tremolo** (Stimme $N-1$ moduliert Amplitude)<br>`10` = **Ringmodulation** (Vier-Quadranten Multiplikation) |
| `13` | `$2000` | `v_mute_mix` | `1` = Stumm im Master-Mix (ideal für Modulatoren oder Kaskaden-Vorstufen) |

---

## 3. Extended HAM Video Pipeline ($DFF800)

### 3.1 Das Steuerregister `HAM_CONTROL` (`$DFF800`)

Das Register ist schattiert und wird taktgenau an der Bildwechselflanke (`sof`) aktiv geschaltet.

```
Bit 15:       EXT_ENABLE  (1 = Extended HAM aktiv, 0 = Normales Amiga-Video)
Bits 14..10:  STEP_R      (0..31: Schrittweite Rot)
Bits 9..5:    STEP_G      (0..31: Schrittweite Grün)
Bits 4..0:    STEP_B      (0..31: Schrittweite Blau)
```

* **Standard Reset-Wert:** `$1084` (Bit 15 = 0, Step R=4, Step G=4, Step B=4).
* **Typischer Einschalt-Wert:** `$9084` (`$8000 | (4<<10) | (4<<5) | 4`).

### 3.2 Die Bitplane-Modi (HAM03 bis HAM08)

Die Engine ermittelt den Modus automatisch anhand der konfigurierten Bitplane-Anzahl in `BPLCON0` / AGA (`ham_raw_bpu`):

1. **HAM03 (3 Bitplanes = 8 Werte):**
   * Wenn `Bit 2 == 0`: **Anchor-Pixel!** Lädt Farbe direkt aus der CLUT Palette (Index 0..3) und initialisiert den Farbakku.
   * Wenn `Bit 2 == 1`: **Delta-Pixel!** Modifiziert den Farbakku simultan auf allen 3 Kanälen ($\pm 2 \times \text{Step}$).
   * **Vorteil:** Unglaublich geringer Speicher- und DMA-Bedarf für 24-Bit Verläufe!
2. **HAM04 (4 Bitplanes = 16 Werte):**
   * Wenn `Bit 3 == 0`: **Anchor-Pixel!** Lädt Farbe aus Palette (Index 0..7).
   * Wenn `Bit 3 == 1`: **Delta-Pixel!** Unabhängige Richtungssteuerung: Bit 2 steuert Rot ($\pm 2$), Bit 1 Grün ($\pm 2$), Bit 0 Blau ($\pm 2$).
3. **HAM05 (5 Bitplanes = 32 Werte):**
   * Wenn `Bit 4 == 0`: **Anchor-Pixel!** Palette (Index 0..15).
   * Wenn `Bit 4 == 1`: **Delta-Pixel mit Turbo-Bit!**  
     Bit 3 = Turbo-Multiplikator ($4\times$ Schrittweite bei `1`), Bits 2..0 steuern Vorzeichen für R, G, B ($\pm 1$).
4. **HAM06 (6 Bitplanes = 64 Werte):**
   * Wenn `Bit 5 == 0`: **Anchor-Pixel!** Palette (Index 0..31).
   * Wenn `Bit 5 == 1`: **Delta-Pixel mit feiner Grün-Auflösung!**  
     Grün besitzt 4 Stufen ($-2, -1, +1, +2$), R und B je $\pm 1$, plus Turbo-Multiplikator auf Bit 4.
5. **HAM08 (8 Bitplanes = 256 Werte):**
   * Wenn `Bit 7 == 0`: **Anchor-Pixel!** Palette (Index 0..127).
   * Wenn `Bit 7 == 1`: **Vollwertiges 24-Bit TrueColor Delta!**  
     Je 4 Stufen für R, G und B plus Turbo-Multiplikator auf Bit 6.

### 3.3 Copper-Tricks mit Extended-HAM

Da `$DFF800` von der Copper-List zeilenweise beschrieben werden kann, lassen sich dynamische Effekte erzeugen:
```assembly
; In der Copper-List:
CMOVE   $DFF800, $9084          ; Standard-Schrittweite (R=4, G=4, B=4)
CWAIT   100, 0
CMOVE   $DFF800, $97C0          ; Rot-Intensivierung für Sonnenuntergang (R=31, G=30, B=0)
CWAIT   200, 0
CMOVE   $DFF800, $801F          ; Blauer Horizont / Meer (R=0, G=0, B=31)
```

---

## 4. Live Audio-Capture & Visualizer ($DF8000 & $DFF802)

Zur perfekten Audio-Video-Synchronisation liest die CPU oder Copper das laufende Audio-Ausgangssignal direkt aus dem internen Ringpuffer:

* **Puffer A:** `$DF8000 .. $DF8FFF` (1024 32-Bit Stereopaare: High-Word = Links, Low-Word = Rechts).
* **Steuerung `$DFF802` (`CAP_CTRL`):**
  * `MOVE.W #$0001, $DFF802` – Startet die Aufzeichnung in den internen BRAM.
* **Auslesen im Demo-Frame (Beat-Detection):**
  ```assembly
  MOVE.W  $DF8000, D0             ; Liest aktuelles linkes Sample (16-Bit vorzeichenbehaftet)
  ASR.W   #8, D0                  ; Skalieren auf -128..+127
  ; Jetzt D0 nutzen, um Copper-Farben zu modulieren oder Sprites zu skalieren!
  ```

---

## 5. M68000 Assembler Referenz-Code (VASM)

Das folgende vollständige Code-Skelett demonstriert die saubere Initialisierung der Audio-Engine, die Kaskadierung eines 24 dB Moog-Filters, das Aktivieren von Extended HAM und die Frame-Schleife:

```assembly
; ==============================================================================
; NanoMig 32-Channel Audio & Extended HAM Showcase Skeleton
; Assembler: VASM (vasmm68k_mot -Fhunkexe -nosym)
; ==============================================================================

            SECTION Code, CODE

CUSTOM      EQU $DFF000
HAM_CTRL    EQU $DFF800
CAP_CTRL    EQU $DFF802
AUD_BASE    EQU $DFF400
VOICE_SZ    EQU 32

; Audio-Register Offsets pro Stimme
AUD_PTRH    EQU $00
AUD_PTRL    EQU $02
AUD_LENH    EQU $04
AUD_LENL    EQU $06
AUD_VOL     EQU $08             ; High=Links, Low=Rechts
AUD_PER     EQU $0A             ; Farbtakt-Teiler (744 = 48 kHz)
AUD_CTRL    EQU $0C             ; Bit 0=PCM16, 1=1Shot, 7/8=Flt, 9/10=Src, 11/12=Mod
AUD_PRED    EQU $0E
AUD_BQ_B0   EQU $10
AUD_BQ_B1   EQU $12
AUD_BQ_B2   EQU $14
AUD_BQ_A1   EQU $16
AUD_BQ_A2   EQU $18
AUD_CMD     EQU $1A             ; 1=Start, 2=Stop
AUD_DELAY   EQU $1C

; Start
Main:
            LEA     CUSTOM, A6
            
            ; 1. Extended HAM Video aktivieren (HAM04 oder HAM05)
            ; Bit 15=1, Step R=4, G=4, B=4 -> $9084
            MOVE.W  #$9084, HAM_CTRL

            ; 2. Audio Capture aktivieren für Visualizer
            MOVE.W  #$0001, CAP_CTRL

            ; 3. Audio Initialisieren: Alle Stimmen stoppen
            LEA     AUD_BASE, A0
            MOVE.W  #31, D0
.stop_loop:
            MOVE.W  #$0002, AUD_CMD(A0) ; STOP
            MOVE.W  #$0000, AUD_VOL(A0) ; Mute
            MOVE.W  #$0000, AUD_CTRL(A0)
            LEA     VOICE_SZ(A0), A0
            DBRA    D0, .stop_loop

            ; 4. Stimme 0: Moog Bass Vorstufe (Sägezahn-Wellenform)
            LEA     AUD_BASE, A0
            MOVE.L  #BassWave, D0
            MOVE.W  D0, AUD_PTRL(A0)
            SWAP    D0
            MOVE.W  D0, AUD_PTRH(A0)
            MOVE.W  #0, AUD_LENH(A0)
            MOVE.W  #64, AUD_LENL(A0)   ; 64 Words = 128 Bytes
            MOVE.W  #744, AUD_PER(A0)   ; 48 kHz Basis
            MOVE.W  #$8080, AUD_VOL(A0) ; Halbpegel
            ; Filter B0..A2 laden (1 kHz Lowpass Q2.14)
            MOVE.W  #$0672, AUD_BQ_B0(A0)
            MOVE.W  #$0CE4, AUD_BQ_B1(A0)
            MOVE.W  #$0672, AUD_BQ_B2(A0)
            MOVE.W  #$CD2B, AUD_BQ_A1(A0)
            MOVE.W  #$164D, AUD_BQ_A2(A0)
            ; Bit 0: PCM16, Bits 8..7: Stereo-Filter, Bit 13: Mute in Master-Mix ($2000)
            ; (Stimme 0 dient als reiner Vorstufen-Filter fuer Stimme 1 und soll nicht parallel im Mix hoerbar sein)
            MOVE.W  #$2181, AUD_CTRL(A0)

            ; 5. Stimme 1: Moog Bass Zweite 12 dB Stufe (Kaskade von Stimme 0!)
            LEA     VOICE_SZ(A0), A1    ; Stimme 1
            MOVE.W  #0, AUD_LENH(A1)
            MOVE.W  #0, AUD_LENL(A1)    ; WICHTIG: LEN=0 bei Kaskade (keine DMA)!
            MOVE.W  #$8080, AUD_VOL(A1)
            ; Gleiche Filterkoeffizienten für 24 dB Gesamtflankensteilheit
            MOVE.W  #$0672, AUD_BQ_B0(A1)
            MOVE.W  #$0CE4, AUD_BQ_B1(A1)
            MOVE.W  #$0672, AUD_BQ_B2(A1)
            MOVE.W  #$CD2B, AUD_BQ_A1(A1)
            MOVE.W  #$164D, AUD_BQ_A2(A1)
            ; Bit 0: PCM16, Bits 8..7: Stereo-Filter, Bits 10..9: Post-Filter Vorstufe (10 = $0400)
            MOVE.W  #$0581, AUD_CTRL(A1)

            ; 6. Beide Stimmen starten
            MOVE.W  #$0001, AUD_CMD(A0)
            MOVE.W  #$0001, AUD_CMD(A1)

; Hauptschleife (Raster synchronisieren & Visualizer aktualisieren)
MainLoop:
            ; VBlank abwarten
.wait_vb:
            MOVE.L  $DFF004, D0
            ANDI.L  #$0001FF00, D0
            CMPI.L  #$00012C00, D0      ; Zeile 300
            BNE.S   .wait_vb

            ; Audio-Visualizer: Live-Sample aus Capture Puffer lesen
            MOVE.W  $DF8000, D0         ; Linker Kanal 16-Bit
            ASR.W   #9, D0              ; Skalieren
            ANDI.W  #$000F, D0          ; 4-Bit Farbwert
            MOVE.W  D0, $DFF180         ; Hintergrundfarbe pulsiert im Bass!

            ; Linke Maustaste prüft Abbruch
            BTST    #6, $BFE001
            BNE.S   MainLoop

            ; Aufräumen & Beenden
            MOVE.W  #$0002, AUD_CMD(A0)
            MOVE.W  #$0002, AUD_CMD(A1)
            MOVE.W  #$1084, HAM_CTRL    ; Extended HAM deaktivieren
            MOVE.W  #$0000, CAP_CTRL    ; Capture stoppen
            RTS

            SECTION Data, DATA
            EVEN
BassWave:   ; 128 Bytes Big-Endian 16-Bit Sägezahn
            DC.W    -$7FFF, -$7800, -$7000, -$6800, -$6000, -$5800, -$5000, -$4800
            DC.W    -$4000, -$3800, -$3000, -$2800, -$2000, -$1800, -$1000, -$0800
            DC.W    $0000,  $0800,  $1000,  $1800,  $2000,  $2800,  $3000,  $3800
            DC.W    $4000,  $4800,  $5000,  $5800,  $6000,  $6800,  $7000,  $7FFF
            ; Wiederholung für zweite Halbwelle
            DC.W    -$7FFF, -$7800, -$7000, -$6800, -$6000, -$5800, -$5000, -$4800
            DC.W    -$4000, -$3800, -$3000, -$2800, -$2000, -$1800, -$1000, -$0800
            DC.W    $0000,  $0800,  $1000,  $1800,  $2000,  $2800,  $3000,  $3800
            DC.W    $4000,  $4800,  $5000,  $5800,  $6000,  $6800,  $7000,  $7FFF
