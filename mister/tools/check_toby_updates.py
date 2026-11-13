#!/usr/bin/env python3
"""check_toby_updates.py - meldet neue Beitraege von Tobys KI (toby01019).

ZWECK
    Prueft alle Kanaele, auf denen Toby's KI antworten kann, und gibt neue
    Beitraege auf der Konsole aus. Gedacht fuer einen periodischen Aufruf
    (geplanter Auftrag, Cron, Watcher).

KANAELE
    1. Kommentare unter Issue #9 und #10
    2. Kommentare unter Pull Request #11
    3. Inline-Review-Kommentare am Diff von PR #11
    4. Formale Reviews von PR #11 (APPROVED / CHANGES_REQUESTED / COMMENTED)

    Punkt 3 und 4 liegen auf anderen Endpunkten als normale Kommentare.
    Wer nur /issues/comments abfragt, verpasst jedes zeilenweise Review.

AUFRUF
    python mister/tools/check_toby_updates.py
    python mister/tools/check_toby_updates.py --pr 11 --issues 9,10 --minutes 60
    python mister/tools/check_toby_updates.py --minutes 20 --out "%LOCALAPPDATA%\\dsh-toby\\news.txt"

    Mit --out wird das Ergebnis zusaetzlich in eine Datei geschrieben, und
    zwar nur dann, wenn es etwas Neues gibt. Damit kann ein Zeitplan den
    Aufruf uebernehmen, ohne dass jemand den Bildschirmausgabe lesen muss:
    Es entsteht nur eine Datei, wenn Toby wirklich geschrieben hat.

    Mit --watch laeuft das Skript in einer Schleife und beendet sich beim
    ersten Treffer. Als DSH-Hintergrundauftrag gestartet ist das die
    sparsamste Bauart: solange Toby schweigt, laeuft es ohne Tokenverbrauch,
    und beim Treffer endet der Auftrag - das ist das Signal an den Agenten.

AUSGABE
    [SILENT_NO_UPDATE]            nichts Neues, Exit 0
    [NEW_UPDATE_FOUND]            gefolgt von den Beitraegen, Exit 0
    [CHECK_ERROR] <grund>         Netz-/Tokenfehler, Exit 1

BEWUSST ZUSTANDSLOS
    Das Skript schreibt keine Datei. Es fragt nur Beitraege ab, die juenger
    als --minutes sind (Standard 120). Damit funktioniert es auch dort, wo
    der Prozess nicht schreiben darf, und es gibt keinen Zustand, der
    veralten oder mit falschen Rechten haengen bleiben kann.

    Frueher lag hier eine toby_monitor_state.json. Die ist auf diesem
    Rechner schreibgeschuetzt und wird nicht mehr verwendet.

VORAUSSETZUNG
    Ein GitHub-Token in `git credential` (protocol=https, host=github.com).
    Ohne Token funktioniert es lesend, aber mit niedrigerem Rate-Limit.
    Das Passwort der Austausch-Konfiguration wird NICHT gebraucht.

STAND
    aktiv, ersetzt die fruehere Fassung mit Zustandsdatei. Die alte Fassung
    beobachtete nur Issue-Kommentare auf #9/#10 und uebersah damit
    PR-Reviews vollstaendig.
"""
import argparse
import datetime
import json
import subprocess
import sys
import time
import urllib.request

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

REPO = 'Rudi7503/NanoMig'
API = 'https://api.github.com/repos/' + REPO
AUTHOR = 'toby01019'


def get_token():
    try:
        p = subprocess.Popen(['git', 'credential', 'fill'],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        out, _ = p.communicate('protocol=https\nhost=github.com\n')
        for line in out.splitlines():
            if line.startswith('password='):
                return line.split('=', 1)[1]
    except Exception:
        pass
    return None


def fetch(url, token):
    headers = {'User-Agent': 'dsh-agent', 'Accept': 'application/vnd.github+json'}
    if token:
        headers['Authorization'] = 'token ' + token
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=20) as r:
        data = json.loads(r.read().decode('utf-8'))
    if data is None:
        return []
    if isinstance(data, dict):
        return [data]
    return [c for c in data if c is not None]


def parse_ts(value):
    if not value:
        return None
    try:
        return datetime.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ')
    except Exception:
        return None


