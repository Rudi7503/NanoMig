# Übergabe — Tang Console 138K

Stand: 2026-11-14, 01:00. Für die nächste Sitzung geschrieben, damit nichts
neu erraten werden muss.

**Wer das liest:** Diese Datei ersetzt kein Wissen, sie erspart Wiederholung.
Was hier als „belegt" steht, ist auf dem Gerät gemessen. Was als „Verdacht"
steht, ist nicht gemessen.

---

## 1. Worum es geht

NanoMig (Minimig-AGA) soll auf einer **Tang Console 138K** (GW5AST-138C)
laufen. Darauf aufbauend eine eigene **Sprite-Engine**, die zusätzlich zu
Denise 32/64-Bit-Sprites darstellen kann.

Der MiSTer-Zweig (`mister/`) ist davon getrennt; die Tang-Konsole nutzt
`src/minimig-aga/`, `src/nanomig.v` und `src/tang/console138k/`.

## 2. Was heute belegt wurde

| Befund | Wie belegt |
|---|---|
| Core mit AGA/68020/Cache **bootet** auf der Konsole | Kickstart-Hand auf HDMI, Bitstream `nospr` |
| Sprite-Engine im **Videopfad** ist unschuldig | `nospr` bootet mit aktiver Engine |
| **Arbiter im CPU-Speicherpfad → schwarzes Bild** | gleicher Commit, nur `ifdef`-Zweig unterschiedlich |
| Engine fordert bei `SPR_LIST_PTR = 0` **nichts** an | `tb_dma_idle_read.v`: 0 Impulse über 10 Bildwechsel |
| Kickstart **3.1** bootet (noch) nicht | 1.3 an derselben Stelle bootet, 3.1 nicht |
| Block-RAM-Testmuster wird korrekt gelesen | `tb_spr_test_pattern.v`: 64×32, RGB16, 8 Wortbursts |

## 3. Der Kern des Problems

Sobald der Arbiter zwischen Prozessor und SDRAM-Anschluss `p2` liegt, bleibt
das Bild schwarz — **obwohl die Engine nachweislich nichts anfordert**.

Drei Erklärungsversuche wurden gebaut und **widerlegt**:

1. Ack als Toggle statt Impuls → schwarz
2. CPU-Pfad registerlos durchgereicht → schwarz
3. Ack unregistriert (`a_ack = b_active ? a_ack_hold : p2_ack`) → schwarz

