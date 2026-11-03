Release 2026-11-01
==================

RBF: Minimig_00e6a049.rbf (4.051.120 Bytes)
SHA256: 00e6a0490e9c6d6dc010cf0f29f5139a306757d23915588faa964799e5510f69

Stand: Branch rudi/chain-stereo (Option 2 - Direkte Speicheranbindung + Option A)
  - Direkte Speicheranbindung (Option 2): Eigener Audio-DMA-Master direkt am DDR3/SDRAM-Bus
  - Voller 32-Bit-Adressraum: Samples koennen beliebig im Fast-RAM/Slow-RAM/Chip-RAM liegen
  - Entkoppelt von Agnus und 7-MHz-Chip-Bus: Direkte 114-MHz-FastRAM-Zugriffe ohne Agnus-Warten
  - Option A: Globale IRQ-Register nach $DFF804..$DFF80A verlegt, Voice 31 voll nutzbar
  - Voice 31 CMD/Biquad/Delay/Status uneingeschraenkt verfuegbar
  - Stereo-Deadlock behoben (32-Bit-Frames)
  - Linker und rechter Kanal getrennt (echtes Stereo AM / Ringmod)
  - Filter-DSPs nach Kanal geteilt, 32 Stimmen je Instanz
  - Koeffizienten im Block-RAM
  - Fester Zaehler statt Prioritaetsdurchlauf
  - Gestoppte Stimme ist still
  - Fruehes Nachladen bei Loops
  - Kette fuehrt links und rechts getrennt
  - Alle Testprogramme (rechteck, kaskade, bandpass) mit AUD_LEN=0 auf Folgestufen und Post-Filter-Capture aktualisiert

Vorherige Bitstreams:
  - Minimig_c106117b.rbf (4.123.036 Bytes, SHA256: c106117b119706c13430087b5fa0649b54cfe63a2588c7ba707ad3151f4e482d)
  - Minimig_2a92564d.rbf (4.130.608 Bytes, SHA256: 2a92564d62f618fd7c5328e2335453d2f065a8a13cfb2915adb8a5cb87b45cc1)
  - Minimig_5f83871c.rbf (4.104.228 Bytes, SHA256: 5f83871c7ee6b04a1ba189d59422bd27a17a9c7e8cff3f82afe6985edba7b99f)

Testprogramme, alle als Amiga-Hunk-Executable:

  stereotest   links 440 Hz, rechts 880 Hz         Farbe: gruen/rot
  kaskade      32 Stufen auf Rauschen              Farbe: gruen/rot (Schleifenzaehler behoben)
  rechteck     200 Hz Rechteck durch 32 Tiefpaesse Farbe: gruen/rot (Schleifenzaehler behoben)
  bandpass     1-kHz-Sinus aus der Kette           Farbe: gruen/rot (Schleifenzaehler behoben)
  delay        32 Echos, 10 ms Versatz             gruen nach 0,5 s, blau nach 2 s
  am           440 Hz mit 2-Hz-Tremolo             -
  adpcm        4-Bit-ADPCM, 1 s im Loop            gruen = laeuft

Start: Programm auf den MiSTer kopieren und auf der Amiga-Seite starten,
per Doppelklick oder in der Shell durch Eingabe des Namens.
showcase (Mono-Regression) liegt bereits vor und ist nicht enthalten.
