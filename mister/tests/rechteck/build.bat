@echo off
rem Baut rechteck aus Quelle und Datentabelle.
rem Voraussetzung: vasmm68k_mot.exe und vlink.exe im PATH.

if exist rechteck.o del rechteck.o
if exist rechteck del rechteck

python gen_rechteck_data.py || goto :err
vasmm68k_mot -quiet -Fhunk -o rechteck.o rechteck.s || goto :err
vlink -bamigahunk -s -o rechteck rechteck.o || goto :err

echo.
echo Fertig: rechteck  (Amiga-Hunk-Executable)
echo Rechteck 200 Hz durch 32 Tiefpaesse a 300 Hz.
echo   gruen  -^> Ausgang ist ein Sinus, die Filter arbeiten
echo   rot    -^> Ausgang noch eckig, Filter greifen nicht
echo Hoerbar: ein weicher Sinus bei 200 Hz.
exit /b 0

:err
echo Fehler beim Bauen.
exit /b 1
