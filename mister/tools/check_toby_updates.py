import urllib.request
import json
import os
import sys
import subprocess

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

STATE_FILE = os.path.join(os.path.dirname(__file__), 'toby_monitor_state.json')

def load_state():
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            pass
    return {'last_seen_comment_id': 6720475925}

def save_state(state):
    with open(STATE_FILE, 'w', encoding='utf-8') as f:
        json.dump(state, f, indent=2)

def get_token():
    try:
        p = subprocess.Popen(['git', 'credential', 'fill'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        out, _ = p.communicate('protocol=https\nhost=github.com\n')
        for line in out.splitlines():
            if line.startswith('password='):
                return line.split('=', 1)[1]
    except Exception:
        pass
    return None

def check_updates():
    state = load_state()
    last_id = state.get('last_seen_comment_id', 6720475925)
    
    url = 'https://api.github.com/repos/Rudi7503/NanoMig/issues/comments?sort=updated&direction=desc&per_page=15'
    headers = {'User-Agent': 'Mozilla/5.0'}
    token = get_token()
    if token:
        headers['Authorization'] = f'token {token}'
        
    req = urllib.request.Request(url, headers=headers)
    
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            comments = json.loads(r.read().decode('utf-8'))
    except Exception as e:
        print(f'[CHECK_ERROR] {e}')
        sys.exit(1)
        
    new_comments = []
    for c in comments:
        cid = c.get('id', 0)
        user = c.get('user', {}).get('login')
        issue_url = c.get('issue_url', '')
        # Monitor strictly Issue #9 (Audio Extension)
        if cid > last_id and user == 'toby01019' and issue_url.endswith('/issues/9'):
            new_comments.append(c)
            
    if not new_comments:
        print('[SILENT_NO_UPDATE]')
        sys.exit(0)
        
    print('[NEW_UPDATE_FOUND]')
    for c in sorted(new_comments, key=lambda x: x.get('id', 0)):
        print(f"=== NEUER KOMMENTAR VON {c.get('user', {}).get('login')} (ID: {c.get('id')}) ===")
        print(f"Zeit: {c.get('created_at')}")
        print(f"Issue: {c.get('issue_url')}")
        print("--- INHALT ---")
        print(c.get('body', '').strip())
        print("="*60)
        
    max_id = max(c.get('id', 0) for c in new_comments)
    state['last_seen_comment_id'] = max_id
    save_state(state)

if __name__ == '__main__':
    check_updates()
