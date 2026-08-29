#!/bin/bash
# build_windows.sh — build and publish the Windows Lux installer from macOS via prlctl.
#
# Usage:
#   bash scripts/build_windows.sh [patch|minor|major]
#   SKIP_BUILD=1 bash scripts/build_windows.sh   # upload existing installer only
#
# Requires:
#   - Parallels Desktop, VM named "Windows 11 (1)"
#   - C:\lux-build on the VM with lux, itun2socks, flutter, dist2
#   - scripts/.oauth_token.json on this mac (copied to VM before publish)

set -euo pipefail

VM="Windows 11 (1)"
WIN_LUX="C:\\lux-build\\lux"
WIN_ITUN="C:\\lux-build\\itun2socks"
WIN_FLUTTER="C:\\lux-build\\flutter\\bin\\flutter.bat"
WIN_ISCC="C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe"
WIN_DIST="C:\\lux-build\\dist2"
WIN_PYTHON="python"
PREPROXY="http://192.168.68.62:8079"   # always-on, bypasses lux

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUMP="${1:-patch}"

# Proxy for macOS-side operations (GDrive upload etc.)
if curl -s -o /dev/null --max-time 4 -x http://127.0.0.1:1090 https://example.com 2>/dev/null; then
  MAC_PROXY=http://127.0.0.1:1090
else
  MAC_PROXY=http://127.0.0.1:8079
fi
export https_proxy="$MAC_PROXY" http_proxy="$MAC_PROXY" GIT_SSL_NO_VERIFY=1

# ── Helpers ────────────────────────────────────────────────────────────────
win() {
  # Run a cmd /c command inside the VM; print output; fail if exit != 0
  local out
  out=$(prlctl exec "$VM" cmd /c "$*" 2>&1)
  local rc=$?
  echo "$out"
  return $rc
}

winps() {
  # Run a PowerShell -Command inside the VM
  local out
  out=$(prlctl exec "$VM" powershell -NonInteractive -NoProfile -Command "$*" 2>&1)
  local rc=$?
  echo "$out"
  return $rc
}

step() { echo; echo "==> $1"; }

# ── Start VM if needed ─────────────────────────────────────────────────────
step "Ensuring VM is running"
VM_STATUS=$(prlctl status "$VM" 2>/dev/null | awk '{print $NF}' || echo "stopped")
if [ "$VM_STATUS" != "running" ]; then
  echo "Starting $VM..."
  prlctl start "$VM"
  sleep 25
fi
win "echo VM_READY"

