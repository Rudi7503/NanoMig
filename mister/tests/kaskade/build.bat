@echo off
rem Baut kaskade aus Quelle und Datentabelle.
rem Voraussetzung: vasmm68k_mot.exe und vlink.exe im PATH.

if exist kaskade.o del kaskade.o
if exist kaskade del kaskade

python gen_kaskade_data.py || goto :err
vasmm68k_mot -quiet -Fhunk -o kaskade.o kaskade.s || goto :err
vlink -bamigahunk -s -o kaskade kaskade.o || goto :err

echo.
echo Fertig: kaskade  (Amiga-Hunk-Executable)
echo 32 Stufen in Reihe, stereo, rund 384 dB/Oktave auf Rauschen.
echo   sehr dunkles Rauschen, Seiten verschieden -^> Kaskade arbeitet
echo   helles Rauschen wie vorher                -^> Filter greift nicht
echo   Pfeifen oder Brummen                      -^> Kaskade schwingt
echo   Stille                                    -^> keine Einspeisung
exit /b 0

:err
echo Fehler beim Bauen.
exit /b 1
