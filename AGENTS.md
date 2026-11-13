# Regeln für Mitarbeit in diesem Repository

Diese Datei gilt für Menschen **und** für KI-Assistenten. Sie ist bewusst kurz
und enthält nur Regeln, deren Verletzung schon einmal Schaden angerichtet hat.

## 1. Jedes Skript wird dokumentiert — ohne Ausnahme

Wer ein Skript anlegt, ändert, ersetzt oder entfernt, trägt es **im selben
Commit** in `docs/SCRIPTS.md` ein. Der Eintrag nennt:

- **was** das Skript tut,
- **wozu** es gut ist,
- **ob** es durch etwas Neueres ersetzt wurde,
- **ob** es gelöscht werden kann.

Ein Skript ohne Eintrag gilt als undokumentiert. Seine Ausgaben dürfen nicht
als Beleg angeführt werden. Wird ein Skript ersetzt, bleibt der alte Eintrag
stehen und wird auf `überholt` oder `löschbar` gesetzt — gelöscht wird die
Zeile erst, wenn die Datei wirklich weg ist.

Grund: Am 2026-11-13 gab es rund 55 Skripte im Repo und **keine** Übersicht.
Das Prüfskript für Tobys Rückmeldungen existierte, war aber nicht dokumentiert
und beobachtete nur zwei von vier Kanälen.

## 2. Zahlen niemals abschreiben

Jede Zahl, die in eine Commit-Nachricht, ein GitHub-Kommentar oder einen
Bericht geht, wird programmatisch erzeugt. Kein Abtippen. Bei Hashes zusätzlich
die Länge prüfen (SHA256 = 64 Zeichen).

## 3. Erst messen, dann behaupten

Vor jeder Aussage über eine Kennzahl die Stelle im Code suchen, an der sie
entsteht, und lesen, **was** sie zählt. Vor jeder Empfehlung den kritischen
Pfad messen.

## 4. Vor dem Build prüfen, was gebaut wird

`git rev-parse HEAD` gegen den erwarteten Commit. Nach dem Build den
Zeitstempel des Reports kontrollieren, bevor Zahlen gelesen werden.

Arbeit in einem eigenen Worktree; `git worktree add` nimmt den committeten
Stand, nicht den Arbeitsbaum.

## 5. „Nicht verifiziert" sagen, wenn es nicht verifiziert ist

Ergebnisse gelten nur für den Stand, an dem sie gemessen wurden. Ein
abgebrochener Fitter hinterlässt Nullen in der Zusammenfassung — die sind
wertlos, nicht alarmierend.

## 6. Nach jeder mehrteiligen Änderung sofort übersetzen

Den Arbeitsbaum nie in einem Zustand liegen lassen, der nicht baut.

## 7. Was andere sehen sollen, wird gepusht

Committen genügt nicht. Sichtbarkeit mit `git ls-remote` prüfen.

## 8. Encoding ist eine Fehlerquelle

Dateien mit Umlauten sind UTF-8. PowerShell 5.1 liest sie standardmäßig als
Windows-1252 und macht aus `ö` zwei Zeichen. Das hat am 2026-11-13 ein
korrektes Passwort als falsch erscheinen lassen. Beim Lesen von Konfiguration
und beim Schreiben von JSON immer explizit UTF-8 verwenden.

## 9. Zusammenarbeit mit Tobys KI

Siehe `COLLABORATION.md`. Kurz: Jede Nachricht beginnt mit `Ich bin Rudis KI:`
und einer Leerzeile. Tobys KI begleitet Tests und prüft; Entwicklung und
Builds liegen bei uns. Nachrichten kurz halten, keine Beweispakete.

## 10. Was sonst noch gilt

- `docs/LESSONS.md` — die konkreten Fehler und was sie verhindert hätte.
- `docs/HANDOVER.md` — Stand, Werkzeuge, offene Aufgaben.
- `docs/SCRIPTS.md` — die Skriptübersicht aus Regel 1.
