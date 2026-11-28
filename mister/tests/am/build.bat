@echo off
if exist am.o del am.o
if exist am del am
python gen_am_data.py || goto :err
vasmm68k_mot -quiet -Fhunk -o am.o am.s || goto :err
vlink -bamigahunk -s -o am am.o || goto :err
echo.
echo Fertig: am  (Amiga-Hunk-Executable)
echo 440 Hz, moduliert mit 2 Hz Traeger.
echo   gleichmaessiges Tremolo  -^> AM arbeitet
echo   konstant lauter Ton      -^> Modus wirkt nicht
exit /b 0
:err
echo Fehler beim Bauen.
exit /b 1