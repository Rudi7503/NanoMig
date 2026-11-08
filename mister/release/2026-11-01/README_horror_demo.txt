==============================================================================
NanoMig / Minimig-AGA: "GOTHIC HORROR" Audio Engine & Horror Testcase
==============================================================================

Datei:        horror_demo
Dateigröße:   24028 Bytes
SHA-256:      9765ba99ade79dc3f0f7cf04abe21b2e9005b7163e2f9918b9859fe0731c854f
Plattform:    MiSTer FPGA DE10-Nano (Minimig-AGA Core Minimig_9f4914f0 / rudi/chain-stereo)
System:       AmigaOS Kickstart 1.3 oder 3.x (CLI / AmigaDOS)

Überblick & Features:
---------------------
Dieses Testprogramm demonstriert alle Audio- und Hardware-Features des neuen
32-Kanal Audio-Systems in einer zusammenhängenden Gothic-Horror-Szene:

1. ACT I: DIE SCHRITTE IM LANGEN SCHLOSSFLUR
   - 6 bedrohliche, näherkommende Schritte (16-Bit Big-Endian PCM).
   - Multi-Tap Korridor-Echo über Hardware Start-Delay ($DFF41C, 32.768 kHz)
     mit 150 ms, 300 ms und 450 ms Reflexionen ohne zusätzlichen CPU- oder RAM-Bedarf!
   - Biquad IIR Tiefpassfilter auf den Echo-Taps zur Nachbildung der akustischen
     Wandabsorption in langen Steinfluren.
   - Panning wandert dynamisch von links nach rechts durch den Flur.

2. ACT II: DAS GEHEULE DURCH DIE LANGEN FLURE
   - Heulender Sturmwind über 24 dB/Okt kaskadierte Moog-Filter (CTRL_SRC_POST, $0400).
   - Sanfte Resonanz-Sweeps ohne Mikroknacken.
   - Geisterhaftes Wimmern und metallisches Kreischen über Hardware-Ringmodulation
     (CTRL_MOD_RING, $1000).
   - Vorstufen mit CTRL_MUTE_MIX ($2000) im Master-Mix stummgeschaltet.
   - Im Bild: Schlossflur-Pfeiler mit flackerndem Fackellicht und finstere Vampirgestalt
     mit leuchtend roten Augen.

3. ACT III: DER SCHWARM DER 32 FLEDERMÄUSE
   - Der Vampir löst sich auf und verwandelt sich in einen Schwarm von 32 Fledermäusen!
   - ALLE 32 HARDWARE-STIMMEN GLEICHZEITIG AKTIV (1 Stimme pro Fledermaus).
   - Fledermaus-Flügelschlagen über Hardware AM / Tremolo (CTRL_MOD_AM, $0800).
   - Ultraschall-Zirpen über Biquad IIR Hochpassfilter ($0180).
   - Dynamisches 3D-Stereo-Panning: Die Lautstärke (AUDxVOL) jeder der 32 Stimmen wird
     in Echtzeit an die Bildschirmposition (X, Y) der jeweiligen Fledermaus angepasst!
   - 22-Bit Master-Mixer Headroom (+36 dB) und zentraler 48-kHz True-Peak AGC Limiter
     verhindern jegliches Übersteuern.

4. ACT IV: DAS LACHENDE SKELETT
   - Hinter dem Fledermausschwarm wird im Torbogen ein finsteres Skelett sichtbar.
   - Dämonisches Gelächter ("MWA-HA-HA-HA!") in 5 Stufen.
   - Der Unterkiefer des Skeletts animiert synchron zu den Lachsalven auf und zu!
   - Vokale Formant-Synthese über Biquad-Bandpassfilter.
   - Hardware-Ringmodulation für dämonisches Knurren und Raspeln.
   - Korridor-Echo trägt das Lachen durch die unendlichen Gewölbe.
   - Mächtiger 16-Bit Subbass-Herzschlag auf Stimme 31.

5. ACT V: EPILOG & SAUBERER EXIT
   - Weiches Ausblenden aller 32 Stimmen.
   - Sauberer AmigaOS-Exit zur CLI mit Return Code 0.
   - Jederzeit abbrechbar mit linker Maustaste (LMB).

Ausführung im AmigaDOS:
-----------------------
1. 'horror_demo' auf die Amiga-Festplatte / Diskette kopieren.
2. In der AmigaDOS Shell aufrufen:
   1> horror_demo
3. Nach ca. 30 Sekunden kehrt das Programm automatisch sauber zur Shell zurück (RC: 0).
