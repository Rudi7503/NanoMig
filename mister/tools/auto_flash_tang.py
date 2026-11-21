#!/usr/bin/env python3
"""auto_flash_tang.py - Bitstream auf die Tang Console 138K flashen.

ZWECK
    Das JTAG-Fenster der Konsole ist nur kurz offen. Wer erst nach dem
    Einschalten von Hand flasht, bekommt "Gowin Device not found". Dieses
    Skript pollt deshalb im Kreis und schiesst los, sobald der Flash
    antwortet.

ABLAUF
    1. Konsole stromlos machen, Mode-Taste halten, USB-C anstecken.
    2. Dieses Skript starten. Es fragt alle 0,7 s die Flash-ID ab.
    3. Sobald eine ID kommt, flasht es sofort den Bitstream.
    4. Auf Wunsch danach das Kickstart-ROM an 0x600000.

AUFRUF
    python auto_flash_tang.py --fs nanomig_tc138k_spr.fs
    python auto_flash_tang.py --fs nanomig_tc138k_spr.fs --kick kick13.bin

OPTIONEN
    --fs      Bitstream (.fs), wird mit -r 53 an 0x000000 geschrieben
    --kick    Kickstart (.bin), wird mit -r 55 --mcuFile an 0x600000
              geschrieben; ohne Angabe wird das ROM nicht angefasst
    --cable   Kabelname (Standard "Gowin USB Cable(FT2CH)")
    --device  Baustein (Standard GW5AST-138C)
    --timeout Gesamtzeit fuer das Warten auf JTAG in Sekunden (Standard 120)
    --interval Wartezeit zwischen zwei Abfragen (Standard 0,7 s)

AUSGABE
    [WAIT]        JTAG noch nicht offen
    [JTAG_OK]     Flash antwortet, ID wird ausgegeben
    [FLASH_OK]    Bitstream geschrieben (Dauer wird angezeigt)
    [FLASH_FAIL]  Schreiben fehlgeschlagen, Exit 1
    [TIMEOUT]     JTAG-Fenster nicht erwischt, Exit 2

WARUM EIN PYTHON-SKRIPT
    Der Aufruf muss im richtigen Moment passieren. Von Hand ist das
    praktisch nicht zu treffen - belegt am 2026-11-13 (siehe
    .agent/rules/nanomig-lessons.md, Punkt 11).

STAND
    aktiv. Neu angelegt 2026-11-13.
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path

try:
    import winsound
except Exception:
    winsound = None


def beep(freq, ms, mal=1, pause=0.08):
    """Signalton - man hoert am Gerät, was der Rechner gerade tut."""
    if winsound is None:
        return
    for i in range(mal):
        try:
            winsound.Beep(int(freq), int(ms))
        except Exception:
            pass
        if i + 1 < mal:
            time.sleep(pause)

CLI = Path(r'C:\Gowin\Gowin_V1.9.12.04_x64\Programmer\bin\programmer_cli.exe')


def run(args, timeout=180):
    """programmer_cli aufrufen, Ausgabe und Rueckgabewert zurueckgeben."""
    proc = subprocess.run([str(CLI)] + args, capture_output=True, text=True,
                          timeout=timeout)
    return proc.returncode, (proc.stdout or '') + (proc.stderr or '')


def probe_flash(cable, device):
    """Flash-ID abfragen. True, wenn der Flash antwortet."""
    rc, out = run(['--cable', cable, '--device', device, '--run', '51'], timeout=20)
    if 'Flash id' in out or 'Flash ID' in out:
        return True, out
    if rc == 0 and 'Detected' in out:
        return True, out
    return False, out


def main():
    ap = argparse.ArgumentParser(description='Tang Console 138K flashen, sobald JTAG offen ist')
    ap.add_argument('--fs', required=True, help='Bitstream (.fs)')
    ap.add_argument('--kick', default=None, help='Kickstart (.bin), optional')
    ap.add_argument('--cable', default='Gowin USB Cable(FT2CH)')
    ap.add_argument('--device', default='GW5AST-138C')
    ap.add_argument('--timeout', type=int, default=120)
    ap.add_argument('--interval', type=float, default=0.7)
    ap.add_argument('--settle', type=float, default=3.0, help='Wartezeit nach JTAG_OK, bevor geschrieben wird')
    ap.add_argument('--tries', type=int, default=2, help='Schreibversuche innerhalb eines JTAG-Fensters')
    args = ap.parse_args()

    fs = Path(args.fs).resolve()   # programmer_cli braucht einen absoluten Pfad
    if not fs.exists():
        print('[FEHLER] Bitstream nicht gefunden: %s' % fs)
        return 1
    print('[START] Bitstream: %s (%d Bytes)' % (fs.name, fs.stat().st_size))

    deadline = time.time() + args.timeout
    last_note = ''
    while True:
        ok, out = probe_flash(args.cable, args.device)
        if ok:
            ident = [ln.strip() for ln in out.splitlines() if 'Flash' in ln or 'Detected' in ln]
            beep(1200, 120, 1)   # JTAG offen: ein hoher Ton
            print('[JTAG_OK] %s' % (' | '.join(ident[:2]) if ident else 'Flash antwortet'))
            if args.settle > 0:
                print('[SETTLE] %.1f s warten, damit die Verbindung steht' % args.settle)
                time.sleep(args.settle)
            break
        note = 'Device not found' if 'not found' in out else out.strip().splitlines()[-1:] or ['keine Antwort']
        note = note[0] if isinstance(note, list) else note
        if note != last_note:
            print('[WAIT] %s' % note)
            last_note = note
        if time.time() > deadline:
            beep(250, 700, 1)
            print('[TIMEOUT] JTAG-Fenster nicht erwischt')
            return 2
        time.sleep(args.interval)

    # Bitstream schreiben
    rc = 1
    for versuch in range(1, args.tries + 1):
        t0 = time.time()
        rc, out = run(['--cable', args.cable, '--device', args.device,
                       '--run', '53', '--fsFile', str(fs), '--spiaddr', '0x000000'])
        dauer = time.time() - t0
        if 'finished' in out.lower() and rc == 0:
            beep(900, 120, 3)
            print('[FLASH_OK] Bitstream geschrieben in %.1f s' % dauer)
            break
        print('[FLASH_TRY%d] rc=%d nach %.1f s' % (versuch, rc, dauer))
        if versuch < args.tries:
            print('[RETRY] neuer Versuch')
            time.sleep(1.0)
    else:
        beep(300, 500, 1)
        print('[FLASH_FAIL] rc=%d' % rc)
        print(chr(10).join(out.strip().splitlines()[-6:]))
        return 1

    # Kickstart optional
    if args.kick:
        rom = Path(args.kick).resolve()
        if not rom.exists():
            print('[FEHLER] Kickstart nicht gefunden: %s' % rom)
            return 1
        t0 = time.time()
        rc, out = run(['--cable', args.cable, '--device', args.device,
                       '--run', '55', '--mcuFile', str(rom), '--spiaddr', '0x600000'])
        dauer = time.time() - t0
        if 'finished' in out.lower() and rc == 0:
            beep(1400, 150, 2)
            print('[KICK_OK] %s nach 0x600000 in %.1f s' % (rom.name, dauer))
        else:
            print('[KICK_FAIL] rc=%d' % rc)
            print('\n'.join(out.strip().splitlines()[-6:]))
            return 1

    print('[FERTIG] Konsole stromlos machen und neu einschalten.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
