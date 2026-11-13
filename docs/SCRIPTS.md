# Skripte im Projekt

Diese Datei beschreibt **jedes** Skript im Repo: was es tut, wozu es gut ist,
ob es noch gebraucht wird und ob es gelöscht werden kann.

**Regel (verbindlich, siehe `AGENTS.md`):** Wer ein Skript anlegt, ändert,
ersetzt oder entfernt, trägt es hier ein. Ein Skript ohne Eintrag gilt als
undokumentiert und darf nicht als Beleg angeführt werden.

Stand: 2026-11-13

Spalten:
- **Status** — `aktiv` (wird gebraucht), `Ersatz für …` (neu, löst etwas ab),
  `überholt` (funktioniert, aber nicht mehr der Weg), `löschbar` (kein Nutzen mehr).
- **Zweck** — ein Satz, was das Skript tut.

---

## 1. Werkzeuge für die Zusammenarbeit mit Toby

| Pfad | Status | Zweck | Anmerkung |
|---|---|---|---|
| `mister/tools/check_toby_updates.py` | **aktiv**, Ersatz für die frühere Fassung | Meldet neue Beiträge von `toby01019` auf vier Kanälen: Issue #9/#10, PR-Kommentare, Diff-Kommentare, formale Reviews. | Zustandslos, schreibt keine Datei. `--minutes` steuert das Zeitfenster, `--out` schreibt Treffer zusätzlich in eine Datei (und nur dann). Läuft alle 15 Minuten über die Windows-Aufgabe `NanoMig TobyWatch`, siehe Abschnitt 6. |
| `mister/tools/toby_chat.py` | aktiv | Client für Tobys Austausch-Server: Chat lesen (`GET /austausch/api/chat`) und schreiben (`POST`). Basic Auth aus `austausch_config.json`. | Braucht die Zugangsdaten. Achtung: die Datei ist **UTF-8**; wer sie mit Windows-1252 liest, bekommt ein falsches Passwort (Umlaut). |
| `mister/tools/watch_toby_chat.py` | aktiv | Dauerbeobachter für den Austausch-Chat, ruft `toby_chat.py` im Takt auf. | Endlosschleife, nur in einer eigenen Sitzung starten. |
| `mister/tools/austausch_config.json` | aktiv | Zugangsdaten für den Austausch-Server. | **Nicht** ins Repo gehört das Passwort in Klartext — derzeit liegt es dort. Sollte durch Umgebungsvariablen ersetzt werden. |
| `mister/tools/austausch_config.json.template` | aktiv | Vorlage ohne Passwort. | |
| `mister/tools/toby_monitor_state.json` | **löschbar** | Alte Zustandsdatei des früheren Prüfskripts (eine Kommentar-ID). | Wird nicht mehr gelesen; auf diesem Rechner schreibgeschützt. Kann weg, sobald die Rechte es zulassen. |
| `mister/tools/toby_check_state.json` | **löschbar** | Zwischenstand aus einem Zwischenversuch mit Zustandsdatei. | Das aktive Skript ist zustandslos und legt sie nicht mehr an. |
| `mister/tests/toby_comments.json` | überholt | Zwischenspeicher von Tobys Kommentaren (28 Einträge, Stand 05.11.). | Nur noch als Nachschlagewerk; die Quelle ist GitHub. |
| `mister/tools/chat_state.json` | aktiv (Daten) | Lokaler Verlauf des Austausch-Chats, 45 Nachrichten bis 12.11. | Wird von `toby_chat.py` fortgeschrieben. Enthält den Review-Plan aus Nachricht #44. |

## 2. Build- und Prüfwerkzeuge

