#!/usr/bin/env python3
"""Push a fake 1.42.0 appcast entry to test the in-app updater dialog."""
import io, json, warnings, sys
warnings.filterwarnings('ignore')
sys.path.insert(0, '/Users/virgoh/lux/scripts')
from constants import GDRIVE_FOLDER_ID, APPCAST_FILE_ID

from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload

TOKEN_CACHE  = '/Users/virgoh/lux/scripts/.oauth_token.json'
SCOPES       = ['https://www.googleapis.com/auth/drive']

creds = Credentials.from_authorized_user_file(TOKEN_CACHE, SCOPES)
if creds.expired and creds.refresh_token:
    creds.refresh(Request())
service = build('drive', 'v3', credentials=creds)

existing = json.loads(open('/Users/virgoh/lux/scripts/appcast.json').read())
fake = dict(existing)
fake['version'] = '1.42.0'
fake['notes']   = '🧪 Test release — ignore this update. The updater is working!'
# Use correct drive.usercontent.google.com URL (not the old drive.google.com/uc which triggers virus scan)
dmg_id = '1fqQSl9emMPKqDkn9Lx7Om9ma2wGt9RWF'
fake['macOS'] = {
    'url': f'https://drive.usercontent.google.com/download?id={dmg_id}&export=download&confirm=t',
    'sha256': existing.get('macOS', {}).get('sha256', ''),
    'size': existing.get('macOS', {}).get('size', 0),
}

payload = json.dumps(fake, indent=2).encode()
media = MediaIoBaseUpload(io.BytesIO(payload), mimetype='application/json')
service.files().update(fileId=APPCAST_FILE_ID, media_body=media).execute()
print('✅ Pushed fake 1.42.0 to appcast.json on GDrive')

# Also update the GitHub copy
import subprocess
with open('/Users/virgoh/lux/appcast.json', 'w') as f:
    json.dump(fake, f, indent=2)
    f.write('\n')
subprocess.run(['git', 'add', 'appcast.json'], cwd='/Users/virgoh/lux', check=True)
subprocess.run(['git', 'commit', '-m', 'test: push 1.42.0 appcast for update dialog test'], cwd='/Users/virgoh/lux', check=True)
subprocess.run(['git', 'push', 'origin', 'personal/all-features'], cwd='/Users/virgoh/lux', check=True)
print('✅ Also pushed to GitHub raw URL')
print()
print('Open Lux → Settings → Advanced → Check for Updates')
print('Should show 1.42.0 update dialog with Download button.')
print()
print('Run: python3 scripts/release.py --no-rebuild  (to restore 1.41.0)')
