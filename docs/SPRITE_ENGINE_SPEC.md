# Architektur- und Design-Spezifikation: 32/64-Bit HAM-Sprite-Engine

**Status:** Konzept-Entwurf zur technischen Prüfung (kein RTL-Code erzeugt)  
**Zielplattform:** MiSTer FPGA (Cyclone V `5CSEBA6U23I7`), Minimig-AGA / Denise-Erweiterung  

---

## 1. Überblick & Kernidee

Die neue Sprite-Engine kombiniert die neu entwickelten **variablen HAM-Modi (`HAM03`, `HAM04`, `HAM05`, `HAM06`, `HAM08`)** mit einer **zeilenbasierten Ping-Pong-Puffer-Architektur**, einem **eigenen dedizierten High-Speed-HAM-Decoder** und direktem **64-Bit-DMA-Zugriff auf das DDR3-Fast-RAM**.

1. **Eigener dedizierter Sprite-HAM-Decoder (volle Geschwindigkeit):**
   * Die Sprite-Engine besitzt ihren **eigenen `ham_pixel_decoder`** sowie eine **eigene 256×24-Bit-Sprite-Palette (M10K)**.
   * Dadurch arbeitet die Sprite-Engine zu **100 % unabhängig vom Playfield-HAM (`ext_ham`)** und kann über die gesamte Zeilenzeit ohne jede Unterbrechung mit voller Geschwindigkeit rendern.
2. **Konstanter 256-Bit-Burst-Speicherzugriff (`4 × 64 Bit`) trotz variabler Pixeldichte:**
   * Die minimale Breite und das Zeilen-Raster eines Sprites im RAM beträgt **`4 × 64 Bit = 256 Bit` (32 Bytes = 8 × 32-Bit-Blöcke)**.
   * Dies entspricht exakt einem physischen **DDR3-BL8-Burst (`BURSTCNT = 4`)** auf dem MiSTer. Jeder Burst-Zugriff liefert in 4 aufeinanderfolgenden `clk_114`-Takten **32 bis 64 Pixel auf einen Schlag** (und beim Lesen der Descriptor-Liste gleich **2 komplette 16-Byte-Descriptoren** auf einmal!).
   * **Hardware Zero-Word-Skip:** Ist ein 64-Bit-Wort innerhalb des 256-Bit-Bursts komplett `0` (`64'h00000000_00000000` = lauter transparente Anker-0-Pixel), setzt der Entpacker den HAM-Akkumulator auf `0`, addiert die Pixelanzahl (8..16) direkt auf `cur_x` und überspringt das gesamte 64-Bit-Wort in **einem einzigen Takt**! Dadurch kosten schmalere Sprites (die im 256-Bit-Raster mit `0` aufgefüllt sind) oder transparente Ränder großer Sprites keinerlei Decoder-Zeit.
3. **Zwei Zeilenbuffer im Wechsel (Ping-Pong + Clear-on-Read):**
   * Während **Zeilenbuffer A** synchron zum Videostrahl am Ausgang von Denise ausgelesen, mit dem fertigen 24-Bit-Amiga-Bild gemischt und im selben Takt auf `0` gelöscht wird (**Clear-on-Read**),
   * rendert die Sprite-Engine im Hintergrund die nächste Bildschirmzeile (`Y + 1`) in **Zeilenbuffer B**.
4. **Y-sortierte Descriptor-Liste im Fast-RAM:**
   * Der Engine wird über ein Register lediglich ein 32-Bit-Zeiger auf ein nach **`Y_POS` aufsteigend sortiertes Array** übergeben.
   * Sobald beim Scannen der Liste ein Eintrag mit `Y_POS > next_line_y` erreicht wird, bricht die Engine die Suche für diese Zeile sofort ab (**Early Exit**).
5. **Freies Positionieren & Hardware-Clipping:**
   * Sprites können an beliebigen negativen oder positiven Koordinaten (`int16 X_POS`, `int16 Y_POS`) außerhalb des Bildschirms starten und enden.

---

## 2. Dedizierter High-Speed HAM-Decoder & Timing-Optimierung

