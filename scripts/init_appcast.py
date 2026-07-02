#!/usr/bin/env python3
"""
Create the initial appcast.json in the GDrive folder using OAuth2 (as migangelo1999@gmail.com).
Run once to get the stable appcast file ID, then bake the URL into the Flutter app.

Requires a Desktop OAuth2 client secret. Create one at:
  console.cloud.google.com → APIs & Services → Credentials → + Create Credentials
  → OAuth client ID → Desktop app → Download JSON → save as scripts/oauth_client.json
"""
import io, json, os, warnings
warnings.filterwarnings('ignore')

import sys
sys.path.insert(0, '/Users/virgoh/lux/scripts')
from constants import GDRIVE_FOLDER_ID, APPCAST_FILE_NAME

OAUTH_CLIENT  = '/Users/virgoh/lux/scripts/oauth_client.json'
TOKEN_CACHE   = '/Users/virgoh/lux/scripts/.oauth_token.json'
SCOPES        = ['https://www.googleapis.com/auth/drive']

# ── Auth ───────────────────────────────────────────────────────────────────────
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload

creds = None
if os.path.exists(TOKEN_CACHE):
    creds = Credentials.from_authorized_user_file(TOKEN_CACHE, SCOPES)

if not creds or not creds.valid:
    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    else:
        if not os.path.exists(OAUTH_CLIENT):
            print(f'ERROR: OAuth client secrets not found at {OAUTH_CLIENT}')
            print()
            print('Steps:')
            print('  1. Go to console.cloud.google.com')
            print('  2. Select project lucky-science-501221-c2')
            print('  3. APIs & Services → Credentials → + Create Credentials')
            print('  4. OAuth client ID → Desktop app → name it "Lux Release Script"')
            print('  5. Download JSON → save as scripts/oauth_client.json')
            print('  6. Run this script again')
            sys.exit(1)
        flow = InstalledAppFlow.from_client_secrets_file(OAUTH_CLIENT, SCOPES)
        creds = flow.run_local_server(port=0)
    with open(TOKEN_CACHE, 'w') as f:
        f.write(creds.to_json())
    print(f'Token saved to {TOKEN_CACHE}')

service = build('drive', 'v3', credentials=creds)

# ── Create / update appcast.json ───────────────────────────────────────────────
placeholder = json.dumps({
    "version":  "1.41.0",
    "channel":  "stable",
    "notes":    "Initial release",
    "macOS":    {"url": "", "sha256": "", "size": 0},
    "windows":  {"url": "", "sha256": "", "size": 0},
}, indent=2).encode()

q = f'"{GDRIVE_FOLDER_ID}" in parents and name = "{APPCAST_FILE_NAME}" and trashed = false'
existing = service.files().list(q=q, fields='files(id,name)').execute().get('files', [])
media = MediaIoBaseUpload(io.BytesIO(placeholder), mimetype='application/json')

if existing:
    fid = existing[0]['id']
    service.files().update(fileId=fid, media_body=media).execute()
    print(f'Updated existing {APPCAST_FILE_NAME} (id={fid})')
else:
    meta = {'name': APPCAST_FILE_NAME, 'parents': [GDRIVE_FOLDER_ID]}
    f = service.files().create(body=meta, media_body=media, fields='id,name').execute()
    fid = f['id']
    # Make public read
    service.permissions().create(
        fileId=fid, body={'type': 'anyone', 'role': 'reader'},
    ).execute()
    print(f'Created {APPCAST_FILE_NAME} (id={fid})')

url = f'https://drive.google.com/uc?export=download&id={fid}&confirm=t'
print(f'\n✅ Stable appcast URL:\n   {url}')
print(f'\nAdd to lib/const/const.dart:')
print(f"   const appcastUrl = '{url}';")
print(f'\nAnd to scripts/constants.py:')
print(f"   APPCAST_FILE_ID = '{fid}'")
