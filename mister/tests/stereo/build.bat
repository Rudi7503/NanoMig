@echo off
rem Baut stereotest aus Quelle und Datentabelle.
rem Voraussetzung: vasm/vbcc-Binaries im PATH (vasmm68k_mot.exe, vlink.exe).

if exist stereotest.o del stereotest.o
if exist stereotest del stereotest

python gen_stereo_data.py || goto :err

vasmm68k_mot -quiet -Fhunk -o stereotest.o stereotest.s || goto :err
vlink -bamigahunk -s -o stereotest stereotest.o || goto :err

echo.
echo Fertig: stereotest  (Amiga-Hunk-Executable)
echo Auf den MiSTer kopieren und starten. Erwartung:
echo   links 440 Hz, rechts 880 Hz  -^> Kanaltrennung arbeitet
echo   beide Seiten gleich          -^> Demux defekt
echo   nur eine Seite               -^> ein Kanal fehlt
exit /b 0

:err
echo Fehler beim Bauen.
exit /b 1
