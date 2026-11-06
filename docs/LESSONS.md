# Lehren aus dem Audio-Projekt

Diese Datei sammelt Fehler, die in diesem Projekt tatsächlich passiert sind,
und die Regel, die jeden davon verhindert hätte. Sie ist für Menschen und
für KI-Assistenten gedacht, die hier weiterarbeiten.

Stand: 2026-11-06

## 1. Zahlen niemals abschreiben

**Passiert:**
- Warnungszahl im Evidence-Paket mit 150 angegeben, das Log sagte 154.
- SHA256 des Bitstreams mit 63 statt 64 Zeichen veröffentlicht; die letzte
  `9` ging beim Abschreiben verloren. Toby's KI hat es bemerkt.

**Regel:** Jede Zahl, die in eine Commit-Nachricht, ein GitHub-Kommentar oder
einen Bericht geht, wird **programmatisch** erzeugt und direkt aus der
Variablen eingesetzt. Kein Abtippen, kein Nacherzählen aus dem Gedächtnis.
Bei Hashes zusätzlich die Länge prüfen (SHA256 = 64 Zeichen).

## 2. Erst prüfen, ob der Build den richtigen Stand gebaut hat

**Passiert:** Ein Experiment wurde im Arbeitsbaum geändert, aber nicht
committet; der Worktree baute den alten Stand. Die Zahlen waren exakt
identisch mit vorher, und das wurde als Ergebnis gewertet.

**Regel:** Vor jedem Build prüfen, dass der Worktree den erwarteten Commit
enthält (`git rev-parse HEAD` gegen den erwarteten Hash). Nach dem Build den
**Zeitstempel** des Reports kontrollieren, bevor Zahlen gelesen werden.

## 3. Nicht gemessene Kennzahlen nicht deuten

