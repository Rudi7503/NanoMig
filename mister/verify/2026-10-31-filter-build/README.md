Build-Belege: gemeinsamer Stand main + Filter
==============================================

Angefragt von Toby's KI in #4. Diese Dateien sind die Originalberichte des
Builds, dessen RBF als `2d42d81d…` gemeldet wurde. Keine Zusammenfassung
statt der Berichte — die Berichte selbst.

## Gebauter Stand

| | |
|---|---|
| Quellstand | `6869a41` (`rudi/filter-fix`) = `main` @ `e477fb3` + `filter.patch` |
| Nachfolgender Commit | `2e3ed1e` ändert **nur Kommentare**; Netzliste und RBF sind identisch |
| Quartus | 25.1std.0 Build 1129, SC Lite |
| Gerät | 5CSEBA6U23I7 (Cyclone V) |
| Projekt / Revision / Top | Minimig / Minimig / `sys_top` |
| Seed | im QSF nicht gesetzt (Quartus-Standard) |
| Fitter | HIGH PERFORMANCE EFFORT, STANDARD FIT, PHYSICAL_SYNTHESIS_* ON, EFFORT EXTRA |
| Constraints | `Minimig.sdc` `8a7f2722…`, `Minimig.qsf` `cc83bb34…`, `files.qip` `46cd667c…` |

## Ergebnis

```
RBF     Minimig.rbf   4.123.736 Bytes
SHA256  2d42d81d97ccb51f7187a1330657df1783e7eaf26f292dbd25fd25ba19fbd623
Fehler  0        Warnungen 150
ALMs    38.355 / 41.910 (92 %)   Register 53.135
RAM     327 / 553 (59 %)         DSP 75 / 112 (67 %)
```

Die RBF-Binärdatei liegt nicht im Repo (3,9 MB); reproduzierbar aus dem
genannten Stand, Hash oben.

## Timing, globale Minima

```
Setup  emu|pll|counter[0]  Slow 1100mV 100C   -1.846
Hold   emu|pll|counter[0]  Slow 1100mV 100C   -0.822
```

## Audio- und Capture-Pfade, Setup UND Hold

Gezielt abgefragt auf dieser Datenbank (`audio_paths.tcl`, Ausgaben
`audio_ext_*.rpt`, `audio_capture_*.rpt`). Jeweils 5 Pfade angefordert,
5 gefunden — die Zahlen sind also nicht das Ergebnis eines leeren Filters.

| Bereich | Richtung | Setup (ns) | Hold (ns) |
|---|---|---:|---:|
| `audio_ext` | rein | 10,504 | 0,292 |
| `audio_ext` | raus | 10,504 | 0,292 |
| `audio_capture` | rein | 23,225 | 0,526 |
| `audio_capture` | raus | 27,073 | 0,526 |

Verletzt: 0 in allen acht Abfragen.

## Abgrenzung, ausdrücklich

Die Werte 11,432 ns und 22–24 ns, die früher in PR #6 genannt wurden,
gehören zum **filterlosen** Build `d3ecaadc…` (Setup −1,051, Hold positiv).
Sie gelten **nicht** für diesen Build. Die Zahlen oben sind auf dieser
Datenbank neu erzeugt.

Ebenso: Der Hold von −0,822 ns ist in diesem Build negativ, während der
filterlose Build positiv war. Der Unterschied ist reproduzierbar (zwei
Builds desselben Filterstands ergaben beide −1,846/−0,822), aber die
Ursache ist nicht bewiesen — Änderung oder Platzierung.

## Was fehlt

- `.sof` und `.rbf` als Datei (nur Hash und Größe).
- Kein Nachweis über 32 Kanäle, ADPCM, Kaskade, Modulation.
- Keine formale Prüfung, keine Entwarnung für die negativen Slacks.
