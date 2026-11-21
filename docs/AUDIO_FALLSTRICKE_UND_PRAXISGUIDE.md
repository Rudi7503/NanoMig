# NanoMig 32-Kanal Audio-Erweiterung: Fallstricke & Best Practices Guide

> **Zweck dieses Dokuments:**  
> Dieses Dokument fasst alle real in der Entwicklung und Verifikation aufgetretenen Fallstricke, Design-Entscheidungen und Programmierregeln der 32-Kanal Audio-Erweiterung und des Master-Mixers für NanoMig / Minimig-AGA zusammen. Es dient als verbindliche Anleitung für Entwickler und Software-Autoren.

---

## 1. Übersicht der Kernarchitektur

* **Stimmenanzahl:** 32 unabhängige Stimmen (TDM bei 25 MHz, Adressbereich `$DFF400..$DFF7FE`).
* **Auflösung:** 16-Bit Big-Endian PCM, 8-Bit PCM oder verlustarme 4-Bit Hardware-ADPCM.
* **DSP pro Stimme:** 2 parallele 2nd-Order Biquad IIR-Filterkerne (Q2.14 Festkomma), strikt getrennt nach Links (`biquad0`) und Rechts (`biquad1`).
* **Signalfluss:** DMA/FIFO $\rightarrow$ Dekoder $\rightarrow$ Pre/Post-Kaskade $\rightarrow$ Biquad $\rightarrow$ AM/Ringmod $\rightarrow$ 21-Bit Akkumulator $\rightarrow$ 42-Bit CDC Mailbox $\rightarrow$ 22-Bit Master-Mixer $\rightarrow$ 48-kHz True-Peak AGC Limiter $\rightarrow$ DAC.

---

## 2. Die 10 kritischen Fallstricke & Wie man es richtig macht

### Fallstrick 1: 16-Bit PCM Endianness (Motorola Big-Endian)
* ❌ **Falsch:** 16-Bit Wave- oder Rohaudiodateien nativ auf x86-PCs erzeugen und ohne Byte-Swap auf den Amiga kopieren (Little-Endian `<i2`).
* 💥 **Symptom:** Das schnelle LSB liegt auf dem MSB der Hardware. Resultat: Extremer, ohrenbetäubender Sägezahn-Lärm („Kreissäge“).
* ✅ **Richtig:** Alle 16-Bit Audiodaten müssen zwingend im Motorola Big-Endian Format vorliegen:
  ```python
  # Python Generator:
  import struct
  raw_bytes = struct.pack('>h', sample_value)  # Big-Endian Signed 16-Bit
  # Oder NumPy:
  data.astype('>i2').tofile("sample.raw")
  ```

---

### Fallstrick 2: Falsche Zeitbasis für Perioden-Register (`AUDxPER`)
* ❌ **Falsch:** Verwendung der Amiga-Paula-Formel (Farbtakt $3{,}54\,\text{MHz} / f_s$, z. B. $744$ für 48 kHz).
* 💥 **Symptom:** Tonhöhe ist um den Faktor $\approx 7{,}06$ viel zu tief oder unhörbar.
* ✅ **Richtig:** Die Audio-Engine nutzt eine virtuelle **25-MHz-Zeitbasis** ($50\,\text{MHz} / 2$):
  $$f_s = \frac{25.000.000}{\text{PER}} \quad \Longleftrightarrow \quad \text{PER} = \frac{25.000.000}{f_s}$$
  * **48.000 Hz:** $\text{PER} = 521$ (`$0209`)
  * **44.100 Hz:** $\text{PER} = 567$ (`$0237`)
  * **32.000 Hz:** $\text{PER} = 781$ (`$030D`)
  * **22.050 Hz:** $\text{PER} = 1134$ (`$046E`)

---

