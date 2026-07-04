"""Upload Windows installer to the lux GDrive folder and update appcast.json."""
import ssl, pickle, os, io, json, urllib3, httplib2, re, hashlib

os.chdir(r'Y:\vcf')
os.environ.update({'PYTHONHTTPSVERIFY': '0', 'CURL_CA_BUNDLE': '', 'REQUESTS_CA_BUNDLE': ''})
ssl._create_default_https_context = ssl._create_unverified_context
urllib3.disable_warnings()

import requests as req
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload, MediaIoBaseUpload

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

sess = req.Session()
sess.verify = False
sess.proxies = {'http': proxy, 'https': proxy}

creds = pickle.load(open('gdrive_token.pickle', 'rb'))
if creds.expired:
    creds.refresh(Request(sess))

svc = build('drive', 'v3', credentials=creds)

LUX_FOLDER_ID    = '1FMBWkcE77YM6aWYJqpKG0PalvqGsr5tI'
APPCAST_FILE_ID  = '1jf-8thv_VVPIQ3k_n83UhygzEKkydI2p'
INSTALLER        = r'C:\Users\virgoh\lux\dist\lux-1.41.0-windows-setup.exe'
INSTALLER_NAME   = 'lux-1.41.0-windows-setup.exe'

# Hash installer
h = hashlib.sha256()
with open(INSTALLER, 'rb') as f:
    for chunk in iter(lambda: f.read(65536), b''):
        h.update(chunk)
sha256 = h.hexdigest()
size = os.path.getsize(INSTALLER)
print(f'Installer: {INSTALLER_NAME} ({size//1024//1024} MB) sha256={sha256[:16]}...')

# Check if file already exists in folder
q = f'"{LUX_FOLDER_ID}" in parents and name = "{INSTALLER_NAME}" and trashed = false'
existing = svc.files().list(q=q, fields='files(id,name)').execute().get('files', [])

media = MediaFileUpload(INSTALLER, mimetype='application/octet-stream', resumable=True)

if existing:
    file_id = existing[0]['id']
    print(f'Updating existing file id={file_id}')
    r = svc.files().update(fileId=file_id, media_body=media, fields='id').execute()
else:
    print(f'Uploading new file to folder {LUX_FOLDER_ID}')
    meta = {'name': INSTALLER_NAME, 'parents': [LUX_FOLDER_ID]}
    r = svc.files().create(body=meta, media_body=media, fields='id').execute()
    # Make public
    svc.permissions().create(fileId=r['id'], body={'type': 'anyone', 'role': 'reader'}).execute()

file_id = r['id']
windows_url = f'https://drive.usercontent.google.com/download?id={file_id}&export=download&confirm=t'
print(f'Done! id={file_id}')
print(f'URL: {windows_url}')

# Now update appcast.json
print('\nUpdating appcast.json...')
# Fetch current appcast
appcast_resp = svc.files().get_media(fileId=APPCAST_FILE_ID).execute()
appcast = json.loads(appcast_resp)
print(f'  Current version: {appcast["version"]}')

appcast['windows'] = {
    'url': windows_url,
    'sha256': sha256,
    'size': size,
}

payload = json.dumps(appcast, indent=2).encode()
media2 = MediaIoBaseUpload(io.BytesIO(payload), mimetype='application/json')
svc.files().update(fileId=APPCAST_FILE_ID, media_body=media2, fields='id').execute()
print(f'  appcast.json updated with windows url')

# Save locally
with open(r'C:\Users\virgoh\lux\appcast.json', 'w') as f:
    json.dump(appcast, f, indent=2)
print(f'  Saved locally to appcast.json')
print(f'\nDone! Windows installer live at:\n  {windows_url}')
