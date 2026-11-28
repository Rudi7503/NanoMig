@echo off
rem Baut delay aus Quelle und Datentabelle.
if exist delay.o del delay.o
if exist delay del delay
python gen_delay_data.py || goto :err
vasmm68k_mot -quiet -Fhunk -o delay.o delay.s || goto :err
vlink -bamigahunk -s -o delay delay.o || goto :err
echo.
echo Fertig: delay  (Amiga-Hunk-Executable)
echo 32 Echos im 10-ms-Raster, je 10 Prozent leiser, One-Shot.
echo   gruen nach 0,5 s -^> Echos laufen
echo   blau  nach 2 s   -^> alles wieder still
exit /b 0
:err
echo Fehler beim Bauen.
exit /b 1