"""Upload Windows installer to lux GDrive folder using lux build credentials."""
import ssl, os, io, json, urllib3, httplib2, re, hashlib

ssl._create_default_https_context = ssl._create_unverified_context
urllib3.disable_warnings()
os.environ.update({'PYTHONHTTPSVERIFY': '0', 'CURL_CA_BUNDLE': '', 'REQUESTS_CA_BUNDLE': ''})

proxy = 'http://127.0.0.1:1090'

_oi = httplib2.Http.__init__
def _pi(self, *a, **k):
    k['disable_ssl_certificate_validation'] = True
    m = re.match(r'http://(?:([^:@]+):([^@]+)@)?([\w.]+):(\d+)', proxy)
    if m:
        k.setdefault('proxy_info', httplib2.ProxyInfo(
            httplib2.socks.PROXY_TYPE_HTTP, m.group(3), int(m.group(4))))
    _oi(self, *a, **k)
httplib2.Http.__init__ = _pi

import requests as req
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload, MediaIoBaseUpload

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
TOKEN_FILE  = os.path.join(SCRIPTS_DIR, 'build_oauth_token.json')

sess = req.Session(); sess.verify = False; sess.proxies = {'http': proxy, 'https': proxy}
creds = Credentials.from_authorized_user_file(TOKEN_FILE, ['https://www.googleapis.com/auth/drive'])
if creds.expired and creds.refresh_token:
    creds.refresh(Request(sess))

svc = build('drive', 'v3', credentials=creds)
me = svc.about().get(fields='user').execute()
print(f'Authenticated as: {me["user"]["emailAddress"]}')

LUX_FOLDER_ID   = '1FMBWkcE77YM6aWYJqpKG0PalvqGsr5tI'
APPCAST_FILE_ID = '1jf-8thv_VVPIQ3k_n83UhygzEKkydI2p'
INSTALLER       = r'C:\Users\virgoh\lux\dist\lux-1.41.0-windows-setup.exe'
INSTALLER_NAME  = 'lux-1.41.0-windows-setup.exe'

# Hash
h = hashlib.sha256()
with open(INSTALLER, 'rb') as f:
    for chunk in iter(lambda: f.read(65536), b''):
        h.update(chunk)
sha256 = h.hexdigest()
size   = os.path.getsize(INSTALLER)
print(f'Installer: {INSTALLER_NAME} ({size//1024//1024} MB) sha256={sha256[:16]}...')

# Check if already exists in folder
q = f'"{LUX_FOLDER_ID}" in parents and name = "{INSTALLER_NAME}" and trashed = false'
existing = svc.files().list(q=q, fields='files(id,name)').execute().get('files', [])
media = MediaFileUpload(INSTALLER, mimetype='application/octet-stream', resumable=True)

if existing:
    file_id = existing[0]['id']
    print(f'Updating existing file id={file_id}')
    req_obj = svc.files().update(fileId=file_id, media_body=media, fields='id')
else:
    print(f'Creating new file in folder')
    meta = {'name': INSTALLER_NAME, 'parents': [LUX_FOLDER_ID]}
    req_obj = svc.files().create(body=meta, media_body=media, fields='id')

# Resumable upload with progress
resp = None
while resp is None:
    status, resp = req_obj.next_chunk()
    if status:
        print(f'\r  {int(status.progress()*100)}%', end='', flush=True)

file_id = resp['id']
print(f'\nUploaded! id={file_id}')

if not existing:
    svc.permissions().create(fileId=file_id, body={'type': 'anyone', 'role': 'reader'}).execute()

windows_url = f'https://drive.usercontent.google.com/download?id={file_id}&export=download&confirm=t'
print(f'URL: {windows_url}')

# Update appcast
print('\nUpdating appcast.json...')
from googleapiclient.http import MediaIoBaseDownload
buf = io.BytesIO()
dl = MediaIoBaseDownload(buf, svc.files().get_media(fileId=APPCAST_FILE_ID))
done = False
while not done:
    _, done = dl.next_chunk()
appcast = json.loads(buf.getvalue())
print(f'  Current version: {appcast["version"]}')

appcast['windows'] = {'url': windows_url, 'sha256': sha256, 'size': size}

payload = json.dumps(appcast, indent=2).encode()
svc.files().update(
    fileId=APPCAST_FILE_ID,
    media_body=MediaIoBaseUpload(io.BytesIO(payload), mimetype='application/json'),
    fields='id'
).execute()

# Save locally
repo_root = os.path.dirname(SCRIPTS_DIR)
with open(os.path.join(repo_root, 'appcast.json'), 'w') as f:
    json.dump(appcast, f, indent=2)
print(f'  appcast.json updated and saved locally')
print(f'\nDone! Windows installer live at:\n  {windows_url}')
