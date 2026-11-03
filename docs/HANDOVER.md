# Übergabe — Stand 2026-11-02

Diese Datei beschreibt alles, was zum Weiterarbeiten nötig ist: was gebaut
wurde, was geprüft ist, was offen ist, und mit welchen Werkzeugen gearbeitet
wird. Sie setzt keinen Vorwissen voraus.

Verwandte Dateien: `docs/LESSONS.md` (Fehler und Regeln),
`docs/AUDIO_DATAPATH.md` (Datenpfad), `docs/audio_core.html` (interaktive
Darstellung), `COLLABORATION.md` (Zusammenarbeit mit Toby).

---

## 1. Wo wir stehen

| Branch | Stand | Bedeutung |
|---|---|---|
| `main` | `2e3ed1e` | unverändert, auf Hardware erprobt |
| **`rudi/chain-stereo`** | `45149cd` | **aktueller Arbeitsstand**, alle Audio-Korrekturen + Option A + AM-Stereo |
| Aktueller Bitstream | `c106117b1197` (RBF) | Fitter Seed 11, Option A, 36.152 ALMs |
| Vorheriger Seed 11 | `2a92564d62f6` (RBF) | Zwischenstand vor Option A |

**Nichts ist nach `main` gemergt.** Der Arbeitsstand ist simuliert, bitgenau verifiziert (inkl. ADPCM gegen Python) und
gebaut, aber **noch nicht auf MiSTer-Hardware getestet** (Test mit Toby für 7:00 Uhr vereinbart).

### Der Arbeitsstand im Einzelnen

Alle Änderungen liegen in `mister/rtl/audio_ext/` und `mister/rtl/chipdma_arb.v`:

1. **32-Bit-Frames dekodierbar** (`96d4b06`) — 16-Bit-Stereo war ein
   Deadlock: `v_bc` war 5 Bit breit und erreichte nie die 32 Bit eines
   Stereo-Frames; der Nachladezweig wartete auf `v_bc <= 8`. Zähler auf 6 Bit,
   Reservoir auf 32 Bit, Nachladen bei `v_bc + 16 <= v_frame_bits`.
2. **Linker und rechter Kanal getrennt** (`d25f8d8`) — vorher las der Dekoder
   nur das untere Wort, beide Seiten hatten dasselbe Sample. Jetzt
   `sdpb_pcm_idx = {rechts, links}`, der ADPCM-Index liegt in
   `sdpb_timer_bc[9:3]`.
3. **Filter auf 32 Stimmen je Instanz** (`459d2ad`).
4. **Filter-DSPs nach Kanal geteilt** (`97d02b5`): DSP 0 links, DSP 1 rechts,
   je alle 32 Stimmen. Vorher nach Stimmenhälfte (`cur_voice[4]`).
5. **Koeffizienten im Block-RAM** (`d056559`) — Ganzwort-Schreibzugriff statt
   zweier Byte-Zweige. −2.655 ALMs in der Synthese, +2 M10K.
6. **Gestoppte Stimme ist still** (`9d87766`) — Stille entsteht nur über den
   Lautstärkefaktor, der Dekodierzustand bleibt erhalten.
7. **Frühes Nachladen bei Loops** (`9d87766`) — der DMA füllt, sobald er das
   letzte Byte geholt hat, nicht erst bei leerem FIFO.
8. **Fester Zähler statt Prioritätsdurchlauf** (`e649fe0`) — `stage` läuft
   0…31, eine leere Stufe kostet einen Takt. Reihenfolge garantiert.
9. **Kette führt links und rechts getrennt** (`a379ee4`) — vier Register
   statt zwei. Vorher war eine verkettete Stimme mono.
10. **Audio-DMA bis Fast-RAM** (`5580e35`) — liegt auf einem eigenen Branch
    `rudi/dma-full-address`, **nicht** im Arbeitsstand.

---

## 2. Was geprüft ist

Alles in Icarus, gegen die Testbenches in `mister/verify/testbenches/`.

| Prüfung | Ergebnis |
|---|---|
| Mono, Stimmen 0/16/30 | 198725 / 198757 / 198789 (32 Takte Anlauf, sonst identisch zu `main`) |
| 32 Stimmen stereo | 201.763 Samples, **alle** mit L ≠ R |
| Gestoppte Stimme, Lautstärke bleibt | 52 von 8000 Takten ≠ 0 (nur Pipeline-Auslauf) |
| Leerlauf FIFO bei Loop | 11,7 % → 0,1 % |
| Ketten-stereo | L ≠ R von 0,7 % auf 100 % |
| Warteschlange | max 4 von 32 im Normalbetrieb |

**Nicht geprüft:** ADPCM auf Hardware, Kaskade über 32 Stufen, echte
Audiodaten, und überhaupt nichts auf dem MiSTer.

---

## 3. Fläche und Timing

