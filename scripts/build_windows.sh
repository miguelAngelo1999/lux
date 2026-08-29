#!/bin/bash
# build_windows.sh — build and publish the Windows Lux installer from macOS via prlctl.
#
# Usage:
#   bash scripts/build_windows.sh [patch|minor|major]
#   SKIP_BUILD=1 bash scripts/build_windows.sh   # upload existing installer only

set -euo pipefail

VM="Windows 11 (1)"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUMP="${1:-patch}"
SCRIPTS_DIR="$REPO/scripts"

# Proxy for macOS-side operations
if curl -s -o /dev/null --max-time 4 -x http://127.0.0.1:1090 https://example.com 2>/dev/null; then
  MAC_PROXY=http://127.0.0.1:1090
else
  MAC_PROXY=http://127.0.0.1:8079
fi
export https_proxy="$MAC_PROXY" http_proxy="$MAC_PROXY" GIT_SSL_NO_VERIFY=1

step() { echo; echo "==> $1"; }

# Run a command in the VM via cmd /c
win() { prlctl exec "$VM" cmd /c "$*" 2>&1 || true; }

# Write a script file to the Mac shared folder, run it on Windows, then delete
win_script() {
  local name="$1"
  local content="$2"
  local mac_path="$REPO/$name"
  local win_path="\\\\Mac\\Home\\lux-clean\\${name}"
  printf '%s' "$content" > "$mac_path"
  win "$win_path"
  rm -f "$mac_path"
}

win_ps_script() {
  local name="$1"
  local content="$2"
  local mac_path="$REPO/$name"
  local win_path="\\\\Mac\\Home\\lux-clean\\${name}"
  printf '%s' "$content" > "$mac_path"
  # -ExecutionPolicy Bypass needed for UNC path scripts
  prlctl exec "$VM" powershell -NonInteractive -NoProfile -ExecutionPolicy Bypass -File "$win_path" 2>&1 || true
  rm -f "$mac_path"
}

# ── Start VM if needed ────────────────────────────────────────────────────
step "Ensuring VM is running"
VM_STATUS=$(prlctl status "$VM" 2>/dev/null | awk '{print $NF}' || echo "stopped")
if [ "$VM_STATUS" != "running" ]; then
  echo "Starting $VM..."
  prlctl start "$VM"
  sleep 25
fi
win "echo VM_READY"

