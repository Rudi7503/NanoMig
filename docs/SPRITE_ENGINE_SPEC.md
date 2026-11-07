# Architektur- und Design-Spezifikation: 32/64-Bit HAM-Sprite-Engine

**Status:** Konzept-Entwurf zur technischen Prüfung (kein RTL-Code erzeugt)  
**Zielplattform:** MiSTer FPGA (Cyclone V `5CSEBA6U23I7`), Minimig-AGA / Denise-Erweiterung  

---

## 1. Überblick & Kernidee

Die neue Sprite-Engine kombiniert die neu entwickelten **variablen HAM-Modi (`HAM03`, `HAM04`, `HAM05`, `HAM06`, `HAM08`)** mit einer **zeilenbasierten Ping-Pong-Puffer-Architektur** und direktem **64-Bit-DMA-Zugriff auf das DDR3-Fast-RAM**.

1. **Konstanter Speicherzugriff trotz variabler Pixeldichte:**
   * Die Sprite-Pixeldaten sind in **32-Bit-Blöcken** (`HAM_32BIT_*`) organisiert, wobei der DDR3-Controller immer **64 Bit (= zwei 32-Bit-Blöcke auf einmal)** liest.
   * Je nach gewähltem Mischmodus enthält ein 32-Bit-Block **4, 5, 6, 7 oder 8 Pixel** (also **8 bis 16 Pixel pro 64-Bit-Lesezugriff**).
2. **Zwei Zeilenbuffer im Wechsel (Ping-Pong + Clear-on-Read):**
   * Während **Zeilenbuffer A** synchron zum Videostrahl am Ausgang von Denise ausgelesen, mit dem fertigen 24-Bit-Amiga-Bild gemischt und im selben Takt auf `0` gelöscht wird (**Clear-on-Read**),
   * rendert die Sprite-Engine im Hintergrund die nächste Bildschirmzeile (`Y + 1`) in **Zeilenbuffer B**.
3. **Y-sortierte Descriptor-Liste im Fast-RAM:**
   * Der Engine wird über ein Register lediglich ein 32-Bit-Zeiger auf ein nach **`Y_POS` aufsteigend sortiertes Array** übergeben.
   * Sobald beim Scannen der Liste ein Eintrag mit `Y_POS > next_line_y` erreicht wird, bricht die Engine die Suche für diese Zeile sofort ab (**Early Exit**).
4. **Freies Positionieren & Hardware-Clipping:**
   * Sprites können an beliebigen negativen oder positiven Koordinaten (`int16 X_POS`, `int16 Y_POS`) außerhalb des Bildschirms starten und enden.

---

## 2. Timing-Analyse des HAM-Decoders im TDM-Betrieb

### 2.1 Gemessene Hardware-Laufzeit (aus Quartus STA Slow 1100mV 100C)
In den vorliegenden Timing-Reports (`c0_ham_from_setup.rpt`, Pfad `mode_d[0] -> ham_pixel_decoder:engine|accumulator[*]`) ist der kritische Pfad durch [`ham_pixel_decoder.v`](../mister/rtl/ham_pixel_decoder.v) exakt vermessen:

* **Kombinatorische Pfadverzögerung (`Data Delay`):** **$14,774\text{ ns}$** (inkl. Bit-Decode, `turbo`-Shift, Delta-Mux, 13-Bit-Addierer und Sättigungslogik `0..255`).
* **Bei Systemtakt `clk_sys = 28,375 MHz` (Periode $35,234\text{ ns}$):**
  * **Setup Slack:** **$+19,776\text{ ns}$** (extrem hohe Timing-Reserve, völlig unkritisch).
* **Bei Speichertakt `clk_114 = 113,5 MHz` (Periode $8,810\text{ ns}$):**
  * Ein ungepipelineter Betrieb bei 113,5 MHz ist wegen $14,774\text{ ns} > 8,810\text{ ns}$ **nicht möglich** (würde $-6\text{ ns}$ Setup-Violation erzeugen), und wegen der rekursiven Abhängigkeit $\text{acc}[n] = f(\text{acc}[n-1])$ innerhalb desselben Sprites kann die Schleife nicht ohne Weiteres gepipelinet werden.
