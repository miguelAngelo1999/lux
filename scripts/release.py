#!/usr/bin/env python3
"""
Lux release script — builds DMG, uploads to Google Drive, updates appcast.json.

Usage:
    python3 scripts/release.py                          # build + upload current version
    python3 scripts/release.py --dry-run               # build only, no upload
    python3 scripts/release.py --notes "Bug fixes"     # custom release notes
    python3 scripts/release.py --no-rebuild            # skip build, re-upload existing DMG

The service account uploads directly using its Drive API access to the shared folder.
appcast.json is created/updated in-place so its file ID never changes (stable URL).
"""
import argparse, hashlib, io, json, os, re, subprocess, sys, warnings
from pathlib import Path

warnings.filterwarnings('ignore')

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT   = Path(__file__).parent.parent.resolve()
SCRIPTS_DIR = REPO_ROOT / 'scripts'
DIST_DIR    = REPO_ROOT / 'dist'
PUBSPEC     = REPO_ROOT / 'pubspec.yaml'

sys.path.insert(0, str(SCRIPTS_DIR))
from constants import (
    GDRIVE_FOLDER_ID, SERVICE_ACCOUNT_KEY, GITHUB_REPO,
    DMG_BASENAME, WINDOWS_BASENAME, APPCAST_FILE_NAME,
)

# ── Helpers ────────────────────────────────────────────────────────────────────
def run(cmd, **kw):
    print(f'  $ {cmd}')
    result = subprocess.run(cmd, shell=True, check=True, **kw)
    return result

def get_version():
    text = PUBSPEC.read_text()
    m = re.search(r'^version:\s*(\S+)', text, re.MULTILINE)
    if not m:
        raise ValueError('Could not find version in pubspec.yaml')
    return m.group(1).split('+')[0]  # strip build number

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()

OAUTH_CLIENT = SCRIPTS_DIR / 'oauth_client.json'
TOKEN_CACHE  = SCRIPTS_DIR / '.oauth_token.json'
SCOPES       = ['https://www.googleapis.com/auth/drive']

def _patch_ssl_and_proxy():
    """Patch httplib2 and requests to bypass SSL verification and use lux proxy."""
    import ssl, urllib3, httplib2, re, os as _os
    ssl._create_default_https_context = ssl._create_unverified_context
    urllib3.disable_warnings()
    _os.environ.update({'PYTHONHTTPSVERIFY': '0', 'CURL_CA_BUNDLE': '', 'REQUESTS_CA_BUNDLE': ''})
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
    return proxy

def gdrive_service():
    """Authenticate as the user (migangelo1999@gmail.com) via OAuth2."""
    import os
    from google.oauth2.credentials import Credentials
    from google_auth_oauthlib.flow import InstalledAppFlow
    from google.auth.transport.requests import Request
    from googleapiclient.discovery import build
    import requests as _req

    proxy = _patch_ssl_and_proxy()
    sess = _req.Session()
    sess.verify = False
    sess.proxies = {'http': proxy, 'https': proxy}

    creds = None
    if TOKEN_CACHE.exists():
        creds = Credentials.from_authorized_user_file(str(TOKEN_CACHE), SCOPES)

    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request(sess))
        else:
            if not OAUTH_CLIENT.exists():
                print(f'\nERROR: {OAUTH_CLIENT} not found.')
                print('Run scripts/init_appcast.py first (follow instructions there).')
                sys.exit(1)
            flow = InstalledAppFlow.from_client_secrets_file(str(OAUTH_CLIENT), SCOPES)
            creds = flow.run_local_server(port=0)
        TOKEN_CACHE.write_text(creds.to_json())

    return build('drive', 'v3', credentials=creds)

def find_file_in_folder(service, folder_id, name):
    """Return file id if name exists in folder, else None."""
    q = f'"{folder_id}" in parents and name = "{name}" and trashed = false'
    results = service.files().list(q=q, fields='files(id,name)').execute()
    files = results.get('files', [])
    return files[0]['id'] if files else None

