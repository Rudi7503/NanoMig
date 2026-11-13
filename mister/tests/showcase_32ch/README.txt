MiSTer FPGA Minimig-AGA: 32-Channel Audio Showcase Demo
======================================================================
Target: Motorola 68000 / 68020 on MiSTer DE10-Nano (Core Minimig_22a912cc)

Titel:
  "Antigravity: The 32-Voice Hardware Renaissance"
  Gesamtlaufzeit: ca. 45 Sekunden (Abbruch jederzeit mit linker Maustaste)

Demonstrierte Hardware-Faehigkeiten von audio_ext.v:
  - 32 simultane Hardware-Stimmen (vollpolyphon)
  - Dual Biquad IIR DSP-Filter (24 dB kaskadierter Moog-Filter Sweep)
  - Hardware AM-Modulation (Tremolo) & Vier-Quadranten Ringmodulation
  - Sub-Millisekunden Hardware Start-Delay (AUD_DEL, 32.768 kHz)
  - Echtzeit-Farbskopie / Visualizer ueber Audio Capture Buffer ($DF8000)

Dramaturgischer Ablauf:
  [0:00 - 0:07] Szene 1: "THX Deep Note"
                31 Stimmen starten mit Zufallsfrequenzen und gleiten
                synchron in 16.16 Fixed Point in eine monumentale Harmonie!
  [0:07 - 0:38] Szene 2: "Cyberpunk 32-Kanal Synth Track"
                - Ch 0 & 1: 24 dB Moog Acid Bass (kaskadierte Biquad-Filter)
                - Ch 2 & 3: AM-modulierter Pluck Synth
                - Ch 4 & 5: Ringmodulations Space Bells
                - Ch 6..8:  Drums (Kick, Snare, HiHat mit Highpass-Filter)
                - Ch 21..30: 10-stimmiges warmes Breitwand-Pad mit Stereo-Spread
                - Ch 31:    Sub-Bass
  [0:38 - 0:42] Szene 3: Grand Finale & Reverb Fadeout in absolute Stille.

Kickstart 1.3 Shell-kompatibel, meldet sauberen Abschluss mit RC: 0.