### 2.1 Warum ein eigener Decoder für die Sprite-Engine gesetzt ist
* Würde sich die Sprite-Engine den Decoder mit dem Playfield (`ext_ham`) teilen, wäre der Decoder bei aktivem SuperHiRes-HAM-Playfield (1280 px) für 70 % der Zeile durch das Playfield blockiert.
* Mit einem **eigenen dedizierten Decoder** (~95 ALMs) + eigener Paletten-RAM-Instanz (1 M10K) stehen der Sprite-Engine **100 % der Zeilenzeit (volle 64 µs)** ungeteilt zur Verfügung.

### 2.2 Pipeline-Optimierung der Rückkopplungsschleife (Vorberechnung von `delta`)
In `c0_ham_from_setup.rpt` (Slow 1100mV 100C) hatte der bisherige Playfield-Decoder (`ham_pixel_decoder.v`) eine kombinatorische Laufzeit von **`14,774 ns`**, weil Bit-Decode, `turbo`-Shift, Delta-Mux und die 13-Bit-Addition `accumulator + delta` im selben Takt stattfanden.

* **Entscheidende Beobachtung:** Die Vorzeichen-Deltas `delta_r`, `delta_g`, `delta_b` (inkl. `turbo`-Shift `<<< 2` und `level`-Skalierung) hängen **nur von `code`, `mode` und `step_r/g/b` ab – nicht vom `accumulator`!**
* **2-Stufen-Aufteilung (ohne Zusatzlatenz, parallel zum Paletten-BRAM-Read):**
  1. **Stufe 1 (Entpacker & Paletten-Read-Takt):**  
     Parallel zum synchronen Lesezugriff auf das M10K-Paletten-RAM (`palette_index`) berechnet die Logik bereits `anchor` sowie die fertigen 10-Bit-Summanden `delta_r`, `delta_g`, `delta_b` und speichert sie in Registern.
  2. **Stufe 2 (Akkumulator-Takt):**  
     Im eigentlichen Rekursions-Zyklus führt der Decoder **nur noch eine einzige Addition mit Sättigung** und den 2:1-Anker-Mux aus:
     $$\text{acc\_next} = \text{anchor\_reg} \;?\; \text{palette\_data} : \text{sat}_{0..255}(\text{acc} + \text{delta\_reg})$$
* **Ergebnis:**
  * Die kritische Schleifenlaufzeit (`acc -> acc`) sinkt von `14,77 ns` auf **unter `3,5 ns`**!
  * Damit läuft der dedizierte Sprite-Decoder nicht nur bei `clk_sys` (28,375 MHz, 1.816 Pixel/Zeile) mit riesiger Reserve, sondern ist sogar problemlos mit **`56,75 MHz` oder `clk_114` (`113,5 MHz` = bis zu 4 Pixel pro `clk_sys`-Takt / >4.800 Sprite-Pixel pro Zeile!)** taktbar!

---

## 3. Die 13 festgelegten 32-Bit-HAM-Mischmodi (`HAM_32BIT_*`) & 256-Bit-Burst-Raster

Die Pixeldaten im RAM sind in 32-Bit-Worten gepackt, wobei die minimale Sprite-Breite (und das Zeilen-Raster) auf **`4 × 64 Bit = 256 Bit` (32 Bytes = 8 × 32-Bit-Blöcke)** festgelegt ist.  
Dadurch nutzt jeder DMA-Lesezugriff mit **`BURSTCNT = 4`** den physischen **DDR3-BL8-Burst** (32-Bit DDR3 × 8 = 256 Bit) zu **100 %** aus und liefert in 4 aufeinanderfolgenden `clk_114`-Takten **32 bis 64 Pixel auf einen Schlag**:

