# Capture-Stereo-Prüfung, Stand 2026-10-31

Alles hier dient dem Nachweis für PR #1 (`fix(capture): latch right sample
together with left`). Kein RTL, keine Builds — nur Rohdaten und Auswertung.

## Was hier liegt

| Datei | Inhalt |
|---|---|
| `before-stream.raw` | Aufnahme **vor** dem Fix, 65.536 Frames, Big-Endian int16, stereo verschränkt. SHA256 `78a2001adb27ea5edd0ceb862bda207cbcd93f64d6c27a86bffa0f85a86d4d5e` |
| `stream.raw` | **fehlt noch** — die Aufnahme nach dem Fix |
| `check_capture.py` | Auswertung, nur Python-Standardbibliothek |

## Was noch fehlt

`stream.raw` nach dem Rebuild, 65.536 Frames, gleiches Format: **Big-Endian
int16**, verschränkt L/R, 4 Byte pro Frame.

Ablegen, dann:

```bash
python check_capture.py
```

Kein Push-Recht oder Upload nötig? Die Datei per Discord an Rudi, er legt sie
hier ab. Der Ordner ist der einzige Ort, an dem sie gebraucht wird.

## Was das Skript prüft

1. **Format und Umfang** — Framezahl, Wertebereich, Big-Endian-Annahme
2. **Stereo-Kohärenz** — Anzahl Frames mit L≠R. Erwartung nach dem Fix: **0**
3. **Muster** — falls nicht 0: Verteilung von `frame % 32`; vor dem Fix lagen
   alle 57 Abweichungen bei `7 mod 32`
4. **Nachbarschaft** — sind L und R benachbarte Werte der Sinustabelle
5. **Vergleich mit `before-stream.raw`** — sucht den Versatz über ein exaktes
   Fenster und zählt danach die verbleibenden Unterschiede

Punkt 5 ist der interessante: Ohne Versatzbestimmung ist ein Bytevergleich
zwischen zwei freilaufenden Aufnahmen bedeutungslos. Erwartet wird **ein**
Versatz für den ganzen Stream, danach Unterschiede nur an den bekannten Stellen.

## Abnahme für PR #1

- `L != R` bei 0 von 65.536 Frames
- Versatz gegen die Voraufnahme bestimmt, nicht geschätzt
- übrige Abweichungen erklärt oder null

Wer etwas anderes findet, schreibt es hier hinein — auch dann, wenn es die
Erwartung widerlegt. Ein Befund, der die Annahme kippt, ist mehr wert als eine
Bestätigung.
