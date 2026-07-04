#!/bin/bash
# Usage: bash scripts/bump_and_release.sh [patch|minor|major]
# Bumps version in pubspec.yaml, builds, uploads DMG to GDrive, updates appcast.
set -e
export PATH="/opt/homebrew/bin:/Users/virgoh/flutter/bin:$PATH"
export http_proxy=http://127.0.0.1:1090
export https_proxy=http://127.0.0.1:1090
export DART_IO_ALLOW_BAD_CERTIFICATES=true
export GIT_SSL_NO_VERIFY=1

BUMP="${1:-patch}"  # patch = x.y.Z+1, minor = x.Y+1.0, major = X+1.0.0
cd /Users/virgoh/lux

# Read current version
CURRENT=$(grep "^version:" pubspec.yaml | sed 's/version: //' | cut -d'+' -f1)
echo "Current version: $CURRENT"

# Bump version
python3 - <<PYEOF
v = "$CURRENT".split(".")
bump = "$BUMP"
if bump == "major":
    v[0] = str(int(v[0]) + 1); v[1] = "0"; v[2] = "0"
elif bump == "minor":
    v[1] = str(int(v[1]) + 1); v[2] = "0"
else:  # patch
    v[2] = str(int(v[2]) + 1)
new_v = ".".join(v)
import re
content = open("pubspec.yaml").read()
content = re.sub(r"^version: .+", f"version: {new_v}+1", content, flags=re.MULTILINE)
open("pubspec.yaml", "w").write(content)
print(f"Bumped to {new_v}")
PYEOF

# Read new version
VERSION=$(grep "^version:" pubspec.yaml | sed 's/version: //' | cut -d'+' -f1)
echo "New version: $VERSION"

# Build
flutter build macos --release --no-pub

# Deploy
python3 - <<PYEOF
import subprocess, os, time, getpass
BIN = "/Applications/Lux.app/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/lux_core"
REAL = BIN + "_real"
APP_SRC = "/Users/virgoh/lux/build/macos/Build/Products/Release/Lux.app"
for name in ["lux_core_real", "Lux"]:
    subprocess.run(["sudo", "pkill", "-9", "-x", name], capture_output=True)
time.sleep(2)
subprocess.run(["sudo", "rm", "-rf", "/Applications/Lux.app"], capture_output=True)
subprocess.run(["sudo", "cp", "-R", APP_SRC, "/Applications/Lux.app"], check=True)
subprocess.run(["sudo", "mv", BIN, REAL], check=True)
with open("/tmp/_w.sh", "w") as f:
    f.write(f'#!/bin/bash\nexec sudo "{REAL}" "\$@"\n')
subprocess.run(["sudo", "cp", "/tmp/_w.sh", BIN], check=True)
subprocess.run(["sudo", "chmod", "755", BIN], check=True)
subprocess.run(["sudo", "chown", "root:wheel", REAL], check=True)
subprocess.run(["sudo", "chmod", "770", REAL], check=True)
subprocess.run(["sudo", "chmod", "u+s", REAL], check=True)
os.unlink("/tmp/_w.sh")
user = getpass.getuser()
sudoers = "\n".join([
    f"{user} ALL=(root) NOPASSWD: {REAL} *",
    f"{user} ALL=(root) NOPASSWD: /bin/bash /tmp/lux_proxy_apply.sh",
    f"{user} ALL=(root) NOPASSWD: /bin/bash /tmp/lux_proxy_clear.sh",
    f"{user} ALL=(root) NOPASSWD: /bin/bash /tmp/lux_cert_install.sh",
]) + "\n"
subprocess.run(["sudo", "tee", "/etc/sudoers.d/lux_core"], input=sudoers.encode(), capture_output=True)
subprocess.run(["sudo", "chmod", "0440", "/etc/sudoers.d/lux_core"])
subprocess.run(["sudo", "visudo", "-c", "-f", "/etc/sudoers.d/lux_core"])
print("Deployed")
PYEOF

open /Applications/Lux.app
echo "Waiting for proxy..."
sleep 15