| `FORMAT` | Name im Konverter | Bit-Sequenz je 32-Bit-Wort (Summe = 32 Bit) | Pixel / 32 Bit | Pixel / 64 Bit | **Pixel / 256-Bit-Burst (`4×64 Bit`)** | `slotsPerBank` |
| :---: | :--- | :--- | :---: | :---: | :---: | :---: |
| **`0`** | `HAM_32BIT_44444444` | `4 - 4 - 4 - 4 - 4 - 4 - 4 - 4` | **8 px** | 16 px | **64 px** | 8 |
| **`1`** | `HAM_32BIT_53535353` | `5 - 3 - 5 - 3 - 5 - 3 - 5 - 3` | **8 px** | 16 px | **64 px** | 16 |
| **`2`** | `HAM_32BIT_63436343` | `6 - 3 - 4 - 3 - 6 - 3 - 4 - 3` | **8 px** | 16 px | **64 px** | 32 |
| **`3`** | `HAM_32BIT_6446444` | `6 - 4 - 4 - 6 - 4 - 4 - 4` | **7 px** | 14 px | **56 px** | 32 |
| **`4`** | `HAM_32BIT_5454545` | `5 - 4 - 5 - 4 - 5 - 4 - 5` | **7 px** | 14 px | **56 px** | 16 |
| **`5`** | `HAM_32BIT_6454544` | `6 - 4 - 5 - 4 - 5 - 4 - 4` | **7 px** | 14 px | **56 px** | 32 |
| **`6`** | `HAM_32BIT_655655` | `6 - 5 - 5 - 6 - 5 - 5` | **6 px** | 12 px | **48 px** | 32 |
| **`7`** | `HAM_32BIT_844844` | `8 - 4 - 4 - 8 - 4 - 4` | **6 px** | 12 px | **48 px** | 128 |
| **`8`** | `HAM_32BIT_846554` | `8 - 4 - 6 - 5 - 5 - 4` | **6 px** | 12 px | **48 px** | 128 |
| **`9`** | `HAM_32BIT_646565` | `6 - 4 - 6 - 5 - 6 - 5` | **6 px** | 12 px | **48 px** | 32 |
| **`10`** | `HAM_32BIT_86666` | `8 - 6 - 6 - 6 - 6` | **5 px** | 10 px | **40 px** | 128 |
| **`11`** | `HAM_32BIT_85865` | `8 - 5 - 8 - 6 - 5` | **5 px** | 10 px | **40 px** | 128 |
| **`12`** | `HAM_32BIT_8888` | `8 - 8 - 8 - 8` | **4 px** | 8 px | **32 px** | 128 |

*(IDs `13..15` sind als Reserve frei).*

### 3.1 Wahlweise HAM-Modus oder normaler Palettenmodus (`CLUT_MODE`) pro Sprite
Über ein Steuerbit im Descriptor (`STEP_CTRL[6] = CLUT_MODE`) kann für jedes Sprite individuell zwischen **HAM-Modus (`0`)** und **normalem Palettenmodus / CLUT (`1`)** gewählt werden (~1 ALM Zusatzlogik):
* **`CLUT_MODE = 0` (HAM-Modus):**  
  Das oberste Bit (`MSB`) jedes Pixel-Codes entscheidet zwischen **Paletten-Anker (`MSB == 0`)** und **RGB-Delta (`MSB == 1`)**.
* **`CLUT_MODE = 1` (Normaler Palettenmodus / CLUT):**  
  Die Hardware zwingt intern `anchor_reg = 1` für jedes Pixel und nutzt **alle Bits des Pixel-Codes (inklusive `MSB`!)** direkt als Paletten-Offset (`palette_index = PAL_OFFSET + code`):
  * Im Format `0` (`44444444`, **64 Pixel pro 256-Bit-Burst**) stehen damit volle **16 Palettenfarben (`0..15`)** pro Pixel zur Verfügung.
  * Im Format `12` (`8888`, **32 Pixel pro 256-Bit-Burst**) stehen volle **256 Palettenfarben (`0..255`)** pro Pixel zur Verfügung.
  * Auch in allen 5-Bit-, 6-Bit- oder Mischformaten adressiert jedes Feld direkt `32` bzw. `64` Farben ab `PAL_OFFSET`.
  * Index `0` bleibt wie im HAM-Modus **Transparent (`24'h000000`)**, sodass sowohl der **1-Takt `Zero-Word-Skip`** als auch die **24-Bit RGB Horizontal-Interpolation (`SMOOTH_X`)** im normalen Palettenmodus zu 100 % identisch weiterarbeiten!

---

## 4. Transparenz & Farb-Regeln

