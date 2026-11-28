MiSTer FPGA Minimig-AGA: Biquad Filterbank vs. Direktvergleich
========================================================================
Programm: filter_compare
Ziel:     MiSTer FPGA (Minimig-AGA Core 22a912cc)
Datum:    08.11.2026

Zweck:
  Gezielter A/B-Direktvergleich desselben 48 kHz 4-Bit ADPCM Master-Tracks
  ("Kakao bei Lotte", 738.540 Bytes in Fast-RAM) unter identischen
  Pegelbedingungen ($B0B0 = ~70% Aussteuerung) zur getrennten Beurteilung von:
    1. Signalpegel & akustische Reinheit ungefiltert vs. Biquad-Filterbank
    2. Filterdämpfung (gemessen via Hardware Capture $DFF802 / $DF8000)
    3. Initialer Pegelaufbau (25-Frame Soft-Ramp ohne DC-Sprung / Knacken)
    4. Register-Stabilität (kein 50-Hz-Zero-Muting, kein Zipper-Noise)

Ablauf des Tests (Gesamtdauer: ca. 22 Sekunden):
  1. [0:00 - 0:10] Phase 1: Ungefilterte Direktreferenz
     - Stimme 0 spielt den Track direkt an den Master-Mixer
     - Sanfter 0,5s-Ramp (25 Frames) von 0 auf Pegel $B0B0 (knacksfrei)
     - Jede Sekunde Hardware-Capture-Scan auf Peak (0..32767) und RMS
  2. [0:10 - 0:11] Pause (1.0 Sekunde Stille / Reset)
  3. [0:11 - 0:21] Phase 2: Durch die 32-Band Biquad-Filterbank
     - Stimme 0 als Träger mit exakt demselben Grundpegel $B0B0
     - Stimmen 1..31 in Vorstufen-Kaskade (Pre-Filter Cascade)
     - Sek 1..5: Vokal-Formantcluster (Bänder 12..16 um 676 Hz aktiv)
     - Sek 6..10: Vollband-Summensynthese (alle 32 Bänder aktiv)
     - Weiche Registerübergänge ohne hartes Frame-Wiping (kein Zipper-Noise)
     - Jede Sekunde Hardware-Capture-Scan auf Peak und RMS
  4. [0:21 - 0:22] Abschlussmatrix & Rückkehr zu AmigaDOS (RC: 0)
     - Tabellarische Gegenüberstellung von Direkt- vs. Filterpegel
     - Bestätigung von 0 DMA-Unterläufen und 0 Hardware-Clips

Ausführung unter AmigaDOS:
  filter_compare
