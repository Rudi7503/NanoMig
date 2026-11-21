@echo off
if exist adpcm.o del adpcm.o
if exist adpcm del adpcm
vasmm68k_mot -quiet -Fhunk -o adpcm.o adpcm.s || goto :err
vlink -bamigahunk -s -o adpcm adpcm.o || goto :err
echo Fertig: adpcm  (Amiga-Hunk-Executable, 1 s Musik im Loop)
exit /b 0
:err
echo Fehler beim Bauen.
exit /b 1