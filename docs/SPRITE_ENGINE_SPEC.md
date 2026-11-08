# Architektur- und Design-Spezifikation: 32/64-Bit HAM- & CLUT-Sprite-Engine (Rev. 2 – FullHD 2048px & Hardware-Verträge)

**Status:** Spezifikation mit verbindlichen Hardware-Verträgen nach Review durch Tobys KI (kein RTL-Code erzeugt)  
**Zielplattform:** MiSTer FPGA (Cyclone V `5CSEBA6U23I7`), Minimig-AGA / Denise-Erweiterung  

---

## 1. Überblick & Kernidee

Die neue Sprite-Engine kombiniert die **variablen HAM-Modi (`HAM03`, `HAM04`, `HAM05`, `HAM06`, `HAM08`)** sowie einen **wahlweisen direkten Palettenmodus (`CLUT_MODE`)** mit einer **FullHD-fähigen `2048`-Pixel Ping-Pong-Zeilenbuffer-Architektur**, einem **eigenen dedizierten High-Speed-Decoder** und direktem **64-Bit-Burst-DMA-Zugriff (`BURSTCNT = 4`) auf das DDR3-Fast-RAM**.

1. **Eigener dedizierter Sprite-HAM/CLUT-Decoder (volle Geschwindigkeit):**
   * Die Sprite-Engine besitzt ihren **eigenen `ham_pixel_decoder`** sowie eine **eigene 256×24-Bit-Sprite-Palette (M10K)**.
   * Dadurch arbeitet die Sprite-Engine zu **100 % unabhängig vom Playfield-HAM (`ext_ham`)** und kann über die gesamte Zeilenzeit ohne jede Unterbrechung mit voller Geschwindigkeit rendern.
2. **Konstanter 256-Bit-Burst-Speicherzugriff (`4 × 64 Bit`) trotz variabler Pixeldichte:**
   * Die minimale Breite und das Zeilen-Raster eines Sprites im RAM beträgt **`4 × 64 Bit = 256 Bit` (32 Bytes = 8 × 32-Bit-Blöcke)**.
   * Dies entspricht exakt einem physischen **DDR3-BL8-Burst (`BURSTCNT = 4`)** auf dem MiSTer. Jeder Burst-Zugriff liefert in 4 aufeinanderfolgenden `clk_114`-Takten **32 bis 64 Pixel auf einen Schlag** (und beim Lesen der Descriptor-Liste gleich **2 komplette 16-Byte-Descriptoren** auf einmal!).
   * **Hardware Zero-Word-Skip (100 % bit-identisch):** Ist ein 64-Bit-Wort innerhalb des 256-Bit-Bursts komplett `0` (`64'h00000000_00000000` = lauter transparente `raw_code == 0`-Pixel) und steht kein Zoom (`X_SCALE == 8'h40`) sowie kein opakes Vorgängerpixel (`prev_opaque == 0`) an, setzt der Entpacker den HAM-Akkumulator auf `0`, addiert die Pixelanzahl (`8..16`) direkt auf `dst_x` (bzw. subtrahiert bei `H_FLIP`) und überspringt das gesamte 64-Bit-Wort in **einem einzigen Takt**!
3. **Zwei FullHD-fähige `2048`-Pixel-Zeilenbuffer im Wechsel (Ping-Pong + deterministisches Clear):**
   * Beide Zeilenbuffer (A und B) umfassen **`2048 × 32 Bit`** (`16 M10K` gesamt) und unterstützen damit alle Auflösungen von Lores (`320 px`) über SuperHiRes-Overscan (`1432 px`) bis hin zu **FullHD (`1920 × 1080` / `2048 px`)**.
   * Während **Zeilenbuffer A** synchron zum Videostrahl am Ausgang von Denise ausgelesen, mit dem fertigen 24-Bit-Amiga-Bild gemischt und deterministisch über alle `0..2047` Spalten auf `0` gelöscht wird,
   * rendert die Sprite-Engine im Hintergrund die nächste Bildschirmzeile (`next_y`) in **Zeilenbuffer B** (inkl. **1-Takt-Write-Forwarding** für aufeinanderfolgende Schreibzugriffe auf dieselbe Spalte `dst_x`).
