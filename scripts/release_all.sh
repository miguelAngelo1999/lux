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

# ── Logging & Unbuffered Output Setup ─────────────────────────────────────
# Tee all stdout and stderr to /tmp/lux_release.log unbuffered and prevent
# SIGPIPE crashes from killing the script or subshells.
RELEASE_LOG="/tmp/lux_release.log"
: > "$RELEASE_LOG"
trap '' PIPE
exec > >(tee -a "$RELEASE_LOG") 2>&1
export PYTHONUNBUFFERED=1

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUMP="${1:-patch}"
CHANNEL="${2:-beta}"

if [[ "$CHANNEL" != "stable" && "$CHANNEL" != "beta" ]]; then
  echo "FATAL: channel must be 'stable' or 'beta', got '$CHANNEL'"
  exit 1
fi

export PATH="/opt/homebrew/bin:/Users/virgoh/flutter/bin:$PATH"
python3 -c "import os, fcntl; [fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) & ~os.O_NONBLOCK) for fd in (0, 1, 2)]" 2>/dev/null || true

# Shared VM path mapping
REPO_REL="${REPO#$HOME/}"
REPO_WIN_SHARE="\\\\Mac\\Home\\${REPO_REL//\//\\}"

if [ -d "$HOME/itun2socks-clean" ]; then
  ITUN_DIR="$HOME/itun2socks-clean"
elif [ -d "$HOME/itun2socks" ]; then
  ITUN_DIR="$HOME/itun2socks"
else
  ITUN_DIR="$HOME/itun2socks"
fi
ITUN_REL="${ITUN_DIR#$HOME/}"
ITUN_WIN_SHARE="\\\\Mac\\Home\\${ITUN_REL//\//\\}"

if curl -s -o /dev/null --max-time 4 -x http://127.0.0.1:1090 https://example.com 2>/dev/null; then
  PROXY=http://127.0.0.1:1090
else
  PROXY=http://127.0.0.1:8079
fi
export http_proxy="$PROXY" https_proxy="$PROXY" LUX_RELEASE_PROXY="$PROXY"
export DART_IO_ALLOW_BAD_CERTIFICATES=true GIT_SSL_NO_VERIFY=1 PYTHONHTTPSVERIFY=0 REQUESTS_CA_BUNDLE=""

echo "==> Channel: $CHANNEL | Bump: $BUMP | Proxy: $PROXY | Repo: $REPO"
cd "$REPO"

# ── Error Cleanup Trap ────────────────────────────────────────────────────
ORIG_PUBSPEC="$REPO/pubspec.yaml"
ORIG_CHECKSUM="$REPO/lib/core/checksum.dart"
PUBSPEC_BACKUP="$(mktemp /tmp/pubspec.yaml.XXXXXX)"
CHECKSUM_BACKUP="$(mktemp /tmp/checksum.dart.XXXXXX)"
cp "$ORIG_PUBSPEC" "$PUBSPEC_BACKUP"
cp "$ORIG_CHECKSUM" "$CHECKSUM_BACKUP"
OAUTH_TEMP_LINK=""

cleanup_on_err() {
  local ec=$?
  local line=$1
  echo "" >&2
  echo "==> [ERROR] Build failed at line $line (exit code $ec)!" >&2
  if [ -f "$PUBSPEC_BACKUP" ]; then
    echo "==> Restoring original pubspec.yaml from backup..." >&2
    cp -f "$PUBSPEC_BACKUP" "$ORIG_PUBSPEC"
    rm -f "$PUBSPEC_BACKUP"
  fi
  if [ -f "$CHECKSUM_BACKUP" ]; then
    echo "==> Restoring original checksum.dart from backup..." >&2
    cp -f "$CHECKSUM_BACKUP" "$ORIG_CHECKSUM"
    rm -f "$CHECKSUM_BACKUP"
  fi
  if [ -n "$OAUTH_TEMP_LINK" ] && [ -e "$OAUTH_TEMP_LINK" ]; then
    rm -f "$OAUTH_TEMP_LINK"
  fi
  sync 2>/dev/null || true
  exit "$ec"
}
trap 'cleanup_on_err $LINENO' ERR INT TERM

