# NanoMig Audio-Erweiterung – Architektur-Spezifikation

> **Wichtiger Entwicklungsgrundsatz:**  
> Dieses Dokument beschreibt die verbindliche Hard- und Software-Architektur der Audio-Erweiterung in NanoMig / MiSTer.  
> **Bei jeder architekturellen Änderung (RTL, Register, Busse, DSPs, Speicherpfade) MUSS dieses Dokument unmittelbar mit aktualisiert werden.**

---

## 1. Systemübersicht & Blockdiagramm

```
                         +-------------------------------------------------------+
                         |                    68000 / 68020 CPU                  |
                         +-------------------------------------------------------+
                                    | ($DFF400..$DFF7FE / $DFF804..$DFF80A)
                                    v
       +-------------------------------------------------------------------------+
       |                               audio_ext.v                               |
       |                                                                         |
       |  +--------------------+   +------------------------------------------+  |
       |  | Voice Regs (0..31) |   | TDM Scheduler (cur_voice: 0..31)         |  |
       |  | $DFF400 + v*32     |   | Systemtakt: clk_sys (28.375 MHz)          |  |
       |  | PTR, LEN, PER, VOL |   | TDM-Schlitzrate: ~886.7 kHz               |  |
       |  | CTRL, BPS, PRED    |   +------------------------------------------+  |
       |  +--------------------+                         |                       |
       |                                                 v                       |
       |  +-------------------------------------------------------------------+  |
       |  | FIFO-Puffer: 2048 x 16 Bit (64 Wörter je Stimme)                 |  |
       |  +-------------------------------------------------------------------+  |
       |                                                 |                       |
       |                                                 v                       |
       |  +-------------------------------------------------------------------+  |
       |  | Dekoder-Stufe: PCM 8/16-Bit & Hardware-ADPCM (Stateless Core)     |  |
       |  +-------------------------------------------------------------------+  |
       |                                                 |                       |
       |                                                 v                       |
       |  +-------------------------------------------------------------------+  |
       |  | Pre-/Post-Filter Kaskaden-Routing (Pre-Pre, Pre-Post, Post-Post)  |  |
       |  +-------------------------------------------------------------------+  |
       |                         |                               |               |
       |                         v                               v               |
       |        +---------------------------------+  +-------------------------+ |
       |        |       biquad_inst0 (DSP 0)      |  |   biquad_inst1 (DSP 1)  | |
       |        |   LINKS (Alle 32 Stimmen 0..31) |  | RECHTS (Alle 32 Stimmen)| |
       |        | 16-Bit Coeffs, 34-Bit Akkumul.  |  | 16-Bit Coeffs, 34-Bit   | |
       |        +---------------------------------+  +-------------------------+ |
       |                         |                               |               |
       |                         +---------------+---------------+               |
       |                                         v                               |
       |  +-------------------------------------------------------------------+  |
       |  | Stereo-Mixer: Lautstärke (L/R), AM / Tremolo & Ringmodulation     |  |
       |  +-------------------------------------------------------------------+  |
       |                                         |                               |
       |                                         v                               |
       |  +-------------------------------------------------------------------+  |
       |  | 21-Bit Akkumulator (sample_l, sample_r unbeschnitten, +30 dB)     |  |
       |  +-------------------------------------------------------------------+  |
       |            |                                              |             |
       |            v                                              v             |
       |    audio_capture.v                              42-Bit Mailbox CDC      |
       |  (2x 4 KB Ringpuffer)                         (clk_sys -> CLK_AUDIO)    |
       |                                                           |             |
       +-----------------------------------------------------------|-------------+
                                                                   v
                                                  +-------------------------------+
                                                  | Master-Mixer (Minimig.sv)     |
                                                  | 22-Bit Akkumulator (+36 dB)   |
                                                  | Paula + 32ch + CDDA + Toccata |
                                                  +-------------------------------+
                                                                   |
                                                                   v
                                                  +-------------------------------+
                                                  | True-Peak AGC Limiter         |
                                                  | (audio_agc_limiter.v @ 48kHz) |
                                                  | -0.5 dBFS Decke, 85ms Release |
                                                  +-------------------------------+
                                                                   |
                                                                   v
                                                        MiSTer Audio I2S / DAC
                                                        (48 kHz / 96 kHz)
```

