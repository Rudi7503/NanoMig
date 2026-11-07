@echo off
set PATH=C:\Users\Papa\AppData\Local\Temp\vbcc\vbcc\bin;%PATH%
if exist filter_compare.o del filter_compare.o
if exist filter_compare del filter_compare
if exist filter_compare.zip del filter_compare.zip

python ..\..\tools\lint_m68k.py filter_compare.s || goto :err
vasmm68k_mot -quiet -Fhunk -o filter_compare.o filter_compare.s || goto :err
vlink -bamigahunk -x -Bstatic -o filter_compare filter_compare.o || goto :err
echo Fertig: filter_compare
exit /b 0

:err
echo Fehler beim Bauen von filter_compare.
exit /b 1
