#!/bin/bash
# release_all.sh — build and publish macOS + Windows atomically.
#
# Both platforms are built BEFORE either appcast is updated, so users
# always get both at the same time — no window where only one platform
# has the new version available.
#
# Usage:
#   bash scripts/release_all.sh [patch|minor|major] [stable|beta]
#
# Examples:
#   bash scripts/release_all.sh patch beta     ← default
#   bash scripts/release_all.sh patch stable   ← general release

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUMP="${1:-patch}"
CHANNEL="${2:-beta}"

if [[ "$CHANNEL" != "stable" && "$CHANNEL" != "beta" ]]; then
  echo "FATAL: channel must be 'stable' or 'beta', got '$CHANNEL'"
  exit 1
fi

export PATH="/opt/homebrew/bin:/Users/virgoh/flutter/bin:$PATH"

if curl -s -o /dev/null --max-time 4 -x http://127.0.0.1:1090 https://example.com 2>/dev/null; then
  PROXY=http://127.0.0.1:1090
else
  PROXY=http://127.0.0.1:8079
fi
export http_proxy="$PROXY" https_proxy="$PROXY" LUX_RELEASE_PROXY="$PROXY"
export DART_IO_ALLOW_BAD_CERTIFICATES=true GIT_SSL_NO_VERIFY=1 PYTHONHTTPSVERIFY=0 REQUESTS_CA_BUNDLE=""

echo "==> Channel: $CHANNEL | Bump: $BUMP | Proxy: $PROXY"
cd "$REPO"