4. **Y-sortierte Descriptor-Liste im Fast-RAM (bis zu `4.096` Descriptoren):**
   * Der Engine wird über ein VBlank-gepuffertes Register (`SPR_LIST_PTR`) ein 32-Bit-Zeiger auf ein nach **`Y_POS` aufsteigend sortiertes Array** übergeben.
   * Sobald beim Scannen der Liste ein Eintrag mit `Y_POS > next_y` oder das Sentinel `Y_HEIGHT == 0` erreicht wird, bricht die Engine die Suche für diese Zeile sofort ab (**Early Exit**).
5. **Freies Positionieren, X/Y-Skalierung, 24-Bit-Interpolation & Hardware-Clipping:**
   * Sprites können an beliebigen negativen oder positiven Koordinaten (`int16 X_POS`, `int16 Y_POS`, ausgewertet als `int13` `-4096..+4095`) außerhalb des Bildschirms starten und enden, stufenlos skaliert (`X_SCALE`, `Y_SCALE` von `0,25×` bis `4,0×`), gespiegelt (`H_FLIP`, `V_FLIP`) und per 24-Bit-Subpixel-Filterung (`SMOOTH_X`) geglättet werden.

---

## 2. Dedizierter High-Speed HAM-Decoder & Verbreiterte Vorberechnungs-Arithmetik

### 2.1 Warum ein eigener Decoder für die Sprite-Engine gesetzt ist
* Würde sich die Sprite-Engine den Decoder mit dem Playfield (`ext_ham`) teilen, wäre der Decoder bei aktivem SuperHiRes-HAM-Playfield (1280 px) oder FullHD für den Großteil der Zeile durch das Playfield blockiert.
* Mit einem **eigenen dedizierten Decoder** (~100 ALMs) + eigener Paletten-RAM-Instanz (1 M10K) stehen der Sprite-Engine **100 % der Zeilenzeit (volle 64 µs)** ungeteilt zur Verfügung.

### 2.2 Pipeline-Optimierung & Verbreiterung der Delta-Vorberechnung (13-Bit signed)
In `c0_ham_from_setup.rpt` (Slow 1100mV 100C) hatte der bisherige Playfield-Decoder (`ham_pixel_decoder.v`) eine kombinatorische Laufzeit von **`14,774 ns`**, weil Bit-Decode, `turbo`-Shift, Delta-Mux und die Addition `accumulator + delta` im selben Takt stattfanden.

* **Entscheidende Beobachtung:** Die Vorzeichen-Deltas `delta_r`, `delta_g`, `delta_b` hängen **nur von `code`, `mode` und `step_r/g/b` ab – nicht vom `accumulator`!**
* **Verbindliche Bitbreiten (kein Überlauf bei großen Steps/Skalierungen):**
  * Da im Referenzdecoder `255 × step(4) × scale(2) = ±2040` erreichen kann, werden die vorberechneten Deltas mit **13 Bit signed (`-4096 .. +4095`)** geführt.
  * Die Addition im Rekursions-Zyklus erfolgt mit **14 Bit signed (`-8192 .. +8191`)** vor der Sättigung auf `0..255` (`uint8`).