# ── Helper: CLIXML Stripper ───────────────────────────────────────────────
strip_clixml() {
  python3 -c '
import sys, re
raw = sys.stdin.read()
cleaned = re.sub(r"#< CLIXML[\s\S]*?</Objs>\r?\n?", "", raw)
lines = []
for line in cleaned.splitlines():
    if re.match(r"^\s*</?(Objs|S|Obj|MS|B|I32|I64|Props)\b", line):
        continue
    if line.startswith("#< CLIXML"):
        continue
    lines.append(line)
print("\n".join(lines))
'
}

# ── Helper: Python 3.11 Detection ─────────────────────────────────────────
detect_python311() {
  local candidates=(
    "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3"
    "/opt/homebrew/bin/python3.11"
    "/usr/local/bin/python3.11"
    "$(which python3.11 2>/dev/null || true)"
    "$(which python3 2>/dev/null || true)"
  )
  for py in "${candidates[@]}"; do
    if [ -n "$py" ] && [ -x "$py" ]; then
      if "$py" -c "import googleapiclient" 2>/dev/null; then
        echo "$py"
        return 0
      fi
    fi
  done
  for py in "${candidates[@]}"; do
    if [ -n "$py" ] && [ -x "$py" ]; then
      echo "$py"
      return 0
    fi
  done
  echo "python3"
}
UPLOAD_PY=$(detect_python311)
echo "==> Python for upload: $UPLOAD_PY"