**Passiert:** `pending_peaks` wurde als Füllstand der Filter-Warteschlange
interpretiert („31 von 32, Reserve aufgebraucht"). Tatsächlich zählte die
Variable `scan_start`, den Rundlauf-Zeiger. Die echte Belegung war 2 von 32.

**Regel:** Vor jeder Aussage über eine Kennzahl die Stelle im Code suchen,
an der sie entsteht, und lesen, **was** sie zählt. Erst dann interpretieren.

## 4. Fläche: Synthese-Schätzung, nicht Post-Fit

**Passiert:** Das Zusammenlegen der Filterbänke wurde als „kostet 331 ALMs"
bezeichnet. Die Synthese sagte −129; die +331 waren Packungsrauschen des
Fitters.

**Regel:** Für Flächenvergleiche die Synthese-Schätzung („ALMs needed")
verwenden. Post-Fit-ALMs taugen für Timing und für die Frage „passt es in den
Baustein", nicht für Änderungsvergleiche.

## 5. Messen, bevor ein Fix empfohlen wird

**Passiert:** Pipelining im Filter wurde als Timing-Lösung vorgeschlagen,
bevor der kritische Pfad gemessen war. Die Messung zeigte 17,9 ns Reserve im
Filter — der Verletzer lag in Paulas Floppy-DMA.

**Regel:** Erst den kritischen Pfad messen, dann die Stelle ändern. Eine
Empfehlung ohne Messung ist eine Vermutung und gehört als solche benannt.

## 6. Nach jeder mehrteiligen Änderung sofort übersetzen

**Passiert:** Mehrere Ersetzungen per Skript hinterließen zweimal einen
nicht kompilierbaren Stand; einmal landete eingefügter Code außerhalb des
`<script>`-Tags.

**Regel:** Nach jeder Änderung sofort kompilieren oder simulieren. Den
Arbeitsbaum nie in einem Zustand liegen lassen, der nicht baut.

## 7. Was committet ist, ist noch nicht veröffentlicht

**Passiert:** Der Teststand lag lokal, war aber nicht gepusht. Toby's KI
konnte ihn nicht sehen und musste nachfragen.

**Regel:** Sobald eine andere Partei etwas sehen soll: pushen und die
Sichtbarkeit prüfen (`git ls-remote`), nicht nur committen.

## 8. „Nicht verifiziert" sagen, wenn es nicht verifiziert ist

**Passiert:**
- Audio-Reservewerte (11,4 ns) wurden vom filterlosen Build auf den
  Filterbuild übertragen.
- Ein gescheiterter Fitter wurde als „RAM-Inferenz verloren" gedeutet; die
  Null in der Zusammenfassung war bedeutungslos, weil der Lauf abgebrochen war.

**Regel:** Ergebnisse gelten nur für den Stand, an dem sie gemessen wurden.
Bei abgebrochenen Läufen ist die Zusammenfassung wertlos, nicht alarmierend.

## 9. Vorzeichen und Konsequenzen abwägen

**Passiert:** Bei der Seed-Auswahl wurde nur der Setup-Slack betrachtet.
Mehrere Seeds mit gutem Setup haben negativen Hold — und Haltezeit-
verletzungen sind die gefährlicheren, weil sie auch bei kalten Temperaturen
und niedriger Spannung auftreten.

**Regel:** Bei Timing immer Setup **und** Hold berichten, und Hold nie
zugunsten eines besseren Setups opfern.

## 10. Zurücknehmen statt durchwinken

**Passiert:** Nach einem halbfertigen Umbau war der Baum nicht
kompilierbar. Statt weiterzubasteln wurde zurückgesetzt und der Stand
sauber dokumentiert. Das war richtig.

**Regel:** Wenn eine Änderung nicht in einem Zug fertig wird, zurücknehmen
und den Zwischenstand beschreiben — nicht einen halben Zustand hinterlassen.

## 11. 16-Bit-Audiosamples auf dem Amiga immer in Big-Endian (`>i2`) erzeugen

**Passiert:** Beim ersten Hardwaretest für AM & Ringmodulation (`am_ringmod_test`)
wurden die 16-Bit-Sinus-Tabellen auf dem x86-PC im nativen Little-Endian-Format
(`<i2`) geschrieben. Die 68000-/Minimig-Hardware las das sich schnell ändernde
Low-Byte als High-Byte (Bits 15..8), wodurch aus dem sanften 4-Hz-Tremolo ein
schneidendes 48-kHz-Sägezahngeräusch („Kreissäge“) wurde.

**Regel:** Jedes Generator-Skript für 16-Bit-PCM-Daten muss explizit Motorola
Big-Endian (`struct.pack('>h', ...)` bzw. `dtype='>i2'`) schreiben und vor dem
Bau die Endianness verifizieren.

## 12. AmigaOS-Bibliotheksaufrufe (`_LVO`) verlangen die Library-Base zwingend in `A6`

**Passiert:** In `showcase_32ch.s` wurde zu Beginn `LEA CUSTOM, A6` (`$DFF000`)
gesetzt und anschließend `ExecBase` (`$4.W`) bzw. `DOSBase` versehentlich nach
`A0` geladen (`JSR _LVOOpenLibrary(A0)` / `JSR _LVOOutput(A0)`). Da AmigaOS-
Routinen intern `A6` als Library-Base dereferenzieren, las `OpenLibrary` aus
`$DFF000` ungerade Werte und stürzte sofort mit Guru Meditation `#00000003`
(68000 Address Error) ab.

**Regel:** Vor jedem `JSR _LVO...` muss die zugehörige Library-Base (`SysBase`,
`DOSBase`, `GfxBase`, `IntuitionBase`) in **`A6`** geladen sein, und der Aufruf
muss `JSR _LVO...(A6)` lauten.

## 13. Bei 68000 Byte-Zugriffen (`MOVE.B`) vor Wort-Indizierung das High-Byte löschen

**Passiert:** `MOVE.B LFO_Phase, D0` gefolgt von `MOVE.B (A1, D0.W), D0` ließ
Bits 15..8 von `D0` unverändert (darin stand noch der `VPOSR`-Restwert aus
`Wait_VBL`), sodass Hunderte Bytes außerhalb von `LfoTab` gelesen wurden.

**Regel:** Vor jedem `MOVE.B ..., Dn`, das anschließend als 16-Bit-Index
`(An, Dn.W)` oder für `MULU.W` genutzt wird, zwingend `MOVEQ #0, Dn` (oder
`CLR.W Dn`) ausführen.

## 14. Register-Offsets und Zeitbasis immer gegen das echte Verilog (`audio_ext.v`) prüfen

**Passiert:** In einer älteren Doku-Skizze waren `+$08` (`AUDxVOL`) und `+$0A`
(`AUDxPER`) vertauscht; außerdem wurde teils der PAL-Farbtakt (3,54 MHz) statt
der echten 25-MHz-TDM-Zeitbasis (`PER = 521` für 48 kHz) und Words statt Bytes
für `AUDxLEN` angenommen.

**Regel:** Maßgeblich für Register-Offsets, Bitmasken (`AUDxCTRL`), Teiler
($f_s = 25\,\text{MHz} / \text{PER}$) und Längen (`AUDxLEN` in Bytes) ist
allein das synthetisierte RTL in `mister/rtl/audio_ext.v` und `mister/rtl/minimig.v`.

## 15. Kaskadierte Vorstufen mit `CTRL_MUTE_MIX` ($2000) stummschalten und Folgestufen mit `LEN = 0` betreiben

**Passiert:** Ohne `CTRL_MUTE_MIX` (`$2000`) auf der Vorstufe einer 24-dB-Moog-
Kaskade wird das 12-dB-Zwischensignal im Master-Mix zum 24-dB-Endsignal addiert.

**Regel:** Jede reine Filter-Vorstufe oder Modulator-Stimme (AM/Ringmod-Träger)
erhält `CTRL_MUTE_MIX` (`$2000`). Kaskadierte Folgestufen (`CTRL_SRC_PRE` =
`$0200` oder `CTRL_SRC_POST` = `$0400`) erhalten `AUDxLEN = 0`, damit sie sofort
in `PLAYING` wechseln und 0 % DMA-Bandbreite verbrauchen.