### Fallstrick 3: Pufferlänge `AUDxLEN` in Wörtern statt Bytes
* ❌ **Falsch:** Wie bei Paula die Wort-Anzahl (`Samples / 2`) in `AUDxLEN` schreiben.
* 💥 **Symptom:** Das Sample bricht nach der halben Spielzeit ab oder loopt zu früh.
* ✅ **Richtig:** `AUDxLEN` erwartet die **Länge in Bytes** (muss eine gerade Zahl sein):
  ```assembly
  MOVE.L #SAMPLE_SIZE_BYTES, D0
  SWAP   D0
  MOVE.W D0, $DFF404+(CH*32)   ; AUDxLENH (Bits 31..16)
  SWAP   D0
  MOVE.W D0, $DFF406+(CH*32)   ; AUDxLENL (Bits 15..0)
  ```

---

### Fallstrick 4: Kaskadierte Stimmen ohne `LEN = 0` und ungemutete Vorstufen
* ❌ **Falsch:** Eine Folgestufe einer 24-dB Moog-Kaskade oder eines Vocoders mit `LEN > 0` starten und die Vorstufe nicht im Master-Mix stummschalten.
* 💥 **Symptom:** 
  1. Folgestufe fordert DMA-Zyklen für uninitialisierten Speicher an.
  2. Im Master-Mix wird das 12-dB-Zwischensignal der Vorstufe zum 24-dB-Endsignal addiert (Phasenauslöschung / unsauberer Filterklang).
* ✅ **Richtig:**
  1. Vorstufe erhält Bit 13 in `AUDxCTRL` (`CTRL_MUTE_MIX` = `$2000`). Sie berechnet das Filter, gibt ihren Ausgang an die nächste Stimme weiter, wird aber im Mix stummgeschaltet.
  2. Folgestufe erhält `AUDxLEN = 0` und `v_input_src` = `10` (Post-Filter) oder `01` (Pre-Filter). Sie wechselt sofort in `PLAYING` und verbraucht 0 % DMA.

---

### Fallstrick 5: Sprunghafte Lautstärke-/Registerwechsel auf Resonanzfiltern
* ❌ **Falsch:** Bei aktiven Biquad-Bandpass- oder Resonanzfiltern die Lautstärke (`AUDxVOL`) schlagartig umschalten (z. B. Formantbänder von 16 auf 160 alle paar Frames).
* 💥 **Symptom:** Stufendiskontinuitäten mitten in der Schwingungsform erzeugen ein periodisches Mikroknacken bei der Umschaltrate (z. B. 12,5 Hz).
* ✅ **Richtig:** Lautstärke- und Filterkoeffizienten-Änderungen immer über einen **Slew-Rate-Limiter / Micro-Crossfade** dämpfen:
  ```assembly
  ; Slew-Rate Limiter (max. delta = 6 pro 50 Hz Frame)
  MOVE.B  TargetVol(PC), D0
  MOVE.B  CurrentVol(PC), D1
  SUB.B   D1, D0
  BEQ.S   .done
  BGT.S   .up
  CMP.B   #-6, D0
  BGE.S   .apply
  MOVEQ   #-6, D0
  BRA.S   .apply
  .up:
  CMP.B   #6, D0
  BLE.S   .apply
  MOVEQ   #6, D0
  .apply:
  ADD.B   D0, D1
  MOVE.B  D1, CurrentVol
  MOVE.B  D1, $DFF408+(CH*32)   ; AUDxVOL
  .done:
  ```

---

### Fallstrick 6: Summenübersteuerung im Master-Mixer (Clipping vs. Headroom)
* ❌ **Falsch:** Jede Stimme hart in 16 Bit begrenzen oder die Stimmen im Mixer bei Vollaussteuerung einfach auf 16 Bit addieren und hart clippen.
* 💥 **Symptom:** Krächzendes digitales Hard-Clipping oder gegenseitiges Wegdrücken der Stimmen (Intermodulations-Verzerrungen).
* ✅ **Richtig:** Die NanoMig-Architektur trennt Dynamik und Pegelbegrenzung:
  1. `audio_ext.v` akkumuliert alle 32 Stimmen ohne Vor-Clipping in einem **21-Bit Register** (+30 dB Headroom).
  2. `Minimig.sv` summiert alle internen und externen Audioquellen in einem **22-Bit Master-Akkumulator** (+36 dB Headroom).
  3. Der zentrale **Hardware True-Peak AGC Limiter** (`audio_agc_limiter.v`) überwacht die Summe bei 48 kHz. Überschreitet der Spitzenwert -0,5 dBFS (30.720), skaliert eine 15-Zyklen-Division das Signal verzerrungsfrei herunter. Eine exponentielle Release-Kurve (~85 ms) stellt die Verstärkung unhörbar wieder her.

