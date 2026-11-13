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
| `mister/tools/check_toby_updates.py` | **aktiv**, Ersatz für die frühere Fassung | Meldet neue Beiträge von `toby01019` auf vier Kanälen: Issue #9/#10, PR-Kommentare, Diff-Kommentare, formale Reviews. | Zustandslos, schreibt keine Datei. `--minutes` steuert das Zeitfenster. Ersetzt die Fassung, die nur Issue-Kommentare auf #9/#10 las und PR-Reviews übersah. |
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
| `mister/verify/testbenches/calc.py` | **undokumentiert** | Unbekannt, 0,4 KB. | Entweder beschreiben oder löschen. |
| `mister/verify/testbenches/test_cascade_fixedpoint.py` | **undokumentiert** | Vermutlich Festkomma-Test der Filterkaskade. | Prüfen und beschreiben. |
| `src/temp_res.py` | **löschbar** | Kein Kopfkommentar, Name deutet auf Wegwerfskript. | Nicht mehr referenziert. |
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
| `mister/tests/showcase_32ch/` | überholt | 32-Kanal-Variante des Showcase. | Durch `showcase` und die gezielten Tests abgelöst. |
| `mister/tests/horror_demo/` | aktiv | Horrordemo-Daten (V14), von Toby auf Hardware bestätigt. |
| `mister/tests/argon_demo/` | aktiv | Argon-Demo-Daten und Testsuite. |
| `mister/tests/filter_compare/` | **undokumentiert** | Nur `build.bat`, keine Quelle im Verzeichnis. | Prüfen oder löschen. |

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

## Was fehlt noch

Vier Skripte sind undokumentiert und brauchen entweder eine Beschreibung oder
die Löschung:

```
mister/verify/testbenches/calc.py
mister/verify/testbenches/test_cascade_fixedpoint.py
mister/tests/filter_compare/build.bat
src/temp_res.py
```

Dazu gehören alle `build.bat` in `mister/tests/*`, die keinen Kopfkommentar
haben. Sie sind in Abschnitt 3 über ihr Verzeichnis beschrieben.
