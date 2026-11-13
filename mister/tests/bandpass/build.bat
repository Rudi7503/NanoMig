@echo off
rem Baut bandpass aus Quelle und Datentabelle.
if exist bandpass.o del bandpass.o
if exist bandpass del bandpass
python gen_bandpass_data.py || goto :err
vasmm68k_mot -quiet -Fhunk -o bandpass.o bandpass.s || goto :err
vlink -bamigahunk -s -o bandpass bandpass.o || goto :err
echo.
echo Fertig: bandpass  (Amiga-Hunk-Executable)
echo Rechteck 200 Hz durch 32 Bandpaesse a 1 kHz.
echo   gruen -^> 1 kHz Sinus, Bandpass arbeitet
echo   rot   -^> daneben
exit /b 0
:err
echo Fehler beim Bauen.
exit /b 1