# ── Helper: OAuth Token Verification & Symlinking ─────────────────────────
find_oauth_token() {
  local candidates=(
    "$REPO/scripts/.oauth_token.json"
    "$REPO/../lux/scripts/.oauth_token.json"
    "/Users/virgoh/lux/scripts/.oauth_token.json"
    "$HOME/lux/scripts/.oauth_token.json"
    "$HOME/.config/lux/.oauth_token.json"
    "$HOME/.oauth_token.json"
  )
  for c in "${candidates[@]}"; do
    if [ -f "$c" ] && [ -s "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

OAUTH_TARGET="$REPO/scripts/.oauth_token.json"
FOUND_OAUTH_TOKEN=$(find_oauth_token || true)
if [ -z "$FOUND_OAUTH_TOKEN" ]; then
  echo "FATAL: Google Drive OAuth token (.oauth_token.json) not found in candidate paths!" >&2
  echo "       Checked: \$REPO/scripts/, /Users/virgoh/lux/scripts/, ~/.config/lux/, ~/" >&2
  exit 1
fi

if [ ! -f "$OAUTH_TARGET" ]; then
  echo "==> Symlinking OAuth token: $FOUND_OAUTH_TOKEN → $OAUTH_TARGET"
  ln -sf "$FOUND_OAUTH_TOKEN" "$OAUTH_TARGET"
  OAUTH_TEMP_LINK="$OAUTH_TARGET"
else
  echo "==> OAuth token found at: $OAUTH_TARGET"
fi
export LUX_OAUTH_TOKEN="$OAUTH_TARGET"

# Ensure legacy path expected by publish_appcast.py exists if parent directory exists
if [ -d "/Users/virgoh/lux/scripts" ] && [ ! -f "/Users/virgoh/lux/scripts/.oauth_token.json" ]; then
  ln -sf "$FOUND_OAUTH_TOKEN" "/Users/virgoh/lux/scripts/.oauth_token.json" 2>/dev/null || true
fi

# ── Step 1: Determine new version ─────────────────────────────────────────
CURRENT=$(grep "^version:" pubspec.yaml | sed 's/version: //' | cut -d'+' -f1)
VERSION=$(python3 -c "
import sys
cur = '$CURRENT'; bump = '$BUMP'
v = cur.split('.')
if bump == 'major': v = [str(int(v[0])+1),'0','0']
elif bump == 'minor': v = [v[0], str(int(v[1])+1), '0']
elif '.' in bump: v = bump.split('.')
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
sync
for i in 1 2 3 4 5; do
  hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 && break || sleep 2
done
rm -f "dist/$DMG_NAME"   # -ov below also overwrites, but clear it so a stale same-name DMG never blocks convert
hdiutil convert /tmp/lux_tmp.dmg -format UDZO -ov -o "dist/$DMG_NAME" >/dev/null
rm -f /tmp/lux_tmp.dmg; rm -rf "$DMG_STAGE"
hdiutil verify "dist/$DMG_NAME" >/dev/null
bash "$REPO/scripts/sign_and_notarize.sh" dmg "dist/$DMG_NAME" 2>/dev/null || true
echo "==> macOS DMG ready: dist/$DMG_NAME ($(ls -lh "dist/$DMG_NAME" | awk '{print $5}'))"

# ── Step 4: Build Windows (via Parallels VM) ──────────────────────────────
echo "==> Building Windows..."
VM="Windows 11 (1)"
WIN_LUX="C:\\lux-build\\lux"
INSTALLER_WIN="C:\\lux-build\\dist2\\lux-${VERSION}-setup.exe"

win() {
  local cmd="$*"
  local out="" attempt=1 ec=0
  for attempt in 1 2 3 4 5; do
    ec=0
    out=$(prlctl exec "$VM" cmd /c "$cmd" 2>&1) || ec=$?
    if echo "$out" | grep -q -E "(PrlJob_|Unable to open new session|PrlVmGuest_RunProgram|Failed to get session|guest OS is not available)"; then
      echo "==> [retry $attempt] prlctl cmd transient error, waiting 2s..." >&2
      sleep 2
      continue
    fi
    echo "$out"
    return "$ec"
  done
  echo "ERROR: prlctl cmd failed after 5 attempts: $out" >&2
  echo "$out"
  return 1
}

win_ps_script() {
  local name="$1" content="$2"
  printf '%s' "$content" > "$REPO/$name"
  local copied=false
  for copy_att in 1 2 3 4 5; do
    win "copy /y \"${REPO_WIN_SHARE}\\${name}\" \"C:\\lux-build\\${name}\" >nul" >/dev/null 2>&1 || true
    local chk=""
    chk=$(win "if exist \"C:\\lux-build\\${name}\" (echo FILE_EXISTS)" 2>/dev/null || true)
    if echo "$chk" | grep -q "FILE_EXISTS"; then
      copied=true
      break
    fi
    sleep 2
  done
  if [ "$copied" != "true" ]; then
    echo "ERROR: Failed to copy $name to VM after 5 attempts" >&2
    rm -f "$REPO/$name"
    return 1
  fi

  local out="" attempt=1 ec=0
  for attempt in 1 2 3 4 5; do
    ec=0
    out=$(prlctl exec "$VM" powershell -NonInteractive -NoProfile -ExecutionPolicy Bypass \
      -File "C:\\lux-build\\${name}" 2>&1) || ec=$?
    if echo "$out" | grep -q -E "(PrlJob_|Unable to open new session|PrlVmGuest_RunProgram|Failed to get session|guest OS is not available)"; then
      echo "==> [retry $attempt] prlctl ps transient error, waiting 2s..." >&2
      sleep 2
      continue
    fi
    break
  done
  win "del /f /q \"C:\\lux-build\\${name}\" >nul 2>&1 & exit 0" >/dev/null 2>&1 || true
  rm -f "$REPO/$name"

  # Strip CLIXML cleanly without eating valid output starting with '<'
  out=$(echo "$out" | strip_clixml)
  echo "$out"
  return "$ec"
}

win_robocopy() {
  local args="$*"
  # Robocopy exit codes:
  # 0-7: Success (0=no change, 1=copied, 2=extra, etc.)
  # >=8: Error (8=copy errors, 16=fatal error)
  # Mask 0-7 to 0, >=8 to 1 so set -e trips only on genuine failures.
  win "robocopy ${args} & if errorlevel 8 (exit 1) else (exit 0)"
}

VM_STATUS=$(prlctl status "$VM" 2>/dev/null | awk '{print $NF}' || echo "stopped")
if [ "$VM_STATUS" != "running" ]; then prlctl start "$VM"; sleep 25; fi
win "echo VM_READY"

# Kill any stale compiler helper processes before starting build
win "taskkill /F /IM vctip.exe >nul 2>&1 & exit 0" >/dev/null 2>&1 || true

# Sync repos using hardened robocopy wrapper
win_robocopy "${REPO_WIN_SHARE}" "C:\\lux-build\\lux" /E /XD .git build dist dist2 /XF *.dmg *.exe pubspec.yaml /NP /NFL /NDL 2>nul
win "attrib -R C:\\lux-build\\lux\\*.* /S /D >nul 2>&1 & exit 0"
win "del /F C:\\lux-build\\lux\\.flutter-plugins C:\\lux-build\\lux\\.flutter-plugins-dependencies >nul 2>&1 & exit 0"
# Also remove hooks_runner which can be locked as Hidden+ReadOnly after robocopy
win "if exist C:\\lux-build\\lux\\.dart_tool\\hooks_runner attrib -R -H C:\\lux-build\\lux\\.dart_tool\\hooks_runner /S /D >nul 2>&1 & exit 0"
win "if exist C:\\lux-build\\lux\\.dart_tool\\hooks_runner rmdir /S /Q C:\\lux-build\\lux\\.dart_tool\\hooks_runner >nul 2>&1 & exit 0"

# Write pubspec with Windows version
PUBSPEC_WIN=$(sed "s/^version: .*/version: ${VERSION}+1/" "$REPO/pubspec.yaml")
printf '%s' "$PUBSPEC_WIN" > "$REPO/pubspec_win.yaml"
win "copy \"${REPO_WIN_SHARE}\\pubspec_win.yaml\" \"C:\\lux-build\\lux\\pubspec.yaml\" && echo PUBSPEC_OK"
rm -f "$REPO/pubspec_win.yaml"

win_robocopy "${ITUN_WIN_SHARE}" "C:\\lux-build\\itun2socks" /E /XD .git /NP /NFL /NDL 2>nul
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
WIN_HASH=$(win_ps_script "hash.ps1" "(Get-FileHash 'C:\lux-build\lux\assets\bin\lux_core.exe' -Algorithm SHA256).Hash.ToLower()" | tr -d '[:space:]\r\n')
echo "==> Windows core hash: $WIN_HASH"
python3 -c "
import re
with open('$REPO/lib/core/checksum.dart') as f: c = f.read()
c = re.sub(r'windowsAmd64Checksum = \"[a-f0-9]+\"', 'windowsAmd64Checksum = \"$WIN_HASH\"', c)
with open('$REPO/lib/core/checksum.dart', 'w') as f: f.write(c)
"
win "copy \"${REPO_WIN_SHARE}\\lib\\core\\checksum.dart\" \"C:\\lux-build\\lux\\lib\\core\\checksum.dart\" && echo CHECKSUM_SYNCED"

# Build Flutter Windows with vctip guard and timeout.
FLUTTER_OUT=$(win_ps_script "build_flutter.ps1" '
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$env:PUB_CACHE = "C:\Users\virgoh\AppData\Local\Pub\Cache"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:VCPKG_DISABLE_METRICS = "1"

function Stop-LingeringBuildHelpers {
  Get-Process -Name "vctip" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

Stop-LingeringBuildHelpers

Remove-Item -Force "C:\lux-build\flutter_build_result.txt" -ErrorAction SilentlyContinue
Set-Location C:\lux-build\lux
# Clear read-only/hidden/system on the tree so flutter can write the plugin
# registrant (.flutter-plugins-dependencies)
& attrib -R -H -S C:\lux-build\lux\*.* /S /D 2>$null
foreach ($f in @(".flutter-plugins",".flutter-plugins-dependencies")) {
  if (Test-Path $f) { & attrib -R -H -S $f 2>$null; Remove-Item -Force $f -ErrorAction SilentlyContinue }
}
if (Test-Path windows\flutter\ephemeral) { Remove-Item -Recurse -Force windows\flutter\ephemeral -ErrorAction SilentlyContinue }
if (Test-Path .dart_tool\hooks_runner) { Remove-Item -Recurse -Force .dart_tool\hooks_runner -ErrorAction SilentlyContinue }

$exe = "build\windows\x64\runner\Release\lux.exe"
if (Test-Path $exe) { Remove-Item -Force $exe -ErrorAction SilentlyContinue }

& "C:\lux-build\flutter\bin\flutter.bat" pub get --offline
if (-not (Test-Path ".flutter-plugins-dependencies")) {
  Write-Host "FLUTTER_FAILED: pub get did not write .flutter-plugins-dependencies"; exit 1
}

$p = Start-Process -FilePath "C:\lux-build\flutter\bin\flutter.bat" `
     -ArgumentList "build","windows","--release","--no-pub" `
     -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) {
  Write-Host "==> First build attempt exited with $($p.ExitCode), retrying once..."
  $p = Start-Process -FilePath "C:\lux-build\flutter\bin\flutter.bat" `
       -ArgumentList "build","windows","--release","--no-pub" `
       -Wait -PassThru -NoNewWindow
}
if ($p.ExitCode -ne 0) {
  Write-Host "FLUTTER_FAILED: build exit $($p.ExitCode)"
  exit 1
}
if (-not (Test-Path $exe)) {
  Set-Content -Path "C:\lux-build\flutter_build_result.txt" -Value "FLUTTER_FAILED: no lux.exe produced" -NoNewline
  Write-Host "FLUTTER_FAILED: no lux.exe produced"
  exit 1
}
Set-Content -Path "C:\lux-build\flutter_build_result.txt" -Value "FLUTTER_OK" -NoNewline
Write-Host "FLUTTER_OK"
') || true
echo "$FLUTTER_OUT" | tail -5

# Ensure no lingering vctip survives the Flutter step on the host VM
win "taskkill /F /IM vctip.exe >nul 2>&1 & exit 0" >/dev/null 2>&1 || true

# Read the result from the sentinel file the PS script wrote, which survives a
# prlctl-exec stdout wedge (2026-11-01). Fall back to captured stdout only if
# the sentinel is unreadable.
FLUTTER_RESULT=$(win "type C:\\lux-build\\flutter_build_result.txt" | tr -d '\r\n')
if [ "$FLUTTER_RESULT" != "FLUTTER_OK" ]; then
  if echo "$FLUTTER_OUT" | grep -q "FLUTTER_OK"; then
    echo "WARN: sentinel unreadable ('$FLUTTER_RESULT') but stdout shows FLUTTER_OK — trusting stdout"
  else
    echo "ERROR: Windows Flutter build failed — aborting release so a stale lux.exe is never packaged/published."
    echo "       sentinel='$FLUTTER_RESULT'. Common cause: read-only .flutter-plugins-dependencies from the SMB robocopy, or pub-cache empty stubs."
    exit 1
  fi
fi

# Bundle the Visual C++ runtime next to lux.exe (app-local deployment).
VCRT_OUT=$(win_ps_script "bundle_vcrt.ps1" '
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$rel = "C:\lux-build\lux\build\windows\x64\runner\Release"
$required = @("msvcp140.dll","vcruntime140.dll","vcruntime140_1.dll")
$optional = @("msvcp140_1.dll","msvcp140_2.dll","concrt140.dll")
$src = $null
foreach ($root in @("C:\Program Files\Microsoft Visual Studio","C:\Program Files (x86)\Microsoft Visual Studio")) {
  if (-not (Test-Path $root)) { continue }
  $dirs = Get-ChildItem -Path $root -Recurse -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -match "\\x64\\" -and $_.FullName -notmatch "\\onecore\\" -and $_.FullName -notmatch "\\debug_nonredist\\" } |
          Sort-Object FullName -Descending
  foreach ($d in $dirs) {
    $ok = $true
    foreach ($n in $required) { if (-not (Test-Path (Join-Path $d.FullName $n))) { $ok = $false } }
    if ($ok) { $src = $d.FullName; break }
  }
  if ($src) { break }
}
if (-not $src) { $src = "C:\Windows\System32" }
Write-Host "VCRT_SRC $src"
$missing = @()
foreach ($n in $required) {
  $p = Join-Path $src $n
  if (Test-Path $p) { Copy-Item -Force $p (Join-Path $rel $n) } else { $missing += $n }
}
foreach ($n in $optional) {
  $p = Join-Path $src $n
  if (Test-Path $p) { Copy-Item -Force $p (Join-Path $rel $n) }
}
if ($missing.Count -gt 0) { Write-Host ("VCRT_MISSING " + ($missing -join ",")); exit 1 }
foreach ($n in $required) {
  if (-not (Test-Path (Join-Path $rel $n))) { Write-Host "VCRT_MISSING $n (not in Release folder)"; exit 1 }
}
Write-Host "VCRT_OK"
')
echo "$VCRT_OUT" | grep -E "VCRT_" || true
echo "$VCRT_OUT" | grep -q "VCRT_OK" || {
  echo "ERROR: could not bundle the Visual C++ runtime (msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll) into the Windows Release folder."
  echo "       Without them the installer fails on PCs lacking the VC++ Redistributable. Install the VC++ x64 redist or Visual Studio on the build VM, then rerun."
  exit 1
}

# The DLLs only help if the installer script packs the Release folder they were
# copied into. Refuse to build if the VM's ISS never references it.
ISS_SRC=$(win_ps_script "check_iss_source.ps1" '
$c = Get-Content "C:\lux-build\lux\dist-setup.iss" -Raw
if ($c -match "(?i)runner\\Release") { Write-Host "ISS_SRC_OK" } else { Write-Host "ISS_SRC_MISSING" }
')
echo "$ISS_SRC" | grep -E "ISS_SRC_" || true
echo "$ISS_SRC" | grep -q "ISS_SRC_OK" || { echo "ERROR: C:\\lux-build\\lux\\dist-setup.iss does not reference build\\windows\\x64\\runner\\Release — the bundled VC++ DLLs would not be packed. Fix the Source line."; exit 1; }

# Package installer
win "if exist C:\\lux-build\\dist2\\*.exe del /F /Q C:\\lux-build\\dist2\\*.exe >nul 2>&1 & exit 0"
for patch_attempt in 1 2 3 4 5; do
  win_ps_script "patch_iss.ps1" "
\$f = 'C:\\lux-build\\lux\\dist-setup.iss'
\$c = Get-Content \$f -Raw
\$c = \$c -replace 'AppVersion=[^\r\n]*', 'AppVersion=${VERSION}'
\$c = \$c -replace '#define MyAppVersion \"[^\"]*\"', '#define MyAppVersion \"${VERSION}\"'
\$c = \$c -replace 'OutputBaseFilename=[^\r\n]*', 'OutputBaseFilename=lux-${VERSION}-setup'
\$c = \$c -replace 'OutputDir=[^\r\n]*', 'OutputDir=C:\\lux-build\\dist2'
[System.IO.File]::WriteAllText(\$f, \$c)
Write-Host 'iss patched'
"
  sleep 1
  iss_ver=$(win "type C:\\lux-build\\lux\\dist-setup.iss")
  if [[ "$iss_ver" == *"OutputBaseFilename=lux-${VERSION}-setup"* ]]; then
    echo "==> dist-setup.iss verified for $VERSION"
    break
  fi
  echo "==> [retry $patch_attempt] Waiting 2s before retrying patch_iss..."
  sleep 2
done
iss_ver=$(win "type C:\\lux-build\\lux\\dist-setup.iss")
if [[ "$iss_ver" != *"OutputBaseFilename=lux-${VERSION}-setup"* ]]; then
  echo "ERROR: dist-setup.iss not patched with $VERSION"
  exit 1
fi

ISS_CHECK=$(win_ps_script "ensure_iss_kill.ps1" '
$f = "C:\lux-build\lux\dist-setup.iss"
$c = Get-Content $f -Raw
$c2 = [regex]::Replace($c, "(?m)^[ \t]*(AppMutex|CloseApplications|RestartApplications)[ \t]*=[^\r\n]*\r?\n", "")
if ($c2 -ne $c) { [System.IO.File]::WriteAllText($f, $c2); Write-Host "ISS_PROMPT_DIRECTIVES_REMOVED" }
if (($c2 -match "procedure KillLux") -and ($c2 -match "function InitializeSetup")) { Write-Host "ISS_KILL_OK" } else { Write-Host "ISS_KILL_MISSING" }
')
echo "$ISS_CHECK" | grep -E "ISS_" || true
echo "$ISS_CHECK" | grep -q "ISS_KILL_OK" || { echo "ERROR: Windows installer script has no auto-kill (KillLux/InitializeSetup) — would prompt and hang. Fix C:\\lux-build\\lux\\dist-setup.iss from windows/packaging/exe/setup.iss"; exit 1; }
win "cd C:\\lux-build\\lux && \"C:\\Program Files (x86)\\Inno Setup 6\\ISCC.exe\" dist-setup.iss && echo ISCC_OK" | grep -q "ISCC_OK" || { echo "ERROR: Inno Setup failed"; exit 1; }

# Copy to Mac
mkdir -p "$REPO/dist"
WIN_INSTALLER="$REPO/dist/Lux-${VERSION}-Windows-x64-Setup.exe"
rm -f "$WIN_INSTALLER"   # never let a previous version's installer masquerade as this one
win_robocopy "C:\\lux-build\\dist2" "${REPO_WIN_SHARE}\\dist" "lux-${VERSION}-setup.exe" /NP /R:3 /W:5
[ -f "$REPO/dist/lux-${VERSION}-setup.exe" ] && mv -f "$REPO/dist/lux-${VERSION}-setup.exe" "$WIN_INSTALLER"
[ -f "$WIN_INSTALLER" ] || { echo "ERROR: Windows installer not found — ISCC output missing or copy failed"; exit 1; }
WIN_SIZE=$(stat -f%z "$WIN_INSTALLER" 2>/dev/null || echo 0)
[ "$WIN_SIZE" -ge 5000000 ] || { echo "ERROR: Windows installer is only ${WIN_SIZE} bytes — too small, aborting"; exit 1; }
echo "==> Windows installer ready: $(ls -lh "$WIN_INSTALLER" | awk '{print $5, $9}')"

# ── Step 5: Upload BOTH platforms, then update appcast atomically ──────────
echo "==> Uploading both platforms..."

# Upload macOS DMG
$UPLOAD_PY "$REPO/scripts/publish_appcast.py" "$VERSION" "dist/$DMG_NAME" --channel "$CHANNEL"

# Upload Windows installer
$UPLOAD_PY "$REPO/scripts/publish_appcast_windows.py" "$VERSION" "$WIN_INSTALLER" --channel "$CHANNEL"

# ── Step 6: Commit and push ────────────────────────────────────────────────
# Remove temporary OAuth token symlink before staging git files
if [ -n "$OAUTH_TEMP_LINK" ] && [ -e "$OAUTH_TEMP_LINK" ]; then
  rm -f "$OAUTH_TEMP_LINK"
  OAUTH_TEMP_LINK=""
fi

git add pubspec.yaml lib/core/checksum.dart lib/core/core_manager.dart scripts/release_all.sh
if [ "$CHANNEL" == "beta" ]; then
  git add appcast-beta.json 2>/dev/null || true
  git commit -m "release (beta): $VERSION"
else
  git add appcast.json 2>/dev/null || true
  git commit -m "release: $VERSION"
fi

# Release commit succeeded — remove backups and disarm error trap
rm -f "$PUBSPEC_BACKUP" "$CHECKSUM_BACKUP"
trap - ERR INT TERM

echo ""
echo "==> $VERSION released on $CHANNEL (macOS + Windows)"
echo "    push when ready: git push origin rebuild/clean-base"

# ── Step 7: Update download page ──────────────────────────────────────────
echo "==> Updating download page..."
PAGE="$REPO/scripts/release-page/index.html"
# Update version number in the page
sed -i '' "s/v1\.[0-9]*\.[0-9]*/v${VERSION}/g" "$PAGE"

# Publish to here.now if credentials exist
if [ -f "$HOME/.herenow/credentials" ]; then
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
dest = result.get('primaryUrl') or result.get('accountUrl') or 'https://download.lux.here.now'
print(f"Download page updated: {result.get('publishStatus',{}).get('state')} -> {dest}")
PYEOF
else
  echo "WARN: ~/.herenow/credentials not found, skipping download page update"
fi
