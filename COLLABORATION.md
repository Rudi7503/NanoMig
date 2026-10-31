# Zusammenarbeit NanoMig — Rudi7503 ↔ toby01019

Stand 2026-10-31. Diese Datei regelt den technischen Austausch zwischen beiden
Seiten. Sie ersetzt keine Fakten: was gilt, steht im Code und in den Belegen.

## Rollen

| Seite | Beitrag |
|---|---|
| **Rudi (Rudi7503)** | Core-Entwicklung, RTL, Constraints, Build, Freigabe von Releases |
| **Toby (toby01019)** | Hardware-Tests auf dem MiSTer, Testprogramme, Hörtests, Befundpackages |

Die KI-Assistenten beider Seiten arbeiten im Auftrag. Sie dürfen Vorschläge
machen und Befunde erheben, aber nichts als geprüft bezeichnen, was nicht
belegt ist (siehe *Belegpflicht*).

## Kennzeichnung von KI-Beiträgen

KIs schreiben technisch unter dem GitHub-Konto ihres Menschen. Damit niemand
einen KI-Beitrag für eine persönliche Aussage hält, kennzeichnet sich jeder
KI-Beitrag in der **ersten Zeile**:

| Seite | erste Zeile |
|---|---|
| Rudis KI | `Ich bin Rudis KI:` |
| Tobys KI | `Ich bin Tobys KI:` |

Danach eine Leerzeile, dann der Inhalt. Das gilt für Kommentare in PRs und
Issues; Commit-Nachrichten und Code bleiben unmarkiert.

Die Kennzeichnung ändert nichts an der Verbindlichkeit: was eine KI schreibt,
ist ein Vorschlag oder ein Befund, keine Freigabe. Freigaben bleiben bei den
Menschen.

## Ein einziges Integrationsziel

`Rudi7503/NanoMig`, Branch **`main`**. Dort wird gemeinsam gearbeitet.

* `main` ist Integration **und** Upstream-Ableger: 20 Upstream-Commits vom
  2026-10-30 plus die 15 Audio-Commits, zusammengeführt als Merge `aacf921`.
* Bewusst **gemergt, nicht rebased**: die Commit-Hashes `d90e0fb`, `0b86a3e`
  und `3fba796` bleiben gültig. Tobys Befundpackages verweisen darauf.
* `feature/16ch-audio-biquad-pipeline` ist **eingefroren**, nur noch Referenz.
  Nicht weiter darauf arbeiten und nicht löschen, solange eine RBF im Umlauf ist,
  die darauf gebaut wurde.
* Upstream (`MiSTle-Dev/NanoMig`) läuft weiter. Aktualisierung nur als bewusster
  Merge `origin/main` → `main`, nie als Rebase und nie während ein Hardware-Test
  gegen einen bestimmten Stand läuft.

### Warum der Wechsel unkritisch war

Die 20 Upstream-Commits berühren ausschließlich `NETWORKING.md`,
`nanomig-uart-fifo.patch`, `src/misc/amiga.xml`, `src/misc/uart_port.v` und
`src/scripts/build.tcl` — nichts davon liegt im MiSTer-Baum `mister/`.
Der einzige gemeinsam geänderte Pfad war `src/misc/amiga.xml`, dort aber
verschiedene Stellen; der Merge lief konfliktfrei durch.

## Umfang

Aktuell bearbeitet werden **zwei Stränge**:

1. **Audio-Erweiterung** (16/32 Stimmen, Capture, Filter) — aktiv.
2. **HAM-Video** (hohe Auflösungen) — aktiv, eigene Prüfliste.

**Tang/Gowin liegt auf Eis.** Rudi hat frühestens Mitte November ein Board,
Toby hat keins. Es gibt weder eine Portierung noch einen Build noch einen Test;
der Umgang damit ist eine eigene Aufgabe für später. Keine Zusage, dass die
Audio- oder HAM-Arbeit ohne Anpassung auf Tang läuft.

## Vor Arbeitsbeginn

Wer anfängt, etwas zu ändern oder zu messen, sagt es vorher — eine Zeile reicht:

- **was** (Thema, betroffene Dateien)
- **wo** (Branch-Name)
- **wie lange** ungefähr

Und beim Abschluss: was rausgekommen ist, mit Belegen. Das verhindert, dass zwei
Seiten dieselbe Stelle gleichzeitig anfassen — bisher der einzige echte
Kollisionsfall (der Capture-Fix und Tobys Testbuild liefen parallel).

Der **PR-Thread ist der Ort für alles, was diesen PR betrifft**. Für ein neues
Thema gehört ein eigenes Issue her — ein HAM-Befund im Audio-PR geht verloren.

Themen-Issues (Stand 2026-10-31):

| Issue | Thema |
|---|---|
| #2 | Audio: funktionale Hardwareabdeckung der 32-Kanal-Engine |
| #3 | HAM-Video: Stand, Builds und offene Hardwareprüfungen |
| #4 | Timing: negativer Slack im Capture-Build |
| #5 | Spezifikation: `AUDxLEN` und Audio-Registerbasis |

## Branches und Pull Requests

* `rudi/<thema>` — Core, RTL, Doku
* `toby/<thema>` — Testprogramme, Hardware-Befunde, Belege
* `main` ist gemeinsamer Arbeitsbranch: **direktes Pushen ist erlaubt.**
  Gesperrt ist nur der Force-Push, per Ruleset `no-force-push` — für beide Seiten
  und ohne Bypass. Grund: Commits werden in Befundpackages per Hash zitiert, und
  jede RBF hängt an einem Quellstand; ein Force-Push macht beides unauffindbar.
