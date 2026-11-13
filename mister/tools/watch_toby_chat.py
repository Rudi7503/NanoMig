#!/usr/bin/env python3
"""
watch_toby_chat.py - Token-freier lokaler Hintergrund-Poller fuer Tobys Projektchat.
Prueft alle 120 Sekunden, ob neue Nachrichten von Toby / Tobys KI eingetroffen sind.
Beendet sich erst, wenn eine neue Nachricht von Toby empfangen wurde.
Verbraucht waehrend des Wartens keinerlei LLM-Tokens.
"""

import sys
import os
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.append(SCRIPT_DIR)
import toby_chat

POLL_INTERVAL_SECONDS = 120

print(f"[*] Token-freier Hintergrund-Watcher gestartet (Intervall: {POLL_INTERVAL_SECONDS}s).")
sys.stdout.flush()

while True:
    try:
        msgs = toby_chat.fetch_messages()
        # Filter nach Nachrichten, die nicht von uns (rudi) stammen
        toby_msgs = [m for m in msgs if m.get('author') != 'rudi']
        if toby_msgs:
            # Akustisches Signal ueber Windows-Audio abspielen
            try:
                import winsound
                winsound.PlaySound("SystemNotification", winsound.SND_ALIAS | winsound.SND_ASYNC)
                winsound.Beep(1046, 120)
                winsound.Beep(1318, 150)
                winsound.Beep(1568, 280)
            except Exception:
                pass

            print("\n[!] NEUE NACHRICHT VON TOBY / TOBYS KI EMPFANGEN:")
            for m in toby_msgs:
                author = m.get('author', 'Toby')
                ts = m.get('created_at', '')
                topic = m.get('topic', 'sprite')
                text = m.get('text', '').strip()
                print(f"[{ts}] [{topic}] {author}:\n{text}\n")
            sys.stdout.flush()
            sys.exit(0)
    except Exception as e:
        print(f"[!] Fehler bei Chat-Abfrage: {e}")
        sys.stdout.flush()

    time.sleep(POLL_INTERVAL_SECONDS)