Timing ist **nicht** offensichtlich schuld: keine `spr_`-Netze in den
Timingberichten, TNS je Takt 0.000. Es gibt allerdings 829 unbestimmte
Endpunkte — ob der CPU-Pfad darunter ist, ist **ungeklärt** (Toby's Einwand).

Toby's Verdacht: In der Flanke, in der der Adapter das Ack erst später sieht,
vergibt der Arbiter den noch gehaltenen Auftrag **erneut** (Doppelzugriff).

## 4. Was als Nächstes zu tun ist — in dieser Reihenfolge

### Schritt 1: Fast-RAM isolieren (billig, ein Flash)

```powershell
python mister\tools\auto_flash_tang.py --fs src\impl\pnr\nanomig_tc138k_a1200.fs --kick src\kick13.bin
```

Der `a1200`-Bitstream hat **4 MB Fast-RAM** (`sysctrl.v`: `system_fastmem <= 2'd2`).
Mit **Kickstart 1.3** geflasht muss er booten, wenn das Fast-RAM in Ordnung ist.
- Bootet → Fast-RAM ist unschuldig, nur 3.1 ist das Problem.
- Bootet nicht → das Fast-RAM ist die Ursache.

**Wichtig:** Das ROM muss **vor** dem Bitstream ins Flash, oder in einem
eigenen JTAG-Fenster. Nach dem Bitstream-Flash ist JTAG zu.

### Schritt 2: Toby's LED-Diagnose

Gefragt am 13.11. um 00:45 in PR #11 (`issuecomment-6867787614`). Vorschlag:
drei LED-Kanäle für `rom_done`, ein CPU-Adressbit, Reset-Zustand oder
Denise-Ausgabe. Antwort abwarten, dann einbauen.

### Schritt 3: Block-RAM-Muster einbinden

`spr_test_pattern.v` ist **fertig und simuliert grün**. Es fehlt nur die
Einbindung in `top.sv`:

1. `sdram`-Instanz: `p2_*` zurück auf `fastram_*`
2. Arbiter und Adapter in `ifdef USE_SPR_ARB` legen (nicht definieren)
3. `spr_test_pattern` an `spr_mem_*` anschließen
4. `` `define SPR_BRAM_TEST `` setzen (schon in `sprite_engine_dma.v` vorbereitet)

Dann: CPU direkt am SDRAM, Sprites aus Block-RAM. Das ist Toby's Vorschlag
vom 13.11.: „Boot und Sprite-Anzeige auf dem Board gemeinsam prüfen."

**Die Einbindung zweimal per PowerShell-Skript versucht und zweimal die
Datei beschädigt.** Bitte mit dem Editor machen und nach jeder Änderung
`git diff` lesen.

### Schritt 4: Erst danach echtes SDRAM-Sharing

Toby's Entwurf: gepufferte Sprite-Anforderung am Controller, nur bei regulärer
Vergabe und freiem Slot nach CPU/Refresh annehmen, Besitzer bis zum letzten
Datenwort merken, getrennt an die Engine antworten, CPU-Ack-Pfad zeitlich
erhalten.

---

## 5. Flashen — die einzige Prozedur, die funktioniert

```powershell
# Bitstream (dauert ~80 s)
python mister\tools\auto_flash_tang.py --fs <datei.fs> --timeout 300

# Bitstream + Kickstart
python mister\tools\auto_flash_tang.py --fs <datei.fs> --kick src\kick13.bin
```

**Das JTAG-Fenster ist nur kurz offen.** Deshalb pollt das Skript alle 0,7 s
und schießt beim ersten Treffer los. Von Hand nach Zuruf schlägt fehl.

**Kabelname ist Pflicht:**

```
--cable "Gowin USB Cable(FT2CH)"
```

`--cable-index 4` meldet zwar „USB Debugger A", erreicht den Flash aber nicht
(`exit 50` in 0,0 s). Das hat Stunden gekostet.

**Tastensequenz:** Strom ab → Mode-Taste halten → USB-C anstecken → loslassen.

**Töne:** hoher Piep = JTAG erwischt, drei Pieps = fertig, tiefer Ton = Fehler.

## 6. Bitstreams im Ordner `src/impl/pnr/`

| Datei | Bytes | SHA256 (Anfang) | Bedeutung |
|---|---|---|---|
| `nanomig_tc138k_nospr.fs` | 38.603.947 | `548c7d72` | **bootet** mit 1.3, kein Arbiter |
| `nanomig_tc138k_spr.fs` | 39.113.899 | `f4aa2684` | Arbiter, Ack als Impuls — schwarz |
| `nanomig_tc138k_spr2.fs` | 39.346.773 | `0133f58e` | Arbiter, Ack als Toggle — schwarz |
| `nanomig_tc138k_spr3.fs` | 39.751.339 | `30c6b50b` | Arbiter, Ack unregistriert — schwarz |
| `nanomig_tc138k_bypass.fs` | 38.116.097 | `75ae8390` | Engine entfernt — schwarz |
| `nanomig_tc138k_ctrl.fs` | 38.603.947 | `9947bef2` | Kontrolle, Arbiter wegoptimiert |
| `nanomig_tc138k_seen.fs` | 38.858.923 | `74654e07` | Arbiter + Merkbit, LED-Diagnose |
| `nanomig_tc138k_a1200.fs` | 39.241.387 | `e4959ac3` | AGA + 4 MB Fast-RAM |

**Jeder Build überschreibt `nanomig_tc138k.fs`.** Varianten vorher umbenennen,
sonst flashst du den falschen Stand — das ist zweimal passiert.

## 7. Bauen

```powershell
C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe src\build_tc138k.tcl
```

Dauer ~8 Minuten. Danach **immer die Logic-Zahl prüfen**:

```
src/impl/pnr/nanomig_tc138k.rpt.txt
```

Erwartete Werte: 22.6xx = Engine ohne Arbiter, 25.5xx = Engine mit Arbiter.
Stimmt die Zahl nicht, ist der `ifdef`-Zweig nicht aktiv — das passiert leicht,
weil **Verilog-Defines je Datei gelten** (ein `` `define `` in `top.sv` wirkt
nicht in `minimig.v`).

