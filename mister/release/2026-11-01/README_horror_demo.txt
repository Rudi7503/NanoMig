==============================================================================
NanoMig / Minimig-AGA: "GOTHIC HORROR" Audio Engine & Horror Testcase (V3)
==============================================================================

Datei:        horror_demo
Dateigröße:   24472 Bytes
SHA-256:      3ae00d0902fe64d20d9e80ea9a1388f36199a4795cec87a1119bf1efb3deb66b
Plattform:    MiSTer FPGA DE10-Nano (Minimig-AGA Core Minimig_9f4914f0 / rudi/chain-stereo)
System:       AmigaOS Kickstart 1.3 oder 3.x (CLI / AmigaDOS)
Laufzeit:     ca. 18 Sekunden (5 kompakte, klar abgegrenzte Akte)

Korrekturen in Version 3 (Gothic Flur-Bereinigung & Pfeiler-Schutz):
-------------------------------------------------------------------
1. Flur-Begrenzung & Wall-Bouncing: Fledermäuse fliegen strikt im Korridor
   (X: 52..250, Y: 16..180) und prallen an den gotischen Steinmauern sowie
   Decke/Boden realistisch ab (Richtungswechsel).
2. Pfeiler-Schutz: Plot_Bat_Draw und Plot_Bat_Erase clippen strikt auf den
   Mittelkorridor (X: 48..254). Die steinernen Gewölbepfeiler (Bytes 0..5 und
   34..39) können niemals mit Nullen ausgestanzt werden (beseitigt die schwarzen
   Rechtecke unten links).
3. Szenenwechsel Akt III -> Akt IV: Beim Übergang zum lachenden Skelett werden
   alle 32 Fledermäuse vollständig vom Bildschirm getilgt und das gotische Mauerwerk
   frisch aufgefrischt (Clear_Corridor_And_Refresh_Pillars).
4. Audio & Stabilität: Unverändert 100% sauber ("Sound durchgehend gut"),
   18 Sekunden Gesamtlaufzeit, saubere Rückkehr mit Return Code 0.

Korrekturen aus Version 2 (Kickstart 1.3 Verifikation):
------------------------------------------------------
1. Copper-Display: Vollständige DIWSTRT ($2C81), DIWSTOP ($F4C1), DDFSTRT ($0038),
   DDFSTOP ($00D0) und FMODE ($0000) Initialisierung für saubere 320x200 Lowres.
2. Sprites: Alle 8 Sprite-Zeiger im Copper auf Null gesetzt (beseitigt die störenden
   senkrechten Streifen und Balken am linken Rand).
3. 68000 Word-Alignment: Fledermaus-Plotting strikt auf gerade Wortgrenzen fixiert
   (behebt den 68000 Address-Error Crash / Hänger bei ungeraden Koordinaten).
4. Skelett/Kiefer: Bitplane-Register bereinigt und separate Ebenen-Indizierung.
5. VBL-Synchronisation: Auf robuste Zeile-256 Synchronisation umgestellt; jede Schleife
   besitzt eine harte Frame-Begrenzung (max. 18 Sekunden Gesamtlaufzeit).
6. Diagnose-Ausgabe: Jeder Akt meldet Start und sauberen Abschluss live auf die Konsole.

Überblick & Features:
---------------------
1. ACT I: DIE SCHRITTE IM LANGEN SCHLOSSFLUR (~4,0 s)
   - 5 bedrohliche, näherkommende Schritte (16-Bit Big-Endian PCM).
   - Multi-Tap Korridor-Echo über Hardware Start-Delay ($DFF41C, 32.768 kHz)
     mit 150 ms, 300 ms und 450 ms Reflexionen ohne zusätzlichen CPU- oder RAM-Bedarf!
   - Biquad IIR Tiefpassfilter auf den Echo-Taps zur Nachbildung der akustischen
     Wandabsorption in langen Steinfluren.
   - Panning wandert dynamisch von links nach rechts durch den Flur.

2. ACT II: DAS GEHEULE DURCH DIE LANGEN FLURE (~4,0 s)
   - Heulender Sturmwind über 24 dB/Okt kaskadierte Moog-Filter (CTRL_SRC_POST, $0400).
   - Sanfte Resonanz-Sweeps ohne Mikroknacken.
   - Geisterhaftes Wimmern und metallisches Kreischen über Hardware-Ringmodulation
     (CTRL_MOD_RING, $1000).
   - Vorstufen mit CTRL_MUTE_MIX ($2000) im Master-Mix stummgeschaltet.
   - Im Bild: Schlossflur-Pfeiler mit flackerndem Fackellicht und finstere Vampirgestalt
     mit leuchtend roten Augen.

3. ACT III: DER SCHWARM DER 32 FLEDERMÄUSE (~5,0 s)
   - Der Vampir löst sich auf und verwandelt sich in einen Schwarm von 32 Fledermäusen!
   - ALLE 32 HARDWARE-STIMMEN GLEICHZEITIG AKTIV (1 Stimme pro Fledermaus).
   - Fledermaus-Flügelschlagen über Hardware AM / Tremolo (CTRL_MOD_AM, $0800).
   - Ultraschall-Zirpen über Biquad IIR Hochpassfilter ($0180).
   - Dynamisches 3D-Stereo-Panning: Die Lautstärke (AUDxVOL) jeder der 32 Stimmen wird
     in Echtzeit an die Bildschirmposition (X, Y) der jeweiligen Fledermaus angepasst!
   - 22-Bit Master-Mixer Headroom (+36 dB) und zentraler 48-kHz True-Peak AGC Limiter
     verhindern jegliches Übersteuern.

4. ACT IV: DAS LACHENDE SKELETT (~4,4 s)
   - Hinter dem Fledermausschwarm wird im Torbogen ein finsteres Skelett sichtbar.
   - Dämonisches Gelächter ("MWA-HA-HA-HA!") in 5 Salven.
   - Der Unterkiefer des Skeletts animiert synchron zu den Lachsalven auf und zu!
   - Vokale Formant-Synthese über Biquad-Bandpassfilter.
   - Hardware-Ringmodulation für dämonisches Knurren und Raspeln.
   - Korridor-Echo trägt das Lachen durch die unendlichen Gewölbe.

5. ACT V: EPILOG & HARMONISCHES FADEOUT (~0,8 s)
   - Sanftes Ausblenden aller aktiven Stimmen ohne Nulldurchgangssprünge.
   - Sauberes Zurücksetzen der Audio-Hardware und Display-Register.
   - Saubere Rückkehr zu AmigaDOS mit Return Code 0.

Starten:
--------
   horror_demo

Im Fehlerfall:
--------------
Ein Abbruch per Mausklick (linke Maustaste) ist jederzeit möglich und stellt
die System-Displayanzeige sowie alle OS-Ressourcen sauber wieder her.
