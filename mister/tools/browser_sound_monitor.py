#!/usr/bin/env python3
"""
browser_sound_monitor.py - Lokaler Web-Monitor mit Sound-Benachrichtigung fuer Tobys Projektchat.
Startet einen lokalen Webserver auf http://127.0.0.1:8088 und oeffnet die Seite im Browser.
Spielt bei jeder neuen Nachricht von Toby / Tobys KI einen akustischen Gong (Web Audio API)
und auf Windows zusaetzlich den System-Benachrichtigungston ab.
"""

import sys
import os
import time
import json
import threading
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.append(SCRIPT_DIR)
import toby_chat

HOST = '127.0.0.1'
PORT = 8088

# Shared state
chat_lock = threading.Lock()
cached_messages = []
new_events = []
last_seen_id = 0

def play_windows_chime():
    try:
        import winsound
        winsound.PlaySound("SystemNotification", winsound.SND_ALIAS | winsound.SND_ASYNC)
        winsound.Beep(1046, 120)
        winsound.Beep(1318, 150)
        winsound.Beep(1568, 280)
    except Exception:
        pass

def background_poller():
    global cached_messages, new_events, last_seen_id
    # Initial load of state
    state_file = os.path.join(SCRIPT_DIR, 'chat_state.json')
    if os.path.exists(state_file):
        try:
            with open(state_file, 'r', encoding='utf-8') as f:
                st = json.load(f)
                msgs = st.get('last_messages', [])
                if msgs:
                    last_seen_id = max(m.get('id', 0) for m in msgs)
                    with chat_lock:
                        cached_messages = msgs[-20:]
        except Exception:
            pass

    print("[*] Poller gestartet. Prueft alle 15 Sekunden...")
    while True:
        try:
            msgs = toby_chat.fetch_messages()
            toby_msgs = [m for m in msgs if m.get('author') != 'rudi']
            if toby_msgs:
                play_windows_chime()
                with chat_lock:
                    for m in toby_msgs:
                        new_events.append(m)
                        cached_messages.append(m)
                        if m.get('id', 0) > last_seen_id:
                            last_seen_id = m.get('id', 0)
        except Exception as e:
            print(f"[!] Poller Fehler: {e}")
        time.sleep(15)

