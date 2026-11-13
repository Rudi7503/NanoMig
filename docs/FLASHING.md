# Bitstream auf die Konsole bringen

Stand: 2026-11-13. Diese Datei existiert, weil der Flashvorgang sonst jedes
Mal neu erraten werden muss. **Wer ihn ändert oder ergänzt, schreibt es hier
hinein** (Regel 11 in `AGENTS.md`).

## Verifizierte Erkenntnisse vom 2026-11-13 (Gerätetest, in dieser Sitzung)

Alles in diesem Block wurde am Gerät ausgeführt und das Ergebnis gelesen. Wo es
den Abschnitten weiter unten widerspricht, gilt dieser Block.

### Welche USB-Zustände es gibt (alles über denselben MCU-USB-C-Anschluss)

| Zustand am PC | Bedeutung | Was geht |
|---|---|---|
| `Serielles USB-Gerät (COM8)`, `VID_349B:PID_6160` | BL616 im **Bootloader** (BOOT-Taste beim Einstecken gehalten) | nur BL616 flashen (`bflb_mcu_tool`), **kein JTAG** |
| `USB Serial Converter A/B`, COM11 + COM12 (`VID_0403:PID_6010`) | BL616 läuft normal mit der JTAG-Brücke aus `0x0` = **Debugger** | `programmer_cli` für den FPGA |
| kein Gerät | Kabel ohne Daten, falscher Anschluss oder Stromproblem | nichts |

Wer den BL616 mit gedrückter BOOT-Taste geflasht hat, muss das Kabel danach
**ohne BOOT-Taste neu einstecken**, sonst bleibt er im Bootloader und der
Debugger (COM11/12) erscheint nie. Das hat uns mehrere Stunden gekostet.

### JTAG zum FPGA: nur kurz nach dem Einschalten

Läuft ein Core, benutzt er die JTAG-Pins als GPIO (`-use_jtag_as_gpio 1`).
Dann antwortet `programmer_cli` mit `Gowin Device not found` oder bricht ein
Schreiben bei 0 % mit `Error found!` ab, obwohl der Debugger (COM11/12) da ist.

* Dock **ohne S1/S2** (nur die **Mode-Taste** erreichbar): Strom abziehen,
  **Mode-Taste halten**, wieder anstecken, nach ca. 3 s loslassen → JTAG ist
  **kurz** offen.
* Das Fenster schließt sich wieder, sobald der Core aus dem Flash neu bootet.
  Nach einem erfolgreichen Schreibvorgang ist es meist zu. Deshalb pro
  Einschalten **eine** Operation, und die zuerst.
* Zeit zum Reagieren nach „bereit" reicht nicht. Eine **Auto-Flash-Schleife**
  starten, die das Fenster selbst erwischt (`-r 51` alle 0,7 s, bei
  `Detected Flash id` sofort `-r 53`):

```powershell
$p   = 'C:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe'
$fs  = 'D:\programmier_ordner\FPGA\NanoMig\src\impl\pnr\nanomig_tc138k_spr.fs'
for ($i = 0; $i -lt 300; $i++) {
    $o = & $p --cable-index 4 -d GW5AST-138C -r 51 2>&1 | Out-String
    if ($o -match 'Detected Flash id') {
        & $p --cable-index 4 -d GW5AST-138C -r 53 --fsFile $fs --spiaddr 0x000000
        break
    }
    Start-Sleep -Milliseconds 700
}
```

Danach Strom aus/an (ohne Taste), der Core bootet aus dem Flash.

### Ergebnis der Messungen

| Aktion | Ergebnis |
|---|---|
| `--cable-index 4` mit `-r 51`, `-r 53`, `-r 55` | **funktioniert** (Core 81 s, Kickstart 10 s). Der Hinweis weiter unten, `--cable-index 4` scheitere beim Schreiben, ließ sich hier **nicht reproduzieren**; dort fehlte vermutlich nur das offene JTAG-Fenster |
| Core `-r 53 --fsFile` an `0x000000` | `ends at 0x0461600` (offizieller v0.9, 78,7 s), `0x04A7D00` (unser 14:03-Build, 81,5 s) |
| Kickstart `-r 55 --mcuFile <bin> --spiaddr 0x600000` | `ends at 0x0680000`, 9,8 s |
| `-r 55 --fsFile <bin>` | schreibt 0 Bytes (`ends at 0x0600000`) |
| `-r 56` (Verify, Rohdaten) | `Program and Verify Flash Failed`, `-r 55` genügt |
| `-r 1` Reprogram | geht nur bei offenem JTAG-Fenster |
| Operation 53 gegen Stromausfall des Fensters | `Error found!` bei 0 % |