1. **Transparenz = Schwarz (`24'h000000`) auf Paletten-Slot 0:**
   * Der erste Eintrag (`Slot 0`) jeder Farbregisterbank enthält immer **`24'h000000`**.
   * Ein Pixel mit **`code == 0`** (Anker-Bit `MSB == 0` und lokaler Anker-Index `== 0`) ist **immer transparent**:
     * Es wird **nicht** in den Zeilenbuffer geschrieben.
     * Gleichzeitig lädt der HAM-Akkumulator den Wert `24'h000000` aus Slot 0. Dadurch fungiert jedes transparente Pixel automatisch als definierter **Reset-Anker (`000000`)** für nachfolgende Delta-Pixel (wichtig für den linken Sprite-Rand und nach transparenten Lücken innerhalb eines Sprites!).
2. **Auto-Clamp für berechnete Delta-Pixel (`000000 -> 000001`):**
   * Wenn ein **Delta-Pixel** (oder ein Anker mit Index $\neq 0$) rechnerisch auf `24'h000000` fällt, klemmt die Hardware das niederwertigste Blau-Bit automatisch auf **`24'h000001`** (optisch nicht von Schwarz unterscheidbar, aber opak).
   * Damit kann kein Delta-Pixel unbeabsichtigt ein transparentes Loch in dunkle Sprite-Flächen reißen.

---

## 5. Zeilenbuffer (32 Bit) & 8-Bit Prioritäts-Architektur

### 5.1 Format im Zeilenbuffer
Beide Ping-Pong-Zeilenbuffer (A und B) haben eine Tiefe von **2.048 Pixeln** (deckt bis `1.432` Pixel SuperHiRes-Overscan ab) und eine Breite von **32 Bit pro Pixel**:

$$\underbrace{\text{PRIO [31:24]}}_{\text{8-Bit Priorität}} \;\Big|\; \underbrace{\text{R [23:16]} \;\cdot\; \text{G [15:8]} \;\cdot\; \text{B [7:0]}}_{\text{24-Bit RGB}}$$

