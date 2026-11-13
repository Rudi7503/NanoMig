# Bitstream auf die Konsole bringen

Stand: 2026-11-13. Diese Datei existiert, weil der Flashvorgang sonst jedes
Mal neu erraten werden muss. **Wer ihn ändert oder ergänzt, schreibt es hier
hinein** (Regel 11 in `AGENTS.md`).

## Was gebaut wird

```
Projekt   src/nanomig_tc138k.gprj
Skript    src/build_tc138k.tcl
Befehl    gw_sh build_tc138k.tcl          (macht syn + pnr in einem Lauf)
Ergebnis  src/impl/pnr/nanomig_tc138k.fs  (rund 37 MB)
```

## Der eigentliche Knackpunkt: der Weg auf das Gerät

Die Tang Console hat **zwei USB-C-Anschlüsse**, und sie verhalten sich völlig
unterschiedlich. Das ist die Ursache fast aller Verwirrung.

### Anschluss am MCU (BL616)

```
Gerät   Serielles USB-Gerät (COM8)
USB-ID  VID_349B : PID_6160
```

Der BL616 ist der Microcontroller der Konsole. Über ihn läuft die
Companion-Firmware: OSD, Tastatur, Maus, SD-Karte, Netzwerk.

**In diesem Modus ist kein JTAG sichtbar.** `programmer_cli --scan-cables`
meldet nichts, `openFPGALoader` findet kein FTDI-Gerät. Ein Gowin-Flash ist
hier nicht möglich.

### Anschluss am FPGA

Ein zweiter USB-C-Anschluss führt direkt zum FPGA. Steckt das Kabel dort,
erscheint im Geräte-Manager ein JTAG-Interface (FTDI-Treiber `ftd2xx.dll` ist
auf diesem Rechner vorhanden).

**Beobachtung vom 2026-11-13:** Kabel am FPGA-Anschluss, Konsole ohne
Stromversorgung über den MCU-Anschluss → der PC sieht **gar kein Gerät**.
Möglicherweise braucht die Konsole in diesem Zustand zusätzlich Strom über
den anderen Anschluss, oder das verwendete Kabel führt keine Datenadern.

## Die Wege, die funktionieren sollen

### A) Gowin-Programmer mit Tasten-Sequenz

Aus den MiSTeryNano-Release-Hinweisen für Console 60K/138K:

> Direct cable in between Console and PC (no USB Hub). Unpower console by
> removing the USB-C cable. Press the Lid reconfig button and keep pressed
> while power-up the console board by connecting the USB-C cable.

Ablauf:

1. USB-C abziehen
2. „Lid reconfig" halten
3. USB-C anstecken, weiter halten
4. Taste loslassen
5. `programmer_cli --device GW5AST-138C --operation_index 1 --fsFile <datei.fs>`

`--operation_index` bedeutet: `0` Gerätecodes lesen, `1` Reprogram (Flash),
`2` SRAM (flüchtig).

### B) Ohne Taste — über den JTAG-Anschluss (der Weg, der funktioniert hat)

**Das ist der Weg, den Rudi beschrieben hat: die andere KI konnte flashen,
ohne eine Taste zu drücken.** Der entscheidende Punkt ist `--cable-index`:
`--scan-cables` findet nichts, das Kabel wird aber über seinen Index direkt
angesprochen.

```powershell
$cli = 'C:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe'

& $cli --cable-index 4 -d GW5AST-138C -r 53 `
       --fsFile "D:\programmier_ordner\FPGA\NanoMig\src\impl\pnr\nanomig_tc138k.fs" `
       --spiaddr 0x000000 `
       --output "$env:TEMP\flash_out.txt"
```

Belegter Erfolgslauf (Rudi, 2026-11-13):

```
 Programning Flash ends at 0x0461600.
 Program Flash finished.
 Finished.
 Cost 78.72 second(s)
