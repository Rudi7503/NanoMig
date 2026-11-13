# Hardware-Ergebnisse

Jeder Eintrag ist ein tatsächlich durchgeführter Lauf auf einem Gerät. Keine
Simulation, keine Erwartung. Wer etwas testet, trägt es hier ein — mit Datum,
Commit, Bitstream-Hash und dem, was auf dem Bildschirm zu sehen war.

## 2026-11-13 — Tang Console 138K, Start **ohne** Sprite-Anbindung

**Ergebnis: startet. Kickstart-Hand (v1.3) auf HDMI.**

| | |
|---|---|
| Gerät | Tang Console 138K, GW5AST-138C |
| Commit | `a088768` mit `` `define SPR_MEM_DISABLE `` |
| Bitstream | `nanomig_tc138k.fs` = `nanomig_tc138k_nospr.fs`, 38.603.947 Bytes |
| SHA256 | `548c7d729f4fa06f4eb4ef33e1a5721c2be26d44ef49572e115ece8a50ecd795` |
| Flash | `--cable "Gowin USB Cable(FT2CH)" -r 53 --spiaddr 0x000000`, 82,02 s |
| Bild | Amiga-Hand, Kickstart v1.3 |

### Was dieser Lauf beweist

Der Core mit AGA-, 68020- und Cache-Konfiguration startet auf der Konsole.
Die Speicherports in `src/minimig-aga/minimig.v` sind richtig verdrahtet.

### Was er NICHT beweist — und was zuerst behauptet wurde

Dieser Bitstream entstand mit `` `define SPR_MEM_DISABLE ``: **Arbiter und
Adapter waren nicht im Design.** Die Engine hing an Festwerten, der Prozessor
am SDRAM wie zuvor.

Zuerst stand hier geschrieben, der Lauf beweise die Teilung des
Speicheranschlusses. **Das war falsch.** Ursache: der Testbuild um 13:35
überschreibt `nanomig_tc138k.fs`, und die Kopie `nanomig_tc138k_nospr.fs`
entstand erst danach — beide Dateien waren byteweise identisch
(`548c7d72…d795`). Geflasht wurde also die Variante ohne Anbindung.

Rudi hat den Widerspruch bemerkt, nicht das Protokoll.

**Konsequenz für den Build:** Varianten bekommen getrennte Dateinamen,
bevor gebaut wird. Ein Build überschreibt immer `nanomig_tc138k.fs`.


## Frühere Läufe

| Datum | Stand | Ergebnis |
|---|---|---|
| 2026-11-13 | unser Core, Stand vor `7fc2fad` | LED dauerhaft grün, Bild schwarz, kein OSD — Ursache waren die fehlenden Speicherports in `minimig.v` |
| 2026-11-13 | NanoMig v0.9 (offiziell) | läuft, Diskettenhand auf HDMI |

## 2026-11-13 — Vier Bitstreams gegen das schwarze Bild

Alle Läufe auf der Tang Console 138K, jedes Mal geflasht und neu gestartet.
Ausgangspunkt war jeweils derselbe Commit-Stand, nur der `ifdef`-Zweig
unterschied sich.

| Build | Engine | Speicherpfad | Logic | Bild |
|---|---|---|---|---|
| `nospr` (13:53) | drin, Videopfad aktiv | Ports auf 0 | 22.621 | **Amiga-Hand v1.3** |
| `spr` (14:2x) | drin | Arbiter, Ack als Impuls | 25.556 | schwarz |
| `spr2` (14:46) | drin | Arbiter, Ack als Toggle | 25.565 | schwarz |
| `spr3` (15:12) | drin | Arbiter, Ack unregistriert | 25.563 | schwarz |
| `bypass` (15:49) | **entfernt** | Ports auf 0 | 22.172 | schwarz |

### Was daraus folgt

1. **Der Videopfad der Engine ist unschuldig.** Beim funktionierenden Stand war
   die Engine aktiv und ersetzte das Denise-Bild.
2. **Jede Form des Arbiters führt zu schwarz** — unabhängig davon, ob das Ack
   als Impuls, als Toggle oder unregistriert durchgereicht wird.
3. **Der Bypass-Test ist unbrauchbar.** Mit entfernter Engine bleibt das Bild
   ebenfalls schwarz, obwohl dieselbe Speicheranbindung wie beim laufenden
   Stand verwendet wurde. Der Bypass-Zweig in `minimig.v` hat also einen
   eigenen Fehler. Aus ihm lässt sich nichts über den Arbiter schließen.

### Was das nicht erklärt

Zwischen `nospr` (läuft) und `bypass` (schwarz) gibt es keinen
Speicherunterschied. Trotzdem verhalten sie sich gegensätzlich. Das ist offen
und spricht dafür, dass in `minimig.v` mehr geändert wurde als nur die
Speicherports — oder dass das Define an der falschen Stelle stand. Der erste
Bypass-Build um 15:42 war wirkungslos, weil das Define in `top.sv` stand und
das `ifdef` in `minimig.v`; Verilog-Defines gelten je Datei.

### Offen

Toby's Befund vom 13:41 ist noch nicht umgesetzt: bei `beat == 3` direkt nach
`IDLE`, Vergabe in `OWNER_NONE` mit `b_cs && !b_ack` qualifizieren, und die
doppelte Vergabe verhindern, solange das Ack unterwegs ist.

## 2026-11-14, 00:xx — Kickstart 3.1 bootet nicht

| Build | Konfiguration | ROM an 0x600000 | Bild |
|---|---|---|---|
| `nospr` (13:35) | AGA, 68020, 2 MB Chip, **kein** Fast-RAM | 1.3 | **Hand** |
| derselbe | dito | 3.1 | schwarz |
| `a1200` (00:37) | AGA, 68020, 2 MB Chip, **4 MB Fast-RAM** | 3.1 | schwarz |

Bitstream, Offset und ROM-Übertragung sind belegt: mit 1.3 an derselben Stelle
kommt ein Bild. `ENABLE_AGA` ist definiert, `sysctrl` bekommt `.AGA(1)`, die
Defaults sind 68020/AGA/2 MB/Kickstart 3.1.

**Fehler in der bisherigen Deutung:** Ich hatte behauptet, `AGA = 0` sei
aktiv. Das war falsch — der Parameter-Vorgabewert in `sysctrl.v` wird durch
die Instanziierung überschrieben.

**Fehler im Versuchsaufbau:** Beim Wechsel auf 3.1 wurde gleichzeitig
Fast-RAM von 0 auf 4 MB geändert. Zwei Variablen auf einmal.

**Nächster Schritt:** 4 MB Fast-RAM mit Kickstart **1.3** flashen. Bootet das,
ist der Speicher unschuldig und nur 3.1 das Problem. Bootet es nicht, war das
Fast-RAM die Ursache.