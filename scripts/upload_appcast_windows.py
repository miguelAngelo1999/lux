"""Upload the updated appcast.json to Google Drive using saved credentials."""
import ssl, pickle, os, io, json, urllib3, httplib2, re, sys

os.chdir(r'Y:\vcf')
os.environ.update({'PYTHONHTTPSVERIFY': '0', 'CURL_CA_BUNDLE': '', 'REQUESTS_CA_BUNDLE': ''})
ssl._create_default_https_context = ssl._create_unverified_context
urllib3.disable_warnings()

import requests as req
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload

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

APPCAST_FILE_ID = '1jf-8thv_VVPIQ3k_n83UhygzEKkydI2p'
appcast_path = r'C:\Users\virgoh\lux\appcast.json'

data = json.load(open(appcast_path))
print('Uploading appcast.json:')
print(f'  version: {data["version"]}')
print(f'  windows url: {data["windows"]["url"][:60]}...')

payload = json.dumps(data, indent=2).encode()
media = MediaIoBaseUpload(io.BytesIO(payload), mimetype='application/json')
result = svc.files().update(fileId=APPCAST_FILE_ID, media_body=media, fields='id,name').execute()
print(f'Done! id={result["id"]}')
print(f'URL: https://drive.google.com/uc?export=download&id={result["id"]}&confirm=t')
