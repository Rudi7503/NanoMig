@echo off
set PATH=C:\Users\Papa\.vscode\extensions\prb28.amiga-assembly-1.8.13\resources\bin\win32;C:\Users\Papa\AppData\Local\Temp\vbcc\vbcc\bin;%PATH%
if exist argon_demo.o del argon_demo.o
if exist argon_demo del argon_demo
python gen_argon_data.py || goto :err
python ..\..\tools\lint_m68k.py argon_demo.s || goto :err
vasmm68k_mot -quiet -Fhunk -o argon_demo.o argon_demo.s || goto :err
vlink -bamigahunk -x -Bstatic -o argon_demo argon_demo.o || goto :err
echo Fertig: argon_demo (1-Minute Extended-HAM04 und 32-Channel DSP Grand Demo)
exit /b 0
:err
echo Fehler beim Bauen.
exit /b 1
