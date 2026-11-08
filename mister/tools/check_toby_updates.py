import urllib.request
import json
import os
import sys

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
    return {'last_seen_comment_id': 6703093869}

def save_state(state):
    with open(STATE_FILE, 'w', encoding='utf-8') as f:
        json.dump(state, f, indent=2)

def check_updates():
    state = load_state()
    last_id = state.get('last_seen_comment_id', 6703093869)
    
    # Restrict strictly to Issue #9 (Audio Extension only)
    url = 'https://api.github.com/repos/Rudi7503/NanoMig/issues/9/comments?per_page=100'
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            comments = json.loads(r.read().decode('utf-8'))
    except Exception as e:
        print(f'[CHECK_ERROR] {e}')
        sys.exit(1)
        
    new_comments = []
    for c in comments:
        cid = c.get('id', 0)
        user = c.get('user', {}).get('login')
        issue_url = c.get('issue_url', '')
        if cid > last_id and user == 'toby01019':
            new_comments.append(c)
            
    if not new_comments:
        print('[SILENT_NO_UPDATE]')
        sys.exit(0)
        
    # New comments found!
    newest = max(new_comments, key=lambda x: x['id'])
    state['last_seen_comment_id'] = newest['id']
    save_state(state)
    
    print('[NEW_UPDATE_FOUND]')
    for c in new_comments:
        print(f"Author: {c.get('user', {}).get('login')}")
        print(f"Created: {c.get('created_at')}")
        print(f"Body: {c.get('body')}")
    sys.exit(10)

if __name__ == '__main__':
    check_updates()
