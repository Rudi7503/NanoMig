Release 2026-11-04 (Update Option 2 + Copper-Fix)
=================================================

RBF: Minimig_6186b83f.rbf (4.122.716 Bytes)
SHA256: 6186b83fbbe3253fa4cd3b0f0b265e6f79121290aca9a98d7e5fec3f9795fa60

Stand: Branch rudi/chain-stereo (Option 2 - Hybride Speicheranbindung + Option A)
  - Direkte Speicheranbindung (Option 2 Hybrid):
      * DDR3 Fast-RAM (>= $08000000): Direkter 114-MHz-DMA-Master ohne Agnus-Beteiligung
      * Chip-RAM (< $02000000): Saubere Übergabe an chipdma_arb (Agnus-Idle-Erkennung + SDRAM-Read-Timing)
  - Voller 32-Bit-Adressraum: Samples können beliebig im Fast-RAM/Slow-RAM/Chip-RAM liegen
  - Option A: Globale IRQ-Register nach $DFF804..$DFF80A verlegt, Voice 31 voll nutzbar
  - Voice 31 CMD/Biquad/Delay/Status uneingeschränkt verfügbar
  - Stereo-Deadlock behoben (32-Bit-Frames)
  - Linker und rechter Kanal getrennt (echtes Stereo AM / Ringmod)
  - Filter-DSPs nach Stereokanal geteilt (DSP0 = Links, DSP1 = Rechts, alle 32 Stimmen je Instanz)
  - Koeffizienten im Block-RAM
  - Fester Zähler statt Prioritätsdurchlauf
  - Gestoppte Stimme ist still
  - Frühes Nachladen bei Loops
  - Kette führt links und rechts getrennt
  - Alle Testprogramme (rechteck, kaskade, bandpass) aktualisiert:
      * Endlosschleife auf COLOR00 verhindert Workbench-Copper-Overwrite (Blau-Screen-Fix)
      * Stille-Erkennung: TST.W D5 -> Rot, wenn kein Audiosignal empfangen wird
      * Remainder-Maskierung nach DIVU

Vorherige Bitstreams:
  - Minimig_00e6a049.rbf (4.051.120 Bytes, SHA256: 00e6a0490e9c6d6dc010cf0f29f5139a306757d23915588faa964799e5510f69)
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