* **Clear-on-Read:** Beim Auslesen durch Denise für die Anzeige wird an derselben Adresse im selben Takt `32'h0000_0000` zurückgeschrieben (`BUF_PRIO = 0`, `BUF_RGB = 000000`).
* **Überschreib-Bedingung beim Füllen des Zeilenbuffers:**
  Während der HAM-Decoder das aktuelle Pixel berechnet, wird am Dual-Port-M10K-RAM die bestehende Priorität `BUF_PRIO` der Zielspalte `X` gelesen. Geschrieben wird nur, wenn:
  $$\text{WE} = (\text{NEW\_RGB} \neq \text{24'h000000}) \;\land\; (\text{SPR\_PRIO} > \text{BUF\_PRIO})$$
  *(Optional über Steuerbit umschaltbar auf `>=` für Painter's Algorithmus bei gleicher Priorität).*

### 5.2 Mischen NACH dem fertigen 24-Bit-Amiga-Bild (4 Ebenen über `PRIO[7:6]`)
Das Mischen erfolgt **ganz am Ende von [`denise.v`](../mister/rtl/denise.v#L532)** nach dem fertigen 24-Bit-Amiga-Bild (`amiga_rgb[23:0]`), ohne in die interne Bitplane-/CLUT-Pipeline einzugreifen.  
Dazu werden lediglich 3 bereits in Denise vorhandene Status-Signale synchron zum `amiga_rgb` mitgeführt:
* `sprsel`: Klassisches Amiga-Sprite 0..7 ist an diesem Pixel aktiv.
* `pf_front_opaque`: Vorderes Playfield ist an diesem Pixel $\neq 0$.
* `pf_any_opaque`: Irgendein Playfield ist an diesem Pixel $\neq 0$ (nicht `COLOR00`).

| `PRIO`-Werte | `PRIO[7:6]` | Ebene relativ zum Amiga-Bild | Bedingung für Anzeige von `BUF_RGB` statt `amiga_rgb` |
| :--- | :---: | :--- | :--- |
| **`0`** | `00` | **Leer / Transparent** | Nie (`amiga_rgb` wird angezeigt) |
| **`1 .. 63`** | `00` | **Hintergrund-Layer** (vor `COLOR00`, hinter allen Bitplanes) | `BUF_PRIO != 0 && !sprsel && !pf_any_opaque` |
| **`64 .. 127`** | `01` | **Zwischen Playfield 2 und Playfield 1** | `BUF_PRIO != 0 && !sprsel && !pf_front_opaque` |
| **`128 .. 191`** | `10` | **Vor allen Bitplanes, hinter Amiga-Sprites 0..7** | `BUF_PRIO != 0 && !sprsel` |
| **`192 .. 255`** | `11` | **Ganz vorn** (vor Bitplanes und vor Amiga-Sprites) | `BUF_PRIO != 0` (gewinnt immer) |

---

## 6. Sprite-Descriptor im Fast-RAM (16 Bytes = 2 × 64 Bit, 2 Descriptoren je 256-Bit-Burst)

Das Sprite-Array liegt 32-Byte-aligned im DDR3-Fast-RAM und ist aufsteigend nach **`Y_POS`** sortiert.  
Ein einzelner **`4 × 64 Bit`-DDR3-Burst (`BURSTCNT = 4` = 32 Bytes)** lädt dabei gleichzeitig **2 komplette Sprite-Descriptoren**!  
Die maximale Höhe eines einzelnen Sprites ist auf **255 Zeilen (`uint8`)** festgelegt (`8 × 8 Bit`-Multiplikation für den Zeilen-Offset).

### 64-Bit Wort 0 (Offset `+$00 .. +$07`): Position, Größe, Priorität & Bank
| Bits | Typ | Feldname | Beschreibung |
| :---: | :---: | :--- | :--- |
| `[63:48]` | `int16` | **`Y_POS`** | Startzeile (vorzeichenbehaftet, z. B. `-255 .. +1024`) |
| `[47:32]` | `int16` | **`X_POS`** | Startspalte im SuperHiRes-Raster (vorzeichenbehaftet, z. B. `-2048 .. +1432`) |
| `[31:24]` | `uint8` | **`Y_HEIGHT`** | Höhe in Zeilen (`1 .. 255`; **`0` = Ende der Sprite-Liste / Sentinel!**) |
| `[23:16]` | `uint8` | **`X_WIDTH256`** | Breite in Anzahl der **`4 × 64 Bit` (256-Bit / 32-Byte) Burst-Blöcke** (`1 .. 255`, 1 Block = 32..64 Pixel) |
| `[15:8]` | `uint8` | **`PRIO`** | 8-Bit Priorität (`0` = dieses Sprite überspringen/unsichtbar; `1 .. 255` = aktiv) |
| `[7:0]` | `uint8` | **`PAL_OFFSET`** | Start-Offset in der 256-Farben-Sprite-Palette (z. B. `Bank * slotsPerBank`) |

### 64-Bit Wort 1 (Offset `+$08 .. +$0F`): Datenzeiger, Format, Skalierung & Steuerung
| Bits | Typ | Feldname | Beschreibung |
| :---: | :---: | :--- | :--- |
| `[63:32]` | `uint32` | **`DATA_PTR`** | 32-Bit Byte-Adresse der gepackten Pixeldaten im Fast-RAM (32-Byte / 256-Bit aligned) |
| `[31:28]` | `uint4` | **`FORMAT`** | HAM-Mischmodus `0 .. 12` (gemäß Tabelle in Abschnitt 3) |
| `[27:24]` | `uint4` | **`FLAGS`** | Bit `0`: `H_FLIP` (Horizontal spiegeln)<br>Bit `1`: `V_FLIP` (Vertikal spiegeln)<br>Bit `2`: `SMOOTH_X` (24-Bit RGB Horizontal-Interpolation ein)<br>Bit `3`: `PRIO_GE` (`>=` statt `>` bei gleicher Priorität) |
| `[23:16]` | `uint8` | **`X_SCALE`** | Horizontaler Skalierungsfaktor (Festkomma `2.6`, `64` (`$40`) = 1,0× Originalgröße; `< 64` = Vergrößern, `> 64` = Verkleinern) |
| `[15:8]` | `uint8` | **`Y_SCALE`** | Vertikaler Skalierungsfaktor (Festkomma `2.6`, `64` (`$40`) = 1,0× Originalgröße; unabhängig von `X_SCALE` für Strecken/Stauchen!) |
| `[7:0]` | `uint8` | **`STEP_CTRL`** | Bit `6`: **`CLUT_MODE`** (`0` = HAM-Modus, `1` = Normaler Palettenmodus / CLUT)<br>Bit `7`: `CUSTOM_STEP` (`0` = Globale HAM-Steps, `1` = Sprite-eigene HAM-Step-Skalierung `R[5:4]`, `G[3:2]`, `B[1:0]`) |

---

## 7. Clipping, X/Y-Skalierung, 24-Bit-Interpolation & Zero-Word-Skip

Für jede vorzubereitende Zielzeile `next_y` (`0 .. Screen_Height - 1`):

1. **Sliding-Window Start-Index (`first_active_idx`):**
   * Zu Beginn des Frames (`next_y == 0`) ist `first_active_idx = 0`.
   * Abgelaufene Sprites am Listenanfang werden über `first_active_idx` übersprungen.
2. **Early Exit durch Y-Sortierung:**
   * Liest die Engine einen Descriptor mit `Y_HEIGHT == 0` (Listenende) **oder** `Y_POS > next_y`, ist die Zeile fertig! Alle nachfolgenden Sprites starten erst in tieferen Bildschirmzeilen.
3. **Vertikales Clipping, Y-Skalierung (`Y_SCALE`) & `V_FLIP`:**
   * Aus dem Zeilenabstand `dy = next_y - Y_POS` wird über denselben 8×8-Multiplizierer (im 2-Takt-Zeitmultiplex vor der Zeilenadress-Multiplikation, daher **0 Extra-DSPs!**) die skalierte Quellzeile berechnet:
     $$\text{scaled\_y} = (\text{dy} \times \text{Y\_SCALE}) \gg 6$$
   * Ist `scaled_y >= Y_HEIGHT`, ist das (ggf. gestreckte oder gestauchte) Sprite auf dieser Bildschirmzeile bereits zu Ende.
   * Bei `V_FLIP == 1` wird `rel_y = (Y_HEIGHT - 1) - scaled_y[7:0]` gewählt, sonst `rel_y = scaled_y[7:0]`.
   * Startadresse der aktuellen Sprite-Zeile im RAM (immer exakt 32-Byte / 256-Bit-Burst-aligned!):
     $$\text{Line\_Addr} = \text{DATA\_PTR} + (\text{rel\_y}[7:0] \times \text{X\_WIDTH256}[7:0]) \ll 5$$
4. **Horizontale Skalierung (`X_SCALE`), `H_FLIP` & 24-Bit-RGB-Interpolation (`SMOOTH_X`):**
   * **Warum X-Skalierung & H-Flip nach dem HAM-Decoder 100 % artefaktfrei arbeiten:**  
     Der HAM-Decoder verarbeitet die Quellpixel einer Zeile immer lückenlos von links nach rechts, damit der rekursive RGB-Akkumulator zu jedem Zeitpunkt exakt stimmt.
   * **Beim Vergrößern (`X_SCALE < 64`):** Der Phasenakkumulator `x_phase` hält den HAM-Decoder für Zwischenspalten kurz an (`decoder_hold`), während der Zeilenbuffer-Schreiber vorrückt.
   * **Beim Verkleinern (`X_SCALE > 64`):** Der HAM-Decoder läuft für jedes Quellpixel weiter, aber nur bei Überlauf der Zielspalte wird in den Zeilenbuffer geschrieben.
   * **Bei `H_FLIP == 1`:** Der Decoder läuft trotzdem von links nach rechts durch die Quelldaten, aber der Zielspalten-Zähler `dst_x` zählt vom rechten Sprite-Rand rückwärts (`dst_x - 1`) in den Zeilenbuffer!
   * **24-Bit RGB Horizontal-Interpolation (`SMOOTH_X`):**  
     Da der HAM-Decoder bereits lineares 24-Bit TrueColor (`R, G, B`) liefert, hält die Stufe nach dem Decoder das vorherige Quellpixel `prev_rgb[23:0]` und das aktuelle Quellpixel `curr_rgb[23:0]`.  
     Mit **nur zwei 8-Bit-Addierern pro Farbkanal** (ohne Multiplizierer!) werden alle 4 Subpixel-Zwischenstufen (`0 %`, `25 %`, `50 %`, `75 %`) erzeugt:
     * `mid = (P0 + P1) >> 1` *(dient gleichzeitig als 50:50 Anti-Aliasing-Mittelwert beim Verkleinern!)*
     * `qtr = (mid + (frac[1] ? P1 : P0)) >> 1`
     * **Transparenz-Kantenschutz (Edge-Guard):** Ist `P0` oder `P1` transparent (`24'h000000`), wird **nicht** mit Schwarz gemischt, sondern hart umgeschaltet – so entstehen niemals dunkle Trauerränder an den Außenkanten gezoomter Sprites!
5. **Horizontales Clipping (Links / Rechts) & Hardware Zero-Word-Skip:**
   * **Links (`dst_x < 0`):** Der HAM-Decoder verarbeitet die Pixel ab `X_POS` normal mit (damit der RGB-Akkumulator bei `dst_x == 0` exakt stimmt!), unterdrückt aber für `dst_x < 0` das Schreibsignal in den Zeilenbuffer.
   * **Rechts (`dst_x >= Screen_Width`):** Sobald `dst_x` den rechten Bildschirmrand erreicht (bei `H_FLIP == 0`), bricht die Engine den Lese- und Decodiervorgang für den Rest dieser Sprite-Zeile sofort ab.
   * **Zero-Word-Skip (1-Takt-Schnellübersprung für transparente 64-Bit-Worte):** Ist ein aus dem FIFO gelesenes 64-Bit-Wort komplett `64'h00000000_00000000` (lauter transparente Anker-0-Pixel), setzt der Entpacker `acc <= 24'h000000`, rückt `dst_x` entsprechend vor und springt in **nur 1 Takt** sofort zum nächsten 64-Bit-Wort!

---

## 8. 256-Bit Burst-DMA (`BURSTCNT = 4`), Prefetch-FIFO & Ressourcen-Bilanz

### 8.1 Volle Ausnutzung des physischen DDR3-BL8-Bursts (`4 × 64 Bit = 256 Bit`) + Prefetch-FIFO
Das physische DDR3-RAM auf dem MiSTer arbeitet intern mit einer Burst-Länge von 8 über einen 32-Bit-Bus (**BL8 = 256 Bit = `4 × 64 Bit` = 32 Bytes**).  
Durch die Festlegung der minimalen Sprite-Länge auf **`4 × 64 Bit` (256 Bit)** und den Einsatz eines kleinen **64-Bit Prefetch-FIFOs** (1–2 M10K-Blöcke) zwischen [`ddram_ctrl.v`](../mister/rtl/ddram_ctrl.v) (`clk_114 = 113,5 MHz`) und dem Bitstream-Entpacker/HAM-Decoder wird der DDR3-Burst zu **100 %** ausgenutzt:

1. **3,25× höhere Speichereffizienz durch feste `4 × 64 Bit`-Bursts (`BURSTCNT = 4`):**
   * Ein einzelner 64-Bit-Lesezugriff benötigt ~12 Takte Latenz + 1 Datentakt = 13 `clk_114`-Takte.
   * Ein **`4 × 64 Bit`-Burst (`256 Bit`)** benötigt dieselben ~12 Takte Latenz + **4 direkt aufeinanderfolgende Datentakte** = **nur ~16 `clk_114`-Takte (~140 ns)** für **32 bis 64 Pixel**!
   * Während der Decoder diese 32 bis 64 Pixel verarbeitet, ist der DDR3-Bus zu **über 85–90 % der Zeit komplett frei** für die 68020-CPU und das 32-Kanal-Audio.
2. **Vollständige Verdeckung der DDR3-Latenz (Zero-Stall-Streaming):**
   * Sobald im Prefetch-FIFO Platz für mindestens 4 × 64-Bit-Worte ist, feuert die DMA-State-Machine im Hintergrund automatisch den nächsten `4 × 64 Bit`-Burst ab, während der Decoder noch am vorherigen Burst arbeitet. Der Decoder läuft dadurch **zu 100 % unterbrechungsfrei ohne Wartetakte** durch!
3. **2 Descriptoren auf einen Streich (Descriptor-Burst):**
   * Da ein Sprite-Descriptor exakt `16 Bytes` (`2 × 64 Bit`) groß ist, liest ein einziger `4 × 64 Bit`-Burst (`32 Bytes`) immer **2 komplette Sprite-Descriptoren gleichzeitig** in den Lookahead-Puffer.
4. **Saubere Takttrennung (CDC):**
   * Das Dual-Clock-fähige M10K-FIFO nimmt auf der Schreibseite die 4 Burst-Worte im vollen `113,5 MHz`-Takt (`clk_114`) entgegen und speist auf der Leseseite nahtlos den Entpacker/Decoder.

### 8.2 Speicherdurchsatz & Render-Geschwindigkeit
* [`ddram_ctrl.v`](../mister/rtl/ddram_ctrl.v) liest intern bei jedem Zugriff **64 Bit (`ram_dout[63:0]`)**. Durch Bereitstellung dieser vollen 64 Bit am DMA-Port liefert **1 Lesezugriff = zwei 32-Bit-Blöcke (8 bis 16 Pixel)**.
* Mit dem eigenen dedizierten Sprite-HAM-Decoder (inkl. vorberechneter `delta_r/g/b`-Stufe parallel zum Paletten-Read) und dem vorgeschalteten **64-Bit Prefetch-FIFO** kann die Render-Pipeline wahlweise mit `clk_sys` (**1.816 Takte/Zeile**, ~1.750 Sprite-Pixel/Zeile ohne Stalls) oder im schnellen **`clk_114`-Takt (113,5 MHz = 7.264 Takte/Zeile**, **bis zu 4.800 Sprite-Pixel/Zeile = 3,5× SuperHiRes-Fullscreen-Overdraw**) betrieben werden!
* Die DDR3-Buslast bleibt durch die gepufferten 64-Bit-Zugriffe niedrig (ca. 15–30 %), sodass 68020-CPU und 32-Kanal-Audio ungebremst weiterlaufen.

### 8.3 Geschätzter FPGA-Ressourcenbedarf (Cyclone V)
Aktuell frei im Core (Stand Seed 11): **5.758 ALMs**, **223 M10K-Blöcke**, **37 DSPs**.

| Modul / Teilblock | ALMs | M10K-Blöcke | DSPs |
| :--- | :---: | :---: | :---: |
| **Ping-Pong Zeilenbuffer A & B** (2 × 2048 × 32 Bit) | ~40 | **16** | 0 |
| **Dedizierte Sprite-Palette** (256 × 24 Bit Dual-Port) | ~20 | **1** | 0 |
| **64-Bit Prefetch-FIFO** (z. B. 64 × 64 Bit zwischen DDR3 & Unpacker) | ~25 | **1–2** | 0 |
| **32-Bit Multi-Mode Unpacker** (13 Formate `HAM_32BIT_*` + Zero-Word-Skip) | ~105 | 0 | 0 |
| **Dedizierter High-Speed HAM-Decoder** (mit Pre-Delta-Stufe) | ~95 | 0 | 0 |
| **X/Y-Skalierer, `H_FLIP`/`V_FLIP` & 24-Bit RGB X-Interpolator (`SMOOTH_X`)** | **~90** | **0** | **0** |
| **Y-Listen-Scanner, Clipping, 8×8-Multiplizierer (TDM) & DMA-FSM** | ~190 | 0 | 0–1 |
| **Denise-Ausgangs-Prioritätsmischer** (4 Ebenen) | ~35 | 0 | 0 |
| **Gesamtsumme** | **~600 ALMs** | **18–19 M10K** | **0–1 DSP** |
| *Anteil an den freien Ressourcen* | *~10,4 % der freien ALMs* | *~8,5 % der freien M10K* | *< 3 %* |