* Für RTL-Änderungen und alles, was eine RBF beeinflusst, ist ein PR der
  vereinbarte Weg — nicht als Kontrolle, sondern weil der PR der Ort ist, an dem
  „geprüft / nicht geprüft" dokumentiert wird. Doku-Korrekturen und Kleinkram
  dürfen direkt gepusht werden.
* Jeder rebased nur seinen eigenen Themenbranch.
* **Ein PR = ein Thema.** RTL-Fix, Doku-Korrektur und Pfadanpassungen nicht mischen.
* Der PR nennt den Basis-Commit, auf dem er aufsetzt.

## Wer ändert was (ohne Rückfrage)

| Bereich | Owner | Dateien |
|---|---|---|
| Audio-RTL | Rudi | `mister/rtl/audio_ext/*`, `mister/rtl/audio_ext.v` |
| Capture-RTL | Rudi | `mister/rtl/audio_capture.v`, `mister/rtl/audio_ext/audio_capture.v` |
| SySTEM/Build | Rudi | `mister/sys/*`, `mister/Minimig.qsf`, `mister/files.qip` |
| Testprogramme | Toby | `mister/tests/*` |
| Hardware-Belege | Toby | `mister/verify/<datum>-<thema>/` |
| Doku | beide, PR-pflichtig | `README.md`, `GITHUB_AI_HANDOVER.md`, `COLLABORATION.md` |

Alles andere: vorher im PR-Thread abstimmen.

## Belegpflicht — Definition of Done

Jeder PR beantwortet vier Fragen, sonst wird er nicht gemergt:

1. **Was ist geändert** und auf welchem Basis-Commit?
2. **Was ist geprüft** — und womit (Simulationslog, Synthese, Timing, Hardware)?
3. **Was ist ausdrücklich nicht geprüft?** „Nicht geprüft" ist ein gültiges
   Ergebnis und muss dastehen; es wird nicht weggelassen.
4. **Was kostet es** — Ressourcen, Timing, Verhalten im Wiedergabepfad?

Belege sind Dateien im PR (Log, Rohdaten, Hash), keine Prosa. Ein
Synthese-Erfolg ist kein Timing-Pass. Eine Hörprobe ist kein Sample-Beweis.

## Umgang mit gelieferten Patches

* Patches werden gegen den genannten Basis-Commit geprüft, nicht gegen den
  eigenen Arbeitsstand.
* Pfad- und Umgebungskorrekturen gehören nicht in den Patch, sondern in die
  Bauanleitung; sonst ist der Patch nicht reproduzierbar.
* Weicht ein gelieferter Kandidat von der gemergten Datei ab, wird die
  Abweichung benannt — auch wenn sie nur Kommentare betrifft.
* Byte-Identität zwischen getestetem Kandidaten und gemergter Datei ist das Ziel.

## Offene Entscheidungen

| Thema | Stand | Klärung durch |
|---|---|---|
| DMA-Länge: `AUDxLEN` in Worten oder Bytes? | Doku sagt Worte, der 16CH-Test rechnet mit 256 Bytes | Rudi bestätigt gegen RTL-Zähler |
| Audio-Registerbasis: `$DFF400` oder `$DFF800`? | Handover sagt `$DFF400`, `mister/README.md` sagt `$DFF800` | Rudi, dann Doku-Fix |
| Doppelte RTL-Kopien (`rtl/x.v` und `rtl/x/x.v`) | identisch, nur `rtl/audio_ext/...` wird gebaut | Rudi, Aufräum-PR |
| Timing `feature`-Branch: −1,819 ns | offen, unverändert | Rudi |
| Upstream-Abgleich | erledigt am 2026-10-31 (Merge `aacf921`), ab jetzt periodisch | beide |
| Capture-Stereo-Fix | liegt als `rudi/capture-stereo-coherence` (`225e8d5`) bereit | Rudi → PR |

## Wo welche Dateien liegen

Nicht alles gehört ins Repo. Git behält jede Version für immer — eine 4-MB-RBF
pro Iteration bläht die Historie dauerhaft auf und lässt sich nicht mehr
rückgängig machen.

| Inhalt | Ort |
|---|---|
| Code, Doku, Skripte, Logs, JSON-Belege | **Repo** |
| WAV-Aufnahmen, Hörproben, große Rohdaten | **Discord** |
| Build-Artefakte (RBF), ZIP-Pakete | **Discord**, bei Bedarf zusätzlich GitHub Releases |

Pflicht bei jeder geteilten Datei: **SHA256** und der Quellcommit, aus dem sie
gebaut wurde. Im Repo steht dann der Hash plus ein kurzer Auszug — nicht die
Datei. So bleibt ein Befund zuordenbar, ohne dass der Git-Baum wächst.

Auf Discord verteilte Dateien sind Arbeitsmaterial, kein Projektstand. Wer
später nachvollziehen will, was geprüft wurde, liest die Belege im Repo.

## Technische Randbedingungen

* Quartus Prime Lite 25.1std, Gerät `5CSEBA6U23I7`, Projekt `Minimig`, Top `sys_top`.
* Simulation: Icarus Verilog `-g2012`. Toolpfade gehören in eine Umgebungsvariable,
  nicht fest in ein Skript.
* Rohdaten aus der Capture-Einheit: **Big-Endian** int16, stereo verschränkt.
  Wer das anders liest, bekommt Plausibles, aber Falsches.
* Jede RBF wird mit SHA256 und dem exakten Quellstand ausgeliefert.
