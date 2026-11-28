@echo off
set PATH=C:\Users\Papa\AppData\Local\Temp\vbcc\vbcc\bin;%PATH%
if exist showcase_32ch.o del showcase_32ch.o
if exist showcase_32ch del showcase_32ch
python ..\..\tools\lint_m68k.py showcase_32ch.s || goto :err
vasmm68k_mot -quiet -Fhunk -o showcase_32ch.o showcase_32ch.s || goto :err
vlink -bamigahunk -x -Bstatic -o showcase_32ch showcase_32ch.o || goto :err
echo Fertig: showcase_32ch
exit /b 0
:err
echo Fehler beim Bauen von showcase_32ch.
exit /b 1
