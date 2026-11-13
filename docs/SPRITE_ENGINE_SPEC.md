# Architektur- und Design-Spezifikation: 32/64-Bit HAM-, HighColor-, ARGB- & CLUT-Sprite-Engine (Rev. 4 – HAM12/16, RGB16, ARGB8888, Alpha-Blending, FullHD 2048px)

**Status:** Spezifikation mit verbindlichen Hardware-Verträgen nach Review #10 durch Tobys KI (`toby01019`) (kein RTL-Code erzeugt)  
**Zielplattform:** MiSTer FPGA (Cyclone V `5CSEBA6U23I7`), Minimig-AGA / Denise-Erweiterung  
**Descriptor-Revision:** `DESC_REV = 4` (Verbindlicher Hardware- & Software-Vertrag, 16 Bytes / Descriptor)

---

## 1. Überblick & Kernidee

Die Sprite-Engine kombiniert **variable HAM-Modi (`HAM04`, `HAM06`, `HAM08`, `HAM12`, `HAM16`)**, **16-Bit Direct HighColor (`RGB565`)**, **32-Bit Direct TrueColor (`ARGB8888`)**, **4 Hardware-Blend-Modi (Opak, Additiv, 50/50, 8-Bit Alpha)** sowie **8 direkte Palettenmodi (CLUT 1..8 Bit)** mit einer **FullHD-fähigen `2048`-Pixel Ping-Pong-Zeilenbuffer-Architektur**, einem **eigenen dedizierten High-Speed-Decoder** und direktem **64-Bit-Burst-DMA-Zugriff (`BURSTCNT = 4`) auf das DDR3-Fast-RAM**.

1. **Eigener dedizierter Sprite-HAM/HighColor/CLUT-Decoder (volle Geschwindigkeit):**
   * Die Sprite-Engine besitzt ihren **eigenen `ham_pixel_decoder`** sowie eine **eigene 256×24-Bit-Sprite-Palette (M10K)**.
   * Darüber hinaus arbeiten **`HAM12`**, **`HAM16`**, **`RGB16`** und **`ARGB32`** mit direkten RGB-Farben im Bitstream und damit auf Wunsch **zu 100 % palettenfrei**.
   * Dadurch arbeitet die Sprite-Engine zu **100 % unabhängig vom Playfield-HAM (`ext_ham`)** und kann über die gesamte Zeilenzeit ohne jede Unterbrechung mit voller Geschwindigkeit rendern.
2. **Konstanter 256-Bit-Burst-Speicherzugriff (`4 × 64 Bit`) trotz variabler Pixeldichte:**
   * Die minimale Breite und das Zeilen-Raster eines Sprites im RAM beträgt **`4 × 64 Bit = 256 Bit` (32 Bytes = 8 × 32-Bit-Blöcke)**.
   * Dies entspricht exakt einem physischen **DDR3-BL8-Burst (`BURSTCNT = 4`)** auf dem MiSTer. Jeder Burst-Zugriff liefert in 4 aufeinanderfolgenden `clk_114`-Takten **8 bis 64 Pixel auf einen Schlag** (und beim Lesen der Descriptor-Liste gleich **2 komplette 16-Byte-Descriptoren** auf einmal!).
   * **Hardware Zero-Word-Skip (100 % bit-identisch):** Ist ein 64-Bit-Wort innerhalb des 256-Bit-Bursts komplett `0` (`64'h00000000_00000000` = lauter transparente `raw_code == 0`-Pixel) und steht kein Zoom sowie kein opakes Vorgängerpixel (`prev_opaque == 0`) an, setzt der Entpacker den HAM-Akkumulator auf `0`, addiert die Pixelanzahl (`2..16` je nach Format) direkt auf `dst_x` (bzw. subtrahiert bei `H_FLIP`) und überspringt das gesamte 64-Bit-Wort in **einem einzigen Takt**!
3. **Zwei FullHD-fähige `2048`-Pixel-Zeilenbuffer im Wechsel (Ping-Pong + deterministisches Clear):**
   * Beide Zeilenbuffer (A und B) umfassen **`2048 × 32 Bit`** (`16 M10K` gesamt) und unterstützen damit alle Auflösungen von Lores (`320 px`) über SuperHiRes-Overscan (`1432 px`) bis hin zu **FullHD (`1920 × 1080` / `2048 px`)**.
   * Während **Zeilenbuffer A** synchron zum Videostrahl am Ausgang von Denise ausgelesen, mit dem fertigen 24-Bit-Amiga-Bild gemischt und deterministisch über alle `0..2047` Spalten auf `0` gelöscht wird,
   * rendert die Sprite-Engine im Hintergrund die nächste Bildschirmzeile (`next_y`) in **Zeilenbuffer B** (inkl. **1-Takt-Write-Forwarding** für aufeinanderfolgende Schreibzugriffe auf dieselbe Spalte `dst_x`).
4. **Y-sortierte Descriptor-Liste im Fast-RAM (bis zu `4.096` Descriptoren):**
   * Der Engine wird über ein VBlank-gepuffertes Register (`SPR_LIST_PTR` bei `$DFF580` / `$DFF582`) ein 32-Bit-Zeiger auf ein nach **`Y_POS` aufsteigend sortiertes Array** übergeben.
   * Sobald beim Scannen der Liste ein Eintrag mit `Y_POS > next_y` oder das Sentinel `HEIGHT == 0` erreicht wird, bricht die Engine die Suche für diese Zeile sofort ab (**Early Exit**).
5. **Freies Positionieren, X/Y-Skalierung, 24-Bit-Interpolation & Hardware-Clipping:**
   * Sprites können an beliebigen negativen oder positiven Koordinaten (`int16 X_POS`, `int16 Y_POS`, ausgewertet als `int13` `-4096..+4095`) außerhalb des Bildschirms starten und enden, in 2er-Potenzen skaliert (`X_SCALE`, `Y_SCALE`: 1x, 2x, 4x, 1/2, 1/4), gespiegelt (`H_FLIP`, `V_FLIP`) und per 24-Bit-Subpixel-Filterung (`SMOOTH_X`) geglättet werden.
6. **Hardware Alpha-Blending & 24/32-Bit Hintergrund/Tile-Compositing:**
   * **4 Hardware-Blend-Modi (`BLEND_MODE[1:0]`):** `00` Normal/Opak, `01` Additiv ($\min(255, S + D)$ für Triebwerksfeuer/Laser), `10` 50/50 Translucent ($(S + D) \gg 1$ für Kanzelglas/Rauch), `11` Full 8-Bit Alpha ($D + \frac{\alpha \cdot (S - D)}{256}$).
   * **32-Bit Direct TrueColor (`FORMAT 16 ARGB8888`):** Unkomprimierte Kacheln, Tiles und Hintergrundbilder (1 Pixel pro 32 Bit, 8 px/Burst) sowie Sprites mit eigenem Per-Pixel-Alpha (`code[31:24]`).
   * **Hintergrund-Modus (Layer `00`):** Descriptoren mit `PRIO 1..63` rendern hinter allen Bitplanes und vor Amiga `COLOR00`. Zusammen mit negativen Offsets (`X_POS`, `Y_POS`) ermöglicht dies ruckelfreies Hardware-Scrolling ganzer 24/32-Bit-Hintergründe ohne CPU-/Chipset-Belastung.

---

## 2. Dedizierter High-Speed HAM-Decoder & Verbreiterte Vorberechnungs-Arithmetik