Kopierhinweis für Kickstart-Dateien mit Klammern im Namen
(`...[o].rom`): `Copy-Item -LiteralPath`. Ohne `-LiteralPath` schlägt die
Kopie wegen `[o]` still fehl (Wildcard).

### Kickstart und Core müssen zusammenpassen

| Core | Kickstart an `0x600000` | Ergebnis |
|---|---|---|
| Original NanoMig v0.9 (OCS/ECS, 68000) | 1.3, 512 KB, MD5 `192d6d950d0ed3df8040b788502831c2` | **läuft**, Diskettenhand auf HDMI |
| unser AGA/68020-Core | 3.1 A1200, `kick40068.A1200`, SHA256 `6D43840D4099A74170EA0F0425B6257C3891EBCAA39C4D1840075A9AB22B5707` | siehe `nanomig-lessons.md` Punkt 11 |

Das 3.1-ROM stammt aus `Amiga-WHDLOAD-Kick-files-kickstart-rom-pack.zip`
(`kick40068.A1200`, 524 288 Bytes). SHA256 immer per Skript bestimmen
(`Get-FileHash`), nicht abtippen.

### Diagnose-LED im erweiterten Core (`top.sv`)

| Muster | Bedeutung |
|---|---|
| schnelles Flackern | PLL ohne Lock |
| 1x lang blinken | SDRAM-Init fehlgeschlagen |
| 2x lang blinken | Flash-Init fehlgeschlagen |
| 3x lang blinken | ROM-Kopie hängt |
| dauer an | Kickstart kopiert, CPU läuft (sagt nichts über das Bild aus) |

**„LED dauer grün" heißt nur: ROM kopiert. Ein schwarzes Bild kann trotzdem
am AGA-Video- oder Speicherpfad liegen.**

### BL616-Firmware flashen (OSD/Tastatur)

Der BL616 hat zwei Teile: `0x0` = JTAG-Brücke
(`bl616_fpga_partner_console138k.bin`, nicht anfassen), `0x40000` = App.

| App an `0x40000` | Wirkung |
|---|---|
| `tangcore_console138k.bin` | TangCore-Menü, **nicht** für NanoMig-OSD |
| `fpga_companion_console60k.bin` (v1.4.33) | FPGA-Companion für NanoMig. Für 138K gibt es kein eigenes Asset; das Dock ist gleich |

```
python -m bflb_mcu_tool --chipname bl616 --interface uart --port COM8 `
       --baudrate 2000000 --firmware <bin> --addr 0x40000
```

* BLFlashCube ist nur eine GUI. Das Kommandozeilen-Werkzeug ist
  `bflb-mcu-tool` (`pip install bflb-mcu-tool`).
* Python 3.14 braucht zusätzlich `pip install standard-telnetlib`, sonst
  `ModuleNotFoundError: telnetlib`.
* **Niemals `--erase`** (Chip-Erase).
* Nebenwirkung der pip-Installation: `cryptography` wird auf 37.0.4
  gesenkt, `esptool` 5.6.0 verlangt ≥ 43.
* Verify per SHA256 steht im Ausgabelog (`verification succeeded`).
* Nach dem Flash Kabel **ohne BOOT-Taste** neu einstecken (siehe oben).

Offen: OSD per F12 funktioniert nicht, Tastatur-LED bleibt aus. Welche
USB-Buchse am Dock den BL616 als Host anspricht, ist ungeklärt.

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

### B) Ohne Taste — über den JTAG-Anschluss (der Weg, der funktioniert)

**Das ist der Weg, der funktioniert, und zwar ohne jede Taste.** Entscheidend
ist der **Kabelname**, nicht der Index:

```powershell
$cli = 'C:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe'

& $cli --cable "Gowin USB Cable(FT2CH)" -d GW5AST-138C -r 53 `
       --fsFile "D:\programmier_ordner\FPGA\NanoMig\src\impl\pnr\nanomig_tc138k.fs" `
       --spiaddr 0x000000
```

Belegte Erfolgsläufe am 2026-11-13:

```
 Programning Flash ends at 0x0461600.   (offizieller Core, 78,72 s)
 Programning Flash ends at 0x049D800.   (unser Core,       82,02 s)
 Program Flash finished.
