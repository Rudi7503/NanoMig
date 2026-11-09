# Architektur- und Design-Spezifikation: 32/64-Bit HAM-, HighColor-, ARGB- & CLUT-Sprite-Engine (Rev. 3 – HAM12/16, RGB16, ARGB8888, Alpha-Blending, FullHD 2048px)

**Status:** Spezifikation mit verbindlichen Hardware-Verträgen nach Review #5 durch Tobys KI (`toby01019`) (kein RTL-Code erzeugt)  
**Zielplattform:** MiSTer FPGA (Cyclone V `5CSEBA6U23I7`), Minimig-AGA / Denise-Erweiterung  
**Descriptor-Revision:** `DESC_REV = 3` (Verbindlicher Hardware- & Software-Vertrag)

---

## 1. Überblick & Kernidee

Die Sprite-Engine kombiniert **variable HAM-Modi (`HAM03`, `HAM04`, `HAM05`, `HAM06`, `HAM08`, `HAM12`, `HAM16`)**, **15/16-Bit Direct HighColor (`RGB565` / `RGB555`)**, **32-Bit Direct TrueColor (`ARGB8888`)**, **4 Hardware-Blend-Modi (Opak, Additiv, 50/50, 8-Bit Alpha)** sowie einen **wahlweisen direkten Palettenmodus (`CLUT_MODE`)** mit einer **FullHD-fähigen `2048`-Pixel Ping-Pong-Zeilenbuffer-Architektur**, einem **eigenen dedizierten High-Speed-Decoder** und direktem **64-Bit-Burst-DMA-Zugriff (`BURSTCNT = 4`) auf das DDR3-Fast-RAM**.

1. **Eigener dedizierter Sprite-HAM/HighColor/CLUT-Decoder (volle Geschwindigkeit):**
   * Die Sprite-Engine besitzt ihren **eigenen `ham_pixel_decoder`** sowie eine **eigene 256×24-Bit-Sprite-Palette (M10K)**.
   * Darüber hinaus arbeiten **`HAM12`**, **`HAM16`**, **`RGB16`** und **`ARGB32`** mit direkten RGB-Farben im Bitstream und damit auf Wunsch **zu 100 % palettenfrei**.
   * Dadurch arbeitet die Sprite-Engine zu **100 % unabhängig vom Playfield-HAM (`ext_ham`)** und kann über die gesamte Zeilenzeit ohne jede Unterbrechung mit voller Geschwindigkeit rendern.
2. **Konstanter 256-Bit-Burst-Speicherzugriff (`4 × 64 Bit`) trotz variabler Pixeldichte:**
   * Die minimale Breite und das Zeilen-Raster eines Sprites im RAM beträgt **`4 × 64 Bit = 256 Bit` (32 Bytes = 8 × 32-Bit-Blöcke)**.
   * Dies entspricht exakt einem physischen **DDR3-BL8-Burst (`BURSTCNT = 4`)** auf dem MiSTer. Jeder Burst-Zugriff liefert in 4 aufeinanderfolgenden `clk_114`-Takten **8 bis 64 Pixel auf einen Schlag** (und beim Lesen der Descriptor-Liste gleich **2 komplette 16-Byte-Descriptoren** auf einmal!).
   * **Hardware Zero-Word-Skip (100 % bit-identisch):** Ist ein 64-Bit-Wort innerhalb des 256-Bit-Bursts komplett `0` (`64'h00000000_00000000` = lauter transparente `raw_code == 0`-Pixel) und steht kein Zoom (`X_SCALE == 8'h40`) sowie kein opakes Vorgängerpixel (`prev_opaque == 0`) an, setzt der Entpacker den HAM-Akkumulator auf `0`, addiert die Pixelanzahl (`2..16` je nach Format) direkt auf `dst_x` (bzw. subtrahiert bei `H_FLIP`) und überspringt das gesamte 64-Bit-Wort in **einem einzigen Takt**!
3. **Zwei FullHD-fähige `2048`-Pixel-Zeilenbuffer im Wechsel (Ping-Pong + deterministisches Clear):**
   * Beide Zeilenbuffer (A und B) umfassen **`2048 × 32 Bit`** (`16 M10K` gesamt) und unterstützen damit alle Auflösungen von Lores (`320 px`) über SuperHiRes-Overscan (`1432 px`) bis hin zu **FullHD (`1920 × 1080` / `2048 px`)**.
   * Während **Zeilenbuffer A** synchron zum Videostrahl am Ausgang von Denise ausgelesen, mit dem fertigen 24-Bit-Amiga-Bild gemischt und deterministisch über alle `0..2047` Spalten auf `0` gelöscht wird,
   * rendert die Sprite-Engine im Hintergrund die nächste Bildschirmzeile (`next_y`) in **Zeilenbuffer B** (inkl. **1-Takt-Write-Forwarding** für aufeinanderfolgende Schreibzugriffe auf dieselbe Spalte `dst_x`).
4. **Y-sortierte Descriptor-Liste im Fast-RAM (bis zu `4.096` Descriptoren):**
   * Der Engine wird über ein VBlank-gepuffertes Register (`SPR_LIST_PTR`) ein 32-Bit-Zeiger auf ein nach **`Y_POS` aufsteigend sortiertes Array** übergeben.
   * Sobald beim Scannen der Liste ein Eintrag mit `Y_POS > next_y` oder das Sentinel `Y_HEIGHT == 0` erreicht wird, bricht die Engine die Suche für diese Zeile sofort ab (**Early Exit**).
5. **Freies Positionieren, X/Y-Skalierung, 24-Bit-Interpolation & Hardware-Clipping:**
   * Sprites können an beliebigen negativen oder positiven Koordinaten (`int16 X_POS`, `int16 Y_POS`, ausgewertet als `int13` `-4096..+4095`) außerhalb des Bildschirms starten und enden, stufenlos skaliert (`X_SCALE`, `Y_SCALE` von `0,25×` bis `4,0×`), gespiegelt (`H_FLIP`, `V_FLIP`) und per 24-Bit-Subpixel-Filterung (`SMOOTH_X`) geglättet werden.