# ── Step 1: Determine new version ─────────────────────────────────────────
CURRENT=$(grep "^version:" pubspec.yaml | sed 's/version: //' | cut -d'+' -f1)
VERSION=$(python3 -c "
import sys
cur = '$CURRENT'; bump = '$BUMP'
v = cur.split('.')
if bump == 'major': v = [str(int(v[0])+1),'0','0']
elif bump == 'minor': v = [v[0], str(int(v[1])+1), '0']
else: v = [v[0], v[1], str(int(v[2])+1)]
print('.'.join(v))
")
echo "==> Version: $CURRENT → $VERSION"

# ── Step 2: Bump pubspec ───────────────────────────────────────────────────
sed -i '' "s/^version: .*/version: ${VERSION}+1/" pubspec.yaml
echo "==> pubspec bumped to $VERSION+1"

# ── Step 3: Build macOS ────────────────────────────────────────────────────
echo "==> Building macOS..."
rm -f assets/bin/lux_core.exe 2>/dev/null || true

APP=build/macos/Build/Products/Release/Lux.app
flutter build macos --release --no-pub
xattr -cr "$APP"
bash "$REPO/scripts/sign_and_notarize.sh" app "$APP" 2>/dev/null || true

# Build DMG
DMG_STAGE="/tmp/lux-dmg-stage"
rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
cp "$REPO/macos/install.sh" "$DMG_STAGE/"
DMG_NAME="Lux-${VERSION}-macOS-universal.dmg"
SIZE_KB=$(du -sk "$DMG_STAGE" | awk '{print $1}'); SIZE_KB=$((SIZE_KB + 5000))
hdiutil create -size ${SIZE_KB}k -fs HFS+ -volname "Lux $VERSION" -ov /tmp/lux_tmp.dmg >/dev/null
MOUNT_DIR=$(hdiutil attach /tmp/lux_tmp.dmg | grep "/Volumes" | awk -F'\t' '{print $NF}')
cp -R "$DMG_STAGE/Lux.app" "$MOUNT_DIR/"
cp "$DMG_STAGE/install.sh" "$MOUNT_DIR/"
hdiutil detach "$MOUNT_DIR" >/dev/null
hdiutil convert /tmp/lux_tmp.dmg -format UDZO -o "dist/$DMG_NAME" >/dev/null
rm -f /tmp/lux_tmp.dmg; rm -rf "$DMG_STAGE"
hdiutil verify "dist/$DMG_NAME" >/dev/null
bash "$REPO/scripts/sign_and_notarize.sh" dmg "dist/$DMG_NAME" 2>/dev/null || true
echo "==> macOS DMG ready: dist/$DMG_NAME ($(ls -lh "dist/$DMG_NAME" | awk '{print $5}'))"

# ── Step 4: Build Windows (via Parallels VM) ──────────────────────────────
echo "==> Building Windows..."
VM="Windows 11 (1)"
WIN_LUX="C:\\lux-build\\lux"
INSTALLER_WIN="C:\\lux-build\\dist2\\lux-${VERSION}-setup.exe"

win() { prlctl exec "$VM" cmd /c "$*" 2>&1 || true; }
win_ps_script() {
  local name="$1" content="$2"
  printf '%s' "$content" > "$REPO/$name"
  prlctl exec "$VM" powershell -NonInteractive -NoProfile -ExecutionPolicy Bypass \
    -File "\\\\Mac\\Home\\lux-clean\\${name}" 2>&1 || true
  rm -f "$REPO/$name"
}

VM_STATUS=$(prlctl status "$VM" 2>/dev/null | awk '{print $NF}' || echo "stopped")
if [ "$VM_STATUS" != "running" ]; then prlctl start "$VM"; sleep 25; fi
win "echo VM_READY"

# Sync repos
win "robocopy \\\\Mac\\Home\\lux-clean C:\\lux-build\\lux /E /XD .git build dist dist2 /XF *.dmg *.exe pubspec.yaml /NP /NFL /NDL 2>nul & exit 0"
win "attrib -R C:\\lux-build\\lux\\*.* /S /D >nul 2>&1 & exit 0"
win "del /F C:\\lux-build\\lux\\.flutter-plugins C:\\lux-build\\lux\\.flutter-plugins-dependencies >nul 2>&1 & exit 0"

# Write pubspec with Windows version
PUBSPEC_WIN=$(sed "s/^version: .*/version: ${VERSION}+1/" "$REPO/pubspec.yaml")
printf '%s' "$PUBSPEC_WIN" > "$REPO/pubspec_win.yaml"
win "copy \"\\\\Mac\\Home\\lux-clean\\pubspec_win.yaml\" \"C:\\lux-build\\lux\\pubspec.yaml\" && echo PUBSPEC_OK"
rm -f "$REPO/pubspec_win.yaml"

win "robocopy \\\\Mac\\Home\\itun2socks-clean C:\\lux-build\\itun2socks /E /XD .git /NP /NFL /NDL 2>nul & exit 0"
win "attrib -R C:\\lux-build\\itun2socks\\*.* /S /D >nul 2>&1 & exit 0"

# Fix executor.go mixed→system
win_ps_script "fix_executor.ps1" '
$f = "C:\lux-build\itun2socks\internal\executor\executor.go"
$c = [System.IO.File]::ReadAllText($f)
$c = $c.Replace("NewStack(`"mixed`"","NewStack(`"system`"")
[System.IO.File]::WriteAllText($f,$c)
Write-Host "executor patched"
'

# Build lux_core.exe
win_ps_script "build_core.ps1" "
Set-Content 'C:\\lux-build\\build_core.bat' '@echo off
setlocal
set CGO_ENABLED=0
set GOOS=windows
set GOARCH=amd64
set GOPROXY=file:///C:/Users/virgoh/go/pkg/mod/cache/download,off
set GONOSUMCHECK=*
set GONOSUMDB=*
set GOINSECURE=*
set GOFLAGS=-mod=mod
cd /d C:\\lux-build\\itun2socks
go build -ldflags=\"-s -w\" -trimpath -o ..\\lux\\assets\\bin\\lux_core.exe .
if %ERRORLEVEL% EQU 0 (echo BUILD_OK) else (echo BUILD_FAILED)
endlocal'
"
win "C:\\lux-build\\build_core.bat" | grep -q "BUILD_OK" || { echo "ERROR: Windows core build failed"; exit 1; }

# Update checksum
WIN_HASH=$(prlctl exec "$VM" powershell -NonInteractive -NoProfile -Command \
  "(Get-FileHash 'C:\lux-build\lux\assets\bin\lux_core.exe' -Algorithm SHA256).Hash.ToLower()" 2>&1 | tr -d '[:space:]\r\n')
echo "==> Windows core hash: $WIN_HASH"
python3 -c "
import re
with open('$REPO/lib/core/checksum.dart') as f: c = f.read()
c = re.sub(r'windowsAmd64Checksum = \"[a-f0-9]+\"', 'windowsAmd64Checksum = \"$WIN_HASH\"', c)
with open('$REPO/lib/core/checksum.dart', 'w') as f: f.write(c)
"
win "copy \"\\\\Mac\\Home\\lux-clean\\lib\\core\\checksum.dart\" \"C:\\lux-build\\lux\\lib\\core\\checksum.dart\" && echo CHECKSUM_SYNCED"

# Build Flutter Windows
win_ps_script "build_flutter.ps1" '
$env:PUB_CACHE = "C:\Users\virgoh\AppData\Local\Pub\Cache"
Set-Location C:\lux-build\lux
& "C:\lux-build\flutter\bin\flutter.bat" pub get --offline
$p = Start-Process -FilePath "C:\lux-build\flutter\bin\flutter.bat" `
     -ArgumentList "build","windows","--release","--no-pub" `
     -Wait -PassThru -NoNewWindow
if ($p.ExitCode -eq 0) { Write-Host "FLUTTER_OK" } else { Write-Host "FLUTTER_FAILED"; exit 1 }
'

# Package installer
win "if exist C:\\lux-build\\dist2\\*.exe del /F /Q C:\\lux-build\\dist2\\*.exe >nul 2>&1 & exit 0"
win_ps_script "patch_iss.ps1" "
\$f = 'C:\\lux-build\\lux\\dist-setup.iss'
\$c = Get-Content \$f -Raw
\$c = \$c -replace '#define MyAppVersion \"[^\"]*\"', '#define MyAppVersion \"${VERSION}\"'
\$c = \$c -replace 'OutputBaseFilename=[^\r\n]*', 'OutputBaseFilename=lux-${VERSION}-setup'
\$c = \$c -replace 'OutputDir=[^\r\n]*', 'OutputDir=C:\\lux-build\\dist2'
[System.IO.File]::WriteAllText(\$f, \$c)
Write-Host 'iss patched'
"
win "cd C:\\lux-build\\lux && \"C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe\" dist-setup.iss && echo ISCC_OK" | grep -q "ISCC_OK" || { echo "ERROR: Inno Setup failed"; exit 1; }

# Copy to Mac
mkdir -p "$REPO/dist"
WIN_INSTALLER="$REPO/dist/Lux-${VERSION}-Windows-x64-Setup.exe"
win "copy \"${INSTALLER_WIN}\" \"\\\\Mac\\Home\\lux-clean\\dist\\Lux-${VERSION}-Windows-x64-Setup.exe\" && echo COPY_OK"
[ -f "$WIN_INSTALLER" ] || { echo "ERROR: Windows installer not found"; exit 1; }
echo "==> Windows installer ready: $(ls -lh "$WIN_INSTALLER" | awk '{print $5, $9}')"

# ── Step 5: Upload BOTH platforms, then update appcast atomically ──────────
echo "==> Uploading both platforms..."

# Upload macOS DMG
python3 "$REPO/scripts/publish_appcast.py" "$VERSION" "dist/$DMG_NAME" --channel "$CHANNEL"

# Upload Windows installer
cp /Users/virgoh/lux/scripts/.oauth_token.json "$REPO/scripts/.oauth_token.json"
python3 "$REPO/scripts/publish_appcast_windows.py" "$VERSION" "$WIN_INSTALLER"
rm -f "$REPO/scripts/.oauth_token.json"

# ── Step 6: Commit and push ────────────────────────────────────────────────
git add pubspec.yaml lib/core/checksum.dart
if [ "$CHANNEL" == "beta" ]; then
  git add appcast-beta.json 2>/dev/null || true
  git commit -m "release (beta): $VERSION"
else
  git add appcast.json 2>/dev/null || true
  git commit -m "release: $VERSION"
fi

echo ""
echo "==> $VERSION released on $CHANNEL (macOS + Windows)"
echo "    push when ready: git push origin rebuild/clean-base"

# ── Step 7: Update download page ──────────────────────────────────────────
echo "==> Updating download page..."
PAGE="$REPO/scripts/release-page/index.html"
# Update version number in the page
sed -i '' "s/v1\.[0-9]*\.[0-9]*/v${VERSION}/g" "$PAGE"

# Publish to here.now
python3 - << PYEOF
import json, subprocess, os
proxy = '$PROXY'
api_key = open(os.path.expanduser('~/.herenow/credentials')).read().strip()
slug = 'bright-mustard-qghz'
index_size = os.path.getsize('$PAGE')
icon_path = '$REPO/scripts/release-page/lux-icon.png'
icon_size = os.path.getsize(icon_path)
body = json.dumps({'files': [
    {'path': 'index.html', 'size': index_size, 'contentType': 'text/html; charset=utf-8'},
    {'path': 'lux-icon.png', 'size': icon_size, 'contentType': 'image/png'}
]})
r = subprocess.run(['curl', '-sS', '-X', 'PUT', '-H', f'Authorization: Bearer {api_key}',
    '-H', 'Content-Type: application/json', '-H', 'X-HereNow-Account: lux',
    '-H', 'X-HereNow-Client: kiro/direct-api', '--proxy', proxy,
    f'https://here.now/api/v1/publish/{slug}', '-d', body], capture_output=True, text=True)
data = json.loads(r.stdout)
upload = data['upload']
for u in upload['uploads']:
    src = '$PAGE' if u['path'] == 'index.html' else icon_path
    subprocess.run(['curl', '-sS', '-X', 'PUT', '-H', f"Content-Type: {u['headers']['Content-Type']}",
        '--data-binary', f'@{src}', '--proxy', proxy, '-o', '/dev/null', u['url']], capture_output=True)
r = subprocess.run(['curl', '-sS', '-X', 'POST', '-H', f'Authorization: Bearer {api_key}',
    '-H', 'Content-Type: application/json', '-H', 'X-HereNow-Account: lux',
    '--proxy', proxy, upload['finalizeUrl'],
    '-d', json.dumps({'versionId': upload['versionId']})], capture_output=True, text=True)
result = json.loads(r.stdout)
print(f"Download page updated: {result.get('publishStatus',{}).get('state')}")
PYEOF