| Pfad | Status | Zweck | Anmerkung |
|---|---|---|---|
| `mister/build_bitstream.ps1` | aktiv | Vollständiger Quartus-Build für Minimig auf MiSTer. | Führt `build_id.tcl` und den Compile-Flow aus. Ohne den ersten Schritt scheitert `quartus_map` an `build_id.v`. |
| `mister/tools/seed_sweep.ps1` | aktiv | Baut denselben Stand mit mehreren Fitter-Seeds, meldet ALMs/Register/RAM/Setup/Hold/RBF je Seed. | 40–50 Minuten je Seed. `-Seeds` als Komma-String, wenn per `-File` aufgerufen. |
| `mister/verify/2026-11-13-review17/run_extended_local.py` | aktiv | Führt Tobys Review17-Tests gegen dieses Repo aus (9 Tests). | Erwartet `9 / 9`. Auf dem Vor-Fix-Stand 7/9 — die Suite unterscheidet also. |
| `mister/verify/2026-10-31-capture-stereo/check_capture.py` | aktiv | Wertet die Capture-Rohdaten aus PR #1 aus. | |
| `mister/verify/testbenches/verify_adpcm.py` | aktiv | Prüft den ADPCM-Codec gegen eine Referenz. | |
| `mister/verify/testbenches/calc.py` | aktiv | Rechnet den Frequenzgang einer Biquad-Stufe und der 32-fach-Kaskade für fest eingetragene Koeffizienten aus (5 Hz bis 1 kHz). | Reines Rechenwerkzeug für die Filterdimensionierung, keine Dateien, keine Ausgabe ausser Zahlen. Koeffizienten sind hartcodiert; für andere Filter die Werte oben im Skript ersetzen. |
| `mister/verify/testbenches/test_cascade_fixedpoint.py` | aktiv | Simuliert 32 Festkomma-Biquad-Stufen hintereinander und gibt je Stufe den Spitzenwert aus. | Prüft, ob eine Kaskade bei Vollaussteuerung überläuft. Rechteck bei 200 Hz, Koeffizienten wie in `calc.py`. Damit wurde der Rechteck-Test auf Headroom geprüft. |
| `mister/tests/filter_compare/` | aktiv | A/B-Direktvergleich desselben ADPCM-Tracks ungefiltert gegen die 32-Band-Filterbank, mit Hardware-Capture je Sekunde. | Vollständiges Testprogramm mit Quelle (22,8 KB), `build.bat`, fertigem Executable und `README.txt`, das den 22-Sekunden-Ablauf beschreibt. Der Build ruft zusätzlich `lint_m68k.py` auf. |
| `src/temp_res.py` | aktiv, Wegwerfwerkzeug | Liest den Gowin-Synthesebericht (`nanomig_syn_resource.html`) und listet alle Zellen mit mehr als 100 LUTs. | Nützlich für die Tang-Ressourcenanalyse. Pfad ist absolut hartcodiert; vor Benutzung anpassen. Kein Zustand, keine Nebenwirkungen. |
| `src/gowin_pll_parser.py` (unter `src/tang/`) | aktiv | Liest Gowin-PLL-Konfigurationen aus. | |

## 3. Testprogramme (68000) und ihre Datengeneratoren

Jedes Verzeichnis enthält `build.bat` (vasm + vlink), eine `.s`-Quelle, einen
Python-Generator für die Datentabelle und das fertige Executable.

| Verzeichnis | Status | Zweck |
|---|---|---|
| `mister/tests/stereo/` | aktiv | Kanaltrennung: links 440 Hz, rechts 880 Hz, Farbe grün/rot. |
| `mister/tests/kaskade/` | aktiv | 32 Filterstufen auf Rauschen, Pegelvergleich als Farbe. |
| `mister/tests/rechteck/` | aktiv | Rechteck durch 32 Tiefpässe, Nachweis über Amplitudenverteilung. |
| `mister/tests/bandpass/` | aktiv | 1-kHz-Sinus aus der Kette, Nachweis über Nulldurchgänge. |
| `mister/tests/delay/` | aktiv | 32 Echos im 10-ms-Raster mit Lautstärkeabfall. |
| `mister/tests/am/` | aktiv | 440 Hz mit 2-Hz-Tremolo. |
| `mister/tests/adpcm/` | aktiv | Echte 4-Bit-ADPCM-Datei aus dem Apollo-Projekt. |
| `mister/tests/showcase/` | aktiv | Mono-Regression, das ursprüngliche Demo-Programm. |
| `mister/tests/filter_compare/` | aktiv | Biquad-Filterbank gegen Direktvergleich, siehe Abschnitt 2. | A/B-Test mit Hardware-Capture, 22 Sekunden Ablauf. |
| `mister/tests/showcase_32ch/` | überholt | 32-Kanal-Variante des Showcase. | Durch `showcase` und die gezielten Tests abgelöst. |
| `mister/tests/horror_demo/` | aktiv | Horrordemo-Daten (V14), von Toby auf Hardware bestätigt. |
| `mister/tests/argon_demo/` | aktiv | Argon-Demo-Daten und Testsuite. |

## 4. Sprite-Engine-Tests