* **Konsequenz:** Der `ham_pixel_decoder` läuft im **28,375-MHz-Takt (`clk_sys`)** mit **1 Pixel pro Takt** bei knapp **20 ns positiver Timing-Reserve**.

### 2.2 TDM-Variante A vs. TDM-Variante B

Es gibt zwei Möglichkeiten für den TDM-Betrieb (Time-Division Multiplexing):

| Kriterium | **TDM-Variante A (Empfohlen):**<br>1 eigener Decoder für alle Sprites im TDM | **TDM-Variante B:**<br>Playfield-HAM (`ext_ham`) und Sprites teilen sich 1 Decoder |
| :--- | :--- | :--- |
| **Funktionsweise** | Alle Sprites einer Zeile teilen sich nacheinander **einen** Sprite-HAM-Decoder (28,375 MHz). Playfield behält seinen Decoder. | Nur 1 physischer Decoder im gesamten Chip; schaltet pro Takt zwischen Playfield-Pixel und Sprite-Pixel um (2 getrennte `accumulator`-Register nötig). |
| **Verfügbare Takte pro Zeile ($64\,\mu\text{s} = 1.816$ Takte)** | **Volle 1.816 Takte** für Sprites (unabhängig vom Playfield-Modus!). | Bei aktivem SuperHiRes-HAM-Playfield (1280 px) belegt das Playfield 1.280 Takte $\rightarrow$ **nur ~536 Takte** (im HBlank) für Sprites übrig! |
| **Max. Sprite-Pixel pro Zeile** | **~1.600 Sprite-Pixel / Zeile** (z. B. **50 Sprites à 32 px** pro Zeile). | In SuperHiRes-HAM nur ~450 Sprite-Pixel / Zeile (ca. 14 Sprites à 32 px). |
| **Logik-Aufwand** | ~95 ALMs für die Decoder-Instanz, keine Mux-Kollisionen. | Spart ~60 ALMs am Decoder, braucht aber 24-Bit-Akkumulator-Mux + Paletten-Port-Arbitrierung. |

**Empfehlung zur Bewertung:**  
Innerhalb der Sprite-Engine arbeiten alle Sprites seriell im TDM über **einen einzigen Sprite-Decoder** bei `clk_sys` (28,375 MHz, 1 Pixel/Takt, $+19,7\text{ ns}$ Slack). Ob dieser Decoder physisch mit dem Playfield-Decoder (`ext_ham`) zusammengelegt wird (Variante B) oder als dedizierte Instanz für die Sprite-Engine läuft (Variante A, ~95 ALMs), hängt davon ab, ob gleichzeitig zum SuperHiRes-HAM-Hintergrundbild (1280 px) mehr als ~450 Sprite-Pixel pro Zeile benötigt werden.

---

## 3. Die 13 festgelegten 32-Bit-HAM-Mischmodi (`HAM_32BIT_*`)

Die Pixeldaten im RAM sind in 32-Bit-Worten gepackt. Da der DDR3-Controller pro Lesezugriff **64 Bit** liefert, holt jeder RAM-Zugriff **zwei 32-Bit-Blöcke (8 bis 16 Pixel)** auf einen Schlag.

Der Bitstream-Entpacker zerlegt jedes 32-Bit-Wort von MSB nach LSB gemäß `FORMAT[3:0]` in eine Sequenz aus `mode` (`HAM03..HAM08`) und `code`:

| `FORMAT` | Name im Konverter | Bit-Sequenz je 32-Bit-Wort (Summe = 32 Bit) | Pixel / 32 Bit | Pixel / 64-Bit-Read | Ø Bit/Pixel | `slotsPerBank` |
| :---: | :--- | :--- | :---: | :---: | :---: | :---: |
| **`0`** | `HAM_32BIT_44444444` | `4 - 4 - 4 - 4 - 4 - 4 - 4 - 4` | **8 px** | 16 px | 4,00 | 8 |
| **`1`** | `HAM_32BIT_53535353` | `5 - 3 - 5 - 3 - 5 - 3 - 5 - 3` | **8 px** | 16 px | 4,00 | 16 |
| **`2`** | `HAM_32BIT_63436343` | `6 - 3 - 4 - 3 - 6 - 3 - 4 - 3` | **8 px** | 16 px | 4,00 | 32 |
| **`3`** | `HAM_32BIT_6446444` | `6 - 4 - 4 - 6 - 4 - 4 - 4` | **7 px** | 14 px | 4,57 | 32 |
| **`4`** | `HAM_32BIT_5454545` | `5 - 4 - 5 - 4 - 5 - 4 - 5` | **7 px** | 14 px | 4,57 | 16 |
| **`5`** | `HAM_32BIT_6454544` | `6 - 4 - 5 - 4 - 5 - 4 - 4` | **7 px** | 14 px | 4,57 | 32 |
| **`6`** | `HAM_32BIT_655655` | `6 - 5 - 5 - 6 - 5 - 5` | **6 px** | 12 px | 5,33 | 32 |
| **`7`** | `HAM_32BIT_844844` | `8 - 4 - 4 - 8 - 4 - 4` | **6 px** | 12 px | 5,33 | 128 |
| **`8`** | `HAM_32BIT_846554` | `8 - 4 - 6 - 5 - 5 - 4` | **6 px** | 12 px | 5,33 | 128 |
| **`9`** | `HAM_32BIT_646565` | `6 - 4 - 6 - 5 - 6 - 5` | **6 px** | 12 px | 5,33 | 32 |
| **`10`** | `HAM_32BIT_86666` | `8 - 6 - 6 - 6 - 6` | **5 px** | 10 px | 6,40 | 128 |
| **`11`** | `HAM_32BIT_85865` | `8 - 5 - 8 - 6 - 5` | **5 px** | 10 px | 6,40 | 128 |
| **`12`** | `HAM_32BIT_8888` | `8 - 8 - 8 - 8` | **4 px** | 8 px | 8,00 | 128 |

*(IDs `13..15` sind als Reserve frei).*

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
3. **Startwert zu Beginn einer Sprite-Zeile:**
   * Am linken Startpunkt jedes Sprites wird der HAM-Akkumulator vor dem ersten Pixel auf `24'h000000` (bzw. `24'h7F7F7F`, konfigurierbar) initialisiert; in der Regel beginnt ein Sprite mit einem Anker-Pixel (oder Anker 0 für transparenten Rand).

---

## 5. Zeilenbuffer (32 Bit) & 8-Bit Prioritäts-Architektur

### 5.1 Format im Zeilenbuffer
Beide Ping-Pong-Zeilenbuffer (A und B) haben eine Tiefe von **2.048 Pixeln** (deckt bis `1.432` Pixel SuperHiRes-Overscan ab) und eine Breite von **32 Bit pro Pixel**:

$$\underbrace{\text{PRIO [31:24]}}_{\text{8-Bit Priorität}} \;\Big|\; \underbrace{\text{R [23:16]} \;\cdot\; \text{G [15:8]} \;\cdot\; \text{B [7:0]}}_{\text{24-Bit RGB}}$$

* **Clear-on-Read:** Beim Auslesen durch Denise für die Anzeige wird an derselben Adresse im selben Takt `32'h0000_0000` zurückgeschrieben (`BUF_PRIO = 0`, `BUF_RGB = 000000`).
* **Überschreib-Bedingung beim Füllen des Zeilenbuffers:**
  Während der HAM-Decoder das aktuelle Pixel berechnet (1 Takt), wird am Dual-Port-M10K-RAM die bestehende Priorität `BUF_PRIO` der Zielspalte `X` gelesen. Geschrieben wird nur, wenn:
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