---

### Fallstrick 7: Nicht-kohärentes Clock-Domain Crossing (CDC)
* ❌ **Falsch:** Linken und rechten Audiokanal in getrennten Registern über Taktdomänen (`clk_sys` 28 MHz $\rightarrow$ `CLK_AUDIO` 24,576 MHz) synchronisieren.
* 💥 **Symptom:** Ein Abtasttakt kann den linken Kanal von Sample $k$ und den rechten von Sample $k-1$ erfassen $\rightarrow$ Stereo-Phasenjitter und Bitfehler.
* ✅ **Richtig:** Übergabe in einem gemeinsamen, atomaren **42-Bit Mailbox-Register** (`[41:21]` Links, `[20:0]` Rechts).

---

### Fallstrick 8: AmigaOS Library-Calls (`_LVO`) ohne `A6`
* ❌ **Falsch:** `_LVO`-Funktionen mit der Library-Base in `A0` aufrufen, während `A6` auf `$DFF000` (`CUSTOM`) zeigt:
  ```assembly
  MOVE.L  DOSBase, A0
  JSR     _LVOOutput(A0)   ; CRASH!
  ```
* 💥 **Symptom:** Guru Meditation `#00000003` (Address Error), da AmigaOS-Funktionen intern `(A6)` dereferenzieren.
* ✅ **Richtig:** Zwingend `MOVE.L LibraryBase, A6` gefolgt von `JSR _LVO...(A6)`:
  ```assembly
  MOVE.L  DOSBase, A6
  JSR     _LVOOutput(A6)   ; Sicher und OS-konform
  ```

---

### Fallstrick 9: Vorzeichen- und High-Byte-Reste bei 68000 Wortindizierung
* ❌ **Falsch:** `MOVE.B Index, D0` gefolgt von `MOVE.B (A0, D0.W), D1`.
* 💥 **Symptom:** In Bits 15..8 von `D0` steht noch Datenmüll einer vorherigen Operation $\rightarrow$ Indizierung greift Hunderte Bytes daneben in fremden Speicher.
* ✅ **Richtig:** Vor jedem Byte-Ladevorgang, der als Wortindex oder Multiplikand genutzt wird, `MOVEQ #0, Dn` ausführen:
  ```assembly
  MOVEQ   #0, D0
  MOVE.B  LFO_Phase, D0
  MOVE.B  (A0, D0.W), D1   ; Garantiert sauberer 0..255 Offset
  ```

---

### Fallstrick 10: DMA-Puffer im ungemappten Speicher
* ❌ **Falsch:** Audiodaten in dynamisch allokiertem BSS oder Nicht-DMA-fähigem Speicher ablegen.
* 💥 **Symptom:** DMA-Fehler oder Stille auf Systemen mit Slow-RAM (`$C00000`).
* ✅ **Richtig:** Sample-Puffer und Copperlisten immer in `SECTION ...,DATA_C` (Chip-RAM) oder dediziertem Fast-RAM-Adressbereich platzieren.

---

## 3. Vollständige Register-Referenztabelle

### Stimmenregister (`$DFF400 + Stimme * 32`, Stimmen 0..31):

