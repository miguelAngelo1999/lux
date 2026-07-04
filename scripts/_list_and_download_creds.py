"""List lux GDrive folder and download creds/token files."""
import pickle, os, ssl, urllib3, httplib2, re, io

os.chdir(r'Y:\vcf')
ssl._create_default_https_context = ssl._create_unverified_context
urllib3.disable_warnings()

proxy = 'http://127.0.0.1:1090'
import requests as req
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

_oi = httplib2.Http.__init__
def _pi(self, *a, **k):
    k['disable_ssl_certificate_validation'] = True
    m = re.match(r'http://(?:([^:@]+):([^@]+)@)?([\w.]+):(\d+)', proxy)
    if m:
        k.setdefault('proxy_info', httplib2.ProxyInfo(
            httplib2.socks.PROXY_TYPE_HTTP, m.group(3), int(m.group(4))))
    _oi(self, *a, **k)
httplib2.Http.__init__ = _pi

sess = req.Session(); sess.verify = False; sess.proxies = {'http': proxy, 'https': proxy}
creds = pickle.load(open('gdrive_token.pickle', 'rb'))
if creds.expired:
    creds.refresh(Request(sess))
svc = build('drive', 'v3', credentials=creds)

FOLDER = '1FMBWkcE77YM6aWYJqpKG0PalvqGsr5tI'
DEST   = r'C:\Users\virgoh\lux\scripts'

results = svc.files().list(
    q=f'"{FOLDER}" in parents and trashed=false',
    fields='files(id,name,size,modifiedTime)',
    orderBy='modifiedTime desc'
).execute()

files = results.get('files', [])
print(f'Files in lux GDrive folder ({len(files)} total):')
print()
for f in files:
    size_kb = int(f.get('size', 0)) // 1024
    print(f'  {f["modifiedTime"][:16]}  {f["name"]:<50s}  {size_kb:>6}KB  id={f["id"]}')

# Download anything that looks like creds/token/oauth
DOWNLOAD_PATTERNS = ['oauth_client', 'token', 'creds', '.json', '.pickle']
print()
for f in files:
    name = f['name']
    if any(p in name.lower() for p in DOWNLOAD_PATTERNS):
        dest_path = os.path.join(DEST, name)
        print(f'Downloading {name} → {dest_path}')
        request = svc.files().get_media(fileId=f['id'])
        buf = io.FileIO(dest_path, 'wb')
        downloader = MediaIoBaseDownload(buf, request)
        done = False
        while not done:
            status, done = downloader.next_chunk()
        buf.close()
        print(f'  ✓ {os.path.getsize(dest_path)} bytes')

print('\nDone.')
