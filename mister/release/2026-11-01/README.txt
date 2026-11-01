Release 2026-11-01
==================

RBF  Minimig_5f83871c.rbf   4.104.228 Bytes
SHA256 5f83871c7ee6b04a1ba189d59422bd27a17a9c7e8cff3f82afe6985edba7b9f

Stand: Branch rudi/chain-stereo
  Stereo-Deadlock behoben (32-Bit-Frames)
  Linker und rechter Kanal getrennt
  Filter-DSPs nach Kanal geteilt, 32 Stimmen je Instanz
  Koeffizienten im Block-RAM
  Fester Zaehler statt Prioritaetsdurchlauf
  Gestoppte Stimme ist still
  Fruehes Nachladen bei Loops
  Kette fuehrt links und rechts getrennt
  36.094 ALMs (86 %), Setup -1.154, Hold positiv

Testprogramme, alle als Amiga-Hunk-Executable:

  stereotest   links 440 Hz, rechts 880 Hz         Farbe: gruen/rot
  kaskade      32 Stufen auf Rauschen              Farbe: gruen/rot
  rechteck     200 Hz Rechteck durch 32 Tiefpaesse  Farbe: gruen/rot
  bandpass     1-kHz-Sinus aus der Kette           Farbe: gruen/rot
  delay        32 Echos, 10 ms Versatz             gruen nach 0,5 s, blau nach 2 s
  am           440 Hz mit 2-Hz-Tremolo             -
  adpcm        4-Bit-ADPCM, 1 s im Loop            gruen = laeuft

Start: Programm auf den MiSTer kopieren und auf der Amiga-Seite starten,
per Doppelklick oder in der Shell durch Eingabe des Namens.
showcase (Mono-Regression) liegt bereits vor und ist nicht enthalten.