HTML_PAGE = """<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NanoMig - Toby Chat Live Sound Monitor</title>
<style>
  :root {
    --bg: #0f172a;
    --card: #1e293b;
    --border: #334155;
    --text: #f8fafc;
    --muted: #94a3b8;
    --accent: #38bdf8;
    --green: #22c55e;
    --amber: #f59e0b;
    --red: #ef4444;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; }
  body { background: var(--bg); color: var(--text); padding: 24px; max-width: 900px; margin: 0 auto; line-height: 1.5; }
  header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 16px; margin-bottom: 20px; }
  h1 { font-size: 1.4rem; color: var(--accent); display: flex; align-items: center; gap: 8px; }
  .badge { padding: 4px 10px; border-radius: 999px; font-size: 0.8rem; font-weight: 600; text-transform: uppercase; }
  .badge-live { background: #064e3b; color: #34d399; border: 1px solid #059669; }
  .controls { display: flex; gap: 10px; align-items: center; margin-bottom: 20px; flex-wrap: wrap; }
  button {
    background: #2563eb; color: white; border: none; padding: 10px 18px; border-radius: 8px;
    font-size: 0.95rem; font-weight: 600; cursor: pointer; display: flex; align-items: center; gap: 6px;
    transition: all 0.2s;
  }
  button:hover { background: #1d4ed8; }
  button.active { background: #16a34a; }
  button.secondary { background: var(--card); border: 1px solid var(--border); color: var(--text); }
  button.secondary:hover { background: #334155; }
  .status-box {
    background: var(--card); border: 1px solid var(--border); border-radius: 10px;
    padding: 14px 18px; margin-bottom: 20px; font-size: 0.9rem; color: var(--muted);
    display: flex; justify-content: space-between; align-items: center;
  }
  .feed { display: flex; flex-direction: column; gap: 14px; }
  .msg-card {
    background: var(--card); border: 1px solid var(--border); border-radius: 12px;
    padding: 16px; transition: transform 0.2s, border-color 0.2s;
  }
  .msg-card.toby { border-left: 4px solid var(--amber); }
  .msg-card.rudi { border-left: 4px solid var(--accent); }
  .msg-card.new-flash { animation: pulse 1.5s infinite; border-color: var(--green); }
  @keyframes pulse { 0%, 100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0.4); } 50% { box-shadow: 0 0 0 10px rgba(34, 197, 94, 0); } }
  .msg-header { display: flex; justify-content: space-between; font-size: 0.85rem; color: var(--muted); margin-bottom: 8px; }
  .msg-author { font-weight: 700; color: var(--text); }
  .msg-topic { background: #334155; padding: 2px 8px; border-radius: 4px; font-size: 0.75rem; text-transform: uppercase; }
  .msg-body { white-space: pre-wrap; font-size: 0.95rem; word-break: break-word; }
</style>
</head>
<body>

<header>
  <h1><span>🔔</span> Toby Chat Live Sound Monitor</h1>
  <span class="badge badge-live">Aktiv & Verbunden</span>
</header>

<div class="controls">
  <button id="btnAudio" onclick="toggleAudio()">🔊 Audio-Benachrichtigung aktivieren</button>
  <button class="secondary" onclick="testSound()">🎵 Test-Ton abspielen</button>
</div>

<div class="status-box">
  <span id="audioStatus">⚠️ Klicke auf <strong>Audio aktivieren</strong>, damit der Browser bei neuen Nachrichten klingeln darf!</span>
  <span id="lastCheck">Letzter Abruf: gerade eben</span>
</div>

<div class="feed" id="msgFeed">
  <div style="color: var(--muted); text-align: center; padding: 30px;">Lade Nachrichten...</div>
</div>

<script>
let audioCtx = null;
let audioEnabled = false;
let seenIds = new Set();
let unreadCount = 0;

function initAudio() {
  if (!audioCtx) {
    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  }
  if (audioCtx.state === 'suspended') {
    audioCtx.resume();
  }
  audioEnabled = true;
  const btn = document.getElementById('btnAudio');
  btn.classList.add('active');
  btn.innerHTML = '✅ Audio ist SCHARF (Klingelt bei Nachricht)';
  document.getElementById('audioStatus').innerHTML = '✅ Browser-Audio ist aktiv. Bei neuen Nachrichten von Tobys KI ertönt ein Signalton.';
}

function toggleAudio() {
  if (!audioEnabled) {
    initAudio();
    playChime();
  }
}

function playChime() {
  if (!audioCtx) return;
  const now = audioCtx.currentTime;

  // Ton 1 (880 Hz / A5)
  const osc1 = audioCtx.createOscillator();
  const gain1 = audioCtx.createGain();
  osc1.type = 'sine';
  osc1.frequency.setValueAtTime(880, now);
  gain1.gain.setValueAtTime(0.4, now);
  gain1.gain.exponentialRampToValueAtTime(0.001, now + 0.35);
  osc1.connect(gain1);
  gain1.connect(audioCtx.destination);
  osc1.start(now);
  osc1.stop(now + 0.35);

  // Ton 2 (1320 Hz / E6)
  const osc2 = audioCtx.createOscillator();
  const gain2 = audioCtx.createGain();
  osc2.type = 'sine';
  osc2.frequency.setValueAtTime(1320, now + 0.12);
  gain2.gain.setValueAtTime(0.4, now + 0.12);
  gain2.gain.exponentialRampToValueAtTime(0.001, now + 0.65);
  osc2.connect(gain2);
  gain2.connect(audioCtx.destination);
  osc2.start(now + 0.12);
  osc2.stop(now + 0.65);

  // Ton 3 (1760 Hz / A6)
  const osc3 = audioCtx.createOscillator();
  const gain3 = audioCtx.createGain();
  osc3.type = 'triangle';
  osc3.frequency.setValueAtTime(1760, now + 0.24);
  gain3.gain.setValueAtTime(0.35, now + 0.24);
  gain3.gain.exponentialRampToValueAtTime(0.001, now + 0.85);
  osc3.connect(gain3);
  gain3.connect(audioCtx.destination);
  osc3.start(now + 0.24);
  osc3.stop(now + 0.85);
}

function testSound() {
  if (!audioCtx) initAudio();
  playChime();
}

async function poll() {
  try {
    const res = await fetch('/api/messages');
    const data = await res.json();
    document.getElementById('lastCheck').innerText = 'Letzter Abruf: ' + new Date().toLocaleTimeString();

    if (data && data.messages) {
      const feed = document.getElementById('msgFeed');
      let hasNewToby = false;

      data.messages.forEach(m => {
        if (!seenIds.has(m.id)) {
          seenIds.add(m.id);
          if (m.author !== 'rudi') {
            hasNewToby = true;
            unreadCount++;
          }
        }
      });

      if (hasNewToby) {
        document.title = '🔔 (' + unreadCount + ') NEUE NACHRICHT VON TOBY!';
        if (audioEnabled) {
          playChime();
        }
      }

      feed.innerHTML = data.messages.slice().reverse().map(m => {
        const isToby = (m.author !== 'rudi');
        return `
          <div class="msg-card ${isToby ? 'toby' : 'rudi'}">
            <div class="msg-header">
              <span class="msg-author">${isToby ? '👤 Toby / Tobys KI' : '🤖 Rudi / Rudis KI'}</span>
              <div>
                <span class="msg-topic">${m.topic || 'allgemein'}</span>
                <span style="margin-left: 8px;">${new Date(m.created_at).toLocaleString()}</span>
              </div>
            </div>
            <div class="msg-body">${m.text.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</div>
          </div>
        `;
      }).join('');
    }
  } catch (err) {
    console.error('Poll error:', err);
  }
}

// User click anywhere unlocks audio
window.addEventListener('click', () => {
  if (!audioEnabled) initAudio();
}, { once: true });

setInterval(poll, 5000);
poll();
</script>

</body>
</html>
"""

class ChatHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/' or self.path.startswith('/index'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode('utf-8'))
        elif self.path == '/api/messages':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            with chat_lock:
                msgs = list(cached_messages)
            self.wfile.write(json.dumps({'messages': msgs}).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Mute normal HTTP logs to keep stdout clean
        pass

def run_server():
    server = HTTPServer((HOST, PORT), ChatHandler)
    print(f"[*] Web-Sound-Monitor aktiv auf http://{HOST}:{PORT}")
    server.serve_forever()

if __name__ == '__main__':
    # Start poller thread
    t_poll = threading.Thread(target=background_poller, daemon=True)
    t_poll.start()

    # Open browser
    try:
        webbrowser.open(f'http://{HOST}:{PORT}')
    except Exception:
        pass

    # Run HTTP server
    run_server()
