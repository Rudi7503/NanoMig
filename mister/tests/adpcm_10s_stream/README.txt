MiSTer FPGA Minimig-AGA: 32-Stimmen ADPCM 10-Sekunden Loopfreier Stream
========================================================================

Ziel:
  Vollstaendiger Ausschluss jeglicher Loop-DMA-Artefakte durch Abspielen
  eines kontinuierlichen 10,0-Sekunden-Audiosamples (240.000 Bytes, 480.000 Samples)
  auf allen 32 Stimmen simultan bei 48 kHz im 4-Bit ADPCM-Modus.

Features:
  - 10 Sekunden kontinuierliche Audiodaten ohne Rueckspulen/Loop (One-Shot).
  - 768 KB/s kontinuierliche DMA-Buslast ueber alle 32 Kanaele.
  - Laufende Hardware-Ueberwachung im Sekundentakt:
    * Clipping-Zaehler ueber AUD_CAP (Scan des 16-Bit Capture-Puffers auf +-32767/32768)
    * DMA-Unterlaufzaehler ueber AUD_IRQ_HI/AUD_IRQ_LO
  - Skalierter Pegel $1616 (identisch zum vorherigen Stufentest)
  - Vollstaendige Statistik-Ausgabe auf AmigaDOS-Konsole (RC: 0).