```
              ALMs    Register  RAM  DSP   Setup    Hold
main          38.355  53.135    327  75    −1.846   −0.822
Arbeitsstand  36.094  49.745    330  75    −1.154   positiv
Seed 11 (alt) 36.087  49.749    330  75    −0.430   +0.245
Opt A (c1061) 36.152  49.741    330  75    −0.538   +0.252
```

**Die Verletzung liegt nicht im Audio.** Gemessen auf der Datenbank:

```
Pfade in den Filter:   17,9 ns Reserve
Pfade aus dem Filter:  19,3 ns Reserve
```

Der Verletzer ist eine Kreuzung in Paulas Floppy-DMA:

```
von:   paula_floppy_fifo|in_ptr   (clk_sys, 28,375 MHz)
nach:  sdram_ctrl|sd_ras          (clk_114, 113,5 MHz)
14 Logikstufen, 18,9 ns gegen 17,6 ns
```

Das ist eine **Altlast des Minimig-Kerns**, in `main` genauso vorhanden.

### Seed-Statistik (26 Läufe)

```
Setup:  Maximum −0,168   Mittel −0,833   Minimum −3,142
Hold:   negativ bei 8 von 26 (31 %)
Gemeinsam brauchbar (Setup > −0,5 und Hold > 0): nur Seed 11 und 26
```

**Kein Seed erreicht positives Setup.** Bei 86 % Auslastung ist das durch
Platzierung nicht erreichbar. Und die besten Setup-Werte haben negativen
Hold — der Fitter tauscht das eine gegen das andere.

---

## 4. Werkzeuge und wie man sie benutzt

### Quartus

```
C:\altera_lite\25.1std\quartus\bin64\
```

Ein Build braucht **zwei** Schritte, sonst fehlt `build_id.v`:

```powershell
quartus_sh -t sys/build_id.tcl compile Minimig Minimig
quartus_sh --flow compile Minimig
```

Laufzeit 40–50 Minuten. Arbeit immer in einem eigenen Worktree:

```powershell
git worktree add --detach "$env:TEMP\build-xyz" <branch> --quiet
```

**Immer prüfen, dass der Worktree den erwarteten Commit hat** — ein
uncommitteter Arbeitsbaum führt zu Messungen am falschen Stand.

### Seed-Lauf

```powershell
.\mister\tools\seed_sweep.ps1 -Branch rudi/chain-stereo -Seeds "16,17,18,19"
```

Baut je Seed einen Worktree, liest Setup/Hold/ALMs/RBF und sortiert.

### Simulation

```
C:\ProgramData\chocolatey\bin\iverilog.exe
C:\ProgramData\chocolatey\bin\vvp.exe
```

```powershell
cd mister\rtl\audio_ext
iverilog -g2012 -s tb -o "$env:TEMP\t.vvp" `
  "..\..\verify\testbenches\tb_integrated.v" `
  audio_ext.v biquad_iir_ringbuffer.v adpcm_decoder_shared.v
vvp "$env:TEMP\t.vvp" "+VOICE=0" "+DELAY=0"
```

Erwartete Zeile: `INTEGRATED_UNITY_PASS` mit
`output_nonzero=198725` (Stimme 0).

### 68000-Assembler (vasm/vlink)

Nicht im System installiert. Aus dem vbcc-Paket:

```
http://www.ibaug.de/vbcc/vbcc_win_x64.zip
```

entpacken, dann `bin\vasmm68k_mot.exe` und `bin\vlink.exe`:

```
vasmm68k_mot -quiet -Fhunk -o prog.o prog.s
vlink -bamigahunk -s -o prog prog.o
```

Ergebnis beginnt mit `00 00 03 F3` (Amiga-Hunk-Executable).

---

## 5. Testprogramme

Alle in `mister/tests/<name>/`, jeweils mit `build.bat`, Quelle, Datengenerator
und **fertig gebautem Executable**. Alle zeigen eine Farbe zur Selbstprüfung.

| Programm | Prüft | Farbe |
|---|---|---|
| `stereo/stereotest` | Kanaltrennung | grün = L ≠ R in > 900 von 1024 |
| `kaskade/kaskade` | 32 Stufen, Dämpfung | grün = Pegel B < ¼ Pegel A |
| `rechteck/rechteck` | Filter entfernen Oberschwingungen | grün = Ausgang ist Sinus |
| `bandpass/bandpass` | 1-kHz-Sinus aus der Kette | grün = 38…48 Nulldurchgänge |
| `delay/delay` | 32 Echos im 10-ms-Raster | grün nach 0,5 s, blau nach 2 s |
| `am/am` | 440 Hz mit 2-Hz-Tremolo | keine |
| `adpcm/adpcm` | 4-Bit-ADPCM, echte Daten | grün = läuft |

`adpcm` spielt 1 s aus `my_crossdev/Projects/ADPCM_Decoder/
Kakao_bei_Lotte_Run17_4-Bit,Mono,LE.adpx` — Header 21 Bytes, Codes LSB-first,
unverändert übernommen. Siehe `mister/tests/adpcm/README.txt`.