### 2.1 Warum ein eigener Decoder für die Sprite-Engine gesetzt ist
* Würde sich die Sprite-Engine den Decoder mit dem Playfield (`ext_ham`) teilen, wäre der Decoder bei aktivem SuperHiRes-HAM-Playfield (1280 px) oder FullHD für den Großteil der Zeile durch das Playfield blockiert.
* Mit einem **eigenen dedizierten Decoder** (~100 ALMs) + eigener Paletten-RAM-Instanz (1 M10K) stehen der Sprite-Engine **100 % der Zeilenzeit (volle 64 µs)** ungeteilt zur Verfügung.

### 2.2 Pipeline-Optimierung & Feste Hardware-Schrittweite (Schritt = 4)
In `c0_ham_from_setup.rpt` (Slow 1100mV 100C) hatte der bisherige Playfield-Decoder (`ham_pixel_decoder.v`) eine kombinatorische Laufzeit von **`14,774 ns`**, weil Bit-Decode, `turbo`-Shift, Delta-Mux und die Addition `accumulator + delta` im selben Takt stattfanden.

* **Entscheidende Vereinfachung (Revision 4):** Die HAM-Deltaschrittweite ist **global fest in Hardware auf `4` verdrahtet** ($2^2 = 4$, exakte 6-Bit-Quantisierung im 8-Bit-RGB-Raum $256/64 = 4$).
  * Das Custom-Register **`$DFF58C` (`SPR_STEP_RGB`) entfällt komplett**.
  * Die `CUSTOM_STEP`-Multiplikatoren im Deskriptor entfallen komplett.
  * In Hardware bedeutet die Multiplikation mit `4` einen reinen **Bit-Shift um 2 Positionen (`<< 2`)** – es sind keinerlei Multiplizierer in Stufe 1 mehr erforderlich!
* **Maximale Delta-Spanne über alle Modi (`HAM04..16`):**
  * `HAM04..08` (`level ∈ {-2, -1, +1, +2}`, `turbo ∈ {1, 4}`): `|delta| <= 4 × 4 × 2 = 32`.
  * `HAM12` (`dr, db ∈ [-4..+3]`, `dg ∈ [-8..+7]`, `turbo ∈ {1, 4}`): `delta_g ∈ [-8 × 4 × 4 .. +7 × 4 × 4] = [-128 .. +112]`.
  * `HAM16` (`dr ∈ [-8..+7]`, `dg, db ∈ [-16..+15]`, `turbo ∈ {1, 4}`): `delta_g, delta_b ∈ [-16 × 4 × 4 .. +15 × 4 × 4] = [-256 .. +240]`.
  * Alle vorberechneten Deltas passen überlauffrei in **10 Bit signed (`-512 .. +511`)**, und die Addition `acc + delta` im Rekursions-Zyklus benötigt **11 Bit signed** vor der Sättigung auf `0..255` (`uint8`).
