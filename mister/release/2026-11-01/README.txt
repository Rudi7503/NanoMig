Release 2026-11-01
==================

RBF: Minimig_c106117b.rbf (4.123.036 Bytes)
SHA256: c106117b119706c13430087b5fa0649b54cfe63a2588c7ba707ad3151f4e482d

Stand: Branch rudi/chain-stereo (Option A + Seed 11)
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
  - 36.152 ALMs (86 %), 75 DSPs (67 %), Setup -0.538 ns, Hold +0.252 ns (Fitter-Seed 11)

Vorherige Bitstreams:
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