## 8. Fehler, die diese Sitzung gekostet haben

1. **`--cable-index` statt Kabelname** → stundenlange „exit 50"-Suche.
2. **Define in der falschen Datei** → zwei wirkungslose Builds.
3. **Build überschreibt immer denselben Dateinamen** → falscher Bitstream geflasht.
4. **`syn_noprune` schützt nicht vor Konstantenfaltung** → Arbiter wegoptimiert.
5. **Zwei Variablen gleichzeitig geändert** (ROM + Fast-RAM) → Aussage wertlos.
6. **Behauptet, `AGA = 0` sei aktiv** → falsch, die Instanziierung überschreibt es.
7. **PowerShell-String-Ersetzung auf 1245-Zeilen-RTL** → zweimal Datei zerstört.

Regel daraus: **nach jeder RTL-Änderung `git diff` lesen, vor dem Flash die
Logic-Zahl prüfen.**

## 9. Zusammenarbeit mit Toby's KI

- Kanal: **GitHub PR #11** in `Rudi7503/NanoMig`.
- Jede Nachricht beginnt mit `Ich bin Rudis KI:` und einer Leerzeile.
- Prüfskript: `python mister\tools\check_toby_updates.py --watch 25 --minutes 1 --pr 11`
  (vier Kanäle, zustandslos, meldet nur bei Treffer).
- **Offen:** Toby bittet um Installation des *ChatGPT Codex Connector* für
  `Rudi7503`, nur für `NanoMig`. Das muss Rudi selbst im Browser machen.
- Letzte Antworten: 13:30, 13:41 (Adapter-Doppelvergabe), 15:47 (ACK-Wechsel
  am CPU-Signal, Vergleichsplan), 22:26 (Zeitpfad plausibel, sync abgelehnt,
  Block-RAM-Vorschlag).

## 10. Dateien, die diese Sitzung angelegt oder geändert hat

```
docs/HARDWARE.md              Messprotokoll aller Läufe
docs/FLASHING.md              Flashprozedur, Fallstricke, Kabelname
docs/SCRIPTS.md               alle Skripte, keines undokumentiert
docs/HANDOVER_TANG.md         diese Datei
AGENTS.md                     elf Regeln, u. a. „Vorgänge am Gerät werden beschrieben"
mister/tools/auto_flash_tang.py       Auto-Flash mit Ton
mister/tools/check_toby_updates.py    vier Kanäle, zustandslos
src/tang/console138k/sprite_mem_adapter.v   Arbiter + Adapter
src/tang/console138k/spr_test_pattern.v     Block-RAM-Testmuster
src/minimig-aga/minimig.v     Speicherports, ifdef-Zweige
src/nanomig.v                 Ports für den Speicher-Master
src/misc/sysctrl.v            4 MB Fast-RAM
```

## 11. Wenn du nur eine Sache liest

Der Arbiter im CPU-Speicherpfad ist die einzige bekannte Ursache für das
schwarze Bild. Die Engine fordert nichts an. Der billigste nächste Test ist
Toby's Block-RAM-Muster: CPU direkt am SDRAM lassen, Sprites aus internem
Speicher. Das liefert zum ersten Mal ein Bild **mit** Sprite — und trennt
Boot von Speicherteilung.