* **2-Stufen-Aufteilung (ohne Zusatzlatenz, parallel zum Paletten-BRAM-Read):**
  1. **Stufe 1 (Entpacker & Paletten-Read-Takt):**  
     Parallel zum synchronen Lesezugriff auf das M10K-Paletten-RAM (`palette_index = (PAL_OFFSET + raw_code) & 8'hFF`) berechnet die Logik bereits `anchor_reg`, `direct_anchor_reg` (für `HAM12`/`HAM16`/`RGB16`/`ARGB32`), `direct_rgb_reg[23:0]`, `alpha_reg[7:0]`, `opaque_reg = (raw_code != 0)` sowie die fertigen Summanden `delta_r`, `delta_g`, `delta_b` per Shift (`<< 2` bzw. `<< 4` bei Turbo) und speichert sie in Registern.
  2. **Stufe 2 (Akkumulator-Takt):**  
     Im eigentlichen Rekursions-Zyklus wählt der Anker-Mux `anchor_rgb = direct_anchor_reg ? direct_rgb_reg : palette_data`, und der Decoder führt **nur noch eine einzige 11-Bit-Addition mit Sättigung auf `0..255`** aus:
     $$\text{acc\_next} = (\neg\text{opaque\_reg}) \;?\; \text{24'h000000} : \big(\text{anchor\_reg} \;?\; \text{anchor\_rgb} : \text{sat}_{0..255}(\text{acc} + \text{delta\_reg})\big)$$
* **Pipeline-Steuerung (`valid`, `decoder_hold`, `line_reset`):**
  * Zu Beginn jeder neuen Sprite-Quellzeile (`line_reset = 1`) werden `acc_r/g/b <= 0`, `prev_rgb <= 0`, `prev_opaque <= 0` sowie die Pipeline-Valid-Stufen synchron zurückgesetzt.
  * Ist `decoder_hold == 1` (während der `X_SCALE`-Interpolator bei Vergrößerung Zwischenspalten ausschreibt), frieren alle Decoder-Stufen und `acc_r/g/b` taktsynchron ein.

---

## 3. Die 17 festgelegten 256-Bit-Burst-Formate (CLUT 1..8 Bit, HAM, RGB16, ARGB32)

Die minimale Sprite-Breite (und das Zeilen-Raster) im RAM ist auf **`4 × 64 Bit = 256 Bit` (32 Bytes)** festgelegt.  
Dadurch nutzt jeder DMA-Lesezugriff mit **`BURSTCNT = 4`** den physischen **DDR3-BL8-Burst** (32-Bit DDR3 × 8 = 256 Bit) zu **100 %** aus und liefert in 4 aufeinanderfolgenden `clk_114`-Takten **8 bis 256 Pixel auf einen Schlag**:

| `FORMAT` | Name im Konverter | Typ / Modus | Pixel / 256-Bit-Burst | Füllbits am Ende des Bursts (LSB) |
| :---: | :--- | :--- | :---: | :--- |
| **`0`** | `FMT_CLUT01` | 1-Bit CLUT (2 Farben) | **256 px** | **0 Füllbits** |
| **`1`** | `FMT_CLUT02` | 2-Bit CLUT (4 Farben) | **128 px** | **0 Füllbits** |
| **`2`** | `FMT_CLUT03` | 3-Bit CLUT (8 Farben) | **85 px** | **1 Füllbit** (`Bit [0]`) |
| **`3`** | `FMT_CLUT04` | 4-Bit CLUT (16 Farben) | **64 px** | **0 Füllbits** |
| **`4`** | `FMT_CLUT05` | 5-Bit CLUT (32 Farben) | **51 px** | **1 Füllbit** (`Bit [0]`) |
| **`5`** | `FMT_CLUT06` | 6-Bit CLUT (64 Farben / EHB) | **42 px** | **4 Füllbits** (`Bits [3:0]`) |
| **`6`** | `FMT_CLUT07` | 7-Bit CLUT (128 Farben) | **36 px** | **4 Füllbits** (`Bits [3:0]`) |
| **`7`** | `FMT_CLUT08` | 8-Bit CLUT (256 Farben) | **32 px** | **0 Füllbits** |
| **`8`** | `FMT_HAM04_64` | HAM04 (`4-4-4-4...`) | **64 px** | **0 Füllbits** |
| **`9`** | `FMT_HAM06_03_64` | HAM06 (`6-3-4-3-6-3-4-3`) | **64 px** | **0 Füllbits** |
| **`10`** | `FMT_HAM08_32` | HAM08 (`8-8-8-8`) | **32 px** | **0 Füllbits** |
| **`11`** | `FMT_HAM12_12_686` | HAM12 (`12-6-8-6`) | **32 px** | **0 Füllbits** |
| **`12`** | `FMT_HAM12_12_5555` | HAM12 (`12-5-5-5-5`) | **40 px** | **0 Füllbits** |
| **`13`** | `FMT_HAM16_12X4` | HAM16 (`16-12-12-12-12`) | **20 px** | **0 Füllbits** |
| **`14`** | `FMT_HAM16_DIRECT` | Reines HAM16 (`16-16`) | **16 px** | **0 Füllbits** |
| **`15`** | `FMT_RGB16` | Direct HighColor (`RGB565` / `RGB555`) | **16 px** | **0 Füllbits** |
| **`16`** | `FMT_ARGB32` | Direct TrueColor (`ARGB8888` mit Alpha) | **8 px** | **0 Füllbits** |
| **`17`** | `FMT_HAM12_5D` | `HAM12 12_5555_DELTA` (`ham5delta`) | **40 px** | **0 Füllbits** |
| **`18`** | `FMT_HAM12_686_D` | `HAM12 12_686_DELTA` (`ham6delta/ham8delta`) | **32 px** | **0 Füllbits** |
| **`19`** | `FMT_HAM08_D` | `HAM08_DELTA` (`ham8delta` Turboturbo) | **32 px** | **0 Füllbits** |

*(Werte `FORMAT >= 20` sind als ungültig/Reserve definiert und führen zum deterministischen Überspringen des Sprites ohne DMA-Zugriff).*

### 3.1 Exakte Bit-Definition der erweiterten Formate (`HAM12`, `HAM16`, `RGB16`, `ARGB32`)

1. **`HAM12 12_686` (`FORMAT 11`) & `HAM12 12_5555` (`FORMAT 12`):**
   * **`code == 0`:** Transparent (`pix_opaque = 0`, setzt `acc_r/g/b <= 24'h000000`).
   * **`FORMAT 11` (`HAM12 12_686`):** 12-Bit Anker gefolgt von 6-Bit, 8-Bit und 6-Bit HAM-Pixeln (32 Pixel pro 256-Bit Burst).
   * **`FORMAT 12` (`HAM12 12_5555`):** 12-Bit Anker gefolgt von vier 5-Bit-Palettenankern (40 Pixel pro 256-Bit Burst).
   * Für Palettenanker gilt: `slot = (code + pal_offset) & 0xFF`. Slot `0` ist transparent; jeder andere Slot ist opak (`pix_opaque = 1`).

2. **`HAM16 12x4` (`FORMAT 13`):**
   * **`code == 0`:** Transparent (`pix_opaque = 0`).
   * **Erstes Pixel (16 Bit):** Direktes 16-Bit **`RGB565`** als absoluter Anker:
     * `R = {code[15:11], 3'b000}`, `G = {code[10:5], 2'b00}`, `B = {code[4:0], 3'b000}`.
   * **Folgende vier Pixel (je 12 Bit):** 12-Bit Zweierkomplement-Deltas (`dr_s4`, `dg_s4`, `db_s4` je 4 Bit `[-8..+7]` mit festem Hardware-Schritt `4`):
     * `dr_s4 = signed(code[11:8])`, `dg_s4 = signed(code[7:4])`, `db_s4 = signed(code[3:0])`.
     * `R = clamp(acc_r + dr_s4 * 4)`, `G = clamp(acc_g + dg_s4 * 4)`, `B = clamp(acc_b + db_s4 * 4)`.

3. **`HAM16 Direct` (`FORMAT 14`, 16 Bit pro Pixel, palettenfrei):**
   * **`code == 16'h0000`:** Transparent (`pix_opaque = 0`, setzt `acc_r/g/b <= 24'h000000`).
   * **`code[15:14] == 2'b00` (Palette / Direkter Farbwechsel):** Palettenanker oder direkte Farberneuerung.
   * **`code[15:14] == 2'b01` (Blue Delta / Anker):** `acc_b` wird neu gesetzt oder modifiziert.
   * **`code[15:14] == 2'b10` (Red Delta / Anker):**
     * `dr_s4 = (code >> 10) & 0xF`; falls `dr_s4 >= 8: dr_s4 -= 16`.
     * Delta-Modus: `acc_r = clamp(acc_r + dr_s4 * 4)`.
     * *(Hinweis: `code == 16'h8000` nach Reset oder transparentem Pixel erzeugt `acc_r = 0` mit `acc_g = acc_b = 0`, also echtes opakes Tiefschwarz `24'h000000`!)*.
   * **`code[15:14] == 2'b11` (Green Delta / Anker):** `acc_g` wird neu gesetzt oder modifiziert.

4. **`RGB16 Direct` (`FORMAT 15`, 16-Bit HighColor ohne HAM, palettenfrei):**
   * **`code == 16'h0000`:** Transparent (`pix_opaque = 0`, Zeilenbuffer-Schreibzugriff gesperrt).
   * **`code != 16'h0000`:** Direktes 16-Bit **`RGB565`** (`pix_opaque = 1`):
     * `R = {code[15:11], 3'b000}`, `G = {code[10:5], 2'b00}`, `B = {code[4:0], 3'b000}`.
     * *(Wichtig: `code == 16'h8000` stellt im RGB565-Format Dunkelrot `24'h800000` dar (`R=128, G=0, B=0`), transparent ist ausschließlich `16'h0000`!)*.

5. **`ARGB32 Direct` (`FORMAT 16`, 32 Bit pro Pixel TrueColor mit Alpha):**
   * **`code == 32'h0000_0000` oder `code[31:24] == 0`:** Transparent (`pix_opaque = 0`, Zeilenbuffer-Schreibzugriff unterdrückt, Priorität und Hintergrundfarbe bleiben unberührt).
   * **`code != 0`:** Direktes 32-Bit TrueColor (`pix_opaque = 1`):
     * `Alpha = code[31:24]` (`0 .. 255`, Per-Pixel-Alpha für `BLEND_MODE = 11`)
     * `R = code[23:16]` (`0 .. 255`)
     * `G = code[15:8]` (`0 .. 255`)
     * `B = code[7:0]` (`0 .. 255`)
   * **Packung:** 1 Pixel pro 32-Bit-Langwort, 2 Pixel pro 64-Bit DDR3-Wort, **8 Pixel pro 256-Bit Burst**.
   * **Einsatzbereich:** Unkomprimierte Kacheln, 24/32-Bit-Hintergrundbilder, RTG-Overlays und Sprites mit stufenlosem 8-Bit Per-Pixel-Alpha.

6. **Verbindlicher Vertrag zur Linksshift-Sättigung & Schwarz-Semantik:**
   * **Linksshift:** `RGB565` wird im FPGA gezielt per fester Linksverschiebung auf 8 Bit erweitert (`<< 3` für 5-Bit-Kanäle $\to$ Maximum 248; `<< 2` für 6-Bit-Grün $\to$ Maximum 252). Dies spart DSP-Blöcke und hält den Taktweg unter 3,5 ns. Konverter oder Software-Pipelines, die exakt 255 benötigen, können im Quellbild das obere Bitmuster spiegeln (`(c << 3) | (c >> 2)`), in der Hardware gilt verbindlich der reine Linksshift.
   * **Opaque Schwarz vs. Transparenz:**
     * In allen Paletten-Formaten (`FORMAT 0..7, 11, 12`): Index `0` ist transparent (`opaque = 0`). Palettenslots mit Farbwert `24'h000000` bei Index `!= 0` sind opak (`opaque = 1`).
     * `HAM16 Direct` (`FORMAT 14`): Code `16'h8000` nach Reset ist **opakes Tiefschwarz** (`opaque = 1`, `acc = 24'h000000`).
     * `RGB16 Direct` (`FORMAT 15`): Code `16'h0000` ist transparent. Opakes Schwarz wird z.B. als Fast-Black `16'h0020` oder über Blend-Modus/Palette erzeugt. Code `16'h8000` ist Dunkelrot (`128, 0, 0`).


### 3.2 Die neuen reinen HAM-Delta-Modi (`ham5delta`, `ham6delta`, `ham8delta`)

In reinen Delta-Streams nach einem 12-Bit RGB444-Direktanker entfällt das Anker-Bit (`anchor`). Dadurch stehen alle Bits für präzise Farb-Deltas und mehrstufige Turbo-Schritte zur Verfügung:

1. **`ham5delta` (5 Bit pro Pixel, genutzt in `FORMAT 17` `HAM12 12_5555_DELTA`):**
   * **Bit `[4]` (Turbo):** `0` = $4\times$ (Standard-Schritt), `1` = $16\times$ (Super-Turbo).
   * **Bit `[3]` (`dr`):** 1 Bit für Rot ($1 = +1, 0 = -1$).
   * **Bits `[2:1]` (`dg`):** 2 Bits für Grün (`two_delta`: `00` = -2, `01` = -1, `10` = +1, `11` = +2).
   * **Bit `[0]` (`db`):** 1 Bit für Blau ($1 = +1, 0 = -1$).
   * Entspricht exakt der Farbauflösung des vollen `HAM06` im Delta-Modus ohne Anker-Overhead!

2. **`ham6delta` (6 Bit pro Pixel, genutzt in `FORMAT 18` `HAM12 12_686_DELTA`):**
   * **Bits `[5:4]` (2-Bit Turboturbo `turbo[1:0]`):**
     `00` = $1\times$ (Feinstufe), `01` = $4\times$ (Standard), `10` = $8\times$ (Turbo), `11` = $16\times$ (Super-Turbo).
   * **Bit `[3]` (`dr`):** 1 Bit für Rot ($1 = +1, 0 = -1$).
   * **Bits `[2:1]` (`dg`):** 2 Bits für Grün (`two_delta`: -2, -1, +1, +2).
   * **Bit `[0]` (`db`):** 1 Bit für Blau ($1 = +1, 0 = -1$).

3. **`ham8delta` (8 Bit pro Pixel, genutzt in `FORMAT 18` und `FORMAT 19` `HAM08_DELTA`):**
   * **Bits `[7:6]` (2-Bit Turboturbo `turbo[1:0]`):**
     `00` = $1\times$, `01` = $4\times$, `10` = $8\times$, `11` = $16\times$.
   * **Bits `[5:4]` (`dr`):** 2 Bits für Rot (`two_delta`: -2, -1, +1, +2).
   * **Bits `[3:2]` (`dg`):** 2 Bits für Grün (`two_delta`: -2, -1, +1, +2).
   * **Bits `[1:0]` (`db`):** 2 Bits für Blau (`two_delta`: -2, -1, +1, +2).
   * Ermöglicht 4-stufige Turbosprünge bei gleichzeitiger 2-Bit-Präzision auf allen 3 Farbkanälen.

---

## 4. Verbindliche Transparenz-Semantik (`opaque`-Bit statt `RGB == 0`)

Auf Empfehlung aus dem Architektur-Review wird **Transparenz strikt von der 24-Bit-RGB-Farbe getrennt** und als eigenes **`opaque`-Bit** durch Decoder, Skalierer und `SMOOTH_X`-Interpolator geführt:

1. **Entstehung des `opaque`-Bits am Entpacker-Eingang (vor `PAL_OFFSET`):**
   * Ein entpacktes Quellpixel ist **genau dann transparent (`pix_opaque = 0`)**, wenn sein lokaler gepackter Code im Bitstream **`raw_code == 0`** ist.
   * Ist **`raw_code != 0`** (egal ob HAM-Anker `1..N`, HAM-Delta `MSB == 1` oder CLUT-Index `1..255`), ist das Pixel **immer opak (`pix_opaque = 1`)**!
2. **Verhalten bei `raw_code == 0` (Transparent):**
   * `pix_opaque = 0`: Das Pixel wird später **nicht** in den Zeilenbuffer geschrieben.
   * Gleichzeitig setzt der HAM-Akkumulator `acc_r/g/b <= 24'h000000`. Damit wirkt jedes transparente Pixel automatisch als definierter **Reset-Anker (`000000`)** für nachfolgende Delta-Pixel (wichtig nach transparenten Lücken innerhalb eines Sprites!).
3. **Echtes opakes Schwarz (`24'h000000`) & Keine Löcher nach `SMOOTH_X`-Interpolation:**
   * Da `pix_opaque` separat mitgeführt wird, benötigt die Engine **keinen Near-Black-Clamp (`000001`)** mehr: Ein opaker Anker oder ein Delta-Pixel darf exakt `24'h000000` (echtes Tiefschwarz) annehmen und bleibt trotzdem zu 100 % opak (`pix_opaque = 1`).
   * Wenn zwei dunkle opake Pixel wie `(0, 0, 1)` und `(0, 1, 0)` im `SMOOTH_X`-Interpolator gemittelt werden (`(P0 + P1) >> 1 = (0, 0, 0)`), bleibt `out_opaque = 1 & 1 = 1` erhalten – **es kann niemals ein unbeabsichtigtes transparentes Loch entstehen!**
4. **Speicherung im Zeilenbuffer ohne Extra-BRAM-Bit:**
   * Im `2048 × 32 Bit`-Zeilenbuffer (`[31:24] BUF_PRIO`, `[23:0] BUF_RGB`) haben alle aktiven Sprites eine Priorität `SPR_PRIO >= 1`.
   * Ein gelöschter/transparenter Eintrag im Zeilenbuffer hat `BUF_PRIO == 8'h00`. Ein geschriebenes opakes Pixel schreibt `BUF_PRIO = SPR_PRIO` (`1..255`). Damit repräsentiert `BUF_PRIO != 8'h00` beim Auslesen verlustfrei das `opaque`-Bit!

---

## 5. FullHD-Zeilenbuffer (`2048 × 32 Bit`), Hardware Alpha-Blending & Denise-Komposition

### 5.1 Format im `2048`-Pixel Ping-Pong-Zeilenbuffer
Beide Ping-Pong-Zeilenbuffer (A und B) haben eine Tiefe von **2.048 Pixeln** und eine Breite von **32 Bit pro Pixel** (`16 M10K`-Blöcke gesamt):

$$\underbrace{\text{BUF\_PRIO [31:24]}}_{\text{8-Bit Priorität (`0` = leer)}} \;\Big|\; \underbrace{\text{R [23:16]} \;\cdot\; \text{G [15:8]} \;\cdot\; \text{B [7:0]}}_{\text{24-Bit RGB}}$$

* **1-Takt Write-Forwarding für Prioritäts- und Blending-Lesezugriff:**  
  Da das synchrone Lesen von `{OLD_PRIO, OLD_RGB}` aus dem M10K-Zeilenbuffer 1 Takt Latenz besitzt, hält die Schreibstufe ein Bypass-Register (`last_wr_valid`, `last_wr_x[10:0]`, `last_wr_prio[7:0]`, `last_wr_rgb[23:0]`).  
  Wird in zwei direkt aufeinanderfolgenden Takten dieselbe Zielspalte `dst_x == last_wr_x` adressiert, verwendet die Misch- und Prioritätslogik automatisch die Bypass-Registerwerte:
  $$\text{eff\_old\_prio} = (\text{last\_wr\_valid} \land (\text{dst\_x} == \text{last\_wr\_x})) \;?\; \text{last\_wr\_prio} : \text{ram\_old\_prio}$$
  $$\text{eff\_old\_rgb} = (\text{last\_wr\_valid} \land (\text{dst\_x} == \text{last\_wr\_x})) \;?\; \text{last\_wr\_rgb} : \text{ram\_old\_rgb}$$

* **Deterministisches Löschen (Clear-on-Read & Line-Switch Sweep):**  
  - Während Denise den aktiven Zeilenbuffer synchron zum Videostrahl mit `clk_sys` ausliest (`col = 0 .. CLIP_XMAX - 1`), wird jeder gelesene 32-Bit-Eintrag im selben Lesezyklus auf `32'h00000000` zurückgesetzt (**Clear-on-Read**).
  - Der über `CLIP_XMAX` hinausgehende Pufferbereich bis Spalte 2047 (sowie ungenutzte Pixel im Overscan/HBlank) wird beim Pufferwechsel (`line_sync`) durch einen synchronen Hardware-Sweep im schnellen `clk_114`-Taktbereich in der neu zu beschreibenden Bank deterministisch auf 0 gesetzt. Erst wenn dieser Sweep abgeschlossen ist (`clear_done_before_first_write = 1`), wird der erste Schreibzugriff der Sprite-Engine auf diese Zeile freigegeben. Dies garantiert auch bei dynamischer `CLIP_XMAX`-Vergrößerung absolute Artefaktfreiheit.

### 5.2 Die 4 Hardware-Blend-Modi (`BLEND_MODE[1:0]`)
Beim Schreiben in den Zeilenbuffer liest die Hardware die Zielfarbe $D = \{R_d, G_d, B_d\}$ und berechnet aus dem Quellpixel $S = \{R_s, G_s, B_s\}$ die Ausgabefarbe:

| `BLEND_MODE` | Modus | Formel für jeden Kanal | ALMs / DSPs | Typischer Anwendungsfall |
| :---: | :--- | :--- | :---: | :--- |
| **`00`** | **Normal / Opak** | $C_{\text{out}} = S$ | 0 ALMs | Standard-Sprites, HUD-Elemente, Kanten |
| **`01`** | **Additive Blending** | $C_{\text{out}} = \min(255, S + D)$ | ~15 ALMs, 0 DSPs | **Triebwerksflammen**, Laser, Explosionen |
| **`10`** | **50/50 Translucent** | $C_{\text{out}} = (S + D) \gg 1$ | ~8 ALMs, 0 DSPs | **Cockpit-Kanzelglas**, Schatten, Rauch |
| **`11`** | **Full 8-Bit Alpha** | $C_{\text{out}} = D + \lfloor \frac{\alpha \cdot (S - D)}{256} \rfloor$ | ~55 ALMs *(oder 1 DSP)* | **Stufenloses Ein-/Ausblenden**, Anti-Aliasing |

* **Verbindliche Semantik des Blending & Transparenz (Intra-Sprite Linebuffer Compositing):**
  * **Reichweite des Blending:** Das Hardware-Blending findet ausschließlich **intra-sprite** innerhalb des 32-Bit-Zeilenbuffers (`clk_114`) statt (Mischen von Vordergrund-Sprites mit bereits gerenderten Hintergrund-Sprites oder TrueColor-Kacheln). Der Zeilenbuffer speichert 24-Bit RGB und 8-Bit Priorität, aber kein Per-Pixel-Alpha.
  * **Transparenz-Semantik bei Alpha 0 (`BLEND_MODE == 11` und $\alpha == 0$):** Quellpixel mit effektivem Alpha von 0 sind vollständig transparent. Die Schreibstufe deaktiviert das Schreibsignal (**`WE = 0`**); es wird weder `BUF_RGB` noch `BUF_PRIO` in den Zeilenbuffer geschrieben. Darunterliegende Sprite-Pixel oder Amiga-Bitplanes bleiben zu 100 % unverändert (kein versehentliches Tiefschwarz oder Ausstanzen von Löchern).
  * **Leerer Puffer (`eff_old_prio == 0`):**
    * Modi `01` (Additiv) und `10` (50/50 Translucent) schreiben das Quellpixel $S$ direkt mit `BUF_PRIO = SPR_PRIO`.
    * Modus `11` (Alpha): Schreibt $C_{\text{out}} = \lfloor \frac{\alpha \cdot S}{256} \rfloor$ (bzw. bei $\alpha = 255$ gesättigt exakt $S$). Ist $\alpha = 0$, gilt `WE = 0`.
  * **Endpunkt-Sättigung bei $\alpha = 255$:** Wenn $\alpha == 255$, wird ohne Rundungsverlust exakt $S$ geschrieben ($C_{\text{out}} = S$).
  * **Herkunft des Alpha-Werts ($\alpha$):**
    * Bei **`FORMAT 16` (`ARGB8888`)**: Direkt per Pixel aus `code[31:24]` (echtes Per-Pixel-Alpha).
    * Bei **`FORMAT 13..15`**: Aus dem Feld `ALPHA[7:0]` (Descriptor-Byte Offset `+$0D`, das bei palettenfreien Formaten frei ist).
    * Bei **`FORMAT 0..12`**: Enthalten Palettenanker (`PAL_OFFSET` liegt auf Byte `+$0D`). Für diese Formate ist Byte `+$0D` als `PAL_OFFSET` reserviert; Modus `11` verwendet für diese Formate den Standardwert $\alpha = 255$ (oder ein globales Register).

### 5.3 Mischen NACH dem fertigen 24-Bit-Amiga-Bild (4 Ebenen über `PRIO[7:6]`)
Das Mischen erfolgt **ganz am Ende von [`denise.v`](../mister/rtl/denise.v#L532)** nach dem fertigen 24-Bit-Amiga-Bild (`amiga_rgb[23:0]`):

| `PRIO`-Werte | `PRIO[7:6]` | Ebene relativ zum Amiga-Bild | Bedingung für Anzeige von `BUF_RGB` statt `amiga_rgb` (wenn `!blank_aligned`) |
| :--- | :---: | :--- | :--- |
| **`0`** | `00` | **Leer / Transparent** | Nie (`amiga_rgb` wird angezeigt) |
| **`1 .. 63`** | `00` | **Hintergrund-Layer** (vor `COLOR00`, hinter allen Bitplanes) | `BUF_PRIO != 0 && !sprsel_aligned && !pf_any_opaque` |
| **`64 .. 127`** | `01` | **Zwischen hinterem und vorderem Playfield** | `BUF_PRIO != 0 && !sprsel_aligned && !pf_front_opaque` |
| **`128 .. 191`** | `10` | **Vor allen Bitplanes, hinter Amiga-Sprites 0..7** | `BUF_PRIO != 0 && !sprsel_aligned` |
| **`192 .. 255`** | `11` | **Ganz vorn** (vor Bitplanes und vor Amiga-Sprites) | `BUF_PRIO != 0` (gewinnt immer innerhalb des sichtbaren Bildes) |

* **FullHD-Hintergründe & Tiles:** Wird ein `FORMAT 16`- oder `FORMAT 15`-Sprite mit `PRIO 1..63` definiert, fungiert es als **vollwertiger 24/32-Bit-Hintergrund**. Sind die Amiga-Bitplanes transparent (oder Denise-Bitplanes per Register deaktiviert), wird das TrueColor-Hintergrundbild nahtlos sichtbar. Über negative Startkoordinaten (`X_POS`, `Y_POS`) kann der Hintergrund pixelgenau gescrollt werden.

---

## 6. Sprite-Descriptor im Fast-RAM (16 Bytes = 2 × 64 Bit, `DESC_REV = 4`)

Das Sprite-Array liegt 32-Byte-aligned im DDR3-Fast-RAM und ist aufsteigend nach **`Y_POS`** sortiert.  
Ein einzelner **`4 × 64 Bit`-DDR3-Burst (`BURSTCNT = 4` = 32 Bytes)** lädt gleichzeitig **2 komplette Sprite-Descriptoren**!
Alle 16-Bit- und 32-Bit-Felder sind zu 100 % natürlich auf geraden Adressen ausgerichtet (keine 68000 Address Errors).

### 64-Bit Wort 0 (Offset `+$00 .. +$07`): Y/X-Position & Reiner 32-Bit Datenzeiger
| Offset | Bits | Typ | Feldname | Beschreibung |
| :---: | :---: | :---: | :--- | :--- |
| `+$00` | `[63:48]` | `int16` | **`Y_POS`** | Startzeile (vorzeichenbehaftet, ausgewertet als `int13` `-4096 .. +4095`, deckt FullHD `1080p` + Offscreen-Clipping ab). Liegt an Offset `+$00` für schnellen direkten Zugriff in der 68000-Sortierschleife. |
| `+$02` | `[47:32]` | `int16` | **`X_POS`** | Startspalte (vorzeichenbehaftet, ausgewertet als `int13` `-4096 .. +4095`, deckt `2048 px` + Offscreen-Clipping ab). |
| `+$04` | `[31:0]`  | `uint32` | **`DATA_PTR`** | **Reiner 32-Bit Pointer** auf die Sprite-Pixeldaten im Fast-RAM (32-Byte-aligned). Keine hineingeschobenen Bits mehr! Direkt mit `MOVE.L #Gfx, spr_DataPtr(A0)` beschreibbar. |

### 64-Bit Wort 1 (Offset `+$08 .. +$0F`): Höhe, Breite, Format, Priorität, Alpha & Steuerwort
| Offset | Bits | Typ | Feldname | Beschreibung |
| :---: | :---: | :---: | :--- | :--- |
| `+$08` | `[63:48]` | `uint16` | **`HEIGHT`** | **Echte 16-Bit Quellhöhe** (`1 .. 2047` Zeilen; **`0` = Sentinel / Listenende!**). |
| `+$0A` | `[47:40]` | `uint8` | **`WIDTH`** | Quellbreite in **256-Bit (32-Byte) Bursts** (`1 .. 64` Bursts = 8 bis 4096 Quellpixel; `0` = No-Op; Werte `> 64` werden auf `64` geklemmt). |
| `+$0B` | `[39:32]` | `uint8` | **`FORMAT`** | **Echtes 8-Bit-Format (`0 .. 16`)**: `0..7` = CLUT 1..8 Bit, `8..14` = HAM, `15` = RGB16 Direct, `16` = ARGB32 Direct. |
| `+$0C` | `[31:24]` | `uint8` | **`PRIO`** | 8-Bit Priorität (`0` = dieses Sprite überspringen/unsichtbar; `1 .. 255` = aktiv). |
| `+$0D` | `[23:16]` | `uint8` | **`ALPHA`** | Für Formate `0..12`: Paletten-Offset (`PAL_OFFSET`).<br>Für palettenfreie Formate `13..16`: Globaler Alpha-Wert (`0..255`) für `BLEND_MODE = 11`. Bei `FORMAT 16` (`ARGB8888`) dominiert das Per-Pixel-Alpha `code[31:24]`. |
| `+$0E` | `[15:0]`  | `uint16` | **`CTRL`** | **Steuerwort (Flags, Blend-Mode & 2er-Potenz Skalierung)**:<br>• `Bits [2:0]`: `X_SCALE` (`0`=1x, `1`=2x, `2`=4x, `3`=1/2, `4`=1/4)<br>• `Bits [5:3]`: `Y_SCALE` (`0`=1x, `1`=2x, `2`=4x, `3`=1/2, `4`=1/4)<br>• `Bit 6`: `H_FLIP` (Horizontal spiegeln)<br>• `Bit 7`: `V_FLIP` (Vertikal spiegeln)<br>• `Bit 8`: `SMOOTH_X` (24-Bit lineare Farbglättung)<br>• `Bits [10:9]`: `BLEND_MODE` (`00` Opak, `01` Additiv, `10` 50/50, `11` Alpha)<br>• `Bit 11`: `PRIO_GE` (`>=` statt `>` bei Prioritätsgleichstand)<br>• `Bits [15:12]`: Reserviert (`0`). |

### 68000 Sortier-Konvention
Die Descriptoren müssen aufsteigend nach `Y_POS` vorliegen. Da Koordinaten vorzeichenbehaftet sind (`int16`), darf auf dem 68000 kein unsigned Longword-Vergleich erfolgen (zudem existiert `CMP.L (A0), (A1)` auf dem 68000 nicht). Ein sauberer M68K-Sortierschritt vergleicht vorzeichenbehaftete Wörter:
```m68k
; 68000 Sortierschritt (aufsteigend nach Y_POS, sekundär X_POS):
; A0 = Zeiger auf Descriptor 1, A1 = Zeiger auf Descriptor 2
    move.w  spr_YPos(A0), d0
    cmp.w   spr_YPos(A1), d0    ; Vorzeichenbehafteter 16-Bit-Vergleich
    blt.s   .d1_before_d2
    bgt.s   .d2_before_d1
    move.w  spr_XPos(A0), d0
    cmp.w   spr_XPos(A1), d0    ; Sekundär nach X_POS
    blt.s   .d1_before_d2
.d2_before_d1:
    ; Swap descriptors...
.d1_before_d2:
```

---

## 7. Verbindliche Verträge: DMA, Epochs, Handshake & Bank-Commit (Review #5 Punkt 3 & Review #6 Punkt 6)

### 7.1 DMA-Anforderungs- und Annahme-Bedingung (`ddram_ctrl.v`)
1. **Handshake-Vertrag:**  
   Eine Anforderung für einen 4er-Burst (`BURSTCNT = 4`, 32 Bytes) gilt als angenommen, wenn im selben Takt `spr_dma_req == 1 && spr_dma_ack == 1` ansteht.
2. **In-Flight Beat Tracking:**  
   Die DMA-Steuerung führt einen Zähler `in_flight_beats` (`0..64`). Jede angenommene Anforderung addiert `+4`. Jeder eintreffende Datenbeat (`spr_dma_valid == 1`) dekrementiert `-1`. Eine neue Anforderung darf nur gestellt werden, wenn:
   $$\text{fifo\_count} + \text{in\_flight\_beats} \le 60$$
3. **Audio-Priorität & Latenz-Garantie:**  
   Sprite-DMA hat strikt niedrigere Priorität als Audio-DMA (Port 2) und Video-Refresh. Bei 4er-Bursts (`BURSTCNT = 4`) beträgt die reine Busbelegung 4 Takte (~35 ns bei 114 MHz). Einschließlich Controller-Arbitrierung, Refresh-Zyklen und Worst-Case-Waitstates ist die Latenz am Audio-Port im DDR3-Controller auf maximal 16 Takte begrenzt ($16 / 114{,}75\text{ MHz} \approx 140\text{ ns}$). Gegenüber dem $330\,\mu\text{s}$ Audio-FIFO (16 Samples) entspricht dies $\approx 0{,}043\,\%$. Diese Obergrenze ist ein verbindliches Entwurfsziel, das im zyklusgenauen Taktmodell und durch SystemVerilog-Assertions am Arbiter formal nachgewiesen wird.

### 7.2 Dynamisches Zeilenbudget, Epoch-Tags, Drain-Mechanismus & 4-Zeilen-Wrap-Schutz
1. **Zeilenbudget-Ende (`line_budget_eof`):**  
   Genau 16 Takte vor Zeilenende sperrt die Engine neue Burst-Requests (`spr_dma_req <= 0`).
2. **Epoch-Tagging, Drain & Schutz vor 4-Zeilen-Wrap-Around:**  
   Jeder Request wird mit einem 2-Bit Zeilen-Epoch-Tag `cur_epoch` (`00`, `01`, `10`, `11`) markiert, der zeilenweise rotiert. Eintreffende Beats, deren Epoch nicht mehr zur aktuellen Zeile gehört, werden nicht in das Prefetch-FIFO geschrieben, sondern in eine Discard-Senke verworfen (`drain_beats`).  
   * **Strikte kontinuierliche Video-Synchronisation:** Die Pixel- und Zeilenausgabe von Denise läuft unterbrechungsfrei weiter; der Videostrahl wird niemals angehalten (keine unbegrenzte Videopause!).
   * **Drain-Timeout & Overrun-Verhalten:** Am Zeilenende wartet die Hardware in einem definierten Drain-State auf `in_flight_beats == 0`. Kann der Drain bis zum Start des Renderfensters der Folgezeile nicht abgeschlossen werden, bleibt der Zeilenbuffer für die Folgezeile deterministisch leer (oder behält den Hintergrund), und der Zähler `SPR_OVERRUN_CNT` wird inkrementiert.
   * **Freigabe neuer Zeilen-Epochs:** Eine neue Epoch und neue DMA-Requests dürfen erst nach tatsächlich abgeschlossenem Drain (`in_flight_beats == 0 && drain_complete == 1`) freigegeben werden. Das Prefetch-FIFO wird vor Beginn der Folgezeile deterministisch geleert (`fifo_clear = 1`). Dadurch ist mathematisch ausgeschlossen, dass verzögerte Beats aus Zeile $Y$ in Zeile $Y+4$ eintreffen können!
3. **Diagnosezähler:**  
   Wurde ein Sprite wegen Erreichen von `line_budget_eof` vorzeitig abgebrochen oder eine Zeile wegen Drain-Timeout ausgelassen, inkrementiert die Hardware den 16-Bit-Zähler **`SPR_OVERRUN_CNT`** (`$DFF594`). Bereits in den Zeilenbuffer geschriebene Pixel bleiben sichtbar.

### 7.3 Native Amiga-VBlank-Pointer-Übernahme & Word-Staging-Vertrag (Revision 4.1)
Anstelle komplexer Schattenbank-Handshakes mit asynchronen Flanken-Triggern folgt die Sprite-Engine der klassischen, bewährten **Amiga-Hardware-Architektur** (analog zu Copper `COP1LC`, Bitplanes `BPL1PT` und Denise-Sprites `SPR0PT`):

1. **Register-Schnittstelle & High/Low Word Staging (`$DFF580` / `$DFF582`):**
   * **`$DFF580` (`SPR_LIST_PTR_HI`):** 16-Bit-Schreibzugriff legt das High-Word in einem internen 16-Bit-Vorbereitungsregister (`staging_hi`) ab. Es erfolgt noch *keine* Aktualisierung des Schattenregisters.
   * **`$DFF582` (`SPR_LIST_PTR_LO`):** 16-Bit-Schreibzugriff übernimmt das Low-Word und schreibt `(staging_hi << 16) | val16` **vollständig atomar** in das Schattenregister `spr_list_ptr_shadow`.
   * **68000 `MOVE.L A0, $DFF580`:** Der Standard-68000-Bus führt einen 32-Bit-Zugriff automatisch als zwei 16-Bit-Zyklen aus (zuerst High-Word auf `$DFF580`, dann Low-Word auf `$DFF582`). Triggert der VBlank exakt zwischen den beiden Bus-Zyklen, bleibt das bisherige Schattenregister unverändert gültig. Ein zerrissener Zeiger ist damit hardwareseitig ausgeschlossen!
   * **Lesezugriff (`$DFF580` / `$DFF582`, CPU):** Liefert den *aktuell von der Hardware dargestellten* Zeiger `spr_list_ptr_active` zurück. Bei einem 32-Bit-Lesen (`MOVE.L $DFF580, D0`) schnappt der Lesezugriff auf `$DFF580` (High-Word) gleichzeitig das korrespondierende Low-Word in einem internen `read_snapshot`-Register ein. Das darauffolgende Lesen von `$DFF582` liefert diesen Schnappschuss. Dadurch ist auch das Auslesen atomar und gegen zwischenzeitliche VBlank-Sprünge geschützt.
2. **Atomare VBlank-Übernahme & Nullpointer-Abschaltung:**
   * Am Frame-Start bei Beginn des vertikalen Austastintervalls (`vblank_start`) übernimmt die Hardware den Schattenzeiger atomar:
     $$\text{spr\_list\_ptr\_active} \le \text{spr\_list\_ptr\_shadow}$$
   * **Nullpointer (`NULL / 32'd0`):** Ist `spr_list_ptr_active == 0`, ist die Sprite-Engine **vollständig deaktiviert**. Es finden keinerlei DMA-Zugriffe statt (0 % Speicherbandbreite, 0 ALMs Buslast).
   * **Gültiger Pointer (`!= 0`):** Ist `spr_list_ptr_active != 0`, startet die Engine ab Scanline 0 den geordneten Descriptor-Vorabruf.
3. **Natives Double-/Triple-Buffering im Fast-RAM:**
   * Der Entwickler allokiert zwei Descriptor-Puffer (`Buffer_A`, `Buffer_B`) im Fast-RAM.
   * Während die Hardware aus `Buffer_A` rendert, baut die 68000-CPU den nächsten Frame in `Buffer_B` auf.
   * Am Frame-Ende schreibt die Software einfach `MOVE.L #Buffer_B, $DFF580`.
   * Beim nächsten VBlank erfolgt die Umschaltung automatisch, deterministisch und gloriös ohne jeden Handshake-Wartezyklus!
   * **Copper-Listen-Kompatibilität:** Da es sich um ein normales Longword-Register handelt, kann auch eine Copper-Liste den Zeiger per `CMOVE` umschalten.
4. **Buffer Ownership:**  
   Zeilenbuffer A und B tauschen ihre Rollen deterministisch am Zeilensynchronisationspunkt (`line_sync`). Während Denise Buffer A ausliest und per Clear-on-Read leert, schreibt die Engine exklusiv in Buffer B.

---

## 8. Diagnose-Metriken & Reproduzierbare Test-Suite

### 8.1 Klarstellung der Zeilenlast-Metriken, Latenzverträge & Diagnose-Register
Die im HUD angezeigte Zeilenlast ist als **`Decoder-Operationsschätzung ohne DMA/Clear/Ausgabe`** definiert. Für detaillierte Hardware-Analysen stellt die Engine getrennte Zähler bereit:
* **`src_steps`:** Anzahl der dekomprimierten Quellpixel.
* **`dst_steps`:** Anzahl der erzeugten Zielpixel nach Skalierung.
* **`skip_words`:** Anzahl der per 1-Takt Zero-Word-Skip übersprungenen 64-Bit-Worte.
* **`descriptors_scanned`:** Anzahl der im Frame ausgewerteten Descriptoren.
* **Speicherlatenz-Verträge:**
  * **Einzel-Burst-Arbiter-Latenz (`single_burst_latency`):** Maximale Turnaround-Zeit eines isolierten Bursts vom Anfordern bis zum 1. Beat beträgt $\le 16$ Takte ($139{,}4\text{ ns}$).
  * **Warteschlangen-Latenz (`queue_latency`):** Bei Vorabruf-Pipelining mehrerer Bursts (z. B. 8 Bursts in Folge) werden die 4 Beats pro Burst sequentiell auf dem Bus übertragen, sodass spätere Bursts bis zur Freigabe des Busses warten ($16 + 7 \times 3 = 37$ Takte für den 8. Burst). Beide Metriken werden im Timing-Modell separat erfasst und validiert.
* **Hardware-Register (Clear-on-Read / VBlank-Reset):**
  * `$DFF580`: `SPR_LIST_PTR_HI` (W: High-Word Staging-Register; R: High-Word von `spr_list_ptr_active` + atomarer Low-Word-Snapshot).
  * `$DFF582`: `SPR_LIST_PTR_LO` (W: Low-Word + Atomarer Shadow-Commit; R: Low-Word Snapshot; `0` = Engine OFF).
  * `$DFF584`: `SPR_CTRL` (Bit 2: Reset).
  * `$DFF586`: `SPR_PAL_ADDR` (Paletten-Slot 0..255).
  * `$DFF588`: `SPR_PAL_DATA_H` (Paletten-Rot [7:0]).
  * `$DFF58A`: `SPR_PAL_DATA_L` (Paletten-Grün [15:8], Blau [7:0]).
  * `$DFF590`: `SPR_MAX_BUSY` (Maximale Decoder-Busy-Takte einer Zeile).
  * `$DFF592`: `SPR_DMA_STALL` (Wartezyklen auf Speicherdaten).
  * `$DFF594`: `SPR_OVERRUN_CNT` (Anzahl unvollständiger Zeilenbudgets / Drain-Timeouts).

### 8.2 Offizielle Versionierte Test-Suite (`fixtures/sprite_engine_fixtures_v4.json`)
Zur dauerhaften Qualitätssicherung und für Cross-Renderer-Vergleiche zwischen Python, Browser-JS und FPGA-Simulatoren liegt die versionierte Test-Suite vor:
* **Pfad:** [`NanoMig/mister/tests/sprite_engine/fixtures/sprite_engine_fixtures_v4.json`](../mister/tests/sprite_engine/fixtures/sprite_engine_fixtures_v4.json)
* **Validierungsskript:** [`NanoMig/mister/tests/sprite_engine/verify_fixtures.py`](../mister/tests/sprite_engine/verify_fixtures.py) – führt alle **20 Testfälle** dynamisch über `render_scanline()` aus und vergleicht jedes Pixel bitgenau.
* **Gegenprüfungen:**
  1. Raw 16-Byte Descriptor Pack/Unpack Roundtrip ohne Bypasses (DESC_REV = 4).
  2. Negative Koordinaten (`X_POS = -4, Y_POS = -10`) und horizontales/vertikales Clipping.
  3. 2er-Potenz Skalierung (1x, 2x, 4x, 1/2, 1/4) inkl. 4096-Pixel-Quarter-Scale-Testfall (1024 Pixel).
  4. Gleichheits-Arbitrierung (`PRIO_GE = 0` vs. `PRIO_GE = 1`).
  5. Opaque Schwarz-Semantik (`RGB16 $8000` = Dark Red vs. `$0000` = Transparent; HAM16 `$8000` = Opaque Black) vs. Transparenz (`$0000`).
  6. 4 Hardware-Blend-Modi (`00` Opak, `01` Additiv, `10` 50/50, `11` Alpha) mit Alpha 0-Transparenz (`WE = 0`) und Endpunkt-Sättigung bei Alpha 255.
  7. `FORMAT 16` (`ARGB8888`) mit Per-Pixel-Alpha Sweep (0, 1, 128, 255).
  8. `FORMAT 11` und `FORMAT 12` `PAL_OFFSET`-Erhalt (Palettenslot 1 vs. 129).
  9. Multiline `V_FLIP`-Invertierung (`next_y = 0` vs. `next_y = 3`).
  10. Zero-Word-Skip Bit-Äquivalenz (`skip_pair_on` vs. `skip_pair_off` zu 100 % identisch).

---

## 9. Ressourcen-Bilanz (Cyclone V `5CSEBA6U23I7`)

Freie Ressourcen im Minimig-AGA Core (Stand Quartus Fit vom 08.11.2026): **5.144 ALMs**, **224 M10K-Blöcke**, **35 DSPs**.  
*(Hinweis: ALM- und DSP-Werte sind fundierte Architektur-Schätzungen vor Verilog-Synthese und TimeQuest STA; ein zyklusgenaues Taktmodell mit Stalls, Clear und Blend-Forwarding wird nach Freigabe der Spezifikation realisiert).*

| Modul / Teilblock | ALMs | M10K-Blöcke | DSPs |
| :--- | :---: | :---: | :---: |
| **Ping-Pong Zeilenbuffer A & B** (`2 × 2048 × 32 Bit` + 1-Takt-Forwarding) | ~50 | **16** | 0 |
| **Dedizierte Banked Sprite-Palette** (`2 × 256 × 24 Bit` Dual-Port für unterbrechungsfreien Wechsel) | ~30 | **2** | 0 |
| **64-Bit Prefetch-FIFO** (`64 × 64 Bit` zwischen DDR3 & Unpacker) | ~25 | **1** | 0 |
| **Multi-Mode Unpacker** (19 Formate `0..18` inkl. `ARGB8888` & Zero-Word-Skip) | ~140 | 0 | 0 |
| **Dedizierter HAM/HighColor-Decoder** (12-Bit Pre-Delta, `4-Bit step_r/g/b`, `HAM12/16`) | ~115 | 0 | 0 |
| **X/Y-Skalierer, `H_FLIP`/`V_FLIP` & 24-Bit RGB X-Interpolator (`SMOOTH_X`)** | ~105 | 0 | 0 |
| **Hardware Alpha-Blender** (4 Modi: Opak, Additiv, 50/50, 8-Bit Alpha) | ~65 | 0 | 0–1 |
| **Y-Listen-Scanner (`4096`), Clipping, 13×8-Multiplizierer & DMA-FSM** | ~210 | 0 | 0–1 |
| **Denise-Ausgangs-Prioritätsmischer** (4 Ebenen + Blank-Gate) | ~35 | 0 | 0 |
| **Gesamtsumme** | **~775 ALMs** | **19 M10K** | **0–1 DSP** |
| *Anteil an den freien Ressourcen* | *~15,1 % der freien ALMs* | *~8,5 % der freien M10K* | *< 3 %* |