---

## 2. Speicheranbindung (Option 2 – Hybrider 114-MHz-Master & Chip-DMA-Handoff)

Im Gegensatz zum Standard-Minimig-Audio läuft die Audio-DMA **vollständig entkoppelt von Agnus und dem 7-MHz-Chip-Bus für Fast-RAM**:

1. **Dedizierter Bus-Master ([`audio_dma_master.v`](file:///D:/programmier_ordner/FPGA/NanoMig/mister/rtl/audio_dma_master.v)):**
   * Arbeitet mit vollem **32-Bit-Adressraum**.
   * Unterscheidet transparent über `memory_router`, ob eine Sample-Adresse im **Fast-RAM / Zorro-RAM** (`is_ddr`) oder im **Chip-RAM / Slow-RAM** liegt.
2. **Fast-RAM / DDR3-Zugriff (Option 2 Direct):**
   * Bei Adressen $\ge \$08000000$ (DDR3 Fast-RAM / Zorro II & III) greift der Audio-DMA-Master direkt mit **114 MHz (`clk_114`)** auf den DDR3-Controller (`ddram_ctrl`) zu.
   * Latenz: 3–5 Taktzyklen, **ohne** Agnus-Arbitrierung, **ohne** 7-MHz-Wartezyklen, **ohne** DMA-Busüberlastung.
3. **Chip-RAM / SDRAM-Zugriff (chipdma_arb Handoff):**
   * Bei Adressen $<\$02000000$ (Standard-Amiga-Chip-RAM) übergibt der Master die Anforderung per Handshake an [`chipdma_arb.v`](file:///D:/programmier_ordner/FPGA/NanoMig/mister/rtl/chipdma_arb.v).
   * `chipdma_arb` synchronisiert die Transaktion sicher auf Leerlaufphasen von Agnus (`minimig_idle`), steuert `sdram_ctrl` mit sauberem SDRAM-Read-Timing und verhindert Buskonflikte mit Akiko/CDTV.
   * Sobald die Daten im SDRAM-Zyklus bereitstehen, erhält der Master ein Acknowledge (`chip_dma_ack`) und liefert die 16-Bit-Audiodaten an `audio_ext` zurück.

---

## 3. DSP-Architektur: Trennung nach Links / Rechts

Die beiden Hardware-Biquad-Filterkerne sind **strikt nach Stereokanälen getrennt**:

| DSP-Instanz | Stereokanal | Zugeordnete Stimmen | Funktion |
| :--- | :--- | :--- | :--- |
| **`biquad_inst0` (DSP 0)** | **Links** | **Alle 32 Stimmen (0..31)** | Filtert exklusiv den linken Audio-Pfad aller Stimmen |
| **`biquad_inst1` (DSP 1)** | **Rechts** | **Alle 32 Stimmen (0..31)** | Filtert exklusiv den rechten Audio-Pfad aller Stimmen |

### Warum diese Kanaltrennung entscheidend ist:
* **Kaskaden-Integrität:** Eine Kaskadenkette über alle 32 Stufen ($0 \rightarrow 1 \rightarrow \dots \rightarrow 31$) verbleibt vollständig innerhalb **derselben** DSP-Instanz.
* **Latenzfreie Auflösung:** Da jede Instanz alle 32 Stimmen sequenziell bedient, wird eine 32-stufige Kaskade innerhalb einer einzigen Sampleperiode aufgelöst.
* **Echtes Stereo:** Linker und rechter Kanal können völlig unabhängige Filterkoeffizienten und Modulationspfade besitzen.

---

## 4. Register-Layout (Option A)

### Stimmen-Register: `$DFF400 + (Stimme \times 32)` (Stimmen 0 bis 31)

Jede der 32 Stimmen belegt 16 Wörter (32 Bytes):

| Offset | Wort-Adresse | Register | Beschreibung |
| :---: | :---: | :--- | :--- |
| `+0` | `$00` | `AUDxPTRH` | Sample-Startzeiger High-Word (Bits 31..16) |
| `+2` | `$01` | `AUDxPTRL` | Sample-Startzeiger Low-Word (Bits 15..1, Byte 0 = 0) |
| `+4` | `$02` | `AUDxLENH` | Sample-Länge High-Word (in Bytes, muss gerade sein) |
| `+6` | `$03` | `AUDxLENL` | Sample-Länge Low-Word (in Bytes, muss gerade sein; `0` bei Kaskaden) |
| `+8` | `$04` | `AUDxVOL`  | Lautstärke: Bit 15..8 = Links (0..255), Bit 7..0 = Rechts (0..255) |
| `+10`| `$05` | `AUDxPER`  | Zeitbasis-Teiler ($f_s = 25\,\text{MHz} / \text{PER}$, z. B. **521 für 48 kHz**) |
| `+12`| `$06` | `AUDxCTRL` | Steuerregister: Format, Filter, Kaskadierung, Modulation, Mute (s. u.) |
| `+14`| `$07` | `AUDxPRED` | ADPCM Prädiktor Initialwert & Index |
| `+16`| `$08` | `AUDxB0`   | Biquad Koeffizient $b_0$ (Q2.14, vorzeichenbehaftet, `$4000` = 1.0) |
| `+18`| `$09` | `AUDxB1`   | Biquad Koeffizient $b_1$ (Q2.14, vorzeichenbehaftet) |
| `+20`| `$0A` | `AUDxB2`   | Biquad Koeffizient $b_2$ (Q2.14, vorzeichenbehaftet) |
| `+22`| `$0B` | `AUDxA1`   | Biquad Koeffizient $a_1$ (Q2.14, vorzeichenbehaftet) |
| `+24`| `$0C` | `AUDxA2`   | Biquad Koeffizient $a_2$ (Q2.14, vorzeichenbehaftet) |
| `+26`| `$0D` | `AUDxCMD`  | Bit 0: Start, Bit 1: Stop |
| `+28`| `$0E` | `AUDxDEL`  | Hardware-Startverzögerung (in 32.768-kHz-Ticks, bis 2,0 s ohne RAM) |
| `+30`| `$0F` | `AUDxSTAT` | Status (Bit 0: Delaying, Bit 1: Prefill, Bit 2: Playing) |

### Detaillierte Bitbelegung des Steuerregisters `AUDxCTRL` (`+$0C`):

* **Bit 0 (`CTRL_PCM16`):** Sample-Format (`1` = 16-Bit Signed Linear PCM Big-Endian, `0` = 8-Bit Signed PCM).
* **Bit 1 (`CTRL_ONESHOT`):** Loop-Modus (`1` = One-Shot Buffer, stoppt bei Pufferende; `0` = Endlos-Loop).
* **Bit 2 (`CTRL_STEREO`):** Kanal-Modus (`1` = Interleaved Stereo: Wort 0 Links, Wort 1 Rechts; `0` = Mono).
* **Bit 3 (`CTRL_ADPCM`):** Hardware-Dekompression (`1` = ADPCM aktiviert, `0` = Linear PCM).
* **Bits 5..4:** ADPCM Hybrid-Modus (`00` = 4-Bit Standard, `01` = 2-Bit, `10` = 5-Bit Hybrid).
* **Bit 7 (`CTRL_FLT_R`):** Biquad IIR Filter Rechter Kanal (`1` = Aktiv, `0` = Bypass).
* **Bit 8 (`CTRL_FLT_L`):** Biquad IIR Filter Linker Kanal (`1` = Aktiv, `0` = Bypass).
* **Bits 8..7 (`CTRL_FLT_STEREO` = `11`):** Stereo Biquad IIR DSP-Filter auf beiden Kanälen aktiv.
* **Bits 10..9 (`v_input_src`):** Signalquelle der Stimme:
  * `00`: **DMA / FIFO** – Normaler Sample-Betrieb aus dem RAM.
  * `01`: **Pre-Filter Kaskade** – Ungefiltertes Signal von Stimme $N-1$.
  * `10`: **Post-Filter Kaskade** – Gefiltertes Ausgangssignal von Stimme $N-1$ (Moog 24 dB Kaskade!).
* **Bits 12..11 (`v_mod_mode`):** Hardware-Modulation:
  * `00`: Keine Modulation.
  * `01`: **AM / Tremolo** – Stimme $N-1$ moduliert die Amplitude von Stimme $N$.
  * `10`: **Ringmodulation** – Bipolares Vier-Quadranten-Produkt zwischen Träger $N$ und Modulator $N-1$.
* **Bit 13 (`v_mute_mix`):** Stummschaltung im Master-Mix (`1` = Mute, Stimme wird nur als Kaskaden- oder Modulationsquelle genutzt).

---

### Erweiterte System- und Video-Register (`$DFF800 .. $DFF80A`)

| Adresse | Register | Zugriff | Beschreibung |
| :--- | :--- | :---: | :--- |
| **`$DFF800`** | **`HAM_CONTROL`** | R/W | **Extended HAM Video Pipeline Steuerregister** (s. Kap. 7) |
| **`$DFF802`** | **`CAP_CTRL`**    | R/W | **Audio Capture Steuer- & Statusregister** (s. Kap. 6) |
| **`$DFF804`** | `AUDINTENAH`      | R/W | Audio Interrupt Enable Bits 31..16 (Stimmen 31..16) |
| **`$DFF806`** | `AUDINTENAL`      | R/W | Audio Interrupt Enable Bits 15..0  (Stimmen 15..0) |
| **`$DFF808`** | `AUDINTREQH`      | R/W | Audio Interrupt Request / W1C Bits 31..16 |
| **`$DFF80A`** | `AUDINTREQL`      | R/W | Audio Interrupt Request / W1C Bits 15..0 |

---

## 5. Kaskaden-Routing & Signalquellen

Über `AUDxCTRL[10:9]` (`v_input_src`) wird bestimmt, woher die Stimme ihr Eingangssignal bezieht:

* `00`: **DMA / FIFO** – Normaler Sample-Betrieb aus dem RAM.
* `01`: **Pre-Filter der Vorstufe ($N-1$)** – Ungefiltertes Signal der vorherigen Stimme.
* `10`: **Post-Filter der Vorstufe ($N-1$)** – Durch das Biquad gefiltertes Ausgangssignal der vorherigen Stimme.
* `11`: Reserviert.

> **Regel für Kaskaden:**  
> Bei Stufen $1 \dots 31$ muss `AUDxLEN = 0` konfiguriert werden, da diese Stufen ihr Signal aus der Kette beziehen und keine eigene DMA anfordern dürfen!

---

## 6. Hardware Audio-Capture & Live-Visualizer Engine ([`audio_capture.v`](file:///D:/programmier_ordner/FPGA/NanoMig/mister/rtl/audio_capture.v))

Die Audio-Capture-Einheit ermöglicht das latenzfreie Rücklesen der gemischten 16-Bit 48-kHz Stereo-Ausgabe im laufenden Betrieb, ohne DMA-Bandbreite zu verbrauchen oder den Systembus zu belasten.

### Speicherbereiche (8 KB Gesamtbereich):
* **Block A:** `$DF8000 .. $DF8FFF` (4096 Bytes = 1024 Stereo-Samplepaare: 16-Bit Links / 16-Bit Rechts interleaved).
* **Block B:** `$DF9000 .. $DF9FFF` (4096 Bytes = 1024 Stereo-Samplepaare: 16-Bit Links / 16-Bit Rechts interleaved).
* **Datenformat:** Wort 0 = Left 0, Wort 1 = Right 0, Wort 2 = Left 1, etc. Ein einzelnes `MOVE.L ($DF8000), D0` liest ein kohärentes 32-Bit Stereopaar!

### Steuer- und Statusregister `CAP_CTRL` (`$DFF802`):
* **Bit 0 (`CAPTURE_EN`):** Aufnahme aktivieren (`1` = Capture läuft, `0` = Angehalten).
* **Bit 1 (`FLAG_BLOCK_A`):** Block A voll / bereit zum Lesen (Write-1-to-Clear durch CPU).
* **Bit 2 (`FLAG_BLOCK_B`):** Block B voll / bereit zum Lesen (Write-1-to-Clear durch CPU).
* **Bit 3 (`ACTIVE_BLOCK`):** Aktuell beschriebener Block (`0` = Hardware schreibt Block A, `1` = Block B).
* **Bit 4 (`OVERRUN_FLAG`):** Hardware-Backpressure aktiv (`1` = Hardware pausiert, da Zielblock noch nicht quittiert war; verhindert Datenüberschreibung).
* **Bit 5 (`IRQ_EN`):** Interrupt aktivieren (`1` = Löst Level-2 INT2 aus, wenn ein Block gefüllt ist).
* **Bits 15..6 (`SAMPLE_POS`):** Aktuelle Schreibposition der Hardware (0..1023 Samplepaare).

> [!TIP]
> **Live-Visualizer / Color-Scope im Demo:**
> Ein Demo kann jederzeit in der VBlank- oder Rasterzeilen-Routine direkt die aktuellen Samples aus `$DF8000` auslesen (z. B. `MOVE.W ($DF8000), D0`) und damit Copper-Balken, Farbpaletten oder Partikeleffekte synchron im Beat der Musik tanzen lassen!

---

## 7. Extended HAM Video Pipeline ([`ham_video_pipeline.v`](file:///D:/programmier_ordner/FPGA/NanoMig/mister/rtl/ham_video_pipeline.v))

Die Extended-HAM-Engine revolutioniert die klassische Amiga Hold-And-Modify-Grafik. Sie bietet **echtes 24-Bit TrueColor** mit differentieller RGB-Sättigungsarithmetik bei drastisch reduzierter Bitplane-Zahl.

### Hardware-Steuerregister: `HAM_CONTROL` (`$DFF800`)

Das Register ist schattiert (`ham_control_shadow`) und wird taktgenau an der Bildwechselflanke (`sof` / Start of Frame) aktiv geschaltet:

| Bits | Feld | Standard | Funktion |
| :---: | :--- | :---: | :--- |
| `15` | `EXT_ENABLE` | `0` | **Extended HAM aktivieren** (`1` = Aktiv, `0` = Normales AGA/OCS-Video) |
| `14..10` | `STEP_R` | `4` | Differentieller Schrittwert Rot ($0 \dots 31$) |
| `9..5` | `STEP_G` | `4` | Differentieller Schrittwert Grün ($0 \dots 31$) |
| `4..0` | `STEP_B` | `4` | Differentieller Schrittwert Blau ($0 \dots 31$) |

* **Reset-Wert:** `$1084` (Bit 15 = 0, Step R = 4, Step G = 4, Step B = 4).
* **Aktivierung:** `MOVE.W #$8000 | (step_r<<10) | (step_g<<5) | step_b, $DFF800` (z. B. `$9084`).

### Unterstützte Bitplane-Modi

Die Engine greift automatisch je nach aktiver Bitplane-Anzahl (`ham_raw_bpu` aus `BPLCON0` / AGA):

| Modus | Bitplanes | Palette-Anchor | Delta-Modifikation | Besonderheiten |
| :---: | :---: | :--- | :--- | :--- |
| **HAM03** | **3** | Wenn `code[2] == 0`: CLUT Index 0..3 | Wenn `code[2] == 1`: Simultaner $\pm 2$ Schritt auf R, G, B | Extrem sparsam: **Nur 3 Bitplanes** für 24-Bit Verläufe! |
| **HAM04** | **4** | Wenn `code[3] == 0`: CLUT Index 0..7 | Wenn `code[3] == 1`: Unabhängiger $\pm 2$ Schritt auf R, G und B | Volle 3-Achsen-Farbwanderung bei nur 4 Planes |
| **HAM05** | **5** | Wenn `code[4] == 0`: CLUT Index 0..15 | Wenn `code[4] == 1`: $\pm 1$ Schritt + **Turbo-Bit** (`code[3]` = $4\times$) | Turbo-Sprünge für scharfe Farbkanten |
| **HAM06** | **6** | Wenn `code[5] == 0`: CLUT Index 0..31 | Wenn `code[5] == 1`: R ($\pm 1$), G (4 Stufen: $-2,-1,+1,+2$), B ($\pm 1$) + Turbo | Feinste Grün-Nuancen (höchste Augenempfindlichkeit) |
| **HAM08** | **8** | Wenn `code[7] == 0`: CLUT Index 0..127 | Wenn `code[7] == 1`: R, G, B je 4 Stufen ($-2,-1,+1,+2$) + Turbo | Maximaler 24-Bit TrueColor Farbraum |

### Differentielles Berechnungsprinzip ([`ham_pixel_decoder.v`](file:///D:/programmier_ordner/FPGA/NanoMig/mister/rtl/ham_pixel_decoder.v))

1. **Startzustand:** Am Bildanfang (`frame_start`) initialisiert sich der RGB-Akkumulator auf neutrales Grau (`$7F7F7F` = 127, 127, 127).
2. **Anchor-Pixel (`anchor = 1`):** Das Pixel wird unverändert aus der Standard-AGA-Farbpalette geladen und setzt den Akkumulator auf die exakte Palettenfarbe.
3. **Delta-Pixel (`anchor = 0`):** Das Pixel modifiziert die bisherige Akkumulatorfarbe:
   $$\text{Farbe}_{\text{neu}} = \text{Clamp}_{0..255}\left(\text{Farbe}_{\text{alt}} + \text{Level} \times \text{Step} \times (\text{Turbo} ? 4 : 1)\right)$$
   Die Addition ist hardwaremäßig geclamped (Sättigung zwischen 0 und 255 ohne arithmetischen Überlauf).
4. **Auflösungen:** Unterstützt Lowres, Hires und SuperHires (bis zu $1280 \times 512$ oder $1432 \times 570$ PAL-Overscan mit `FMODE=3`).

---

## 8. Demo-Leitfaden: Maximale Ausnutzung von HAM & Audio

Für moderne Demos bietet die Kombination aus Extended-HAM und 32-Kanal Audio enorme Synergien:

1. **Bandbreiten-Vorteil:**
   * Klassische Demos kämpfen um DMA-Zyklen zwischen Bitplanes und Audio.
   * **Hier:** Audio-Samples liegen im Fast-RAM und belasten den Chip-Bus mit **0%**!
   * **HAM03 / HAM04** benötigt nur 3 bzw. 4 Bitplanes für fotorealistische 24-Bit-Gradients – dadurch verbleiben über **50% freie Chip-RAM-Bandbreite** für Blitter, Copper und CPU!
2. **Dynamische Copper-Modulation von HAM:**
   * Die Copper-List kann `$DFF800` zeilenweise manipulieren! Ändert man z. B. `STEP_R`, `STEP_G`, `STEP_B` über den Bildschirm, entstehen dynamische Plasmen, Chrom-Reflexionen und Sonnenuntergangs-Verläufe ohne ein einziges Bitplane-Byte neu zu berechnen.
3. **Hardware-Synthesizer & Filter-Sweeps:**
   * Anstelle vorgerenderter 8-Bit-Tracker-Samples nutzt das Demo schlanke Einzelwellenformen (Sinus, Sägezahn) und moduliert Cutoff (`AUDxB0..AUDxA2`) und Lautstärke pro Frame in Software.
   * 24 dB Moog-Filter (Kanal 0 $\rightarrow$ Kanal 1) für analoge Synth-Bässe.
   * AM / Ringmodulation (Kanal 2 $\times$ Kanal 3) für metallische FM-Leads und Glockenklänge.
4. **Geschlossene Audio-Video-Kopplung (Colorscope):**
   * Die CPU liest in jedem VBlank die aktuellen Werte aus dem Audio-Capture-Puffer (`$DF8000`) und schreibt sie in den Hintergrund-Farb- oder Copper-Modulator. Das Bild pulsiert exakt im Bassschlag der Musik.
