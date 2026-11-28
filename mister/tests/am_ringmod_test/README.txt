MiSTer FPGA Minimig-AGA: Hardware AM-Modulation & Ringmodulation Test
======================================================================

Ziel:
  Pruefung der hardwareseitigen Modulations- und Kanalverknuepfungs-Funktionen
  der 32-Kanal Audio-Erweiterung auf MiSTer (Core 22a912cc).

Ablauf:
  1. Phase A (5 Sekunden): AM-Modulation (Tremolo)
     - Kanal 0: 4-Hz Sinus LFO (Bit 13 v_mute_mix = 1 -> stumm im Master-Mix)
     - Kanal 1: 440-Hz Sinuston (Bit 11 v_mod_mode = 01 -> Amplitudenmodulation)
     - Hoertest: Reines, gleichmaessig 4-mal pro Sekunde pulsierendes Tremolo.

  2. Pause (1,5 Sekunden):
     - Absolute Stille.

  3. Phase B (5 Sekunden): Ringmodulation (Vier-Quadranten-Multiplikation)
     - Kanal 0: 440-Hz Sinus (Träger, Bit 13 v_mute_mix = 1)
     - Kanal 1: 330-Hz Sinus (Bit 12 v_mod_mode = 10 -> Ringmodulation)
     - Hoertest: Charakteristischer metallischer Sci-Fi-Klang (Summe 770 Hz / Differenz 110 Hz).

Kickstart 1.3 Shell-kompatibel, meldet sauberen Abschluss mit RC: 0.
