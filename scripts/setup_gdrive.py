#!/usr/bin/env python3
"""Verify service account access and set public read on the Lux Releases folder."""
import warnings
warnings.filterwarnings('ignore')

from google.oauth2 import service_account
from googleapiclient.discovery import build

KEY_FILE  = '/Users/virgoh/lux/lucky-science-501221-c2-7248ccec3971.json'
FOLDER_ID = '1FMBWkcE77YM6aWYJqpKG0PalvqGsr5tI'
SCOPES    = ['https://www.googleapis.com/auth/drive']

creds   = service_account.Credentials.from_service_account_file(KEY_FILE, scopes=SCOPES)
service = build('drive', 'v3', credentials=creds)

# Verify access
try:
    f = service.files().get(fileId=FOLDER_ID, fields='id,name,owners').execute()
    print(f'✅ Folder accessible: {f["name"]} (id={f["id"]})')
    print(f'   Owner: {f.get("owners", [{}])[0].get("emailAddress", "unknown")}')
except Exception as e:
    print(f'❌ Cannot access folder: {e}')
    exit(1)

# Set public read
try:
    service.permissions().create(
        fileId=FOLDER_ID,
        body={'type': 'anyone', 'role': 'reader'},
    ).execute()
    print('✅ Set public read (anyone with link can view)')
except Exception as e:
    print(f'ℹ️  Public permission: {e}')

# List existing contents
files = service.files().list(
    q=f'"{FOLDER_ID}" in parents',
    fields='files(id,name,webContentLink)'
).execute().get('files', [])
print(f'\nFolder contents ({len(files)} files):')
for f in files:
    print(f'  {f["name"]} — id={f["id"]}')

print(f'\n✅ Folder ID: {FOLDER_ID}')
print(f'   Public link: https://drive.google.com/drive/folders/{FOLDER_ID}')