## 6. Sprite-Descriptor im Fast-RAM (16 Bytes = 2 × 64 Bit)

Das Sprite-Array liegt 8-Byte-aligned im DDR3-Fast-RAM und ist aufsteigend nach **`Y_POS`** sortiert.  
Die maximale Höhe eines einzelnen Sprites ist auf **255 Zeilen (`uint8`)** festgelegt (`8 × 8 Bit`-Multiplikation für den Zeilen-Offset).

### 64-Bit Wort 0 (Offset `+$00 .. +$07`): Position, Größe, Priorität & Bank
| Bits | Typ | Feldname | Beschreibung |
| :---: | :---: | :--- | :--- |
| `[63:48]` | `int16` | **`Y_POS`** | Startzeile (vorzeichenbehaftet, z. B. `-255 .. +1024`) |
| `[47:32]` | `int16` | **`X_POS`** | Startspalte im SuperHiRes-Raster (vorzeichenbehaftet, z. B. `-2048 .. +1432`) |
| `[31:24]` | `uint8` | **`Y_HEIGHT`** | Höhe in Zeilen (`1 .. 255`; **`0` = Ende der Sprite-Liste / Sentinel!**) |
| `[23:16]` | `uint8` | **`X_WIDTH32`** | Breite in Anzahl der **32-Bit-Blöcke** (`1 .. 255` $\rightarrow$ bis 2.040 Pixel breit) |
| `[15:8]` | `uint8` | **`PRIO`** | 8-Bit Priorität (`0` = dieses Sprite überspringen/unsichtbar; `1 .. 255` = aktiv) |
| `[7:0]` | `uint8` | **`PAL_OFFSET`** | Start-Offset in der 256-Farben-Sprite-Palette (z. B. `Bank * slotsPerBank`) |

### 64-Bit Wort 1 (Offset `+$08 .. +$0F`): Datenzeiger, Format & Steuerung
| Bits | Typ | Feldname | Beschreibung |
| :---: | :---: | :--- | :--- |
| `[63:32]` | `uint32` | **`DATA_PTR`** | 32-Bit Byte-Adresse der gepackten Pixeldaten im Fast-RAM (4/8-Byte aligned) |
| `[31:28]` | `uint4` | **`FORMAT`** | HAM-Mischmodus `0 .. 12` (gemäß Tabelle in Abschnitt 3) |
| `[27:16]` | `uint12` | **`FLAGS`** | Bit `[1:0]`: Pixel-Breite (`00`=SHres 1×, `01`=Hires 2×, `10`=Lores 4×)<br>Bit `2`: H-Mirror, Bit `3`: V-Mirror |
| `[15:0]` | `uint16` | **`STEP_CTRL`** | Bit `15 == 0`: Globale HAM-Steps nutzen<br>Bit `15 == 1`: Eigene Sprite-HAM-Steps `R[14:10]`, `G[9:5]`, `B[4:0]` |

---

## 7. Clipping-Algorithmus & Listen-Traversierung

Für jede vorzubereitende Zielzeile `next_y` (`0 .. Screen_Height - 1`):

1. **Sliding-Window Start-Index (`first_active_idx`):**
   * Zu Beginn des Frames (`next_y == 0`) ist `first_active_idx = 0`.
   * Da die maximale Sprite-Höhe `255` beträgt, sind alle Sprites am Listenanfang, deren `Y_POS + Y_HEIGHT <= next_y` ist (sofern davor kein noch laufendes höheres Sprite lag), endgültig abgelaufen; `first_active_idx` rückt entsprechend vor, sodass abgelaufene Sprites in späteren Zeilen nicht erneut gelesen werden müssen.
2. **Early Exit durch Y-Sortierung:**
   * Liest die Engine einen Descriptor mit `Y_HEIGHT == 0` (Listenende) **oder** `Y_POS > next_y`, ist die Zeile fertig! Alle nachfolgenden Sprites starten erst in tieferen Bildschirmzeilen.