def upload_file(service, local_path, folder_id, name, mime='application/octet-stream'):
    from googleapiclient.http import MediaFileUpload
    existing_id = find_file_in_folder(service, folder_id, name)
    media = MediaFileUpload(str(local_path), mimetype=mime, resumable=True)
    if existing_id:
        # Update existing file (keeps same ID → same download URL)
        f = service.files().update(
            fileId=existing_id, media_body=media, fields='id,name,size'
        ).execute()
        print(f'  ↻ Updated  {name} (id={f["id"]}, size={int(f.get("size",0))//1024}KB)')
    else:
        meta = {'name': name, 'parents': [folder_id]}
        f = service.files().create(
            body=meta, media_body=media, fields='id,name,size'
        ).execute()
        # Make new file public
        service.permissions().create(
            fileId=f['id'],
            body={'type': 'anyone', 'role': 'reader'},
        ).execute()
        print(f'  ✚ Uploaded {name} (id={f["id"]}, size={int(f.get("size",0))//1024}KB)')
    return f['id']

def upload_json(service, data, folder_id, name):
    """Upload/update a JSON object as a file in the folder."""
    payload = json.dumps(data, indent=2).encode()
    existing_id = find_file_in_folder(service, folder_id, name)
    media_body = io.BytesIO(payload)
    from googleapiclient.http import MediaIoBaseUpload
    media = MediaIoBaseUpload(media_body, mimetype='application/json')
    if existing_id:
        f = service.files().update(
            fileId=existing_id, media_body=media, fields='id,name'
        ).execute()
        print(f'  ↻ Updated  {name} (id={f["id"]})')
    else:
        meta = {'name': name, 'parents': [folder_id]}
        f = service.files().create(
            body=meta, media_body=media, fields='id,name'
        ).execute()
        service.permissions().create(
            fileId=f['id'],
            body={'type': 'anyone', 'role': 'reader'},
        ).execute()
        print(f'  ✚ Uploaded {name} (id={f["id"]})')
    return f['id']

def direct_url(file_id):
    return f'https://drive.usercontent.google.com/download?id={file_id}&export=download&confirm=t'

# ── Build ──────────────────────────────────────────────────────────────────────
def build_macos(version, args):
    print('\n── Building macOS DMG ──────────────────────────────────────────')
    dmg_name = DMG_BASENAME.format(version=version)
    dmg_path = DIST_DIR / dmg_name

    if args.no_rebuild and dmg_path.exists():
        print(f'  ↷ Skipping build — using existing {dmg_name}')
        return dmg_path

    flutter = os.environ.get('FLUTTER_BIN', 'flutter')
    proxy_env = (
        'export http_proxy=http://127.0.0.1:1090; '
        'export https_proxy=http://127.0.0.1:1090; '
        'export DART_IO_ALLOW_BAD_CERTIFICATES=true; '
        'export GIT_SSL_NO_VERIFY=1; '
    )
    run(f'{proxy_env}{flutter} build macos --release --no-pub', cwd=REPO_ROOT)

    app_path = REPO_ROOT / 'build/macos/Build/Products/Release/Lux.app'
    print('\n── Creating DMG ────────────────────────────────────────────────')
    DIST_DIR.mkdir(exist_ok=True)
    if dmg_path.exists():
        dmg_path.unlink()
    run(f'xattr -cr "{app_path}"')
    run(
        f'create-dmg --overwrite --no-code-sign --dmg-title "Lux {version}" '
        f'"{app_path}" "{DIST_DIR}/"',
        cwd=REPO_ROOT,
    )
    # create-dmg names it after the app; rename to versioned name
    created = next(DIST_DIR.glob('*.dmg'), None)
    if created and created != dmg_path:
        created.rename(dmg_path)
    print(f'  ✓ {dmg_name}')
    return dmg_path

