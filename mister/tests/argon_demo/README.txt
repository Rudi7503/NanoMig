======================================================================
ARGON ODYSSEY: EXTENDED-HAM04 & 32-CHANNEL DSP GRAND DEMO (30s VOCODER)
Target: MiSTer DE10-Nano / Minimig-AGA Core (minimig_22a912cc)
======================================================================

OVERVIEW:
Argon Odyssey is a flagship real-time demonstration (~1:18 min, 3896 frames)
showcasing the full hardware capabilities of the extended NanoMig FPGA:

1. Extended HAM04 Video Engine ($DFF800):
   - 24-bit TrueColor plasma and horizon gradients on 4 bitplanes.
   - Dynamic per-frame step modulation and live audio beat reactive pulse.
   - Live oscilloscope waveform rendering pure white Anchor 7 dots with
     decaying Delta comet trails directly from $DF8000 BRAM.
   - High-contrast, razor-sharp on-screen typography rendered in pure Anchor
     mode (BPL4=0: zero color-bleeding).

2. 32-Channel Audio Extension ($DFF400..$DFF7FE):
   - Act I   [0:00 - 0:10] (500 Frames):
             31-voice polyphonic Deep Note glide + Hardware zero-RAM start-delay
             ($DFF41C) + Voice 31 16-bit big-endian sine sub-bass.
   - Act II  [0:10 - 0:24] (696 Frames):
             Voices 0..1 cascaded into a 24 dB/oct Moog acid low-pass filter
             with LFO cutoff sweep + Voices 2..3 hardware AM pluck synth +
             Voices 4..5 hardware ring modulation space bells + synthesized drums.
   - Act III [0:24 - 0:54] (1500 Frames = 30.0s):
             Extended 30-Second Hardware Vocoder Showcase:
             * 10-Second 48 kHz 4-Bit Hardware ADPCM stream (240,000 Bytes).
             * Voices 1..31 pre-filter cascade through 32 logarithmic bandpass
               filters (50 Hz .. 16 kHz) with 0% extra DMA load.
             * 2.0s Fade-In (100 Frames): Smooth, click-free swelling volume.
             * 26.0s Bi-directional Wah-Wah Sweep starting at Band 14 (~676 Hz
               vocal formant) with warm baseline Voice 0 audio bed.
             * 2.0s Fade-Out (100 Frames): Smooth linear fade down to zero.
   - Act IV  [0:54 - 1:12] (900 Frames):
             32-Voice Cyber Symphony with 100% voice load: Moog bass + AM lead +
             Ringmod + Drums + 4x ADPCM chorus + 8x Arp brass + 10x Super-pad +
             16-bit sine sub-bass.
   - Act V   [1:12 - 1:18] (300 Frames):
             32-voice harmonic fadeout to verified digital silence.

3. Audio Capture Engine ($DF8000 / $DF9000 / $DFF802):
   - Double-buffered continuous audio capture (#$0003 / #$0005 handshake)
     feeds the live scope display and beat-reactive step modulation.

DIAGNOSTIC OUTPUT:
Run directly from AmigaCLI / Shell:
  argon_demo

Each scene prints clear timing, frame counts, and live measured audio
peak values from the capture buffer. At completion, a complete hardware
validation report is displayed with Return Code 0.

Press Left Mouse Button ($BFE001 bit 6) anytime to abort cleanly.
OS display and audio DMA are fully restored upon exit.