# Build DMG
DMG_NAME="Lux-${VERSION}-macOS-universal.dmg"
xattr -cr build/macos/Build/Products/Release/Lux.app
rm -f dist/*.dmg; mkdir -p dist
create-dmg --overwrite --no-code-sign --dmg-title "Lux $VERSION" \
  build/macos/Build/Products/Release/Lux.app dist/
for f in dist/*.dmg; do mv "$f" "dist/$DMG_NAME"; done
echo "DMG: $(ls -lh dist/$DMG_NAME | awk '{print $5}')"

# Upload to GDrive
python3 - <<PYEOF
import ssl, os, sys, json, hashlib, io, subprocess
ssl._create_default_https_context = ssl._create_unverified_context
os.environ['http_proxy'] = 'http://127.0.0.1:1090'
os.environ['https_proxy'] = 'http://127.0.0.1:1090'
import urllib3; urllib3.disable_warnings()
sys.path.insert(0, '/Users/virgoh/lux/scripts')
from constants import GDRIVE_FOLDER_ID, APPCAST_FILE_NAME
from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload, MediaIoBaseUpload
import requests

VERSION = "$VERSION"
DMG_NAME = "Lux-${VERSION}-macOS-universal.dmg"
DMG_PATH = f"/Users/virgoh/lux/dist/{DMG_NAME}"

h = hashlib.sha256()
with open(DMG_PATH, 'rb') as f:
    for chunk in iter(lambda: f.read(65536), b''): h.update(chunk)
sha256 = h.hexdigest(); size = os.path.getsize(DMG_PATH)
print(f"DMG: {size//1024//1024}MB sha256={sha256[:16]}...")

creds = Credentials.from_authorized_user_file('/Users/virgoh/lux/scripts/.oauth_token.json',
    ['https://www.googleapis.com/auth/drive'])
if not creds.valid:
    sess = requests.Session(); sess.verify = False
    creds.refresh(Request(session=sess))
service = build('drive', 'v3', credentials=creds)
try: service._http.http.disable_ssl_certificate_validation = True
except: pass

def find(name):
    return ((service.files().list(
        q=f'"{GDRIVE_FOLDER_ID}" in parents and name="{name}" and trashed=false',
        fields='files(id)').execute().get('files') or [{}])[0].get('id'))

dmg_id = find(DMG_NAME)
media = MediaFileUpload(DMG_PATH, mimetype='application/octet-stream', resumable=True)
if dmg_id:
    service.files().update(fileId=dmg_id, media_body=media, fields='id').execute()
    print(f"Updated DMG id={dmg_id}")
else:
    f = service.files().create(body={'name':DMG_NAME,'parents':[GDRIVE_FOLDER_ID]},
        media_body=media, fields='id').execute()
    service.permissions().create(fileId=f['id'], body={'type':'anyone','role':'reader'}).execute()
    dmg_id = f['id']
    print(f"Created DMG id={dmg_id}")

dmg_url = f"https://drive.usercontent.google.com/download?id={dmg_id}&export=download&confirm=t"
notes = subprocess.run(['git','log','-1','--pretty=%s'], capture_output=True, text=True).stdout.strip()
appcast = {'version':VERSION,'channel':'stable','notes':notes,
    'macOS':{'url':dmg_url,'sha256':sha256,'size':size},
    'windows':{'url':'','sha256':'','size':0}}
ac_id = find(APPCAST_FILE_NAME)
media2 = MediaIoBaseUpload(io.BytesIO(json.dumps(appcast,indent=2).encode()), mimetype='application/json')
if ac_id: service.files().update(fileId=ac_id, media_body=media2).execute()
else:
    f2 = service.files().create(body={'name':APPCAST_FILE_NAME,'parents':[GDRIVE_FOLDER_ID]},
        media_body=media2, fields='id').execute()
    service.permissions().create(fileId=f2['id'], body={'type':'anyone','role':'reader'}).execute()
open('/Users/virgoh/lux/appcast.json','w').write(json.dumps(appcast,indent=2)+'\n')
print(f"Done! {dmg_url}")
PYEOF

# Commit + push
git add pubspec.yaml appcast.json
git commit -m "release: bump version to $VERSION + update appcast"
git push origin personal/all-features
echo ""
echo "✅ Released $VERSION — Lux running locally, DMG on GDrive, appcast updated."