6. **Hardware Alpha-Blending & 24/32-Bit Hintergrund/Tile-Compositing:**
   * **4 Hardware-Blend-Modi (`BLEND_MODE[1:0]`):** `00` Normal/Opak, `01` Additiv ($\min(255, S + D)$ für Triebwerksfeuer/Laser), `10` 50/50 Translucent ($(S + D) \gg 1$ für Kanzelglas/Rauch), `11` Full 8-Bit Alpha ($D + \frac{\alpha \cdot (S - D)}{256}$).
   * **32-Bit Direct TrueColor (`FORMAT 18 ARGB8888`):** Unkomprimierte Kacheln, Tiles und Hintergrundbilder (1 Pixel pro 32 Bit, 8 px/Burst) sowie Sprites mit eigenem Per-Pixel-Alpha (`code[31:24]`).
   * **Hintergrund-Modus (Layer `00`):** Descriptoren mit `PRIO 1..63` rendern hinter allen Bitplanes und vor Amiga `COLOR00`. Zusammen mit negativen Offsets (`X_POS`, `Y_POS`) ermöglicht dies ruckelfreies Hardware-Scrolling ganzer 24/32-Bit-Hintergründe ohne CPU-/Chipset-Belastung.

---

## 2. Dedizierter High-Speed HAM-Decoder & Verbreiterte Vorberechnungs-Arithmetik

### 2.1 Warum ein eigener Decoder für die Sprite-Engine gesetzt ist
* Würde sich die Sprite-Engine den Decoder mit dem Playfield (`ext_ham`) teilen, wäre der Decoder bei aktivem SuperHiRes-HAM-Playfield (1280 px) oder FullHD für den Großteil der Zeile durch das Playfield blockiert.
* Mit einem **eigenen dedizierten Decoder** (~100 ALMs) + eigener Paletten-RAM-Instanz (1 M10K) stehen der Sprite-Engine **100 % der Zeilenzeit (volle 64 µs)** ungeteilt zur Verfügung.

### 2.2 Pipeline-Optimierung & Exakte Bitbreiten der Delta-Vorberechnung (4-Bit Steps, 12-Bit signed Pre-Delta)
In `c0_ham_from_setup.rpt` (Slow 1100mV 100C) hatte der bisherige Playfield-Decoder (`ham_pixel_decoder.v`) eine kombinatorische Laufzeit von **`14,774 ns`**, weil Bit-Decode, `turbo`-Shift, Delta-Mux und die Addition `accumulator + delta` im selben Takt stattfanden.

* **Entscheidende Beobachtung:** Die Vorzeichen-Deltas `delta_r`, `delta_g`, `delta_b` sowie die direkten `HAM12`/`HAM16`/`RGB16`/`ARGB32`-Ankerfarben hängen **nur von `code`, `mode` und `step_r/g/b` ab – nicht vom `accumulator`!**
* **Verbindliche Bitbreiten (`step_r/g/b` sind 4 Bit `0..15`, Pre-Delta ist 12 Bit signed):**
  * Im globalen Sprite-Step-Register **`SPR_STEP_RGB` (`$DFF588`)** sind `step_r`, `step_g`, `step_b` jeweils **4 Bit breit (`0 .. 15`, Default `4`)**:
    * `[15:12]`: Reserviert (`0`)
    * `[11:8]`: `STEP_R[3:0]` (`0 .. 15`)
    * `[7:4]`: `STEP_G[3:0]` (`0 .. 15`)
    * `[3:0]`: `STEP_B[3:0]` (`0 .. 15`)
  * **Exakte Definition der 4 `CUSTOM_STEP`-Faktoren (`STEP_CTRL[7] == 1`):**  
    Für jeden Kanal `c` (`R = STEP_CTRL[5:4]`, `G = STEP_CTRL[3:2]`, `B = STEP_CTRL[1:0]`) wird die effektive **5-Bit-Schrittweite `eff_step_c[4:0]` (`0..30`)** wie folgt bestimmt:
    * `2'b00` (`0,5×`): `eff_step_c = step_c >> 1` *(ganzzahlige Abrundung `floor(step_c / 2)`, `0..7`)*
    * `2'b01` (`1,0×`): `eff_step_c = step_c` *(unverändert `0..15`)*
    * `2'b10` (`1,5×`): `eff_step_c = step_c + (step_c >> 1)` *(exakt `step_c + floor(step_c / 2)`, max. `15 + 7 = 22`)*
    * `2'b11` (`2,0×`): `eff_step_c = step_c << 1` *(exakt `2 * step_c`, max. `30`)*
  * **Maximale Delta-Spanne über alle Modi (`HAM03..16`):**
    * `HAM03..08` (`level ∈ {-2, -1, +1, +2}`, `turbo ∈ {1, 4}`): `|delta| <= 30 × 4 × 2 = 240`.
    * `HAM12` (`dr, db ∈ [-4..+3]`, `dg ∈ [-8..+7]`, `turbo ∈ {1, 4}`): `delta_g ∈ [-8 × 30 × 4 .. +7 × 30 × 4] = [-960 .. +840]`.
    * `HAM16` (`dr ∈ [-8..+7]`, `dg, db ∈ [-16..+15]`, `turbo ∈ {1, 4}`): `delta_g, delta_b ∈ [-16 × 30 × 4 .. +15 × 30 × 4] = [-1920 .. +1800]`.
    * Durch die 4-Bit-Begrenzung von `step_c` ist der Delta-Multiplizierer für `HAM12`/`HAM16` in Stufe 1 lediglich ein winziger `5×5`-Bit-Multiplizierer (~15 ALMs pro Kanal).
    * Alle vorberechneten Deltas passen überlauffrei in **12 Bit signed (`-2048 .. +2047`)**, und die Addition `acc + delta` im Rekursions-Zyklus liegt in **`[-1920 .. +2055]`** und benötigt **13 Bit signed** vor der Sättigung auf `0..255` (`uint8`).