| Offset | Wort | Name | R/W | Beschreibung |
|:---:|:---:|:---|:---:|:---|
| `+$00` | `$00` | `AUDxPTRH` | W | Sample-Startadresse High-Word (Bits 31..16) |
| `+$02` | `$01` | `AUDxPTRL` | W | Sample-Startadresse Low-Word (Bits 15..1, Bit 0 = 0) |
| `+$04` | `$02` | `AUDxLENH` | W | Sample-Länge High-Word in **Bytes** |
| `+$06` | `$03` | `AUDxLENL` | W | Sample-Länge Low-Word in **Bytes** (`0` bei Kaskaden) |
| `+$08` | `$04` | `AUDxVOL`  | W | High-Byte: Links (`0..255`), Low-Byte: Rechts (`0..255`) |
| `+$0A` | `$05` | `AUDxPER`  | W | 25-MHz-Teiler ($25.000.000 / f_s$, z. B. `521` für 48 kHz) |
| `+$0C` | `$06` | `AUDxCTRL` | W | Steuerregister (Format, Filter, Kaskadierung, Mute) |
| `+$0E` | `$07` | `AUDxPRED` | W | ADPCM Prädiktor Initialwert & Index |
| `+$10` | `$08` | `AUDxB0`   | R/W | Biquad Koeffizient $b_0$ (Q2.14 vorzeichenbehaftet, `$4000` = 1.0) |
| `+$12` | `$09` | `AUDxB1`   | R/W | Biquad Koeffizient $b_1$ (Q2.14 vorzeichenbehaftet) |
| `+$14` | `$0A` | `AUDxB2`   | R/W | Biquad Koeffizient $b_2$ (Q2.14 vorzeichenbehaftet) |
| `+$16` | `$0B` | `AUDxA1`   | R/W | Biquad Koeffizient $a_1$ (Q2.14 vorzeichenbehaftet) |
| `+$18` | `$0C` | `AUDxA2`   | R/W | Biquad Koeffizient $a_2$ (Q2.14 vorzeichenbehaftet) |
| `+$1A` | `$0D` | `AUDxCMD`  | W/R | Bit 0: Start, Bit 1: Stop. Read: Status |
| `+$1C` | `$0E` | `AUDxDEL`  | W | Startverzögerung (in 32.768-kHz-Ticks, bis 2,0 s) |
| `+$1E` | `$0F` | `AUDxSTAT` | R | Status-Flags |

### Bitmasken für `AUDxCTRL` (`+$0C`):
* `$0001`: `CTRL_PCM16` (1 = 16-Bit Signed PCM, 0 = 8-Bit)
* `$0002`: `CTRL_ONESHOT` (1 = One-Shot, 0 = Loop)
* `$0004`: `CTRL_STEREO` (1 = Interleaved Stereo, 0 = Mono)
* `$0008`: `CTRL_ADPCM` (1 = 4-Bit ADPCM aktiv, 0 = PCM)
* `$0080`: `CTRL_FLT_R` (1 = Biquad auf rechtem Kanal aktiv)
* `$0100`: `CTRL_FLT_L` (1 = Biquad auf linkem Kanal aktiv)
* `$0180`: `CTRL_FLT_STEREO` (Stereo-Filterung aktiv)
* `$0200`: `CTRL_SRC_PRE` (Eingang: Pre-Filter von Stimme $N-1$)
* `$0400`: `CTRL_SRC_POST` (Eingang: Post-Filter von Stimme $N-1$, 24 dB Moog-Kaskade)
* `$0800`: `CTRL_MOD_AM` (AM / Tremolo durch Stimme $N-1$)
* `$1000`: `CTRL_MOD_RING` (Ringmodulation Träger $N \times$ Modulator $N-1$)
* `$2000`: `CTRL_MUTE_MIX` (Stummschaltung im Master-Mix für reine Kaskadenstufen)

### Globale Interrupt- & Capture-Register (`$DFF802 .. $DFF80A`):
* `$DFF802`: `CAP_CTRL` – Audio-Capture Steuerung & Status (Doppelpuffer bei `$DF8000` / `$DF9000`).
* `$DFF804`: `AUDINTENAH` – Interrupt Enable Stimmen 31..16.
* `$DFF806`: `AUDINTENAL` – Interrupt Enable Stimmen 15..0.
* `$DFF808`: `AUDINTREQH` – Interrupt Request / Write-1-to-Clear Stimmen 31..16.
* `$DFF80A`: `AUDINTREQL` – Interrupt Request / Write-1-to-Clear Stimmen 15..0.