def build_channels(pr, issues, since_iso):
    ch = []
    for n in issues:
        ch.append(('issue-%d' % n,
                   API + '/issues/%d/comments?per_page=50&since=%s' % (n, since_iso),
                   '/issues/%d' % n))
    ch.append(('pr-%d-kommentar' % pr,
               API + '/issues/%d/comments?per_page=50&since=%s' % (pr, since_iso), None))
    ch.append(('pr-%d-diff-kommentar' % pr,
               API + '/pulls/%d/comments?per_page=50' % pr, None))
    ch.append(('pr-%d-review' % pr,
               API + '/pulls/%d/reviews?per_page=50' % pr, None))
    return ch


def describe(kind, item):
    user = (item.get('user') or {}).get('login')
    ts = item.get('created_at') or item.get('submitted_at')
    out = ['=== %s von %s  %s ===' % (kind, user, ts)]
    if item.get('path'):
        out.append('Datei: %s  Zeile: %s' % (item.get('path'), item.get('line')))
    if item.get('state'):
        out.append('Review-Status: %s' % item.get('state'))
    out.append('--- INHALT ---')
    out.append((item.get('body') or '').strip())
    out.append('=' * 60)
    return '\n'.join(out)


def collect(args):
    """Einmal pruefen. Rueckgabe: Liste (Kanal, Beitrag) oder None bei Fehler."""
    issues = [int(x) for x in args.issues.split(',') if x.strip()]
    cutoff = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) - datetime.timedelta(minutes=args.minutes)
    since_iso = cutoff.strftime('%Y-%m-%dT%H:%M:%SZ')
    token = get_token()

    found = []
    for name, url, issue_filter in build_channels(args.pr, issues, since_iso):
        try:
            items = fetch(url, token)
        except Exception as exc:
            print('[CHECK_ERROR] %s: %s' % (name, exc))
            return None
        for it in items:
            if (it.get('user') or {}).get('login') != AUTHOR:
                continue
            if issue_filter and issue_filter not in (it.get('issue_url') or ''):
                continue
            ts = parse_ts(it.get('created_at')) or parse_ts(it.get('submitted_at'))
            if ts is None or ts < cutoff:
                continue
            found.append((name, it))
    return found


def report(args, found):
    """Gibt einen Treffer aus und schreibt ihn bei --out in die Datei."""
    print('[NEW_UPDATE_FOUND]')
    text = []
    for name, item in sorted(found, key=lambda x: str(x[1].get('created_at') or x[1].get('submitted_at'))):
        block = describe(name, item)
        print(block)
        text.append(block)

    if args.out:
        try:
            target = os.path.expandvars(args.out)
            folder = os.path.dirname(target)
            if folder and not os.path.isdir(folder):
                os.makedirs(folder, exist_ok=True)
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')
            with open(target, 'a', encoding='utf-8') as f:
                f.write('\n##### %s  (%d neue Beitraege)\n' % (stamp, len(text)))
                f.write('\n'.join(text))
                f.write('\n')
        except Exception as exc:
            print('[CHECK_ERROR] --out nicht schreibbar: %s' % exc)


def main():
    ap = argparse.ArgumentParser(description='Neue Beitraege von Tobys KI melden')
    ap.add_argument('--pr', type=int, default=11, help='Nummer des Pull Requests (Standard 11)')
    ap.add_argument('--issues', default='9,10', help='Komma-Liste der Issues (Standard 9,10)')
    ap.add_argument('--minutes', type=int, default=120, help='Zeitfenster in Minuten (Standard 120)')
    ap.add_argument('--out', default=None,
                    help='Datei, in die neue Beitraege geschrieben werden (nur bei Treffer)')
    ap.add_argument('--watch', type=int, default=0, metavar='SEKUNDEN',
                    help='In einer Schleife pruefen und beim ersten Treffer enden')
    args = ap.parse_args()

    if not args.watch:
        found = collect(args)
        if found is None:
            return 1
        if not found:
            print('[SILENT_NO_UPDATE]')
            return 0
        report(args, found)
        return 0

    # Schleifenbetrieb: ruhig bleiben, bis Toby schreibt.
    print('[WATCH_START] Intervall %d s, Zeitfenster %d min' % (args.watch, args.minutes),
          flush=True)
    rounds = 0
    while True:
        rounds += 1
        found = collect(args)
        if found is None:
            # Netzfehler sind kein Ereignis - weiter warten.
            time.sleep(args.watch)
            continue
        if found:
            print('[WATCH_HIT] nach %d Runden' % rounds, flush=True)
            report(args, found)
            return 0
        if rounds % 120 == 0:
            # Lebenszeichen jede Stunde, damit man sieht: laeuft noch.
            print('[WATCH_ALIVE] %d Runden' % rounds, flush=True)
        time.sleep(args.watch)


if __name__ == '__main__':
    sys.exit(main())