```

#### Warum `--cable-index 4` scheitert

`--cable-index 4` meldet zwar `USB Debugger A`, ist aber die **falsche
Rückende**:

| Aufruf | Lesen (`-r 0`) | SRAM (`-r 2`) | Flash (`-r 53`) |
|---|---|---|---|
| `--cable-index 4` | geht | geht | **exit 50, 0,0 s** |
| `--cable "Gowin USB Cable(FT2CH)"` | geht | geht | **geht, 82 s** |

Der Index zeigt auf einen anderen Kabeltreiber, der zwar JTAG-Kommandos
absetzen, aber den externen Flash nicht erreichen kann. Deshalb kam bei
`-r 12` auch „actual flash storage size is **1 bytes**" — der Flash wurde nie
angesprochen, nicht weil er gesperrt war.

**Merke: `--cable "Gowin USB Cable(FT2CH)"` verwenden, nicht `--cable-index`.**

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

## Zustand am 2026-11-13 — was das Team am Gerät gemessen hat

Die ausführlichen Regeln stehen in `.agent/rules/nanomig-lessons.md`
(Punkt 9 und 11). Hier nur das, was man beim Flashen wirklich braucht.

### Nach dem Boot ist JTAG weg

> Nach Flash des Original-Cores ist JTAG nicht mehr erreichbar
> (`Gowin Device not found`, JTAG-Pins als GPIO) → normal.

**Das erklärt `exit 50` bei jeder Schreiboperation.** Lesen der Device-Codes
geht weiter, Schreiben nicht. Für erneutes Flashen muss die Konsole **mit
gehaltenen Tasten S1/S2 eingeschaltet** werden.

### Was am 13.11. zunächst falsch gedeutet wurde

Aus den Messungen `-r 2` läuft, `-r 53` scheitert, `-r 12` meldet 1 Byte
wurde zunächst geschlossen, ein konfigurierter FPGA sperre den Flash. **Das
war falsch.** Die eigentliche Ursache war `--cable-index 4`: ein anderer
Kabeltreiber, der JTAG-Kommandos absetzt, aber den externen Flash nicht
erreicht.

Mit `--cable "Gowin USB Cable(FT2CH)"` funktioniert `-r 53` im selben
Gerätezustand sofort, ohne Tasten und ohne Kaltstart.

Lehre: bei einem `exit 50` in 0,0 Sekunden zuerst das **Kabel** prüfen, nicht
den Gerätezustand. Ein sofortiger Abbruch ohne Zeitverbrauch ist ein
Schichtproblem, kein Flash-Problem.


### Die Befehle, die funktionieren

```
Bitstream:  --cable-index 4 -d GW5AST-138C -r 53 --fsFile <fs>   --spiaddr 0x000000
Kickstart:  --cable-index 4 -d GW5AST-138C -r 55 --mcuFile <bin> --spiaddr 0x600000
Neustart:   --cable-index 4 -d GW5AST-138C -r 1
```

### Fallstricke

| Falsch | Warum |
|---|---|
| `-r 8`, `-r 12` (Gowin-1-Codes) | GW5AST-138C ist Arora V und braucht eigene Codes (`spi flash not found`) |
| `--fsFile` mit `.bin`/`.rom` | Gowin erwartet einen `.fs`-Header, schreibt sonst 0 Bytes |
| Rohdaten mit `-r 56` verifizieren | meldet `Program and Verify Flash Failed`; `-r 55` genügt |
| `openFPGALoader` unter Windows | FTDIBUS/VCP blockiert libusb (`usb_open() failed -4`) |
| Booten ohne Kickstart an `0x600000` | Boot-FSM liest `0xFF`, CPU stürzt sofort ab → Schwarzbild |

## Unser Core auf der Konsole: schwarzes Bild

Stand 2026-11-13, gemessen vom Team:

| Core | Ergebnis |
|---|---|
| Original NanoMig v0.9 | **läuft**, Diskettenhand auf HDMI |
| unser `nanomig_tc138k.fs` (Flash `0x000000` + Kick 3.1 `0x600000`) | **LED dauerhaft grün, Bild schwarz, kein OSD** |

Der Unterschied zum Original ist groß und umfasst drei Gruppen:

1. **AGAIN/68020-Konfiguration** — `sysctrl.v`-Defaultwerte, `ENABLE_AGA`,
   `ENABLE_TG68K`, `CPU_SLOW14`, `ENABLE_CACHE`, `CHIPRAM_CACHE`.
2. **Reset- und JTAG-Änderungen** — in `5fb071f` wurde `bl616_jtagsel` aus den
   Reset-Bedingungen in `top.sv` entfernt.
3. **Sprite-Speicheranbindung** — Arbiter und Adapter zwischen CPU und dem
   SDRAM-Anschluss p2 (`00e7ac3`, `7fc2fad`).

Gruppe 3 ist der Hauptverdächtige für ein **gar nicht startendes** System:
Der Arbiter sitzt im Speicherpfad des Prozessors. Ist er falsch, bootet
nichts — auch wenn der Rest stimmt.

Ein Test, der das entscheidet: dieselbe Konfiguration **ohne** die
Sprite-Anbindung bauen (Speicherports wieder auf 0), flashen, booten.

- Bootet dieser Stand → der Arbiter ist die Ursache.
- Bootet er auch nicht → liegt es an Gruppe 1 oder 2, und die Sprite-Anbindung
  ist unschuldig.



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