```

Also rund 79 Sekunden für die 37 MB.

## `programmer_cli` — was die Schalter bedeuten

```
--cable-index 4        Kabel direkt ansprechen; --scan-cables findet nichts
-d GW5AST-138C         Zielbaustein
-r <n>                 Operation, siehe Tabelle
--fsFile <datei>       Bitstream
--spiaddr 0x000000     Startadresse im externen Flash
--output <datei>       Bericht
```

Operationen, die hier gebraucht werden:

| `-r` | Bedeutung |
|---|---|
| 0 | Device Codes lesen (funktioniert immer, gut zum Verbindungstest) |
| 1 | Reprogram |
| 2 | SRAM Program (flüchtig, gut für den ersten Test) |
| 51 | exFlash Detect ID |
| 52 | exFlash Bulk Erase Arora V |
| 53 | exFlash Erase,Program Arora V |
| 54 | exFlash Erase,Program,Verify Arora V |

## Zustand am 2026-11-13, 13:17 — Schreibzugriffe blockiert

Nach dem erfolgreichen Lauf oben schlugen **alle** Schreiboperationen fehl:

| Aufruf | Datei | Ergebnis |
|---|---|---|
| `-r 53` | unser `nanomig_tc138k.fs` | exit 50, 0,0 s |
| `-r 53` | offiziell `nanomig_tc138k_official.fs` | exit 50, 0,0 s |
| `-r 2` | unser | exit 50, 0,0 s |
| `-r 2` | offiziell | exit 50, 0,02 s |
| `-r 51` | — | exit 50, 0,01 s |
| `-r 0` | — | **exit 0**, 0,02 s |

Lesen geht, schreiben nicht — und die offizielle Datei scheitert genauso wie
unsere. Der Bitstream ist damit als Ursache ausgeschlossen.

**Nächster Schritt in diesem Zustand: Konsole stromlos machen und neu
anstecken**, dann erneut versuchen. Ein `jtagserver`-Prozess (PID 4612) lief
zu diesem Zeitpunkt noch und liess sich nicht beenden.


## Was am 2026-11-13 gemessen wurde

| Versuch | Ergebnis |
|---|---|
| `programmer_cli --scan-cables`, Konsole am MCU | nichts gefunden, Exit 48 |
| `openFPGALoader --detect` | `unable to open ftdi device`, kein Kabel |
| `openFPGALoader --list-cables` | enthält keinen BL616-Eintrag |
| Geräte-Manager, Konsole am MCU | `VID_349B:PID_6160` = COM8, sonst nichts |
| Kabel am FPGA-Anschluss, ohne Strom über MCU | kein Gerät sichtbar |

## Werkzeuge auf diesem Rechner

```
C:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe
D:\programmier_ordner\FPGA\tools\openFPGALoader\openFPGALoader-1.0.0-windows-amd64\bin\openFPGALoader.exe
D:\programmier_ordner\FPGA\tools\bouffalo_flash_cube\bouffalo_flash_cube-1.1\BLFlashCube.exe
```

`BLFlashCube` ist für die **MCU-Firmware** (BL616), nicht für den FPGA-Bitstream.
Die Firmware-Images liegen unter `D:\programmier_ordner\FPGA\fpga_companion_fw\`
und `D:\programmier_ordner\FPGA\companion_bl616_138k\`, jeweils mit einer
`.ini`-Datei für Adressen und Löschmodus.

## Kickstart-ROMs

Für 138K-Boards liegt das Kickstart bei Offset `0x600000` und `0x640000`.
Ein neuer FPGA-Bitstream löscht es nicht.

## Offene Punkte

1. **Weg B vollständig dokumentieren** — Befehlszeile fehlt.
2. Klären, ob der FPGA-USB-Anschluss zusätzlich Strom über den MCU-Anschluss
   braucht.
3. Prüfen, ob das verwendete USB-C-Kabel Datenadern hat.