* **2-Stufen-Aufteilung (ohne Zusatzlatenz, parallel zum Paletten-BRAM-Read):**
  1. **Stufe 1 (Entpacker & Paletten-Read-Takt):**  
     Parallel zum synchronen Lesezugriff auf das M10K-Paletten-RAM (`palette_index = (PAL_OFFSET + raw_code) & 8'hFF`) berechnet die Logik bereits `anchor_reg`, `direct_anchor_reg` (für `HAM12`/`HAM16`/`RGB16`/`ARGB32`), `direct_rgb_reg[23:0]`, `alpha_reg[7:0]`, `opaque_reg = (raw_code != 0)` sowie die fertigen **12-Bit-signed** Summanden `delta_r`, `delta_g`, `delta_b` und speichert sie in Registern.
  2. **Stufe 2 (Akkumulator-Takt):**  
     Im eigentlichen Rekursions-Zyklus wählt der Anker-Mux `anchor_rgb = direct_anchor_reg ? direct_rgb_reg : palette_data`, und der Decoder führt **nur noch eine einzige 13-Bit-Addition mit Sättigung auf `0..255`** aus:
     $$\text{acc\_next} = (\neg\text{opaque\_reg}) \;?\; \text{24'h000000} : \big(\text{anchor\_reg} \;?\; \text{anchor\_rgb} : \text{sat}_{0..255}(\text{acc} + \text{delta\_reg})\big)$$
* **Pipeline-Steuerung (`valid`, `decoder_hold`, `line_reset`):**
  * Zu Beginn jeder neuen Sprite-Quellzeile (`line_reset = 1`) werden `acc_r/g/b <= 0`, `prev_rgb <= 0`, `prev_opaque <= 0` sowie die Pipeline-Valid-Stufen synchron zurückgesetzt.
  * Ist `decoder_hold == 1` (während der `X_SCALE`-Interpolator bei Vergrößerung Zwischenspalten ausschreibt), frieren alle Decoder-Stufen und `acc_r/g/b` taktsynchron ein.

---

## 3. Die 19 festgelegten 32/64-Bit-Formate (`HAM03..16`, `RGB16`, `ARGB32`) & `CLUT_MODE`

Die minimale Sprite-Breite (und das Zeilen-Raster) im RAM ist auf **`4 × 64 Bit = 256 Bit` (32 Bytes)** festgelegt.  
Dadurch nutzt jeder DMA-Lesezugriff mit **`BURSTCNT = 4`** den physischen **DDR3-BL8-Burst** (32-Bit DDR3 × 8 = 256 Bit) zu **100 %** aus und liefert in 4 aufeinanderfolgenden `clk_114`-Takten **8 bis 64 Pixel auf einen Schlag**:

| `FORMAT` (`5 Bit`) | Name im Konverter | Bit-Sequenz (pro 32-Bit-Wort, bzw. `FORMAT 15` pro 64-Bit-Wort) | Pixel / 32 Bit | Pixel / 64 Bit | **Pixel / 256-Bit-Burst (`4×64 Bit`)** | Anker-Typ (HAM) | Verhalten bei `CLUT_MODE = 1` |
| :---: | :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| **`0`** | `HAM_32BIT_44444444` | `4 - 4 - 4 - 4 - 4 - 4 - 4 - 4` | **8 px** | 16 px | **64 px** | 8 Pal.-Slots | 16 CLUT-Farben |
| **`1`** | `HAM_32BIT_53535353` | `5 - 3 - 5 - 3 - 5 - 3 - 5 - 3` | **8 px** | 16 px | **64 px** | 16 / 4 Pal. | 32 / 8 CLUT |
| **`2`** | `HAM_32BIT_63436343` | `6 - 3 - 4 - 3 - 6 - 3 - 4 - 3` | **8 px** | 16 px | **64 px** | 32 / 8 / 4 Pal. | 64 / 16 / 8 CLUT |
| **`3`** | `HAM_32BIT_6446444` | `6 - 4 - 4 - 6 - 4 - 4 - 4` | **7 px** | 14 px | **56 px** | 32 / 8 Pal. | 64 / 16 CLUT |
| **`4`** | `HAM_32BIT_5454545` | `5 - 4 - 5 - 4 - 5 - 4 - 5` | **7 px** | 14 px | **56 px** | 16 / 8 Pal. | 32 / 16 CLUT |
| **`5`** | `HAM_32BIT_6454544` | `6 - 4 - 5 - 4 - 5 - 4 - 4` | **7 px** | 14 px | **56 px** | 32 / 16 / 8 Pal. | 64 / 32 / 16 CLUT |
| **`6`** | `HAM_32BIT_655655` | `6 - 5 - 5 - 6 - 5 - 5` | **6 px** | 12 px | **48 px** | 32 / 16 Pal. | 64 / 32 CLUT |
| **`7`** | `HAM_32BIT_844844` | `8 - 4 - 4 - 8 - 4 - 4` | **6 px** | 12 px | **48 px** | 128 / 8 Pal. | 256 / 16 CLUT |
| **`8`** | `HAM_32BIT_846554` | `8 - 4 - 6 - 5 - 5 - 4` | **6 px** | 12 px | **48 px** | 128..8 Pal. | 256..16 CLUT |
| **`9`** | `HAM_32BIT_646565` | `6 - 4 - 6 - 5 - 6 - 5` | **6 px** | 12 px | **48 px** | 32 / 16 / 8 Pal. | 64 / 32 / 16 CLUT |
| **`10`** | `HAM_32BIT_86666` | `8 - 6 - 6 - 6 - 6` | **5 px** | 10 px | **40 px** | 128 / 32 Pal. | 256 / 64 CLUT |
| **`11`** | `HAM_32BIT_85865` | `8 - 5 - 8 - 6 - 5` | **5 px** | 10 px | **40 px** | 128 / 32 / 16 Pal. | 256 / 64 / 32 CLUT |
| **`12`** | `HAM_32BIT_8888` | `8 - 8 - 8 - 8` | **4 px** | 8 px | **32 px** | 128 Pal.-Slots | **256 CLUT-Farben** |
| **`13`** | `HAM_32BIT_12_6_8_6` | **`12 - 6 - 8 - 6`** *(32 Bit)* | **4 px** | 8 px | **32 px** | `HAM12` (Direkt) + 32/128 Pal. | `RGB444` + 64/256 CLUT |
| **`14`** | `HAM_32BIT_12_5555` | **`12 - 5 - 5 - 5 - 5`** *(32 Bit)* | **5 px** | 10 px | **40 px** | `HAM12` (Direkt) + 16 Pal. | `RGB444` + 32 CLUT |
| **`15`** | `HAM_64BIT_16_12_12_12_12` | **`16 - 12 - 12 - 12 - 12`** *(64 Bit!)* | *2,5 px* | **5 px** | **20 px** | **100 % palettenfrei** (`HAM16` + 4×`HAM12`) | `RGB565` + 4×`RGB444` |
| **`16`** | `HAM_32BIT_16_16` | **`16 - 16`** *(Reines `HAM16`, 32 Bit)* | **2 px** | 4 px | **16 px** | **100 % palettenfrei** (`RGB555` + 4/5/5 Delta) | Direktes `RGB565` |
| **`17`** | `RGB_32BIT_16_16` | **`16 - 16`** *(Direct HighColor, 32 Bit)* | **2 px** | 4 px | **16 px** | **Direktes `RGB565`** (`65.535` Farben, kein HAM) | **Direktes `RGB555`** (`32.767` Farben) |
| **`18`** | `RGB_32BIT_DIRECT` | **`32`** *(`ARGB8888` TrueColor, 32 Bit)* | **1 px** | **2 px** | **8 px** | **100 % palettenfrei** (`ARGB8888`, Per-Pixel Alpha) | **Direktes 32-Bit TrueColor** |

*(Die 5-Bit-Formatkennung setzt sich aus `FORMAT[4:0] = {DATA_PTR[3], FORMAT_LO[3:0]}` zusammen; für Formate `0..15` ist `DATA_PTR[3] = 0`, für `16, 17, 18` ist `DATA_PTR[3] = 1`. Werte `FORMAT = 19..31` sind als ungültig/Reserve definiert und führen zum deterministischen Überspringen des Sprites ohne DMA-Zugriff).*

### 3.1 Exakte Bit-Definition von `HAM12`, `HAM16`, `RGB16` und `FORMAT 18` (`ARGB8888`)

1. **`HAM12` (12 Bit pro Pixel, palettenfrei):**
   * **`code == 12'h000`:** Transparent (`pix_opaque = 0`, setzt `acc_r/g/b <= 24'h000000`).
   * **`CLUT_MODE == 1` (`code != 0`):** Direktes 12-Bit **`RGB444`** (`anchor_reg = 1`, `direct_anchor_reg = 1`):
     * `R = {code[11:8], 4'b0000}`, `G = {code[7:4], 4'b0000}`, `B = {code[3:0], 4'b0000}`.
   * **`CLUT_MODE == 0` & `code[11] == 0` (Direkter 11-Bit-RGB-Anker ohne Palette, `2.047` opake Ankerfarben):**
     * `b10 = code[10]` (gemeinsames LSB für R und B), `r3 = code[9:7]`, `g4 = code[6:3]`, `b3 = code[2:0]`.
     * `R = {r3, b10, 4'b0000}` (`((r3 << 1) | b10) << 4`)
     * `G = {g4, 4'b0000}` (`g4 << 4`)
     * `B = {b3, b10, 4'b0000}` (`((b3 << 1) | b10) << 4`)
   * **`CLUT_MODE == 0` & `code[11] == 1` (11-Bit Zweierkomplement-Delta):**
     * `turbo = code[10]` (`mult = turbo ? (eff_step << 2) : eff_step`).
     * `dr_s3 = signed(code[9:7])` (`-4 .. +3`), `dg_s4 = signed(code[6:3])` (`-8 .. +7`), `db_s3 = signed(code[2:0])` (`-4 .. +3`).
     * `delta_r = dr_s3 * mult_r`, `delta_g = dg_s4 * mult_g`, `delta_b = db_s3 * mult_b`. *(Hinweis: `code == 12'h800` nach einem transparenten Pixel ergibt `delta = 0` mit `opaque = 1`, also echtes opakes Tiefschwarz `24'h000000`!)*

2. **`HAM16` (16 Bit pro Pixel in `FORMAT 15` und `FORMAT 16`, palettenfrei):**
   * **`code == 16'h0000`:** Transparent (`pix_opaque = 0`, setzt `acc_r/g/b <= 24'h000000`).
   * **`CLUT_MODE == 1` (`code != 0`):** Direktes 16-Bit **`RGB565`** (`anchor_reg = 1`, `direct_anchor_reg = 1`):
     * `R = {code[15:11], 3'b000}`, `G = {code[10:5], 2'b00}`, `B = {code[4:0], 3'b000}`.
   * **`CLUT_MODE == 0` & `code[15] == 0` (Direkter 15-Bit-`RGB555`-Anker ohne Palette, `32.767` opake Ankerfarben):**
     * `r5 = code[14:10]`, `g5 = code[9:5]`, `b5 = code[4:0]`.
     * `R = {r5, 3'b000}` (`r5 << 3`), `G = {g5, 3'b000}` (`g5 << 3`), `B = {b5, 3'b000}` (`b5 << 3`).
   * **`CLUT_MODE == 0` & `code[15] == 1` (15-Bit Zweierkomplement-Delta):**
     * `turbo = code[14]` (`mult = turbo ? (eff_step << 2) : eff_step`).
     * `dr_s4 = signed(code[13:10])` (`-8 .. +7`), `dg_s5 = signed(code[9:5])` (`-16 .. +15`), `db_s5 = signed(code[4:0])` (`-16 .. +15`).
     * `delta_r = dr_s4 * mult_r`, `delta_g = dg_s5 * mult_g`, `delta_b = db_s5 * mult_b`. *(Auch hier erzeugt `code == 16'h8000` nach Reset echtes opakes Schwarz `24'h000000`!)*

3. **`RGB16` (`FORMAT 17`, 15/16-Bit Direct HighColor ohne HAM, palettenfrei):**
   * **`code == 16'h0000`:** Transparent (`pix_opaque = 0`, setzt `acc_r/g/b <= 24'h000000`).
   * **`CLUT_MODE == 0` (`RGB565`, `code != 0`):** `R = {code[15:11], 3'b000}`, `G = {code[10:5], 2'b00}`, `B = {code[4:0], 3'b000}`.
   * **`CLUT_MODE == 1` (`RGB555`, `code != 0`):** `R = {code[14:10], 3'b000}`, `G = {code[9:5], 3'b000}`, `B = {code[4:0], 3'b000}` *(wobei `code == 16'h8000` als `opaque = 1` mit `R=G=B=0` echtes opakes Tiefschwarz `24'h000000` darstellt!)*.

4. **`FORMAT 18` (`RGB_32BIT_DIRECT` / `ARGB8888` TrueColor, 32 Bit pro Pixel, palettenfrei):**
   * **`code == 32'h0000_0000`:** Transparent (`pix_opaque = 0`, `acc_r/g/b <= 0`).
   * **`code != 0`:** Direktes 32-Bit TrueColor (`anchor_reg = 1`, `direct_anchor_reg = 1`, `opaque = 1`):
     * `Alpha = code[31:24]` (`0 .. 255`, Per-Pixel-Alpha für `BLEND_MODE = 11`)
     * `R = code[23:16]` (`0 .. 255`)
     * `G = code[15:8]` (`0 .. 255`)
     * `B = code[7:0]` (`0 .. 255`)
   * **Packung:** 1 Pixel pro 32-Bit-Langwort, 2 Pixel pro 64-Bit DDR3-Wort, **8 Pixel pro 256-Bit Burst**.
   * **Einsatzbereich:** Unkomprimierte Kacheln, 24/32-Bit Hintergrundbilder, RTG-Overlays und Sprites mit stufenlosem 8-Bit Per-Pixel-Alpha.

5. **Verbindlicher Vertrag zur Linksshift-Sättigung & Schwarz-Semantik (Review #5 Punkt 5):**
   * **Linksshift:** `RGB565` und `RGB555` werden im FPGA gezielt per fester Linksverschiebung auf 8 Bit erweitert (`<< 3` für 5-Bit-Kanäle $\to$ Maximum 248; `<< 2` für 6-Bit-Grün $\to$ Maximum 252). Dies spart DSP-Blöcke und hält den Taktweg unter 3,5 ns. Konverter oder Software-Pipelines, die exakt 255 benötigen, können im Quellbild das obere Bitmuster spiegeln (`(c << 3) | (c >> 2)`), in der Hardware gilt verbindlich der reine Linksshift.
   * **Opaque Schwarz:**
     * `RGB555` (`FORMAT 17, CLUT_MODE = 1`): Code `16'h8000` ist **echtes opakes Tiefschwarz** (`opaque = 1`, `RGB = 24'h000000`). Code `16'h0000` ist transparent (`opaque = 0`).
     * `RGB565` (`FORMAT 17, CLUT_MODE = 0`): Code `16'h0000` ist transparent. Opakes Schwarz kann über Interpolation oder `RGB555` erzeugt werden.
     * `HAM12`: Code `12'h800` nach Zeilenstart/Reset ist **opakes Schwarz** (`opaque = 1`, `delta = 0`).
     * `HAM16`: Code `16'h8000` nach Reset ist **opakes Schwarz** (`opaque = 1`, `delta = 0`).

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
  - Der über `CLIP_XMAX` hinausgehende Pufferbereich bis Spalte 2047 (sowie ungenutzte Pixel im Overscan/HBlank) wird beim Pufferwechsel (`line_sync`) durch einen synchronen Hardware-Sweep im schnellen `clk_114`-Taktbereich deterministisch auf 0 gesetzt, sodass bei Folgezeilen niemals Alt-Daten im Speicher stehen.

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
    * Bei **`FORMAT 18` (`ARGB8888`)**: Direkt per Pixel aus `code[31:24]` (echtes Per-Pixel-Alpha).
    * Bei **`FORMAT 15..17`**: Aus dem Feld `SPR_ALPHA[7:0]` (Descriptor-Byte 7 `+$07`, das bei palettenfreien Formaten frei ist).
    * Bei **`FORMAT 0..14`**: Enthalten Palettenanker (`PAL_OFFSET` liegt auf Byte 7). Für diese Formate ist Byte 7 als `PAL_OFFSET` reserviert; Modus `11` verwendet für diese Formate den Standardwert $\alpha = 255$ (oder ein globales Register).

### 5.3 Mischen NACH dem fertigen 24-Bit-Amiga-Bild (4 Ebenen über `PRIO[7:6]`)
Das Mischen erfolgt **ganz am Ende von [`denise.v`](../mister/rtl/denise.v#L532)** nach dem fertigen 24-Bit-Amiga-Bild (`amiga_rgb[23:0]`):

| `PRIO`-Werte | `PRIO[7:6]` | Ebene relativ zum Amiga-Bild | Bedingung für Anzeige von `BUF_RGB` statt `amiga_rgb` (wenn `!blank_aligned`) |
| :--- | :---: | :--- | :--- |
| **`0`** | `00` | **Leer / Transparent** | Nie (`amiga_rgb` wird angezeigt) |
| **`1 .. 63`** | `00` | **Hintergrund-Layer** (vor `COLOR00`, hinter allen Bitplanes) | `BUF_PRIO != 0 && !sprsel_aligned && !pf_any_opaque` |
| **`64 .. 127`** | `01` | **Zwischen hinterem und vorderem Playfield** | `BUF_PRIO != 0 && !sprsel_aligned && !pf_front_opaque` |
| **`128 .. 191`** | `10` | **Vor allen Bitplanes, hinter Amiga-Sprites 0..7** | `BUF_PRIO != 0 && !sprsel_aligned` |
| **`192 .. 255`** | `11` | **Ganz vorn** (vor Bitplanes und vor Amiga-Sprites) | `BUF_PRIO != 0` (gewinnt immer innerhalb des sichtbaren Bildes) |

* **FullHD-Hintergründe & Tiles:** Wird ein `FORMAT 18`- oder `FORMAT 17`-Sprite mit `PRIO 1..63` definiert, fungiert es als **vollwertiger 24/32-Bit-Hintergrund**. Sind die Amiga-Bitplanes transparent (oder Denise-Bitplanes per Register deaktiviert), wird das TrueColor-Hintergrundbild nahtlos sichtbar. Über negative Startkoordinaten (`X_POS`, `Y_POS`) kann der Hintergrund pixelgenau gescrollt werden.

---

## 6. Sprite-Descriptor im Fast-RAM (16 Bytes = 2 × 64 Bit, `DESC_REV = 3`)

Das Sprite-Array liegt 32-Byte-aligned im DDR3-Fast-RAM und ist aufsteigend nach **`Y_POS`** sortiert.  
Ein einzelner **`4 × 64 Bit`-DDR3-Burst (`BURSTCNT = 4` = 32 Bytes)** lädt gleichzeitig **2 komplette Sprite-Descriptoren**!

### 64-Bit Wort 0 (Offset `+$00 .. +$07`): Position, Größe, Priorität & Palette/Alpha
| Offset | Bits | Typ | Feldname | Beschreibung |
| :---: | :---: | :---: | :--- | :--- |
| `+$00` | `[63:48]` | `int16` | **`Y_POS`** | Startzeile (vorzeichenbehaftet, ausgewertet als `int13` `-4096 .. +4095`, deckt FullHD `1080p` + Offscreen-Clipping ab; Bits `[15:13]` werden vorzeichenrichtig ignoriert) |
| `+$02` | `[47:32]` | `int16` | **`X_POS`** | Startspalte (vorzeichenbehaftet, ausgewertet als `int13` `-4096 .. +4095`, deckt `2048 px` + Offscreen-Clipping ab; Bits `[15:13]` werden vorzeichenrichtig ignoriert) |
| `+$04` | `[31:24]` | `uint8` | **`Y_HEIGHT_LO`** | Untere 8 Bit der Quellhöhe; zusammen mit `DATA_PTR[2:0]` als `Y_HEIGHT[10:8]` ergibt sich **`uint11 Y_HEIGHT = {DATA_PTR[2:0], Y_HEIGHT_LO}` (`1 .. 2047` Quellzeilen)**. **Wichtig:** Das Listen-Sentinel ist **`Y_HEIGHT[10:0] == 11'd0`** |
| `+$05` | `[23:16]` | `uint8` | **`X_WIDTH256`** | Breite in **`4 × 64 Bit` (256-Bit / 32-Byte) Burst-Blöcken** (`1 .. 64` Bursts = **8 bis 4.096 Quellpixel**; `0` = No-Op; Werte `> 64` werden auf `64` geklemmt) |
| `+$06` | `[15:8]` | `uint8` | **`PRIO`** | 8-Bit Priorität (`0` = dieses Sprite überspringen/unsichtbar; `1 .. 255` = aktiv) |
| `+$07` | `[7:0]` | `uint8` | **`PAL_OFFSET` / `SPR_ALPHA`** | Für Formate `0..14`: Paletten-Offset (`(PAL_OFFSET + raw_code) & 8'hFF`). Wichtig: Formate 13 (`12_6_8_6`) und 14 (`12_5555`) nutzen `PAL_OFFSET` für die nachfolgenden 6-/8-/5-Bit-Palettenanker!<br>Für palettenfreie Formate `15..17`: Globaler Alpha-Wert **`SPR_ALPHA[7:0]`** (`0..255`) für `BLEND_MODE = 11`.<br>Für Format `18` (`ARGB8888`): Per-Pixel-Alpha im Datenwort `code[31:24]` (Byte 7 reserviert/ignoriert). |

### 64-Bit Wort 1 (Offset `+$08 .. +$0F`): Datenzeiger, Format, Skalierung & Blend-Steuerung
| Offset | Bits | Typ | Feldname | Beschreibung |
| :---: | :---: | :---: | :--- | :--- |
| `+$08` | `[63:32]` | `uint32` | **`DATA_PTR`** | `[31:5]`: 32-Byte-aligned Basisadresse der Pixeldaten im Fast-RAM.<br>`[4]`: **Hardware-Maske 0** (`DATA_PTR & ~32'h10`, Pointer Bit 4 wird stets ignoriert/genullt).<br>`[3]`: **`FORMAT[4]`** (oberstes Bit des 5-Bit-Packformats: `0` für Formate `0..15`, `1` für Formate `16..18`).<br>`[2:0]`: **`Y_HEIGHT[10:8]`** (obere 3 Bits der 11-Bit-Quellhöhe für Sprites mit `256 .. 2047` Zeilen). |
| `+$0C` | `[31:28]` | `uint4` | **`FORMAT_LO`** | Untere 4 Bits des 5-Bit-Packformats **`uint5 FORMAT = {DATA_PTR[3], FORMAT_LO[3:0]}`** (`0 .. 18` gültig gemäß Abschnitt 3; `19 .. 31` = No-Op ohne DMA). |
| `+$0C` | `[27:24]` | `uint4` | **`FLAGS`** | Bit `0`: `H_FLIP` (Horizontal spiegeln)<br>Bit `1`: `V_FLIP` (Vertikal spiegeln)<br>Bit `2`: `SMOOTH_X` (24-Bit RGB Horizontal-Interpolation ein)<br>Bit `3`: `PRIO_GE` (`>=` statt `>` bei gleicher Priorität) |
| `+$0D` | `[23:16]` | `uint8` | **`X_SCALE`** | Horizontaler Skalierungsfaktor (Festkomma `2.6`, `$40` = 1,0×; Bereich **`$10` (4,0× Zoom) bis `$FF` (0,25× Shrink)**; `0` = No-Op, `1..$0F` geklemmt auf `$10`). |
| `+$0E` | `[15:8]` | `uint8` | **`Y_SCALE`** | Vertikaler Skalierungsfaktor (Festkomma `2.6`, `$40` = 1,0×; Bereich **`$10` (4,0× Zoom) bis `$FF` (0,25× Shrink)**; `0` = No-Op, `1..$0F` geklemmt auf `$10`). |
| `+$0F` | `[7:0]` | `uint8` | **`STEP_CTRL` / `BLEND_CTRL`** | Bit `7`: `CUSTOM_STEP` (`0` = Globale 4-Bit-HAM-Steps aus `$DFF588`, `1` = Sprite-eigene HAM-Step-Skalierung).<br>Bit `6`: **`CLUT_MODE`** (`0` = HAM-Modus bzw. `RGB565` bei `FORMAT 17`, `1` = Palettenmodus bzw. `RGB555` bei `FORMAT 17`).<br>Bits `[5:4]`: **`BLEND_MODE[1:0]`** (wenn `CUSTOM_STEP == 0` oder `FORMAT >= 17`): `00` Opak, `01` Additiv, `10` 50/50, `11` Alpha.<br>Bits `[5:0]`: Wenn `CUSTOM_STEP == 1` bei HAM: `R[5:4]`, `G[3:2]`, `B[1:0]` Schrittmultiplikatoren. |

---

## 7. Verbindliche Verträge: DMA, Epochs, Handshake & Bank-Commit (Review #5 Punkt 3 & Review #6 Punkt 6)

### 7.1 DMA-Anforderungs- und Annahme-Bedingung (`ddram_ctrl.v`)
1. **Handshake-Vertrag:**  
   Eine Anforderung für einen 4er-Burst (`BURSTCNT = 4`, 32 Bytes) gilt als angenommen, wenn im selben Takt `spr_dma_req == 1 && spr_dma_ack == 1` ansteht.
2. **In-Flight Beat Tracking:**  
   Die DMA-Steuerung führt einen Zähler `in_flight_beats` (`0..64`). Jede angenommene Anforderung addiert `+4`. Jeder eintreffende Datenbeat (`spr_dma_valid == 1`) dekrementiert `-1`. Eine neue Anforderung darf nur gestellt werden, wenn:
   $$\text{fifo\_count} + \text{in\_flight\_beats} \le 60$$
3. **Audio-Priorität & Latenz-Garantie:**  
   Sprite-DMA hat strikt niedrigere Priorität als Audio-DMA (Port 2) und Video-Refresh. Bei 4er-Bursts (`BURSTCNT = 4`) beträgt die reine Busbelegung 4 Takte (~35 ns bei 114 MHz). Einschließlich Controller-Arbitrierung, Refresh-Zyklen und Worst-Case-Waitstates ist die Latenz am Audio-Port im DDR3-Controller auf maximal 16 Takte begrenzt. Da das Audio-FIFO 16 Samples (~330 µs) Puffer hält, ist diese Latenz vernachlässigbar (< 0,01 % des Audiopuffers).

### 7.2 Dynamisches Zeilenbudget, Epoch-Tags, Drain-Mechanismus & 4-Zeilen-Wrap-Schutz
1. **Zeilenbudget-Ende (`line_budget_eof`):**  
   Genau 16 Takte vor Zeilenende sperrt die Engine neue Burst-Requests (`spr_dma_req <= 0`).
2. **Epoch-Tagging, Drain & Schutz vor 4-Zeilen-Wrap-Around:**  
   Jeder Request wird mit einem 2-Bit Zeilen-Epoch-Tag `cur_epoch` (`00`, `01`, `10`, `11`) markiert, der zeilenweise rotiert. Eintreffende Beats, deren Epoch nicht mehr zur aktuellen Zeile gehört, werden nicht in das Prefetch-FIFO geschrieben, sondern in eine Discard-Senke verworfen (`drain_beats`).  
   **Schutz vor Wiederverwendung nach 4 Zeilen:** Am Zeilenende wartet die Hardware in einem definierten Drain-State, bis alle offenen Anforderungen bedient wurden (`in_flight_beats == 0`). Erst nach vollständigem Drain (`drain_complete`) wird die nächste Bildschirmzeile für neue DMA-Bursts freigegeben. Das Prefetch-FIFO wird vor Beginn der Folgezeile deterministisch geleert (`fifo_clear = 1`). Dadurch ist mathematisch ausgeschlossen, dass verzögerte Beats aus Zeile $Y$ in Zeile $Y+4$ eintreffen können!
3. **Diagnosezähler:**  
   Wurde ein Sprite wegen Erreichen von `line_budget_eof` vorzeitig abgebrochen, inkrementiert die Hardware den 16-Bit-Zähler **`SPR_OVERRUN_CNT`** (`$DFF594`). Bereits in den Zeilenbuffer geschriebene Pixel bleiben sichtbar.

### 7.3 Bank-Commit, Shadow-Register & VBlank-Kopplung
1. **Shadow-Register & CPU-Ownership:**  
   Inaktive Descriptor-Listen, Paletten und HAM-Steps werden von der CPU in separaten inaktiven Speicherregionen / Schattenregistern vorbereitet. Bis zur Übernahme verbleiben alle Daten unter exklusiver CPU-Ownership.
2. **Atomarer Bank-Commit:**  
   Der Wechsel auf die neue Konfiguration wird durch das CPU-Bit `SPR_COMMIT_REQ` signalisiert. Die Übernahme in den aktiven Satz (`active_list_ptr`, aktive Palette/Steps) erfolgt ausschließlich bei **aktivem VBlank am Frame-Start (`next_y == 0 && vblank_active`)**. Nach erfolgreicher Übernahme setzt die Engine das Status-Bit `SPR_COMMIT_ACK`. Erst ab diesem ACK darf die CPU die alte Speicherbank für den nächsten Frame überschreiben.
3. **Buffer Ownership:**  
   Zeilenbuffer A und B tauschen ihre Rollen deterministisch am Zeilensynchronisationspunkt (`line_sync`). Während Denise Buffer A ausliest und per Clear-on-Read leert, schreibt die Engine exklusiv in Buffer B.

---

## 8. Diagnose-Metriken & Reproduzierbare Test-Suite (Review #5 & Review #6)

### 8.1 Klarstellung der Zeilenlast-Metriken & Diagnose-Register
Die im HUD angezeigte Zeilenlast ist als **`Decoder-Operationsschätzung ohne DMA/Clear/Ausgabe`** definiert. Für detaillierte Hardware-Analysen stellt die Engine getrennte Zähler bereit:
* **`src_steps`:** Anzahl der dekomprimierten Quellpixel.
* **`dst_steps`:** Anzahl der erzeugten Zielpixel nach Skalierung.
* **`skip_words`:** Anzahl der per 1-Takt Zero-Word-Skip übersprungenen 64-Bit-Worte.
* **`descriptors_scanned`:** Anzahl der im Frame ausgewerteten Descriptoren.
* **Hardware-Register (Clear-on-Read / VBlank-Reset):**
  * `$DFF590`: `SPR_MAX_BUSY` (Maximale Decoder-Busy-Takte einer Zeile).
  * `$DFF592`: `SPR_DMA_STALL` (Wartezyklen auf Speicherdaten).
  * `$DFF594`: `SPR_OVERRUN_CNT` (Anzahl unvollständiger Zeilenbudgets).

### 8.2 Offizielle Versionierte Test-Suite (`fixtures/sprite_engine_fixtures_v3.json`)
Zur dauerhaften Qualitätssicherung und für Cross-Renderer-Vergleiche zwischen Python, Browser-JS und FPGA-Simulatoren liegt die versionierte Test-Suite vor:
* **Pfad:** [`NanoMig/mister/tests/sprite_engine/fixtures/sprite_engine_fixtures_v3.json`](../mister/tests/sprite_engine/fixtures/sprite_engine_fixtures_v3.json)
* **Validierungsskript:** [`NanoMig/mister/tests/sprite_engine/verify_fixtures.py`](../mister/tests/sprite_engine/verify_fixtures.py) – führt jeden Testfall dynamisch über `render_scanline()` aus und vergleicht alle Pixel bitgenau.
* **Gegenprüfungen:**
  1. Raw 16-Byte Descriptor Pack/Unpack Roundtrip ohne Bypasses.
  2. Negative Koordinaten (`X_POS = -8, Y_POS = -10`) und horizontales/vertikales Clipping.
  3. Skalierungs-Grenzfälle (`Scale 16, 63, 65, 255`).
  4. Gleichheits-Arbitrierung (`PRIO_GE = 0` vs. `PRIO_GE = 1`).
  5. Opaque Schwarz-Semantik (`RGB555 $8000`, HAM12 `$800`, HAM16 `$8000`) vs. Transparenz (`$0000`).
  6. 4 Hardware-Blend-Modi (`00` Opak, `01` Additiv, `10` 50/50, `11` Alpha) mit Alpha 0-Transparenz (`WE = 0`) und Endpunkt-Sättigung bei Alpha 255.
  7. `FORMAT 18` (`ARGB8888`) mit Per-Pixel-Alpha und Zero-Word-Skip.

---

## 9. Ressourcen-Bilanz (Cyclone V `5CSEBA6U23I7`)

Freie Ressourcen im Minimig-AGA Core (Stand Quartus Fit vom 08.11.2026): **5.144 ALMs**, **224 M10K-Blöcke**, **35 DSPs**.  
*(Hinweis: ALM- und DSP-Werte sind fundierte Architektur-Schätzungen vor Verilog-Synthese und TimeQuest STA; ein zyklusgenaues Taktmodell mit Stalls, Clear und Blend-Forwarding wird nach Freigabe der Spezifikation realisiert).*

| Modul / Teilblock | ALMs | M10K-Blöcke | DSPs |
| :--- | :---: | :---: | :---: |
| **Ping-Pong Zeilenbuffer A & B** (`2 × 2048 × 32 Bit` + 1-Takt-Forwarding) | ~50 | **16** | 0 |
| **Dedizierte Sprite-Palette** (`256 × 24 Bit` Dual-Port) | ~20 | **1** | 0 |
| **64-Bit Prefetch-FIFO** (`64 × 64 Bit` zwischen DDR3 & Unpacker) | ~25 | **1** | 0 |
| **Multi-Mode Unpacker** (19 Formate `0..18` inkl. `ARGB8888` & Zero-Word-Skip) | ~140 | 0 | 0 |
| **Dedizierter HAM/HighColor-Decoder** (12-Bit Pre-Delta, `4-Bit step_r/g/b`, `HAM12/16`) | ~115 | 0 | 0 |
| **X/Y-Skalierer, `H_FLIP`/`V_FLIP` & 24-Bit RGB X-Interpolator (`SMOOTH_X`)** | ~105 | 0 | 0 |
| **Hardware Alpha-Blender** (4 Modi: Opak, Additiv, 50/50, 8-Bit Alpha) | ~65 | 0 | 0–1 |
| **Y-Listen-Scanner (`4096`), Clipping, 13×8-Multiplizierer & DMA-FSM** | ~210 | 0 | 0–1 |
| **Denise-Ausgangs-Prioritätsmischer** (4 Ebenen + Blank-Gate) | ~35 | 0 | 0 |
| **Gesamtsumme** | **~760 ALMs** | **18 M10K** | **0–1 DSP** |
| *Anteil an den freien Ressourcen* | *~14,8 % der freien ALMs* | *~8,0 % der freien M10K* | *< 3 %* |