# ── Determine Windows version ──────────────────────────────────────────────
step "Determining version"
WIN_CURRENT=$(python3 -c "
import json
d = json.load(open('$REPO/appcast.json'))
print(d.get('windows', {}).get('version', d.get('version', '1.0.0')))
")
echo "Current Windows version: $WIN_CURRENT"

WIN_VERSION=$(python3 - "$WIN_CURRENT" "$BUMP" << 'PYEOF'
import sys
cur, bump = sys.argv[1], sys.argv[2]
v = cur.split(".")
if bump == "major":   v = [str(int(v[0])+1), "0", "0"]
elif bump == "minor": v = [v[0], str(int(v[1])+1), "0"]
else:                 v = [v[0], v[1], str(int(v[2])+1)]
print(".".join(v))
PYEOF
)
echo "New Windows version: $WIN_VERSION"

INSTALLER="${WIN_DIST}\\lux-${WIN_VERSION}-setup.exe"

if [ "${SKIP_BUILD:-}" != "1" ]; then

  # ── Step 1: Pull both repos ──────────────────────────────────────────────
  step "Pulling latest from origin"
  win "git -C ${WIN_LUX} -c http.proxy=${PREPROXY} -c https.proxy=${PREPROXY} fetch origin"
  win "git -C ${WIN_LUX} reset --hard origin/rebuild/clean-base"
  win "git -C ${WIN_ITUN} -c http.proxy=${PREPROXY} -c https.proxy=${PREPROXY} fetch origin"
  win "git -C ${WIN_ITUN} reset --hard origin/rebuild/clean-base"

  # ── Fix 1: revert mixed->system (macOS agent sets mixed, Windows needs system)
  step "Fixing executor.go: mixed -> system"
  winps "(Get-Content ${WIN_ITUN}\\internal\\executor\\executor.go -Raw).Replace('NewStack(\"mixed\"','NewStack(\"system\"') | Set-Content ${WIN_ITUN}\\internal\\executor\\executor.go -NoNewline"

  # ── Fix 2: ensure dart:convert is imported in core_manager.dart
  step "Ensuring dart:convert import"
  winps "\$f='${WIN_LUX}\\lib\\core\\core_manager.dart'; \$c=[System.IO.File]::ReadAllText(\$f); if(\$c -notmatch 'dart:convert'){[System.IO.File]::WriteAllText(\$f,\$c.Replace(\"import 'dart:async';\",\"import 'dart:async';\`nimport 'dart:convert';\"))}"

  # ── Step 2: Build lux_core.exe ───────────────────────────────────────────
  step "Building lux_core.exe"
  win "set CGO_ENABLED=0 && set GOOS=windows && set GOARCH=amd64 && set GOPROXY=off && set GONOSUMCHECK=* && set GONOSUMDB=* && set GOINSECURE=* && cd ${WIN_ITUN} && go build -ldflags=\"-s -w\" -trimpath -o ..\\lux\\assets\\bin\\lux_core.exe . && echo BUILD_OK"

  # ── Step 3: Update checksum.dart ─────────────────────────────────────────
  step "Updating checksum.dart"
  WIN_HASH=$(winps "(Get-FileHash '${WIN_LUX}\\assets\\bin\\lux_core.exe' -Algorithm SHA256).Hash.ToLower()" | tr -d '[:space:]\r\n')
  echo "Hash: $WIN_HASH"
  winps "\$f='${WIN_LUX}\\lib\\core\\checksum.dart'; \$old=(Select-String 'windowsAmd64Checksum' \$f).Line -replace '.*\"([^\"]+)\".*','\$1'; (Get-Content \$f -Raw).Replace(\$old,'${WIN_HASH}') | Set-Content \$f -NoNewline"

  # ── Step 4: Build Flutter Windows app ────────────────────────────────────
  step "Building Flutter Windows app"
  win "cd ${WIN_LUX} && ${WIN_FLUTTER} build windows --release --no-pub && echo FLUTTER_OK"

  # ── Step 5: Package installer ─────────────────────────────────────────────
  step "Packaging installer (Inno Setup)"
  # Delete any previous output to avoid dist being locked
  winps "Remove-Item '${WIN_DIST}\\*.exe' -Force -ErrorAction SilentlyContinue"

  # Patch dist-setup.iss with new version and output dir
  winps "\$f='${WIN_LUX}\\dist-setup.iss'; \$c=Get-Content \$f -Raw; \$c=\$c -replace '#define MyAppVersion \"[^\"]*\"','#define MyAppVersion \"${WIN_VERSION}\"'; \$c=\$c -replace 'OutputBaseFilename=[^\r\n]*','OutputBaseFilename=lux-${WIN_VERSION}-setup'; \$c=\$c -replace 'OutputDir=[^\r\n]*','OutputDir=C:\\lux-build\\dist2'; [System.IO.File]::WriteAllText(\$f,\$c)"

  win "cd ${WIN_LUX} && \"${WIN_ISCC}\" dist-setup.iss && echo ISCC_OK"

fi

# ── Step 6: Copy installer to Mac via shared folder ───────────────────────
step "Copying installer to macOS"
MAC_DIST="$REPO/dist"
mkdir -p "$MAC_DIST"
MAC_INSTALLER="$MAC_DIST/Lux-${WIN_VERSION}-Windows-x64-Setup.exe"

# Parallels maps macOS home as \\Mac\Home
MAC_WIN_PATH="\\\\Mac\\Home\\lux-clean\\dist\\Lux-${WIN_VERSION}-Windows-x64-Setup.exe"
win "copy \"${INSTALLER}\" \"${MAC_WIN_PATH}\" && echo COPY_OK"

if [ ! -f "$MAC_INSTALLER" ]; then
  echo "ERROR: Installer not found at $MAC_INSTALLER after copy"
  exit 1
fi
echo "Installer: $(ls -lh "$MAC_INSTALLER" | awk '{print $5, $9}')"

# ── Step 7: Copy OAuth token to VM and publish ────────────────────────────
step "Publishing to GDrive + updating appcast"
OAUTH_SRC="$REPO/scripts/.oauth_token.json"
if [ ! -f "$OAUTH_SRC" ]; then
  echo "ERROR: OAuth token not found at $OAUTH_SRC"
  exit 1
fi
# Copy via shared folder (already accessible on Windows side)
win "copy \"\\\\Mac\\Home\\lux-clean\\scripts\\.oauth_token.json\" \"${WIN_LUX}\\scripts\\.oauth_token.json\" && echo TOKEN_OK"

win "cd ${WIN_LUX} && set LUX_RELEASE_PROXY=http://127.0.0.1:1090 && ${WIN_PYTHON} scripts\\publish_appcast_windows.py ${WIN_VERSION} ${INSTALLER} && echo PUBLISH_OK"

# ── Step 8: Verify ────────────────────────────────────────────────────────
step "Verifying appcast"
winps "\$r=Invoke-WebRequest -Uri 'https://drive.usercontent.google.com/download?id=1jf-8thv_VVPIQ3k_n83UhygzEKkydI2p&export=download&confirm=t' -Proxy 'http://127.0.0.1:1090' -UseBasicParsing -TimeoutSec 30; \$j=[System.Text.Encoding]::UTF8.GetString(\$r.Content)|ConvertFrom-Json; Write-Output ('top='+\$j.version+' mac='+\$j.macOS.version+' win='+\$j.windows.version+' win_url='+[bool]\$j.windows.url)"

# ── Step 9: Pull updated appcast.json back to Mac and commit ──────────────
step "Syncing appcast.json"
# The publish script writes appcast.json in the lux repo on Windows;
# pull it back via shared folder
win "copy \"${WIN_LUX}\\appcast.json\" \"\\\\Mac\\Home\\lux-clean\\appcast.json\" && echo SYNC_OK"

cd "$REPO"
git add appcast.json
git commit -m "release(windows): $WIN_VERSION" || echo "# appcast already committed"

echo ""
echo "==> Windows $WIN_VERSION released."
echo "    push when ready: git push origin rebuild/clean-base"
