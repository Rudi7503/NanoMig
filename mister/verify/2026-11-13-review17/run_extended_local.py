"""Fuehrt Tobys Review17-Tests gegen unseren Stand aus.

Angepasst gegenueber run_extended.py:
  - iverilog aus dem Chocolatey-Pfad
  - RTL aus dem NanoMig-Repo statt aus einem lokalen Kopiebaum
  - der Testbench-Pfad kommt aus dem entpackten Paket

Aufruf:
    python run_extended_local.py <paketordner> <repo-wurzel>
"""
import subprocess
import sys
from pathlib import Path

PKG = Path(sys.argv[1])
REPO = Path(sys.argv[2])
IV = Path('C:/ProgramData/chocolatey/bin/iverilog.exe')
VVP = Path('C:/ProgramData/chocolatey/bin/vvp.exe')
RTL = REPO / 'mister' / 'rtl' / 'sprite_engine'
TB = PKG / 'extended_tb.v'

jobs = [
    ('published18',            'tb_sprite_engine', REPO / 'mister/verify/testbenches/tb_sprite_engine.v', None),
    ('burst_consumer',         'extended_tb',      TB, 1),
    ('descriptor_bl4',         'extended_tb',      TB, 2),
    ('palette_write',          'extended_tb',      TB, 3),
    ('clut_palette',           'palette_tb',       TB, None),
    ('capture_complete',       'capture_tb',       TB, 1),
    ('capture_one_read',       'capture_tb',       TB, 2),
    ('descriptor_gapped_tail', 'extended_tb',      TB, 4),
    ('capture_pixel_snapshot', 'capture_tb',       TB, 3),
]

results = []
for name, top, tb, case in jobs:
    image = PKG / (name + '.vvp')
    cmd = [str(IV), '-g2012', '-s', top, '-o', str(image), str(tb)]
    cmd += [str(f) for f in sorted(RTL.glob('*.v'))]
    c = subprocess.run(cmd, capture_output=True, text=True)
    output = c.stdout + c.stderr
    rc = c.returncode
    if rc == 0:
        cmd2 = [str(VVP), str(image)] + ([] if case is None else ['+CASE=' + str(case)])
        try:
            r = subprocess.run(cmd2, capture_output=True, text=True, timeout=60)
            output += r.stdout + r.stderr
            rc = r.returncode
        except subprocess.TimeoutExpired:
            output += '\nTIMEOUT'
            rc = 99
    failed = bool(rc or 'FATAL:' in output or '[FAIL]' in output or 'FAILURES DETECTED' in output)
    results.append((name, rc, failed, output))
    print(name + ': ' + ('FAIL' if failed else 'PASS'))

print()
print('=== Zusammenfassung ===')
bad = [n for n, _, f, _ in results if f]
print('bestanden: %d / %d' % (len(results) - len(bad), len(results)))
if bad:
    print('fehlgeschlagen: ' + ', '.join(bad))
    for n, rc, f, out in results:
        if f:
            print('\n--- ' + n + ' ---')
            print('\n'.join(out.strip().splitlines()[-6:]))
