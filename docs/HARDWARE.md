# Hardware-Ergebnisse

Jeder Eintrag ist ein tatsächlich durchgeführter Lauf auf einem Gerät. Keine
Simulation, keine Erwartung. Wer etwas testet, trägt es hier ein — mit Datum,
Commit, Bitstream-Hash und dem, was auf dem Bildschirm zu sehen war.

## 2026-11-13 — Tang Console 138K, erster Start unseres Cores

**Ergebnis: startet. Kickstart-Hand (v1.3) auf HDMI.**

| | |
|---|---|
| Gerät | Tang Console 138K, GW5AST-138C |
| Commit | `a088768` (Basis) + Arbiter/Adapter aus `00e7ac3`, `7fc2fad` |
| Bitstream | `nanomig_tc138k.fs`, 39.113.899 Bytes, 13.11. 13:35 |
| Flash | `--cable "Gowin USB Cable(FT2CH)" -r 53 --spiaddr 0x000000`, 82,02 s |
| Bild | Amiga-Hand, Kickstart v1.3 |

### Warum das zählt

In diesem Bitstream stecken **Arbiter und Adapter** zwischen Prozessor und
dem einzigen SDRAM-Anschluss p2 (`sdram_p2_arbiter`, `sprite_mem_adapter`).

Bis heute war unklar, ob das trägt: der Adapter war nur isoliert simuliert,
nie im Verbund, und ein Fehler im Speicherpfad hätte jeden Start verhindert.

**Der Start beweist:**

1. Der Arbiter teilt den Anschluss korrekt mit dem Prozessor.
2. Die Antwort-Verzögerung von einem 85-MHz-Takt stört den Prozessor nicht.
3. Die Ports in `src/minimig-aga/minimig.v` sind richtig verdrahtet.
4. Der Core mit AGA-, 68020- und Cache-Konfiguration läuft auf dieser Konsole.

### Was es nicht beweist

Die Sprite-Engine selbst. Ohne Deskriptorliste bleibt sie stumm — sie hat in
diesem Lauf keinen einzigen Speicherzugriff ausgeführt. Der nächste Schritt
ist ein 68000-Programm, das eine Liste anlegt und `$DFF580` beschreibt.

## Frühere Läufe

| Datum | Stand | Ergebnis |
|---|---|---|
| 2026-11-13 | unser Core, Stand vor `7fc2fad` | LED dauerhaft grün, Bild schwarz, kein OSD — Ursache waren die fehlenden Speicherports in `minimig.v` |
| 2026-11-13 | NanoMig v0.9 (offiziell) | läuft, Diskettenhand auf HDMI |