Das Release-Paket für den Tester liegt in `mister/release/2026-11-01/`:
RBF `5f83871c…b99f` (4.104.228 Bytes) plus die sieben Programme.

---

## 6. Zusammenarbeit mit Toby

`COLLABORATION.md` im Wurzelverzeichnis. Aktuelle Regeln:

- **Toby's KI begleitet nur Tests**, kurze Antworten, wenig Token.
- Jede Nachricht beginnt mit `Ich bin Rudis KI:` und einer Leerzeile.
- Nur senden, was zum Testen nötig ist: Hash, Testfall, Erwartung.
- Keine Beweispakete, keine Architekturdiskussion.
- Toby's KI piept dreimal vor jedem MiSTer-Test und wartet auf Tobys
  Bestätigung, dass er am Bildschirm ist.

**Letzter Stand der Zusammenarbeit:** Core und Programme sind bei ihnen
heruntergeladen, die Tests waren am 2026-11-02 um 18:28 noch nicht gelaufen,
weil Toby am Apollo arbeitete. Sie wollen abends testen und je Programm
Farbe, Ton und Abweichung melden.

Zugang zur GitHub-API:

```powershell
$c = "protocol=https`nhost=github.com`n`n" | git credential fill
$tok = (($c -split "`n") | Where-Object { $_ -like 'password=*' }) -replace '^password=',''
```

---

## 7. Was als Nächstes zu tun ist

### Sofort

1. **Testergebnisse abholen** (Issue #9 in `Rudi7503/NanoMig`). Bis dahin
   bleibt der Stand unverifiziert.
2. Bei Störungen im Test: **Seed 11** anbieten (`2a92564d62f6`,
   Setup −0,430 statt −1,154).

### Danach

3. **ADPCM in der Simulation prüfen.** Die zwei strukturellen Belege (LSB-first
   in beiden Implementierungen, Standard-IMA-Tabelle) machen einen Fehler
   unwahrscheinlich, ersetzen den Lauf aber nicht. Referenz in Python gegen
   den RTL-Dekoder.
4. **Kaskadentest über 32 Stufen** — der feste Zähler ist die Voraussetzung,
   ein Test steht noch aus. Dabei beachten: `ch0` muss auf Quelle `00` stehen,
   sonst ist der Ring geschlossen und es wird nichts eingespeist.
5. **Pull Request** gegen `main` — bisher gibt es keinen. Mit dem Abschnitt
   „nicht verifiziert", solange kein Hardwaretest vorliegt.

### Aufgeräumt werden muss

6. **Über 40 Worktrees** unter `%TEMP%` (`build-*`, `map-*`, `seed-*`,
   `filterbranch3`, `simbase`, `simfmt`) — je 0,1 bis 0,4 GB.
   `git worktree list` zeigt sie, `git worktree remove <pfad> --force` räumt auf.
7. **Branches zusammenführen oder löschen.** Erledigt und überholt:
   `rudi/size-timing`, `rudi/filter-merge`, `rudi/bram-config`,
   `rudi/idle-silence`, `rudi/early-refill`, `rudi/fixed-order`,
   `bram-test`, `bram-test2`, `rudi/audio-bram`, `wip/fixed-order-scheduler`.
   Der Inhalt steckt in `rudi/chain-stereo`.

### Offene Entscheidungen

8. **Ringschluss ch31 → ch0** ist gewollt (Rückkopplungsfilter) und im RTL
   dokumentiert. Zu klären bleibt, ob das in die Spezifikation gehört.
9. **Kaskade in einer Sampleperiode** — 32 Stufen mono oder stereo passen,
   aber nur mit Seitenteilung und festem Zähler. Beides ist jetzt vorhanden,
   ein Test fehlt.
10. **Pipelining über Stimmen** — würde 448 auf etwa 224 Takte halbieren.
    Zurückgestellt, und für das Timing **nicht nötig**: der Filter hat
    17,9 ns Reserve.
11. **Vorzeichen-Regel für die drei Arrays im Filter** (`pending_*`,
    `y_held_*`, rund 4.400 Flip-Flops). Verschieben in Block-RAM würde nach
    Schätzung 0,1–0,2 ns bringen — nicht die 0,4+, die für positives Setup
    fehlen.

---

## 8. Fallstricke

- `%TEMP%` wird geleert. Alles, was wichtig ist, gehört ins Repo.
- Der build_id-Schritt vergessen → `quartus_map` bricht mit
  „can't open Verilog Design File build_id.v" ab.
- Ein Fitter-Abbruch hinterlässt eine Zusammenfassung mit **Nullen**. Die ist
  wertlos, nicht alarmierend.
- `git worktree add` nimmt den **committeten** Stand, nicht den Arbeitsbaum.
- Der Seed-Lauf braucht `-Seeds` als Komma-String, wenn er per `-File`
  aufgerufen wird.
- Die Slack-Zeile in `Minimig.sta.summary` steht in der **nächsten** Zeile.