* **2-Stufen-Aufteilung (ohne Zusatzlatenz, parallel zum Paletten-BRAM-Read):**
  1. **Stufe 1 (Entpacker & Paletten-Read-Takt):**  
     Parallel zum synchronen Lesezugriff auf das M10K-Paletten-RAM (`palette_index = (PAL_OFFSET + raw_code) & 8'hFF`) berechnet die Logik bereits `anchor_reg`, `opaque_reg = (raw_code != 0)` sowie die fertigen **13-Bit-signed** Summanden `delta_r`, `delta_g`, `delta_b` und speichert sie in Registern.
  2. **Stufe 2 (Akkumulator-Takt):**  
     Im eigentlichen Rekursions-Zyklus führt der Decoder **nur noch eine einzige 14-Bit-Addition mit Sättigung auf `0..255`** und den 2:1-Anker-Mux aus:
     $$\text{acc\_next} = (\neg\text{opaque\_reg}) \;?\; \text{24'h000000} : \big(\text{anchor\_reg} \;?\; \text{palette\_data} : \text{sat}_{0..255}(\text{acc} + \text{delta\_reg})\big)$$
* **Pipeline-Steuerung (`valid`, `decoder_hold`, `line_reset`):**
  * Zu Beginn jeder neuen Sprite-Quellzeile (`line_reset = 1`) werden `acc_r/g/b <= 0`, `prev_rgb <= 0`, `prev_opaque <= 0` sowie die Pipeline-Valid-Stufen synchron zurückgesetzt.
  * Ist `decoder_hold == 1` (während der `X_SCALE`-Interpolator bei Vergrößerung Zwischenspalten ausschreibt), frieren alle Decoder-Stufen und `acc_r/g/b` taktsynchron ein.

---

## 3. Die 13 festgelegten 32-Bit-HAM-Mischmodi (`HAM_32BIT_*`) & `CLUT_MODE`

Die Pixeldaten im RAM sind in 32-Bit-Worten gepackt, wobei die minimale Sprite-Breite (und das Zeilen-Raster) auf **`4 × 64 Bit = 256 Bit` (32 Bytes = 8 × 32-Bit-Blöcke)** festgelegt ist.  
Dadurch nutzt jeder DMA-Lesezugriff mit **`BURSTCNT = 4`** den physischen **DDR3-BL8-Burst** (32-Bit DDR3 × 8 = 256 Bit) zu **100 %** aus und liefert in 4 aufeinanderfolgenden `clk_114`-Takten **32 bis 64 Pixel auf einen Schlag**:

| `FORMAT` | Name im Konverter | Bit-Sequenz je 32-Bit-Wort (Summe = 32 Bit) | Pixel / 32 Bit | Pixel / 64 Bit | **Pixel / 256-Bit-Burst (`4×64 Bit`)** | `slotsPerBank` (HAM) | Farben (CLUT) |
| :---: | :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| **`0`** | `HAM_32BIT_44444444` | `4 - 4 - 4 - 4 - 4 - 4 - 4 - 4` | **8 px** | 16 px | **64 px** | 8 | 16 |
| **`1`** | `HAM_32BIT_53535353` | `5 - 3 - 5 - 3 - 5 - 3 - 5 - 3` | **8 px** | 16 px | **64 px** | 16 | 32 / 8 |
| **`2`** | `HAM_32BIT_63436343` | `6 - 3 - 4 - 3 - 6 - 3 - 4 - 3` | **8 px** | 16 px | **64 px** | 32 | 64 / 16 / 8 |
| **`3`** | `HAM_32BIT_6446444` | `6 - 4 - 4 - 6 - 4 - 4 - 4` | **7 px** | 14 px | **56 px** | 32 | 64 / 16 |
| **`4`** | `HAM_32BIT_5454545` | `5 - 4 - 5 - 4 - 5 - 4 - 5` | **7 px** | 14 px | **56 px** | 16 | 32 / 16 |
| **`5`** | `HAM_32BIT_6454544` | `6 - 4 - 5 - 4 - 5 - 4 - 4` | **7 px** | 14 px | **56 px** | 32 | 64 / 32 / 16 |
| **`6`** | `HAM_32BIT_655655` | `6 - 5 - 5 - 6 - 5 - 5` | **6 px** | 12 px | **48 px** | 32 | 64 / 32 |
| **`7`** | `HAM_32BIT_844844` | `8 - 4 - 4 - 8 - 4 - 4` | **6 px** | 12 px | **48 px** | 128 | 256 / 16 |
| **`8`** | `HAM_32BIT_846554` | `8 - 4 - 6 - 5 - 5 - 4` | **6 px** | 12 px | **48 px** | 128 | 256..16 |
| **`9`** | `HAM_32BIT_646565` | `6 - 4 - 6 - 5 - 6 - 5` | **6 px** | 12 px | **48 px** | 32 | 64 / 32 / 16 |
| **`10`** | `HAM_32BIT_86666` | `8 - 6 - 6 - 6 - 6` | **5 px** | 10 px | **40 px** | 128 | 256 / 64 |
| **`11`** | `HAM_32BIT_85865` | `8 - 5 - 8 - 6 - 5` | **5 px** | 10 px | **40 px** | 128 | 256 / 64 / 32 |
| **`12`** | `HAM_32BIT_8888` | `8 - 8 - 8 - 8` | **4 px** | 8 px | **32 px** | 128 | **256** |

*(Werte `FORMAT = 13..15` sind als ungültig/Reserve definiert und führen zum deterministischen Überspringen des Sprites ohne DMA-Zugriff).*

### 3.1 Wahlweise HAM-Modus oder normaler Palettenmodus (`CLUT_MODE`) pro Sprite
Über `STEP_CTRL[6] = CLUT_MODE` kann für jedes Sprite individuell zwischen **HAM-Modus (`0`)** und **normalem Palettenmodus / CLUT (`1`)** gewählt werden (~1 ALM Zusatzlogik):
* **`CLUT_MODE = 0` (HAM-Modus):**  
  Das oberste Bit (`MSB`) jedes Pixel-Codes entscheidet zwischen **Paletten-Anker (`MSB == 0`)** und **RGB-Delta (`MSB == 1`)**. Bei einem Anker (`MSB == 0`) ist der Paletten-Index `(PAL_OFFSET + raw_code[K-2:0]) & 8'hFF`.
* **`CLUT_MODE = 1` (Normaler Palettenmodus / CLUT):**  
  Die Hardware zwingt intern `anchor_reg = 1` für jedes Pixel und nutzt **alle Bits des Pixel-Codes (inklusive `MSB`!)** direkt als Paletten-Offset (`palette_index = (PAL_OFFSET + raw_code) & 8'hFF`):
  * Im Format `0` (`44444444`, **64 Pixel pro 256-Bit-Burst**) stehen damit volle **16 Palettenfarben (`0..15`)** pro Pixel zur Verfügung.
  * Im Format `12` (`8888`, **32 Pixel pro 256-Bit-Burst**) stehen volle **256 Palettenfarben (`0..255`)** pro Pixel zur Verfügung.

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

## 5. FullHD-Zeilenbuffer (`2048 × 32 Bit`), Write-Forwarding & Denise-Komposition

### 5.1 Format im `2048`-Pixel Ping-Pong-Zeilenbuffer
Beide Ping-Pong-Zeilenbuffer (A und B) haben eine Tiefe von **2.048 Pixeln** (deckt Lores `320 px`, SuperHiRes-Overscan `1.432 px` sowie **FullHD `1920 × 1080` / `2048 px`** ab) und eine Breite von **32 Bit pro Pixel** (`16 M10K`-Blöcke gesamt):

$$\underbrace{\text{BUF\_PRIO [31:24]}}_{\text{8-Bit Priorität (`0` = leer)}} \;\Big|\; \underbrace{\text{R [23:16]} \;\cdot\; \text{G [15:8]} \;\cdot\; \text{B [7:0]}}_{\text{24-Bit RGB}}$$

* **1-Takt Write-Forwarding für den Prioritätsvergleich:**  
  Da das synchrone Lesen von `OLD_PRIO` aus dem M10K-Zeilenbuffer 1 Takt Latenz besitzt, hält die Schreibstufe ein Bypass-Register (`last_wr_valid`, `last_wr_x[10:0]`, `last_wr_prio[7:0]`).  
  Wird in zwei direkt aufeinanderfolgenden Takten dieselbe Zielspalte `dst_x == last_wr_x` adressiert (z. B. beim Vergrößern `X_SCALE < 8'h40` oder beim nahtlosen Übergang zum nächsten Sprite), verwendet der Prioritätskomparator automatisch `last_wr_prio` statt des RAM-Ausgangs:
  $$\text{eff\_old\_prio} = (\text{last\_wr\_valid} \land (\text{dst\_x} == \text{last\_wr\_x})) \;?\; \text{last\_wr\_prio} : \text{ram\_old\_prio}$$
* **Schreibbedingung (`WE`):**
  $$\text{WE} = \text{out\_opaque} \;\land\; \big(\text{PRIO\_GE} \;?\; (\text{SPR\_PRIO} \ge \text{eff\_old\_prio}) : (\text{SPR\_PRIO} > \text{eff\_old\_prio})\big)$$
* **Deterministisches Löschen über alle 2.048 Spalten:**  
  Im aktiven Auslese-Puffer wird jede gelesene Spalte sofort im selben Takt mit `32'h0000_0000` überschrieben (**Clear-on-Read**). Zusätzlich läuft der Löschzähler bis zum Zeilenende deterministisch über alle verbleibenden Spalten bis `2047`, sodass auch bei schmaleren Bildschirmmodi oder Moduswechseln niemals alte Pixel am Rand stehenbleiben.

### 5.2 Mischen NACH dem fertigen 24-Bit-Amiga-Bild (4 Ebenen über `PRIO[7:6]`)
Das Mischen erfolgt **ganz am Ende von [`denise.v`](../mister/rtl/denise.v#L532)** nach dem fertigen 24-Bit-Amiga-Bild (`amiga_rgb[23:0]`).  
Dazu werden die Status-Signale exakt mit derselben Pipeline-Latenz wie `amiga_rgb` (bzw. `ext_ham`-RGB) verzögert:
* `blank_aligned`: Aktives Horizontal-/Vertikal-Blanking. **Wichtig:** Bei `blank_aligned == 1` ist der Videoausgang **immer `24'h000000`** (sperrt zwingend auch Sprites auf Ebene `11`!).
* `sprsel_aligned`: Klassisches Amiga-Sprite `0..7` ist an diesem Pixel sichtbar (`!= 0`).
* `pf_front_opaque`: Im Single-Playfield-Modus `bpl_index != 0`; im Dual-Playfield-Modus das laut `BPLCON2[6]` (`PF2PRI`) vorn liegende Playfield `!= 0`.
* `pf_any_opaque`: Irgendein Playfield (PF1 oder PF2) ist an diesem Pixel `!= 0` (nicht `COLOR00`).

| `PRIO`-Werte | `PRIO[7:6]` | Ebene relativ zum Amiga-Bild | Bedingung für Anzeige von `BUF_RGB` statt `amiga_rgb` (wenn `!blank_aligned`) |
| :--- | :---: | :--- | :--- |
| **`0`** | `00` | **Leer / Transparent** | Nie (`amiga_rgb` wird angezeigt) |
| **`1 .. 63`** | `00` | **Hintergrund-Layer** (vor `COLOR00`, hinter allen Bitplanes) | `BUF_PRIO != 0 && !sprsel_aligned && !pf_any_opaque` |
| **`64 .. 127`** | `01` | **Zwischen hinterem und vorderem Playfield** | `BUF_PRIO != 0 && !sprsel_aligned && !pf_front_opaque` |
| **`128 .. 191`** | `10` | **Vor allen Bitplanes, hinter Amiga-Sprites 0..7** | `BUF_PRIO != 0 && !sprsel_aligned` |
| **`192 .. 255`** | `11` | **Ganz vorn** (vor Bitplanes und vor Amiga-Sprites) | `BUF_PRIO != 0` (gewinnt immer innerhalb des sichtbaren Bildes) |

---

## 6. Sprite-Descriptor im Fast-RAM (16 Bytes = 2 × 64 Bit, FullHD-fähig)

Das Sprite-Array liegt 32-Byte-aligned im DDR3-Fast-RAM und ist aufsteigend nach **`Y_POS`** sortiert.  
Ein einzelner **`4 × 64 Bit`-DDR3-Burst (`BURSTCNT = 4` = 32 Bytes)** lädt dabei gleichzeitig **2 komplette Sprite-Descriptoren**!  
Alle Felder in Wort 0 sind für den 68000/68020-Programmierer sauber auf **16-Bit-Wort- bzw. 8-Bit-Byte-Grenzen** ausgerichtet (`MOVE.W` / `MOVE.B`). Für Riesen-Sprites in FullHD (`> 255` bis `2.047` Quellzeilen Höhe) werden die 3 oberen Höhenbits `Y_HEIGHT[10:8]` in den durch das 32-Byte-Alignment ohnehin freien Bits `DATA_PTR[2:0]` übergeben.

### 64-Bit Wort 0 (Offset `+$00 .. +$07`): Position, Größe, Priorität & Bank
| Offset | Bits | Typ | Feldname | Beschreibung |
| :---: | :---: | :---: | :--- | :--- |
| `+$00` | `[63:48]` | `int16` | **`Y_POS`** | Startzeile (vorzeichenbehaftet, ausgewertet als `int13` `-4096 .. +4095`, deckt FullHD `1080p` + Offscreen-Clipping ab) |
| `+$02` | `[47:32]` | `int16` | **`X_POS`** | Startspalte (vorzeichenbehaftet, ausgewertet als `int13` `-4096 .. +4095`, deckt `2048 px` + Offscreen-Clipping ab) |
| `+$04` | `[31:24]` | `uint8` | **`Y_HEIGHT_LO`** | Untere 8 Bit der Quellhöhe; zusammen mit `DATA_PTR[2:0]` als `Y_HEIGHT[10:8]` ergibt sich **`uint11 Y_HEIGHT` (`1 .. 2047` Quellzeilen; `11'd0` = Listen-Sentinel!)** |
| `+$05` | `[23:16]` | `uint8` | **`X_WIDTH256`** | Breite in **`4 × 64 Bit` (256-Bit / 32-Byte) Burst-Blöcken** (`1 .. 64` Bursts = **32 bis 4.096 Quellpixel**; `0` = No-Op; Werte `> 64` werden auf `64` geklemmt) |
| `+$06` | `[15:8]` | `uint8` | **`PRIO`** | 8-Bit Priorität (`0` = dieses Sprite überspringen/unsichtbar; `1 .. 255` = aktiv) |
| `+$07` | `[7:0]` | `uint8` | **`PAL_OFFSET`** | Start-Offset in der 256-Farben-Sprite-Palette (`palette_idx = (PAL_OFFSET + raw_code) & 8'hFF`) |

### 64-Bit Wort 1 (Offset `+$08 .. +$0F`): Datenzeiger, Format, Skalierung & Steuerung
| Offset | Bits | Typ | Feldname | Beschreibung |
| :---: | :---: | :---: | :--- | :--- |
| `+$08` | `[63:32]` | `uint32` | **`DATA_PTR`** | `[31:5]`: 32-Byte-aligned Basisadresse der Pixeldaten im Fast-RAM (`DATA_PTR & 32'hFFFF_FFE0`)<br>`[2:0]`: **`Y_HEIGHT[10:8]`** (obere 3 Bits der Quellhöhe für Sprites mit `256 .. 2047` Zeilen; bei normalen Sprites `<= 255` einfach `0`) |
| `+$0C` | `[31:28]` | `uint4` | **`FORMAT`** | HAM/CLUT-Packformat `0 .. 12` (gemäß Tabelle in Abschnitt 3; `13..15` = No-Op) |
| `+$0C` | `[27:24]` | `uint4` | **`FLAGS`** | Bit `0`: `H_FLIP` (Horizontal spiegeln)<br>Bit `1`: `V_FLIP` (Vertikal spiegeln)<br>Bit `2`: `SMOOTH_X` (24-Bit RGB Horizontal-Interpolation ein)<br>Bit `3`: `PRIO_GE` (`>=` statt `>` bei gleicher Priorität) |
| `+$0D` | `[23:16]` | `uint8` | **`X_SCALE`** | Horizontaler Skalierungsfaktor (Festkomma `2.6`, `$40` = 1,0×; zulässiger Bereich **`$10` (4,0× Zoom) bis `$FF` (0,25× Shrink)**; `0` = No-Op, `1..$0F` wird auf `$10` geklemmt) |
| `+$0E` | `[15:8]` | `uint8` | **`Y_SCALE`** | Vertikaler Skalierungsfaktor (Festkomma `2.6`, `$40` = 1,0×; zulässiger Bereich **`$10` (4,0× Zoom) bis `$FF` (0,25× Shrink)**; `0` = No-Op, `1..$0F` wird auf `$10` geklemmt) |
| `+$0F` | `[7:0]` | `uint8` | **`STEP_CTRL`** | Bit `6`: **`CLUT_MODE`** (`0` = HAM-Modus, `1` = Normaler Palettenmodus / CLUT)<br>Bit `7`: `CUSTOM_STEP` (`0` = Globale HAM-Steps, `1` = Sprite-eigene HAM-Step-Skalierung `R[5:4]`, `G[3:2]`, `B[1:0]`) |

---

## 7. Exakte Skalierungs-Arithmetik, Clipping, `SMOOTH_X` & Zero-Word-Skip

Für jede vorzubereitende Zielzeile `next_y` (`0 .. Screen_Height - 1`, bis `1080` bei FullHD):

1. **Atomarer VBlank-Commit & Listen-Sicherheit (`MAX_DESCRIPTORS = 4096`):**
   * CPU-Schreibzugriffe auf `SPR_LIST_PTR` gehen in ein Shadow-Register und werden erst beim **VBlank-Start (`next_y == 0`)** atomar in `active_list_ptr` übernommen.
   * Die Hardware liest pro Zeile maximal `MAX_DESCRIPTORS = 4096` Descriptoren (Schutz gegen fehlendes Sentinel `Y_HEIGHT == 0`).
2. **Sliding-Window Start-Index (`first_active_idx`) & Early Exit:**
   * Zu Beginn des Frames (`next_y == 0`) ist `first_active_idx = 0`. Solange die führenden Sprites der Liste bereits komplett oberhalb von `next_y` liegen (`scaled_y >= Y_HEIGHT`), rückt `first_active_idx` für die Folgezeile vor.
   * Liest die Engine `Y_HEIGHT == 0` (Sentinel) **oder** `Y_POS > next_y`, bricht der Scan für diese Zeile sofort ab (**Early Exit**).
3. **Vorzeichenrichtige Y-Skalierung (`12 × 8 Bit`) & `V_FLIP`:**
   * Hat ein Sprite `Y_POS <= next_y`, ist die Differenz `dy = next_y - Y_POS` garantiert nichtnegativ. Ist `dy >= 2048`, ist das Sprite abgelaufen.
   * Für `dy[11:0]` (`0..2047`) und `eff_y_scale[7:0]` (`$10..$FF`) berechnet der geteilte Multiplizierer in **Zyklus 1** das volle 20-Bit-Produkt:
     $$\text{scaled\_y}[13:0] = (\text{dy}[11:0] \times \text{eff\_y\_scale}[7:0]) \gg 6$$
   * Ist `scaled_y >= Y_HEIGHT[10:0]`, wird das Sprite auf dieser Zeile übersprungen.
   * Andernfalls ist die Quellzeile `rel_y[10:0] = V_FLIP ? (Y_HEIGHT - 11'd1 - scaled_y[10:0]) : scaled_y[10:0]`.
   * In **Zyklus 2** berechnet derselbe Multiplizierer den Zeilen-Offset im RAM (`11 × 7 Bit = 18 Bit` Burst-Index):
     $$\text{Line\_Addr} = (\text{DATA\_PTR} \ \& \ \text{32'hFFFF\_FFE0}) + \big((\text{rel\_y}[10:0] \times \text{eff\_width256}[6:0]) \ll 5\big)$$
4. **Horizontale Skalierung (`X_SCALE`), `H_FLIP` & 24-Bit-RGB-Interpolation (`SMOOTH_X`):**
   * Der HAM/CLUT-Decoder verarbeitet alle Quellpixel einer Zeile immer streng von links nach rechts (`src_x = 0 .. src_width_px - 1`).
   * **Exakte Zielspalten-Steuerung:**
     * Phasenakkumulator `x_phase` (Festkomma `.6`): Für jedes Zielpixel wird `x_phase <= x_phase + eff_x_scale` addiert. Solange `x_phase < 64` (`eff_x_scale < $40`, Vergrößerung), hält `decoder_hold = 1` den Decoder an, während `dst_x` um `+1` (bei `H_FLIP == 0`) bzw. `-1` (bei `H_FLIP == 1`) weiterrückt.
     * Bei `H_FLIP == 1` startet `dst_x` am rechten Rand des skalierten Sprites: `dst_x_start = X_POS + dst_width_px - 1` (wobei `dst_width_px = (src_width_px << 6) / eff_x_scale` einmalig beim Sprite-Zeilenstart per 10-Takt-Shift-Subtract-Teiler während der DDR3-Erstburst-Latenz berechnet wird – **0 Extra-ALMs/DSPs und pixelgenauer rechter Rand!**).
   * **24-Bit RGB Horizontal-Interpolation (`SMOOTH_X`):**
     * Hält `prev_rgb[23:0]`, `prev_opaque` und `curr_rgb[23:0]`, `curr_opaque`.
     * Mit **zwei 8-Bit-Addierern pro Farbkanal** werden die 4 Subpixel-Phasen (`frac = x_phase[5:4]`) berechnet:
       * `mid = (P0 + P1) >> 1`
       * `qtr = (mid + (frac[1] ? P1 : P0)) >> 1`
     * **Transparenz-Kantenschutz (Edge-Guard):**
       * `prev_opaque && curr_opaque`: `out_opaque = 1`, `out_rgb = interp_rgb(P0, P1, frac)`.
       * `prev_opaque && !curr_opaque`: `out_opaque = (frac < 2'b10)`, `out_rgb = P0` (kein Mischen mit Schwarz!).
       * `!prev_opaque && curr_opaque`: `out_opaque = (frac >= 2'b10)`, `out_rgb = P1` (kein Mischen mit Schwarz!).
       * `!prev_opaque && !curr_opaque`: `out_opaque = 0`, `out_rgb = 24'h000000`.
5. **Horizontales Clipping (`0 .. 2047`) & Bitgenauer `Zero-Word-Skip`:**
   * **Clipping:** Schreibzugriffe in den Zeilenbuffer finden nur statt, wenn `0 <= dst_x < 2048`. Erreicht `dst_x` bei `H_FLIP == 0` den Wert `2048` (oder fällt bei `H_FLIP == 1` unter `0`), bricht die Engine die aktuelle Sprite-Zeile sofort ab.
   * **Bitgenauer `Zero-Word-Skip`:** Ist das nächste 64-Bit-Wort `64'h00000000_00000000` **und** gilt `eff_x_scale == 8'h40` (1:1) **und** `prev_opaque == 0` (Pipeline frei von opaken Kantenpixeln), überspringt die Engine das 64-Bit-Wort in **1 Takt** (`acc <= 0`, `dst_x <= dst_x +/- N`). Andernfalls läuft das Wort regulär durch den Entpacker. Dadurch sind `Skip EIN` und `Skip AUS` in allen Modi **100 % bit-identisch**.

---

## 8. DMA-Vertrag (`ddram_ctrl.v`), Zeilen-Zeitbudget & Ressourcen-Bilanz

### 8.1 Verbindlicher 64-Bit Burst-DMA-Vertrag (`BURSTCNT = 4`)
1. **Dedizierter Read-Only-Client in [`ddram_ctrl.v`](../mister/rtl/ddram_ctrl.v):**
   * Eigener 64-Bit-Leseport im `clk_114`-Arbiter mit `BURSTCNT = 4` (`4 × 64 Bit = 256 Bit = 32 Bytes`).
   * **Arbiter-Priorität:** Strikt **unterhalb** des Audio-DMA-Ports (Port 2) und des Video-Refreshs. Damit bleibt die 32-Kanal-Audio-Engine zu 100 % unbeeinträchtigt.
   * **Wort-Endianness:** Innerhalb jedes 64-Bit-DDR3-Worts liegt das niedrigere 32-Bit-Langwort (`Addr + 0`) in `dout[63:32]` und das höhere (`Addr + 4`) in `dout[31:0]`, jeweils Big-Endian gepackt.
2. **Prefetch-FIFO (`64 × 64 Bit`, 1 M10K) & In-Flight-Regel:**
   * Ein neuer 4er-Burst wird nur angefordert, wenn `fifo_count + in_flight_beats <= 60`.
3. **Dynamisches Zeilen-Zeitbudget & Diagnosezähler (`SPR_LINE_OVERRUN`):**
   * Es gibt **keine starre 32-Sprite-Sperre pro Zeile**: In einer Scanline (`7.264 clk_114-Takte` bei 15 kHz PAL bzw. `3.632 clk_114-Takte` bei 31 kHz) können beliebig viele aktive Sprites (z. B. >100 kleine Partikel-Sprites oder mehrere `2048 px` breite FullHD-Layer) gerendert werden, solange das Taktbudget der Zeile reicht.
   * Wird `line_budget_eof` (16 Takte vor Zeilenende) erreicht, beendet die DMA-FSM einen eventuell laufenden 4er-Burst geordnet, verwirft den Rest der Zeile, leert das FIFO und inkrementiert den 16-Bit-Diagnosezähler **`SPR_OVERRUN_CNT`** (Statusbit `SPR_LINE_OVERRUN`).

### 8.2 Geschätzter FPGA-Ressourcenbedarf (Cyclone V, inkl. `2048 px` FullHD-Ausbau)
Aktuell frei im Core (Stand Seed 11): **5.758 ALMs**, **223 M10K-Blöcke**, **37 DSPs**.

| Modul / Teilblock | ALMs | M10K-Blöcke | DSPs |
| :--- | :---: | :---: | :---: |
| **Ping-Pong Zeilenbuffer A & B** (`2 × 2048 × 32 Bit` + 1-Takt-Forwarding) | ~50 | **16** | 0 |
| **Dedizierte Sprite-Palette** (`256 × 24 Bit` Dual-Port) | ~20 | **1** | 0 |
| **64-Bit Prefetch-FIFO** (`64 × 64 Bit` zwischen DDR3 & Unpacker) | ~25 | **1** | 0 |
| **32-Bit Multi-Mode Unpacker** (13 Formate `HAM_32BIT_*`, `CLUT_MODE` & Zero-Word-Skip) | ~110 | 0 | 0 |
| **Dedizierter High-Speed HAM-Decoder** (mit 13-Bit Pre-Delta-Stufe) | ~100 | 0 | 0 |
| **X/Y-Skalierer, `H_FLIP`/`V_FLIP` & 24-Bit RGB X-Interpolator (`SMOOTH_X`)** | **~105** | **0** | **0** |
| **Y-Listen-Scanner (`4096`), Clipping, 12×8-Multiplizierer (TDM) & DMA-FSM** | ~205 | 0 | 0–1 |
| **Denise-Ausgangs-Prioritätsmischer** (4 Ebenen + Blank-Gate) | ~35 | 0 | 0 |
| **Gesamtsumme** | **~650 ALMs** | **18 M10K** | **0–1 DSP** |
| *Anteil an den freien Ressourcen* | *~11,3 % der freien ALMs* | *~8,1 % der freien M10K* | *< 3 %* |
