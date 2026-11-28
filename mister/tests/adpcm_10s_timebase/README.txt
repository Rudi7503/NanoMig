MiSTer FPGA Minimig-AGA: 32-Stimmen ADPCM 10-Sekunden Zeitbasis-Test
======================================================================

Ziel:
  Unabhaengige, hochpraezise Zeitbasismessung des 32-Kanal ADPCM-Streams
  bei 48 kHz (240.000 Bytes, 480.000 Samples) mit akustischem Erkennungssignal.

Besonderheiten & Erfuellung aller Testkriterien:
  1. Akustisches End-Signal (9,0s .. 10,02s):
     - Sekunden 0..8: Wohlklingende Akkordfolge mit 11 dB Headroom (kein Clipping).
     - Sekunde 8,0..9,0: Kurzer Uebergang in 200 ms Stille.
     - Sekunde 9,0..10,02: Markantes 3-Ton-Glockenspiel (880 Hz, 1318 Hz, 1760 Hz)
       hoerbar bis kurz vor dem Pufferende!
  2. Unabhaengige Hardware-Zeitbasis (VBlank-Framezaehler 50/60 Hz):
     - Startzeitpunkt T0
     - Zeitstempel erste fertige Stimme (first voice_done)
     - Zeitstempel letzte fertige Stimme (all 32 voices_done)
     - Gesamte Spieldauer in Sekunden mit Nachkommastellen (Erwartung ca. 10,07 s).
  3. Klare Trennung:
     - voice_done wird explizit als reguläres "Pufferende (32/32)" ausgewiesen.
     - FIFO-Unterlaeufe (Starvation) separat als 0 gefuehrt.
     - Hardware-Clipping-Zaehlung ueber 16-Bit Capture-Puffer.