# ── Main ───────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description='Lux release uploader')
    ap.add_argument('--dry-run',    action='store_true', help='Build only, no upload')
    ap.add_argument('--no-rebuild', action='store_true', help='Skip build, use existing DMG')
    ap.add_argument('--notes',      default='',          help='Release notes (markdown)')
    ap.add_argument('--version',    default='',          help='Override version (default: pubspec)')
    ap.add_argument('--windows-exe', default='',         help='Path to Windows .exe to upload alongside')
    args = ap.parse_args()

    version = args.version or get_version()
    print(f'\n🚀 Lux release {version}')
    print(f'   Repo:   {GITHUB_REPO}')
    print(f'   Folder: https://drive.google.com/drive/folders/{GDRIVE_FOLDER_ID}\n')

    # Build macOS DMG (skip on Windows)
    dmg_path = None
    dmg_sha256 = ''
    dmg_size = 0
    dmg_url = ''

    if sys.platform != 'win32':
        dmg_path = build_macos(version, args)
        dmg_sha256 = sha256_file(dmg_path)
        dmg_size   = dmg_path.stat().st_size
        print(f'\n  SHA-256: {dmg_sha256}')
        print(f'  Size:    {dmg_size // 1024 // 1024} MB')
        if sys.platform == 'darwin':
            run(f'xattr -d com.apple.quarantine "{dmg_path}" 2>/dev/null || true')
    else:
        print('  ↷ Skipping macOS DMG build (running on Windows)')

    if args.dry_run:
        print('\n✅ Dry run complete — no upload.')
        return

    # ── Upload ─────────────────────────────────────────────────────────────────
    print('\n── Uploading to Google Drive ───────────────────────────────────')
    service = gdrive_service()

    if dmg_path is not None:
        dmg_id  = upload_file(service, dmg_path, GDRIVE_FOLDER_ID, dmg_path.name)
        dmg_url = direct_url(dmg_id)
    else:
        # Windows-only run — preserve existing macOS URL from current appcast
        print('  ↷ No DMG — preserving existing macOS entry in appcast')
        try:
            import urllib.request
            with urllib.request.urlopen(
                f'https://drive.google.com/uc?export=download&id=1jf-8thv_VVPIQ3k_n83UhygzEKkydI2p&confirm=t',
                timeout=10
            ) as resp:
                existing = json.loads(resp.read())
                macos_entry = existing.get('macOS', {})
                dmg_url    = macos_entry.get('url', '')
                dmg_sha256 = macos_entry.get('sha256', '')
                dmg_size   = macos_entry.get('size', 0)
                print(f'  ↷ Kept macOS url={dmg_url[:60]}...')
        except Exception as e:
            print(f'  ⚠ Could not fetch existing appcast: {e}')

    windows_url = ''
    windows_sha256 = ''
    windows_size = 0
    if args.windows_exe:
        exe_path = Path(args.windows_exe)
        exe_id   = upload_file(service, exe_path, GDRIVE_FOLDER_ID, exe_path.name)
        windows_url    = direct_url(exe_id)
        windows_sha256 = sha256_file(exe_path)
        windows_size   = exe_path.stat().st_size

    # ── Update appcast.json ────────────────────────────────────────────────────
    print('\n── Updating appcast.json ───────────────────────────────────────')
    appcast = {
        'version': version,
        'channel': 'stable',
        'notes': args.notes or f'Lux {version}',
        'macOS': {
            'url':    dmg_url,
            'sha256': dmg_sha256,
            'size':   dmg_size,
        },
        'windows': {
            'url':    windows_url,
            'sha256': windows_sha256,
            'size':   windows_size,
        },
    }
    appcast_id = upload_json(service, appcast, GDRIVE_FOLDER_ID, APPCAST_FILE_NAME)
    appcast_url = direct_url(appcast_id)

    print(f'\n✅ Release {version} published!')
    print(f'   DMG URL:     {dmg_url}')
    print(f'   Appcast URL: {appcast_url}')
    print(f'\n   Add this to lib/const/const.dart:')
    print(f'   const appcastUrl = \'{appcast_url}\';')

    # Save appcast locally and commit to repo
    local_appcast = REPO_ROOT / 'appcast.json'
    local_appcast.write_text(json.dumps(appcast, indent=2) + '\n')
    print(f'\n   Saved locally: appcast.json')
    print(f'\n── Committing appcast.json to repo ─────────────────────────────')
    try:
        run('git add appcast.json', cwd=REPO_ROOT)
        run(f'git commit -m "release: update appcast.json for {version}"', cwd=REPO_ROOT)
        run('git push origin personal/all-features', cwd=REPO_ROOT)
        print('  ✓ Pushed to GitHub — updater URL is live')
    except Exception as e:
        print(f'  ⚠ Could not push to GitHub: {e}')
        print(f'  Run manually: git add appcast.json && git commit -m "release: {version}" && git push')

if __name__ == '__main__':
    main()
