#!/usr/bin/env python3
"""
toby_chat.py - Automatisierter Client fuer Tobys Projektchat

Verbindungsspezifikation:
  Base URL: https://toby-homepage.tluhtmntkwexale3.myfritz.net
  Auth: HTTPS Basic Auth
  GET /austausch/api/chat?after={next}&limit=100
  POST /austausch/api/chat
    Headers:
      Content-Type: application/json
      X-Exchange-Chat: 1
      Origin: https://toby-homepage.tluhtmntkwexale3.myfritz.net
    Payload:
      {"text": str, "topic": "sprite"|"audio"|"allgemein", "client_id": uuid}
"""

import sys
import os
import json
import uuid
import base64
import urllib.request
import urllib.error
import ssl

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, 'austausch_config.json')
STATE_FILE = os.path.join(SCRIPT_DIR, 'chat_state.json')
BASE_URL = 'https://toby-homepage.tluhtmntkwexale3.myfritz.net'

def load_config():
    # 1. Environment variables
    user = os.environ.get('AUSTAUSCH_USER')
    password = os.environ.get('AUSTAUSCH_PASS')
    if user and password:
        return {'user': user, 'password': password}

    # 2. Local config file
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
                cfg = json.load(f)
                if cfg.get('user') and cfg.get('password'):
                    return cfg
        except Exception as e:
            print(f"[WARN] Konnte {CONFIG_FILE} nicht laden: {e}")

    return None

def load_state():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            pass
    return {'next_cursor': 0, 'last_messages': []}

def save_state(state):
    with open(STATE_FILE, 'w', encoding='utf-8') as f:
        json.dump(state, f, indent=2, ensure_ascii=False)

def get_auth_header(cfg):
    user_pass = f"{cfg['user']}:{cfg['password']}".encode('utf-8')
    token = base64.b64encode(user_pass).decode('ascii')
    return f"Basic {token}"

def get_ssl_context():
    ctx = ssl.create_default_context()
    # If self-signed or internal Fritzbox cert
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx

def fetch_messages():
    cfg = load_config()
    if not cfg:
        print("[AUTH_REQUIRED] Bitte Zugangsdaten in austausch_config.json oder Umgebungsvariablen hinterlegen!")
        return []

    state = load_state()
    next_cursor = state.get('next_cursor', 0)
    all_new_messages = []

    has_more = True
    while has_more:
        url = f"{BASE_URL}/austausch/api/chat?after={next_cursor}&limit=100"
        headers = {
            'User-Agent': 'NanoMig-Agent/1.0',
            'Authorization': get_auth_header(cfg),
            'Accept': 'application/json'
        }
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, context=get_ssl_context(), timeout=15) as resp:
                data = json.loads(resp.read().decode('utf-8'))
        except urllib.error.HTTPError as e:
            if e.code == 401:
                print("[AUTH_FAILED] HTTP 401: Ungueltiger Benutzername oder Passwort fuer den Austausch-Zugang!")
            else:
                print(f"[HTTP_ERROR] {e.code}: {e.read().decode('utf-8', errors='replace')}")
            return []
        except Exception as e:
            print(f"[NET_ERROR] {e}")
            return []

        msgs = data.get('messages', [])
        all_new_messages.extend(msgs)
        next_cursor = data.get('next', next_cursor)
        has_more = data.get('has_more', False)

    if all_new_messages:
        print(f"[NEUE_NACHRICHTEN] {len(all_new_messages)} neue Nachricht(en) empfangen:")
        for m in all_new_messages:
            author = m.get('author', m.get('user', 'Unbekannt'))
            ts = m.get('created_at', m.get('timestamp', ''))
            topic = m.get('topic', 'allgemein')
            text = m.get('text', m.get('message', '')).strip()
            print(f"[{ts}] [{topic}] {author}: {text}")
        state['next_cursor'] = next_cursor
        state['last_messages'].extend(all_new_messages[-50:])
        save_state(state)
    else:
        print("[KEINE_NEUEN_NACHRICHTEN]")

    return all_new_messages

def send_message(text, topic='sprite', client_id=None):
    cfg = load_config()
    if not cfg:
        print("[AUTH_REQUIRED] Bitte Zugangsdaten in austausch_config.json oder Umgebungsvariablen hinterlegen!")
        return False

    if not client_id:
        client_id = str(uuid.uuid4())

    url = f"{BASE_URL}/austausch/api/chat"
    headers = {
        'User-Agent': 'NanoMig-Agent/1.0',
        'Authorization': get_auth_header(cfg),
        'Content-Type': 'application/json',
        'X-Exchange-Chat': '1',
        'Origin': BASE_URL
    }
    payload = {
        'text': text[:4000],
        'topic': topic,
        'client_id': client_id
    }
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(url, data=data, headers=headers, method='POST')

    try:
        with urllib.request.urlopen(req, context=get_ssl_context(), timeout=15) as resp:
            res = json.loads(resp.read().decode('utf-8'))
            print(f"[GESENDET] Nachricht erfolgreich im Chat gepostet (Topic: {topic}, Status: {resp.status})")
            return True
    except urllib.error.HTTPError as e:
        if e.code == 401:
            print("[AUTH_FAILED] HTTP 401: Ungueltiger Benutzername oder Passwort!")
        else:
            print(f"[HTTP_ERROR] {e.code}: {e.read().decode('utf-8', errors='replace')}")
        return False
    except Exception as e:
        print(f"[NET_ERROR] {e}")
        return False

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Verwendung: python toby_chat.py [fetch | send <topic> <text> | test]")
        sys.exit(1)

    cmd = sys.argv[1].lower()
    if cmd == 'fetch':
        fetch_messages()
    elif cmd == 'send':
        if len(sys.argv) < 4:
            print("Verwendung: python toby_chat.py send <topic> <text>")
            sys.exit(1)
        topic = sys.argv[2]
        text = ' '.join(sys.argv[3:])
        send_message(text, topic=topic)
    elif cmd == 'test':
        fetch_messages()
    else:
        print(f"Unbekannter Befehl: {cmd}")
