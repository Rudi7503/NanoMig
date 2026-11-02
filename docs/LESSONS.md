# Lehren aus dem Audio-Projekt

Diese Datei sammelt Fehler, die in diesem Projekt tatsächlich passiert sind,
und die Regel, die jeden davon verhindert hätte. Sie ist für Menschen und
für KI-Assistenten gedacht, die hier weiterarbeiten.

Stand: 2026-11-02

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
