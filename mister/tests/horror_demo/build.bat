@echo off
set PATH=C:\Users\Papa\.vscode\extensions\prb28.amiga-assembly-1.8.13\resources\bin\win32;C:\Users\Papa\AppData\Local\Temp\vbcc\vbcc\bin;%PATH%
if exist horror_demo.o del horror_demo.o
if exist horror_demo del horror_demo
python gen_horror_data.py || goto :err
python ..\..\tools\lint_m68k.py horror_demo.s || goto :err
vasmm68k_mot -quiet -Fhunk -o horror_demo.o horror_demo.s || goto :err
vlink -bamigahunk -x -Bstatic -o horror_demo horror_demo.o || goto :err
echo Fertig: horror_demo (Gothic Horror 32-Channel Audio Engine und Hallway Echo Testcase)
exit /b 0
:err
echo Fehler beim Bauen von horror_demo.
exit /b 1
