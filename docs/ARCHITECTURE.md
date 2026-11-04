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
       |  | 21-Bit Master-Akkumulator & Soft-Clipper (sample_l, sample_r)     |  |
       |  +-------------------------------------------------------------------+  |
       |            |                                              |             |
       |            v                                              v             |
       |    audio_capture.v                               Dual-Clock Mailbox     |
       |  (2x 4 KB Ringpuffer)                         (clk_sys -> CLK_AUDIO)    |
       |                                                           |             |
       +-----------------------------------------------------------|-------------+
                                                                   v
                                                        MiSTer Audio-Mixer
                                                        (48 kHz / 96 kHz I2S)
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
| `+4` | `$02` | `AUDxLENH` | Sample-Länge High-Word (in 16-Bit-Wörtern) |
| `+6` | `$03` | `AUDxLENL` | Sample-Länge Low-Word (in 16-Bit-Wörtern) |
| `+8` | `$04` | `AUDxPER`  | Paula-kompatible Abtastperiode (Farbtakt-Teiler) |
| `+10`| `$05` | `AUDxVOL`  | Lautstärke: Bit 15..8 = Links, Bit 7..0 = Rechts |
| `+12`| `$06` | `AUDxCTRL` | Bit 0: 16-Bit PCM, Bit 1: One-Shot, Bit 2: Stereo, Bit 3: ADPCM, Bit 5..4: BPS, Bit 7: Flt R, Bit 8: Flt L, Bit 10..9: Input-Src |
| `+14`| `$07` | `AUDxPRED` | ADPCM Prädiktor Initialwert |
| `+16`| `$08` | `AUDxB0`   | Biquad Koeffizient $b_0$ (Q2.14, vorzeichenbehaftet) |
| `+18`| `$09` | `AUDxB1`   | Biquad Koeffizient $b_1$ (Q2.14, vorzeichenbehaftet) |
| `+20`| `$0A` | `AUDxB2`   | Biquad Koeffizient $b_2$ (Q2.14, vorzeichenbehaftet) |
| `+22`| `$0B` | `AUDxA1`   | Biquad Koeffizient $a_1$ (Q2.14, vorzeichenbehaftet) |
| `+24`| `$0C` | `AUDxA2`   | Biquad Koeffizient $a_2$ (Q2.14, vorzeichenbehaftet) |
| `+26`| `$0D` | `AUDxCMD`  | Bit 0: Start, Bit 1: Stop |
| `+28`| `$0E` | `AUDxDEL`  | Hardware-Startverzögerung (in 32.768-kHz-Ticks) |
| `+30`| `$0F` | `AUDxSTAT` | Status (Bit 0: Delaying, Bit 1: Prefill, Bit 2: Playing) |

### Globale Interrupt-Register (Option A): `$DFF804 .. $DFF80A`

Da bei Stimme 31 die Register `$DFF7F8 .. $DFF7FE` früher durch Interrupts belegt waren, wurden die globalen IRQ-Register nach `$DFF804` verlegt, sodass **Voice 31 uneingeschränkt nutzbar** ist:

| Adresse | Register | Funktion |
| :--- | :--- | :--- |
| `$DFF804` | `AUDINTENAH` | Interrupt Enable Bits 31..16 (Stimmen 31..16) |
| `$DFF806` | `AUDINTENAL` | Interrupt Enable Bits 15..0  (Stimmen 15..0) |
| `$DFF808` | `AUDINTREQH` | Interrupt Request / W1C Bits 31..16 |
| `$DFF80A` | `AUDINTREQL` | Interrupt Request / W1C Bits 15..0 |

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

## 6. Capture-Engine ([`audio_capture.v`](file:///D:/programmier_ordner/FPGA/NanoMig/mister/rtl/audio_capture.v))

* 2 Puffer zu je 4096 Samples (16-Bit Signed).
* Unterstützt Ringpuffer-Modus oder Single-Shot-Capture (Block A / B).
* Ermöglicht bitgenaue Rücklesung der gefilterten Audiodaten zur automatisierten Verifikation.
