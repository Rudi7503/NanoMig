ADPCM-Test
==========

Spielt echte ADPCM-Daten aus dem Apollo-Projekt ab.

Quelle
------
Rudi7503/my_crossdev, Projects/ADPCM_Decoder
  Kakao_bei_Lotte_Run17_4-Bit,Mono,LE.adpx   (738.561 Bytes, 30,8 s)

Dateiformat
-----------
  Bytes 0..3    "ADPX"
  Bytes 4..5    48000 Hz, big-endian
  Byte  8       Kanaele (1 = mono)
  Byte  9       Bits je Code (4)
  Bytes 21..    Codestrom, LSB-first gepackt

Hier liegen die ersten 24.000 Bytes des Codestroms = 48.000 Codes
= 1,0 s bei 48 kHz, unveraendert uebernommen (adpcm_4bit.bin).

Warum keine Umkodierung noetig ist
----------------------------------
Der Referenzdekoder liest:
    r |= ((b[pos>>3] >> (pos&7)) & 1) << i
also LSB-first aus dem Bytestrom.

Unser Reservoir macht dasselbe: be_fifo tauscht die Bytes eines Wortes,
danach wird ab v_bc geschoben, und der Code ist v_res[3:0] - erst das
niedrige Halbbyte, dann das hohe. Bei big-endian gespeicherten Daten ist
damit die Reihenfolge identisch.

Die Schrittweiten-Tabelle im RTL beginnt mit 7, 8, 9, 10, 11, 12, 13, 14,
16 ... und entspricht damit der Standard-IMA-Tabelle, die auch der Encoder
verwendet hat.

Erwartung
---------
Die Melodie ist hoerbar. Rauschen oder Zischen deutet auf falsche
Bitpackung oder eine abweichende Tabelle hin.

Bauen
-----
    build.bat     (braucht vasmm68k_mot und vlink im PATH)