| Pfad | Status | Zweck |
|---|---|---|
| `sprite_ref_model.py` | aktiv | Python-Referenzmodell der Sprite-Engine, 120 Delta-Fälle. |
| `sprite_timing_model.py` | aktiv | Zeitmodell für Zeilenbudget und Bursts. |
| `generate_fixtures.py` | aktiv | Erzeugt die Fixtures v3/v4 (JSON). |
| `verify_fixtures.py` | aktiv | Prüft Fixtures gegen das Referenzmodell. |
| `test_delta_integration.py` | aktiv | Regressionstests für die Formate aus `dbfd692`. |
| `generate_amiga_test.py` | aktiv | Erzeugt das 68000-Testprogramm für die Engine. |
| `build_spacecraft_test.py` | aktiv | Erzeugt die HTML-Vorschau (Raumschiff-Szene). |
| `inspect_scanline.py` | aktiv | Wertet den Scanline-Capture-Puffer aus. |

## 5. Fremde und historische Skripte

Diese stammen aus dem ursprünglichen MiSTer-Projekt und wurden nicht von uns
geschrieben. Sie bleiben, weil die Upstream-Simulationen sie brauchen.

| Pfad | Status | Zweck |
|---|---|---|
| `mister/rtl/sim/*/run_sim.ps1` | aktiv | ModelSim-Simulationen für Akiko, CDTV, Chipset. |
| `mister/rtl/sim/cache/patch_interlock.py` | aktiv | Patches für den Cache-Interlock in `cpu_cache_new.v`. |
| `mister/rtl/sim/sdram/make_sim_sdram.py` | aktiv | Erzeugt die ModelSim-taugliche Variante von `sdram_ctrl.v`. |
| `mister/rtl/sim/sdram/patch_fwd.py` | aktiv | Store-to-Load-Forwarding-Patch. |
| `src/build.sh`, `src/build_with_version.sh` | aktiv | Upstream-Build für die MiSTer-Variante. |
| `src/lattice/*/build.sh` | aktiv | Lattice-Diamond-Builds (icepi-zero, icesugar-pro). |
| `src/lattice/icesugar-pro/programmer.bat` | aktiv | Flash-Anleitung per `ecpdap`. |
| `src/update_minimig.ps1` | aktiv | Übernimmt Änderungen aus dem Upstream-Minimig. |
| `sim/fx68x_verilator/make.sh` | aktiv | Verilator-Build für die CPU-Simulation. |

---

## 6. Zeitpläne ausserhalb des Repos

Nicht versioniert, aber wichtig zu kennen — sonst sucht man später, wer
diese Datei schreibt.

| Ort | Was | Zweck |
|---|---|---|
| **DSH-Hintergrundauftrag** `python check_toby_updates.py --watch 30 --minutes 2` | prüft alle 30 Sekunden und **endet beim ersten Treffer** | Der Hauptweg. Solange Toby schweigt, läuft der Auftrag ohne Tokenverbrauch. Beim Treffer endet er, und DSH meldet das dem Agenten — das ist der Weckruf. Nach der Behandlung neu starten. |
| Windows-Aufgabe `NanoMig TobyWatch` | ruft alle 15 Minuten `C:\Python314\pythonw.exe mister\tools\check_toby_updates.py --minutes 20 --out "%LOCALAPPDATA%\dsh-toby\news.txt"` auf | Sicherheitsnetz, falls DSH nicht läuft. Schreibt nur dann eine Datei, wenn es wirklich etwas Neues gibt. |
| `%LOCALAPPDATA%\dsh-toby\news.txt` | Ergebnisdatei der Windows-Aufgabe | Existiert nur, wenn Toby geschrieben hat. Inhalt ist der jeweilige Beitrag mit Zeitstempel. |

Das Zeitfenster muss beim Dauerbetrieb klein sein (`--minutes 2` bei 30 Sekunden
Takt), sonst liegt ein bereits behandelter Beitrag noch im Fenster und löst beim
Neustart sofort wieder aus.

Anlegen, prüfen, entfernen:

```powershell
schtasks /query /tn "NanoMig TobyWatch" /v /fo LIST
schtasks /run   /tn "NanoMig TobyWatch"
schtasks /delete /tn "NanoMig TobyWatch" /f
```

Der Python-Lauf kostet keine Tokens. Tokens entstehen erst, wenn jemand die
Ergebnisdatei liest oder die Aufgabe in DSH ausgewertet wird.

---

## Was fehlt noch

Keine Skripte mehr undokumentiert. Offen sind nur die `build.bat` in
`mister/tests/*`, die keinen eigenen Kopfkommentar haben — sie sind in
Abschnitt 3 über ihr Verzeichnis beschrieben.

Offene Aufräumarbeiten:

```
mister/tools/toby_monitor_state.json   löschbar, auf diesem Rechner schreibgeschützt
mister/tools/toby_check_state.json     löschbar, Zwischenstand eines Versuchs
mister/tests/showcase_32ch/            überholt
mister/tests/toby_comments.json        überholt, nur noch Nachschlagewerk
```
