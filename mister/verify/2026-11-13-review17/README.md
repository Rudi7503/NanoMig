# Review17: Gegenbeispiele von Toby's KI, gegen unsere RTL gefahren

Stand 2026-11-13

## Herkunft

`extended_tb.v` und `toby-expected-results.json` stammen aus Tobys Paket
zu Review17:

```
upload-dc00101611d6e4618412c649bfdf38e7
17.826 Bytes
SHA256 d615094777ea61a0afa57100f0605977d556f0bbc8f0d75a0948c471444147a8
```

Der Hash stimmt mit der Angabe in Tobys Nachricht überein. `run_extended_local.py`
ist die lokale Fassung seines Runners: gleiche Tests, aber iverilog aus dem
Chocolatey-Pfad und die RTL aus diesem Repo statt aus seinem Kopiebaum.

## Ergebnis

```
                        f1f0d3b (vor dem Fix)   5fb071f (unser Stand)
published18                    PASS                    PASS
burst_consumer                 PASS                    PASS
descriptor_bl4                 PASS                    PASS
palette_write                  PASS                    PASS
clut_palette                   PASS                    PASS
capture_complete               PASS                    PASS
capture_one_read               PASS                    PASS
descriptor_gapped_tail         FAIL                    PASS
capture_pixel_snapshot         FAIL                    PASS
                              7 / 9                   9 / 9
```

Die beiden Fehlermeldungen auf dem alten Stand sind wortgleich mit Tobys
Befund:

```
delayed descriptor tail: pixel codes=16 expected0 before any pixel response
stable bus sample HI=0011 LO=5566 expected0011/2233
```

Damit ist belegt:

1. Die beiden Fixes in `5fb071f` wirken.
2. Tobys Testsuite unterscheidet die Stände — sie besteht nicht einfach immer.

## Wie man es nachfährt

```powershell
python mister\verify\2026-11-13-review17\run_extended_local.py `
       mister\verify\2026-11-13-review17 `
       D:\programmier_ordner\FPGA\NanoMig
```

Das Skript legt die `.vvp`-Dateien im Paketordner ab und gibt je Test
PASS oder FAIL aus, am Ende eine Zusammenfassung.

## Was das nicht belegt

- Die Tests laufen in einem gemeinsamen Takt. CDC, Timing und Backpressure
  auf echter Hardware sind damit nicht nachgewiesen.
- `published18` ist unsere eigene Testbench und deckt nur Blender, Decoder,
  Register und Compositor ab — nicht DMA und Capture.
- Es ist ein MiSTer-/RTL-Nachweis, kein Tang-Nachweis: auf Tang fehlt
  weiterhin der SDRAM-Adapter, die Speicherantworten stehen auf 0.
