# Pull Request: 32-Voice High-Definition Audio Pipeline, Chain-Stereo & Multi-Format Fixes

## Was ändert dieser PR

Dieser PR behebt fundamentale Fehler im erweiterten Audio-Subsystem (`audio_ext` und `biquad_iir_ringbuffer`):
1. **32-Bit-Frames dekodierbar**: Stereo-Frames (16 Bit L/R) führten zum Deadlock, da der Zähler `v_bc` auf 5 Bit begrenzt war (max 31) und 32 Bit nie erreichte. Zähler auf 6 Bit erweitert, Nachfüllbedingung korrigiert.
2. **Echte Kanaltrennung (L ≠ R)**: Interleaved Stereo trennt linken und rechten Kanal sauber; der ADPCM-Index wurde in `sdpb_timer_bc[9:3]` verschoben.
3. **Filter-DSPs nach Kanal getrennt**: DSP 0 filtert links, DSP 1 filtert rechts über alle 32 Stimmen (beseitigt Übersprechen/Monoverhalten).
4. **Koeffizienten im Block-RAM**: Ganzwort-Zugriff statt Split-Byte-Schreiben spart 2.655 ALMs.
5. **Gestoppte Stimmen stumm**: Lautstärkefaktor mutet Stille ohne Verfälschung des Dekodierzustands.
6. **Frühes Nachladen bei Audio-Loops**: DMA fordert neue Daten an, sobald der Pufferbedarf entsteht, verhindert FIFO-Unterlauf (Idle 11,7% -> 0,1%).
7. **Fester Ring-Scheduler**: Deterministische Reihenfolge (0..31) garantiert synchrone Pipeline-Stufen.
8. **Kette stereo-fähig**: Vier Register statt zwei führen L und R getrennt durch die Kaskade.
9. **Option A Register-Layout**: Globale Interrupt-Register liegen sauber bei `$DFF804..$DFF80A`. Kanal 31 ist vollständig von Überlappungen befreit (alle 32 Kanäle bieten identische Register inkl. $a_2$, Delay und CMD).
10. **Echtes Stereo AM & Ringmod**: Linker und rechter Modulator-Kanal modulieren getrennt links und rechts.

## Basis

- Basis-Commit: `2e3ed1e` (main)
- Head-Branch: `rudi/chain-stereo`
- Betroffene RTL-Dateien:
  - `mister/rtl/audio_ext/audio_ext.v`
  - `mister/rtl/audio_ext/biquad_iir_ringbuffer.v`
  - `mister/rtl/audio_ext/adpcm_decoder_shared.v`
  - `mister/rtl/minimig.v`

## Belege — was ist geprüft

- [x] **Simulation (Icarus Verilog)**:
  - `tb_integrated.v`: Mono-Regression Stimmen 0/16/30 identisch zu main (bis auf 32 Takte Anlauf).
  - `tb_32_voices_stereo.v`: 201.763 Samples, 100% mit L ≠ R.
  - `tb_stop.v`: Stummschaltung bestätigt (nur 52 Takte Pipeline-Auslauf aktiv).
  - `tb_starve.v`: FIFO-Leerlauf bei Loop von 11,7% auf 0,1% gesenkt.
  - `tb_32_voices_chain.v`: Ketten-Stereo von 0,7% auf 100% L ≠ R.
  - `verify_adpcm.py` / `tb_adpcm_ref.v`: 51.240 Stimuli inkl. 48.000 Samples Apollo-ADPCM gegen Python-Referenz bitgenau verifiziert (0 Fehler).
  - `tb_opt_a_irq.v`: Option A Global IRQ ($DFF804) und Kanal-31-Vollfunktionalität (Koeffizient a2, Start-Delay, CMD) verifiziert.
- [x] **Synthese (Quartus 25.1std)**:
  - Vollständiger Build erfolgreich (Bitstream `Minimig_c106117b.rbf`, 4.123.036 Bytes, SHA256 `c106117b119706c13430087b5fa0649b54cfe63a2588c7ba707ad3151f4e482d`).
  - Ressourcen: ALMs von 38.355 auf 36.152 gesenkt (-2.203 ALMs, 86%), 49.741 Register, M10K BRAM 327 -> 330 (+3, 60%), DSP 75 (67%, unverändert).
- [x] **Timing**:
  - Seed 11: Setup -0,538 ns (Slow 100C), Hold +0,252 ns (Slow -40C).
  - Timing-Engpass liegt unverändert in Minimig-Altlast (`paula_floppy_fifo` -> `sdram_ctrl`), nicht im Audio-Pfad (Audiofilter hat > 17 ns Slack).

## Ausdrücklich NICHT geprüft

- Hardware-Verifikation auf MiSTer steht aktuell noch aus (Hardwaretest mit den 7 Amiga-Testprogrammen und Bitstream `Minimig_c106117b.rbf` durch Toby / Tobys KI ist für 7:00 Uhr morgens via GitHub Issue #9 vereinbart; Testergebnisse werden bei Vorliegen nachgetragen).

## Auswirkung

- **Wiedergabepfad**: Stereo-PCM, ADPCM, Filter-Kaskadierung und Ringpufferung voll funktionsfähig und jitterfrei.
- **Ressourcen**: -2.261 ALMs Einsparung im Gesamtcore.
- **Register-/Speicher-Interface**: Rückwärtskompatibel zu Minimig-AGA; Registerbelegung gemäß Dokumentation.
