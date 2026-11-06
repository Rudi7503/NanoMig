======================================================================
ARGON ODYSSEY: 1-MINUTE EXTENDED-HAM04 & 32-CHANNEL DSP GRAND DEMO
Target: MiSTer DE10-Nano / Minimig-AGA Core (minimig_22a912cc)
======================================================================

OVERVIEW:
Argon Odyssey is a flagship 1-minute real-time demonstration showcasing
the full hardware capabilities of the extended NanoMig FPGA architecture:

1. Extended HAM04 Video Engine ($DFF800):
   - 24-bit TrueColor plasma and horizon gradients on 4 bitplanes.
   - Dynamic per-frame step modulation and live audio beat reactive pulse.
   - Live oscilloscope waveform rendering pure white Anchor 7 dots with
     decaying Delta comet trails.

2. 32-Channel Audio Extension ($DFF400..$DFF7FE):
   - Act I   [0:00 - 0:10]: 31-voice polyphonic Deep Note glide +
                            Hardware zero-RAM start-delay ($DFF41C) +
                            Voice 31 16-bit big-endian sine sub-bass.
   - Act II  [0:10 - 0:24]: Voices 0..1 cascaded into a 24 dB/oct Moog
                            acid low-pass filter with LFO cutoff sweep +
                            Voices 2..3 hardware AM pluck synth +
                            Voices 4..5 hardware ring modulation space bells +
                            Synthesized drums & Hi-Pass filtered hi-hat.
   - Act III [0:24 - 0:36]: Voice 0 48 kHz 4-bit hardware ADPCM stream +
                            Voices 1..31 pre-filter cascade (0% extra DMA)
                            through 32 logarithmic bandpass filters (Vocoder)
                            with bi-directional sweep and outside-in build.
   - Act IV  [0:36 - 0:54]: 32-Voice Cyber Symphony with 100% voice load:
                            Moog bass + AM lead + Ringmod + Drums +
                            4x ADPCM chorus + 8x Arp brass + 10x Super-pad +
                            16-bit sine sub-bass.
   - Act V   [0:54 - 1:00]: 32-voice harmonic fadeout to verified silence.

3. Audio Capture Engine ($DF8000 / $DF9000 / $DFF802):
   - Real-time double-buffered audio capture feeds the live scope display.
   - Continuous ping-pong capture with verified non-zero signal detection.

DIAGNOSTIC OUTPUT:
Run directly from AmigaCLI / Shell:
  argon_demo

Each scene prints clear timing, frame counts, and live measured audio
peak values from the capture buffer. At completion, a complete hardware
validation report is displayed with Return Code 0.

Press Left Mouse Button ($BFE001 bit 6) anytime to abort cleanly.
OS display and audio DMA are fully restored upon exit.