3. **Vertikales Clipping (Oben / Unten):**
   * Bedingung für Sichtbarkeit auf `next_y`: `next_y >= Y_POS` und `rel_y = next_y - Y_POS < Y_HEIGHT`.
   * Bei `V-Mirror` wird `rel_y = (Y_HEIGHT - 1) - (next_y - Y_POS)` verwendet.
   * Startadresse der aktuellen Sprite-Zeile im RAM:
     $$\text{Line\_Addr} = \text{DATA\_PTR} + (\text{rel\_y}[7:0] \times \text{X\_WIDTH32}[7:0]) \ll 2$$
4. **Horizontales Clipping (Links / Rechts):**
   * **Links (`cur_x < 0`):** Der HAM-Decoder verarbeitet die Pixel ab `X_POS` normal mit (damit der RGB-Akkumulator bei `cur_x == 0` exakt den richtigen Farbwert erreicht!), unterdrückt aber für `cur_x < 0` das Schreibsignal in den Zeilenbuffer.
   * **Rechts (`cur_x >= Screen_Width`):** Sobald `cur_x` den rechten Bildschirmrand erreicht, bricht die Engine den Lese- und Decodiervorgang für den Rest dieser Sprite-Zeile sofort ab.

---

## 8. Durchsatz- & Ressourcen-Bilanz

### 8.1 Speicherdurchsatz (DDR3 Fast-RAM via `ddram_ctrl.v`)
* [`ddram_ctrl.v`](../mister/rtl/ddram_ctrl.v) liest intern bei jedem Zugriff **64 Bit (`ram_dout[63:0]`)**. Durch Bereitstellung dieser vollen 64 Bit am DMA-Port liefert **1 Lesezugriff = zwei 32-Bit-Blöcke (8 bis 16 Pixel)**.
* Während 8 bis 16 Pixel mit `clk_sys` (1 Pixel pro Takt = 8 bis 16 Takte) durch den HAM-Decoder laufen, hat der DDR3-Controller im Hintergrund längst das nächste 64-Bit-Wort geladen (Latenz nur ~3–4 `clk_sys`-Takte).
* Dadurch läuft der Sprite-Decoder während einer Sprite-Zeile **ohne Wartezyklen mit 100 % Auslastung (1 Pixel pro `clk_sys`-Takt)**.
* Die DDR3-Buslast für die Sprite-Engine beträgt dabei selbst bei Vollbild-Overdraw nur **ca. 15–25 %**, sodass 68020-CPU und 32-Kanal-Audio ungebremst weiterlaufen.

### 8.2 Geschätzter FPGA-Ressourcenbedarf (Cyclone V)
Aktuell frei im Core (Stand Seed 11): **5.758 ALMs**, **223 M10K-Blöcke**, **37 DSPs**.

| Modul / Teilblock | ALMs | M10K-Blöcke | DSPs |
| :--- | :---: | :---: | :---: |
| **Ping-Pong Zeilenbuffer A & B** (2 × 2048 × 32 Bit) | ~40 | **16** | 0 |
| **Sprite-Palette** (256 × 24 Bit Dual-Port) | ~20 | **1** | 0 |
| **32-Bit Multi-Mode Unpacker** (13 Formate `HAM_32BIT_*`) | ~100 | 0 | 0 |
| **HAM-Decoder** (Variante A: eigene Instanz / Variante B: 0) | ~95 | 0 | 0 |
| **Y-Listen-Scanner, Clipping, 8×8-Multiplizierer & DMA-FSM** | ~220 | **1** (FIFO) | 0–1 |
| **Denise-Ausgangs-Prioritätsmischer** (4 Ebenen) | ~35 | 0 | 0 |
| **Gesamtsumme** | **~510 ALMs** | **18 M10K** | **0–1 DSP** |
| *Anteil an den freien Ressourcen* | *~8,8 % der freien ALMs* | *~8,1 % der freien M10K* | *< 3 %* |