# ── Determine Windows version ─────────────────────────────────────────────
step "Determining version"
WIN_CURRENT=$(python3 -c "
import json
d = json.load(open('$REPO/appcast.json'))
print(d.get('windows', {}).get('version', d.get('version', '1.0.0')))
")
echo "Current: $WIN_CURRENT"

WIN_VERSION=$(python3 -c "
import sys
cur = '$WIN_CURRENT'; bump = '$BUMP'
v = cur.split('.')
if bump == 'major': v = [str(int(v[0])+1), '0', '0']
elif bump == 'minor': v = [v[0], str(int(v[1])+1), '0']
else: v = [v[0], v[1], str(int(v[2])+1)]
print('.'.join(v))
")
echo "New Windows version: $WIN_VERSION"

INSTALLER_WIN="C:\\lux-build\\dist2\\lux-${WIN_VERSION}-setup.exe"

if [ "${SKIP_BUILD:-}" != "1" ]; then

  # ── Step 1: Sync repos via shared folder ──────────────────────────────────
  step "Syncing repos to VM via shared folder"
  win "robocopy \\\\Mac\\Home\\lux-clean C:\\lux-build\\lux /E /XD .git build dist dist2 /XF *.dmg *.exe pubspec.yaml /NP /NFL /NDL 2>nul & exit 0"
  win "attrib -R C:\\lux-build\\lux\\*.* /S /D >nul 2>&1 & exit 0"
  # Write pubspec.yaml with quoted version to avoid YAML parse issues on Windows Flutter
  WIN_VER_QUOTED="version: \"${WIN_VERSION}+1\""
  PUBSPEC_CONTENT=$(sed "s/^version: .*/version: ${WIN_VERSION}+1/" "$REPO/pubspec.yaml")
  printf '%s' "$PUBSPEC_CONTENT" > "$REPO/pubspec_win.yaml"
  win "copy \"\\\\Mac\\Home\\lux-clean\\pubspec_win.yaml\" \"C:\\lux-build\\lux\\pubspec.yaml\" && echo PUBSPEC_OK"
  rm -f "$REPO/pubspec_win.yaml"
  win "robocopy \\\\Mac\\Home\\itun2socks-clean C:\\lux-build\\itun2socks /E /XD .git /NP /NFL /NDL 2>nul & exit 0"
  win "attrib -R C:\\lux-build\\itun2socks\\*.* /S /D >nul 2>&1 & exit 0"
  echo "Sync done"

  # ── Fix 1: executor.go mixed->system ─────────────────────────────────────
  step "Patching executor.go (mixed->system)"
  win_ps_script "fix_executor.ps1" '
$f = "C:\lux-build\itun2socks\internal\executor\executor.go"
$c = [System.IO.File]::ReadAllText($f)
$c = $c.Replace("NewStack(`"mixed`"", "NewStack(`"system`"")
[System.IO.File]::WriteAllText($f, $c)
Write-Host "executor.go patched"
'

  # ── Fix 2: dart:convert import ───────────────────────────────────────────
  step "Ensuring dart:convert import"
  win_ps_script "fix_convert.ps1" '
$f = "C:\lux-build\lux\lib\core\core_manager.dart"
$c = [System.IO.File]::ReadAllText($f)
if ($c -notmatch "dart:convert") {
    $c = $c.Replace("import ''dart:async'';", "import ''dart:async'';" + [char]10 + "import ''dart:convert'';")
    [System.IO.File]::WriteAllText($f, $c)
    Write-Host "dart:convert added"
} else {
    Write-Host "dart:convert already present"
}
'

  # ── Step 2: Build lux_core.exe ────────────────────────────────────────────
  step "Building lux_core.exe"
  win_script "build_core.bat" '@echo off
setlocal
set CGO_ENABLED=0
set GOOS=windows
set GOARCH=amd64
set GOPROXY=file:///C:/Users/virgoh/go/pkg/mod/cache/download,off
set GONOSUMCHECK=*
set GONOSUMDB=*
set GOINSECURE=*
set GOFLAGS=-mod=mod
cd /d C:\lux-build\itun2socks
go build -ldflags="-s -w" -trimpath -o ..\lux\assets\bin\lux_core.exe .
if %ERRORLEVEL% EQU 0 (echo BUILD_OK) else (echo BUILD_FAILED & exit /b 1)
endlocal
'
  # Verify the binary was produced
  win "if exist C:\\lux-build\\lux\\assets\\bin\\lux_core.exe (echo CORE_EXISTS) else (echo CORE_MISSING)" | grep -q "CORE_EXISTS" || { echo "ERROR: lux_core.exe not found"; exit 1; }

  # ── Step 3: Update checksum.dart ─────────────────────────────────────────
  step "Updating checksum.dart"
  WIN_HASH=$(prlctl exec "$VM" powershell -NonInteractive -NoProfile -Command "(Get-FileHash 'C:\lux-build\lux\assets\bin\lux_core.exe' -Algorithm SHA256).Hash.ToLower()" 2>&1 | tr -d '[:space:]\r\n')
  echo "Hash: $WIN_HASH"

  win_ps_script "fix_checksum.ps1" "
\$f = 'C:\\lux-build\\lux\\lib\\core\\checksum.dart'
\$old = (Select-String 'windowsAmd64Checksum' \$f).Line -replace '.*\"([^\"]+)\".*', '\$1'
(Get-Content \$f -Raw).Replace(\$old, '${WIN_HASH}') | Set-Content \$f -NoNewline
Write-Host 'checksum updated'
"

  # ── Step 4: Flutter build ─────────────────────────────────────────────────
  step "Building Flutter Windows app"
  win_script "build_flutter.bat" '@echo off
setlocal
cd /d C:\lux-build\lux
C:\lux-build\flutter\bin\flutter.bat build windows --release --no-pub
if %ERRORLEVEL% EQU 0 (echo FLUTTER_OK) else (echo FLUTTER_FAILED & exit /b 1)
endlocal
'
  # Verify Flutter output exists
  win "if exist \"C:\\lux-build\\lux\\build\\windows\\x64\\runner\\Release\\lux.exe\" (echo EXE_EXISTS) else (echo EXE_MISSING)" | grep -q "EXE_EXISTS" || { echo "ERROR: Flutter build output not found"; exit 1; }
  # ── Step 5: Package installer ─────────────────────────────────────────────
  step "Packaging installer"
  win "if exist C:\\lux-build\\dist2\\*.exe del /F /Q C:\\lux-build\\dist2\\*.exe >nul 2>&1 & exit 0"
  mkdir -p "$REPO/dist"

  win_ps_script "patch_iss.ps1" "
\$f = 'C:\\lux-build\\lux\\dist-setup.iss'
\$c = Get-Content \$f -Raw
\$c = \$c -replace '#define MyAppVersion \"[^\"]*\"', '#define MyAppVersion \"${WIN_VERSION}\"'
\$c = \$c -replace 'OutputBaseFilename=[^\r\n]*', 'OutputBaseFilename=lux-${WIN_VERSION}-setup'
\$c = \$c -replace 'OutputDir=[^\r\n]*', 'OutputDir=C:\\lux-build\\dist2'
[System.IO.File]::WriteAllText(\$f, \$c)
Write-Host 'iss patched'
"

  ISCC_OUT=$(win "cd C:\\lux-build\\lux && \"C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe\" dist-setup.iss && echo ISCC_OK")
  echo "$ISCC_OUT" | tail -5
  echo "$ISCC_OUT" | grep -q "ISCC_OK" || { echo "ERROR: Inno Setup failed"; exit 1; }

fi

# ── Step 6: Copy installer to Mac ─────────────────────────────────────────
step "Copying installer to macOS"
MAC_INSTALLER="$REPO/dist/Lux-${WIN_VERSION}-Windows-x64-Setup.exe"
win "copy \"${INSTALLER_WIN}\" \"\\\\Mac\\Home\\lux-clean\\dist\\Lux-${WIN_VERSION}-Windows-x64-Setup.exe\" && echo COPY_OK"

[ -f "$MAC_INSTALLER" ] || { echo "ERROR: Installer not found at $MAC_INSTALLER"; exit 1; }
echo "$(ls -lh "$MAC_INSTALLER" | awk '{print $5, $9}')"

# ── Step 7: Publish ───────────────────────────────────────────────────────
step "Publishing to GDrive + updating appcast"
OAUTH_SRC="/Users/virgoh/lux/scripts/.oauth_token.json"
[ -f "$OAUTH_SRC" ] || { echo "ERROR: OAuth token missing at $OAUTH_SRC"; exit 1; }
win "copy \"\\\\Mac\\Home\\lux\\scripts\\.oauth_token.json\" \"C:\\lux-build\\lux\\scripts\\.oauth_token.json\" && echo TOKEN_OK"

win_script "publish.bat" "@echo off
setlocal
set LUX_RELEASE_PROXY=http://127.0.0.1:1090
cd /d C:\\lux-build\\lux
python scripts\\publish_appcast_windows.py ${WIN_VERSION} ${INSTALLER_WIN}
if %ERRORLEVEL% EQU 0 (echo PUBLISH_OK) else (echo PUBLISH_FAILED & exit /b 1)
endlocal
"

# ── Step 8: Sync appcast.json back to Mac ─────────────────────────────────
step "Syncing appcast.json"
win "copy \"C:\\lux-build\\lux\\appcast.json\" \"\\\\Mac\\Home\\lux-clean\\appcast.json\" && echo SYNC_OK"

cd "$REPO"
git add appcast.json
git commit -m "release(windows): $WIN_VERSION" || echo "# nothing to commit"

echo ""
echo "==> Windows $WIN_VERSION released."
echo "    push when ready: git push origin rebuild/clean-base"
