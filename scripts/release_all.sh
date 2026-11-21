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

if curl -s -k -o /dev/null --max-time 4 -x http://127.0.0.1:1090 https://google.com 2>/dev/null; then
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
MAC_PID=""
WIN_PID=""

cleanup_on_err() {
  local ec=$?
  local line=$1
  echo "" >&2
  echo "==> [ERROR] Build failed at line $line (exit code $ec)!" >&2
  [ -n "${MAC_PID:-}" ] && kill "$MAC_PID" 2>/dev/null || true
  [ -n "${WIN_PID:-}" ] && kill "$WIN_PID" 2>/dev/null || true
  rm -f "$REPO/dist/win_lux_core.exe" "$REPO/dist/win_build_all.ps1" 2>/dev/null || true
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
raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
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

# ── Step 2: Bump pubspec & render ISS ──────────────────────────────────────
sed -i '' "s/^version: .*/version: ${VERSION}+1/" pubspec.yaml
echo "==> pubspec bumped to $VERSION+1"
python3 "$REPO/render_iss.py" "$VERSION"
python3 -c "
import re
p = '$REPO/dist-setup.iss'
with open(p, encoding='utf-8-sig') as f:
    c = f.read()
if '$CHANNEL' == 'beta':
    comp, solid = 'lzma2/fast', 'no'
else:
    comp, solid = 'lzma', 'yes'
c = re.sub(r'(?m)^Compression=.*$', f'Compression={comp}', c)
c = re.sub(r'(?m)^SolidCompression=.*$', f'SolidCompression={solid}', c)
with open(p, 'w', encoding='utf-8-sig') as f:
    f.write(c)
"
echo "==> dist-setup.iss configured for $CHANNEL compression"

# Never bundle Windows lux_core.exe inside macOS app assets
rm -f "$REPO/assets/bin/lux_core.exe" 2>/dev/null || true

# ── Step 2.5: Cross-compile & cache Windows lux_core.exe natively on Mac ──
WIN_CORE_CACHE_DIR="/tmp/lux-win-core-cache"
WIN_CORE_CACHED_EXE="$WIN_CORE_CACHE_DIR/lux_core.exe"
WIN_CORE_CACHE_KEY_FILE="$WIN_CORE_CACHE_DIR/cache.key"
mkdir -p "$WIN_CORE_CACHE_DIR"

ITUN_HEAD=$(git -C "$ITUN_DIR" rev-parse HEAD 2>/dev/null || echo "no-git")
ITUN_DIFF_HASH=$(git -C "$ITUN_DIR" diff 2>/dev/null | shasum -a 256 | awk '{print $1}')
WIN_CORE_KEY="${ITUN_HEAD}:${ITUN_DIFF_HASH}"

if [ -s "$WIN_CORE_CACHED_EXE" ] && [ -f "$WIN_CORE_CACHE_KEY_FILE" ] && [ "$(cat "$WIN_CORE_CACHE_KEY_FILE")" = "$WIN_CORE_KEY" ]; then
  echo "==> Windows lux_core.exe cache HIT ($WIN_CORE_KEY)"
else
  echo "==> Windows lux_core.exe cache MISS — cross-compiling on Mac..."
  CORE_T0=$(date +%s)
  ITUN_TMP=$(mktemp -d /tmp/lux-itun-build.XXXXXX)
  rsync -a --exclude='.git' --exclude='lux_core' --exclude='lux_core_*.zip' "$ITUN_DIR/" "$ITUN_TMP/"
  python3 -c "
import pathlib
p = pathlib.Path('$ITUN_TMP/internal/executor/executor.go')
if p.exists():
    c = p.read_text()
    c2 = c.replace('NewStack(\"mixed\"', 'NewStack(\"system\"')
    if c2 != c:
        p.write_text(c2)
"
  WIN_CORE_TMP_OUT="$WIN_CORE_CACHE_DIR/lux_core.exe.tmp.$$"
  (
    cd "$ITUN_TMP"
    CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" -trimpath -o "$WIN_CORE_TMP_OUT" .
  )
  rm -rf "$ITUN_TMP"
  [ -s "$WIN_CORE_TMP_OUT" ] || { echo "ERROR: Mac Go cross-compile of lux_core.exe failed"; exit 1; }
  mv -f "$WIN_CORE_TMP_OUT" "$WIN_CORE_CACHED_EXE"
  printf '%s' "$WIN_CORE_KEY" > "$WIN_CORE_CACHE_KEY_FILE"
  CORE_DT=$(( $(date +%s) - CORE_T0 ))
  echo "==> Windows lux_core.exe compiled in ${CORE_DT}s and cached ($WIN_CORE_KEY)"
fi

WIN_HASH=$(shasum -a 256 "$WIN_CORE_CACHED_EXE" | awk '{print $1}')
echo "==> Windows core hash: $WIN_HASH"
python3 -c "
import re
with open('$REPO/lib/core/checksum.dart') as f: c = f.read()
c = re.sub(r'windowsAmd64Checksum = \"[a-f0-9]*\"', 'windowsAmd64Checksum = \"$WIN_HASH\"', c)
with open('$REPO/lib/core/checksum.dart', 'w') as f: f.write(c)
"

# ── Step 3 & 4: Build macOS + Windows concurrently ────────────────────────
DMG_NAME="Lux-${VERSION}-macOS-universal.dmg"
WIN_INSTALLER="$REPO/dist/Lux-${VERSION}-Windows-x64-Setup.exe"
mkdir -p "$REPO/dist"

build_macos() {
  trap - ERR INT TERM
  set -euo pipefail
  local t0
  t0=$(date +%s)
  echo "==> [macOS] Building..."
  rm -f "$REPO/assets/bin/lux_core.exe" 2>/dev/null || true

  local APP="build/macos/Build/Products/Release/Lux.app"
  flutter build macos --release --no-pub
  xattr -cr "$APP"
  bash "$REPO/scripts/sign_and_notarize.sh" app "$APP" 2>/dev/null || true

  # Build DMG
  local DMG_STAGE="/tmp/lux-dmg-stage"
  rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
  cp -R "$APP" "$DMG_STAGE/"
  cp "$REPO/macos/install.sh" "$DMG_STAGE/"
  local SIZE_KB
  SIZE_KB=$(du -sk "$DMG_STAGE" | awk '{print $1}')
  SIZE_KB=$((SIZE_KB + 5000))
  hdiutil create -size "${SIZE_KB}k" -fs HFS+ -volname "Lux $VERSION" -ov /tmp/lux_tmp.dmg >/dev/null
  local MOUNT_DIR
  MOUNT_DIR=$(hdiutil attach /tmp/lux_tmp.dmg | grep "/Volumes" | awk -F'\t' '{print $NF}')
  cp -R "$DMG_STAGE/Lux.app" "$MOUNT_DIR/"
  cp "$DMG_STAGE/install.sh" "$MOUNT_DIR/"
  sync
  for i in 1 2 3 4 5; do
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 && break || sleep 2
  done
  rm -f "dist/$DMG_NAME"   # -ov below also overwrites, but clear it so a stale same-name DMG never blocks convert
  if [ "$CHANNEL" == "beta" ]; then
    echo "==> [macOS] Compressing beta DMG (zlib-level=1)..."
    hdiutil convert /tmp/lux_tmp.dmg -format UDZO -imagekey zlib-level=1 -ov -o "dist/$DMG_NAME" >/dev/null
  else
    echo "==> [macOS] Compressing stable DMG..."
    hdiutil convert /tmp/lux_tmp.dmg -format UDZO -ov -o "dist/$DMG_NAME" >/dev/null
  fi
  rm -f /tmp/lux_tmp.dmg; rm -rf "$DMG_STAGE"
  hdiutil verify "dist/$DMG_NAME" >/dev/null
  bash "$REPO/scripts/sign_and_notarize.sh" dmg "dist/$DMG_NAME" 2>/dev/null || true
  local dt=$(( $(date +%s) - t0 ))
  echo "==> [macOS] DMG ready in ${dt}s: dist/$DMG_NAME ($(ls -lh "dist/$DMG_NAME" | awk '{print $5}'))"
}

build_windows() {
  trap - ERR INT TERM
  set -euo pipefail
  local t0
  t0=$(date +%s)
  echo "==> [Windows] Building..."
  local VM="Windows 11 (1)"

  win() {
    local cmd="$*"
    local out="" attempt=1 ec=0
    for attempt in 1 2 3 4 5; do
      ec=0
      out=$(prlctl exec "$VM" cmd /c "$cmd" 2>&1) || ec=$?
      if echo "$out" | grep -q -E "(PrlJob_|Unable to open new session|PrlVmGuest_RunProgram|Failed to get session|guest OS is not available)"; then
        echo "==> [Windows][retry $attempt] prlctl cmd transient error, waiting 2s..." >&2
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

  win_ps_file() {
    local name="$1"
    local copied=false
    for copy_att in 1 2 3 4 5; do
      win "copy /y \"${REPO_WIN_SHARE}\\dist\\${name}\" \"C:\\lux-build\\${name}\" >nul" >/dev/null 2>&1 || true
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
      rm -f "$REPO/dist/$name"
      return 1
    fi

    local out="" attempt=1 ec=0
    for attempt in 1 2 3 4 5; do
      ec=0
      out=$(prlctl exec "$VM" powershell -NonInteractive -NoProfile -ExecutionPolicy Bypass \
        -File "C:\\lux-build\\${name}" 2>&1) || ec=$?
      if echo "$out" | grep -q -E "(PrlJob_|Unable to open new session|PrlVmGuest_RunProgram|Failed to get session|guest OS is not available)"; then
        echo "==> [Windows][retry $attempt] prlctl ps transient error, waiting 2s..." >&2
        sleep 2
        continue
      fi
      break
    done
    win "del /f /q \"C:\\lux-build\\${name}\" >nul 2>&1 & exit 0" >/dev/null 2>&1 || true
    rm -f "$REPO/dist/$name"

    # Strip CLIXML cleanly without eating valid output starting with '<'
    out=$(echo "$out" | strip_clixml)
    echo "$out"
    return "$ec"
  }

  local VM_STATUS
  VM_STATUS=$(prlctl status "$VM" 2>/dev/null | awk '{print $NF}' || echo "stopped")
  if [ "$VM_STATUS" != "running" ]; then
    echo "==> [Windows] Starting VM '$VM'..."
    prlctl start "$VM"
  fi

  echo "==> [Windows] Waiting for VM_READY (polling every 2s, up to 60s)..."
  local VM_UP=false poll_i=0
  for poll_i in $(seq 1 30); do
    if prlctl exec "$VM" cmd /c "echo VM_READY" 2>/dev/null | grep -q "VM_READY"; then
      VM_UP=true
      echo "==> [Windows] VM_READY (elapsed $(( (poll_i - 1) * 2 ))s)"
      break
    fi
    sleep 2
  done
  if [ "$VM_UP" != "true" ]; then
    echo "ERROR: Windows VM did not become ready within 60s" >&2
    return 1
  fi

  rm -f "$WIN_INSTALLER" "$REPO/dist/lux-${VERSION}-setup.exe"

  local ps_name="win_build_all.ps1"
  cat > "$REPO/dist/$ps_name" <<PSEOF
\$Version = "${VERSION}"
\$Channel = "${CHANNEL}"
\$RepoShare = "${REPO_WIN_SHARE}"
PSEOF
  cat >> "$REPO/dist/$ps_name" <<'PSEOF'
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$env:PUB_CACHE = "C:\Users\virgoh\AppData\Local\Pub\Cache"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:VCPKG_DISABLE_METRICS = "1"
$env:VCToolsTelemetry = "0"
$env:VSCMD_SKIP_SENDTELEMETRY = "1"
$env:MSBUILDDISABLENODEREUSE = "1"

function Stop-LingeringBuildHelpers {
  Get-Process -Name "vctip" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  & taskkill.exe /F /IM vctip.exe 2>$null | Out-Null
}

Stop-LingeringBuildHelpers
Remove-Item -Force "C:\lux-build\flutter_build_result.txt", "C:\lux-build\win_pipeline_result.txt" -ErrorAction SilentlyContinue

# 1. Sync repo from Mac share (exclude .git, build, dist, dist2, .dart_tool, installers)
Write-Host "==> [VM] Syncing lux repo via robocopy..."
& robocopy "$RepoShare" "C:\lux-build\lux" /E /XD .git build dist dist2 .dart_tool /XF *.dmg *.exe pubspec.yaml /NP /NFL /NDL 2>$null
if ($LASTEXITCODE -ge 8) {
  Write-Host "ROBOCOPY_LUX_FAILED exit=$LASTEXITCODE"
  exit 1
}

# Clear read-only/hidden/system attributes so Flutter & overwrites never fail
& attrib -R -H -S "C:\lux-build\lux\*.*" /S /D 2>$null

# Explicitly copy version-bumped / generated files to defeat any SMB timestamp skew
Copy-Item -Force "$RepoShare\pubspec.yaml" "C:\lux-build\lux\pubspec.yaml"
Copy-Item -Force "$RepoShare\lib\core\checksum.dart" "C:\lux-build\lux\lib\core\checksum.dart"
Copy-Item -Force "$RepoShare\dist-setup.iss" "C:\lux-build\lux\dist-setup.iss"
foreach ($copiedFile in @("C:\lux-build\lux\pubspec.yaml", "C:\lux-build\lux\lib\core\checksum.dart", "C:\lux-build\lux\dist-setup.iss")) {
  if (Test-Path -LiteralPath $copiedFile) { (Get-Item -LiteralPath $copiedFile -Force).Attributes = 'Normal' }
}

# 2. Copy Mac-cross-compiled cached lux_core.exe into Windows assets\bin
$coreShare = "$RepoShare\dist\win_lux_core.exe"
$coreDest = "C:\lux-build\lux\assets\bin\lux_core.exe"
New-Item -ItemType Directory -Force -Path "C:\lux-build\lux\assets\bin" | Out-Null
if (-not (Test-Path $coreShare)) {
  Write-Host "CORE_EXE_MISSING_ON_SHARE: $coreShare"
  exit 1
}
Copy-Item -Force $coreShare $coreDest
& attrib -R -H -S $coreDest 2>$null
if (-not (Test-Path $coreDest) -or ((Get-Item $coreDest).Length -lt 1000000)) {
  Write-Host "CORE_EXE_COPY_FAILED"
  exit 1
}
Write-Host "==> [VM] lux_core.exe staged ($((Get-Item $coreDest).Length) bytes)"

# 3. Clean stale plugins/assets & run Flutter Windows build
Set-Location C:\lux-build\lux
foreach ($f in @(".flutter-plugins", ".flutter-plugins-dependencies")) {
  if (Test-Path $f) { & attrib -R -H -S $f 2>$null; Remove-Item -Force $f -ErrorAction SilentlyContinue }
}
if (Test-Path "windows\flutter\ephemeral") { Remove-Item -Recurse -Force "windows\flutter\ephemeral" -ErrorAction SilentlyContinue }
if (Test-Path ".dart_tool\hooks_runner") { Remove-Item -Recurse -Force ".dart_tool\hooks_runner" -ErrorAction SilentlyContinue }
if (Test-Path "build\flutter_assets") { Remove-Item -Recurse -Force "build\flutter_assets" -ErrorAction SilentlyContinue }

$exe = "build\windows\x64\runner\Release\lux.exe"
if (Test-Path $exe) { Remove-Item -Force $exe -ErrorAction SilentlyContinue }

Write-Host "==> [VM] Running flutter pub get --offline..."
& "C:\lux-build\flutter\bin\flutter.bat" pub get --offline
if (-not (Test-Path ".flutter-plugins-dependencies")) {
  Write-Host "FLUTTER_FAILED: pub get did not write .flutter-plugins-dependencies"
  exit 1
}

$outLog = "C:\lux-build\flutter_stdout.log"
$errLog = "C:\lux-build\flutter_stderr.log"

function Invoke-FlutterWinBuild {
  Remove-Item -Force $outLog, $errLog -ErrorAction SilentlyContinue
  $proc = Start-Process -FilePath "cmd.exe" `
       -ArgumentList "/c","C:\lux-build\flutter\bin\flutter.bat build windows --release --no-pub > `"$outLog`" 2> `"$errLog`"" `
       -PassThru -WindowStyle Hidden
  while (-not $proc.HasExited) { Start-Sleep -Seconds 2 }
  Stop-LingeringBuildHelpers
  return $proc.ExitCode
}

Write-Host "==> [VM] Running flutter build windows --release --no-pub..."
$buildExit = Invoke-FlutterWinBuild
if ($buildExit -ne 0) {
  Write-Host "==> [VM] First build attempt exited with $buildExit, retrying once..."
  if (Test-Path "build\flutter_assets") { Remove-Item -Recurse -Force "build\flutter_assets" -ErrorAction SilentlyContinue }
  $buildExit = Invoke-FlutterWinBuild
}
if ($buildExit -ne 0) {
  if (Test-Path $outLog) { Get-Content $outLog }
  if (Test-Path $errLog) { Get-Content $errLog }
  Write-Host "FLUTTER_FAILED: build exit $buildExit"
  exit 1
}
if (-not (Test-Path $exe)) {
  Set-Content -Path "C:\lux-build\flutter_build_result.txt" -Value "FLUTTER_FAILED: no lux.exe produced" -NoNewline
  Write-Host "FLUTTER_FAILED: no lux.exe produced"
  exit 1
}
Set-Content -Path "C:\lux-build\flutter_build_result.txt" -Value "FLUTTER_OK" -NoNewline
if (Test-Path $outLog) { Get-Content $outLog | Select-Object -Last 10 }
if (Test-Path $errLog) { Get-Content $errLog | Select-Object -Last 10 }
Write-Host "FLUTTER_OK"

# 4. Bundle Visual C++ runtime next to lux.exe (app-local deployment)
$rel = "C:\lux-build\lux\build\windows\x64\runner\Release"
$required = @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")
$optional = @("msvcp140_1.dll", "msvcp140_2.dll", "concrt140.dll")
$src = $null
foreach ($root in @("C:\Program Files\Microsoft Visual Studio", "C:\Program Files (x86)\Microsoft Visual Studio")) {
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

# 5. Verify & patch dist-setup.iss, then run ISCC.exe
$issPath = "C:\lux-build\lux\dist-setup.iss"
$c = Get-Content $issPath -Raw
if ($c -match "(?i)runner\\Release") {
  Write-Host "ISS_SRC_OK"
} else {
  Write-Host "ISS_SRC_MISSING: dist-setup.iss does not reference runner\Release"
  exit 1
}

$comp = if ($Channel -eq "beta") { "lzma2/fast" } else { "lzma" }
$solid = if ($Channel -eq "beta") { "no" } else { "yes" }
$c = $c -replace 'AppVersion=[^\r\n]*', "AppVersion=$Version"
$c = $c -replace '#define MyAppVersion "[^"]*"', "#define MyAppVersion `"$Version`""
$c = $c -replace 'OutputBaseFilename=[^\r\n]*', "OutputBaseFilename=lux-$Version-setup"
$c = $c -replace 'OutputDir=[^\r\n]*', 'OutputDir=C:\lux-build\dist2'
$c = [regex]::Replace($c, '(?m)^Compression=[^\r\n]*', "Compression=$comp")
$c = [regex]::Replace($c, '(?m)^SolidCompression=[^\r\n]*', "SolidCompression=$solid")
# Strip AppMutex so Inno never blocks before InitializeSetup runs
$c = [regex]::Replace($c, '(?m)^[ \t]*AppMutex[ \t]*=[^\r\n]*\r?\n', '')
# Ensure CloseApplications=no and RestartApplications=no are active
if ($c -notmatch '(?m)^[ \t]*CloseApplications=no') {
  $c = [regex]::Replace($c, '(?m)^\[Setup\]\r?\n', "[Setup]`r`nCloseApplications=no`r`nRestartApplications=no`r`n")
}
if (Test-Path -LiteralPath $issPath) { (Get-Item -LiteralPath $issPath -Force).Attributes = 'Normal' }
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($issPath, $c, $utf8Bom)

$cCheck = Get-Content $issPath -Raw
if ($cCheck -notmatch [regex]::Escape("OutputBaseFilename=lux-$Version-setup")) {
  Write-Host "ISS_PATCH_FAILED: OutputBaseFilename mismatch"
  exit 1
}
if (($cCheck -match "procedure KillLux") -and ($cCheck -match "function InitializeSetup")) {
  Write-Host "ISS_KILL_OK"
} else {
  Write-Host "ISS_KILL_MISSING"
  exit 1
}

New-Item -ItemType Directory -Force -Path "C:\lux-build\dist2" | Out-Null
Get-ChildItem "C:\lux-build\dist2\*.exe" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host "==> [VM] Running ISCC.exe dist-setup.iss ($comp, SolidCompression=$solid)..."
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" "C:\lux-build\lux\dist-setup.iss"
if ($LASTEXITCODE -ne 0) {
  Write-Host "ISCC_FAILED exit=$LASTEXITCODE"
  exit 1
}
$builtInstaller = "C:\lux-build\dist2\lux-$Version-setup.exe"
if (-not (Test-Path $builtInstaller)) {
  Write-Host "ISCC_FAILED: missing $builtInstaller"
  exit 1
}
Write-Host "ISCC_OK"

# 6. Copy built installer back to Mac share
New-Item -ItemType Directory -Force -Path "$RepoShare\dist" | Out-Null
& robocopy "C:\lux-build\dist2" "$RepoShare\dist" "lux-$Version-setup.exe" /NP /R:3 /W:5 2>$null
if ($LASTEXITCODE -ge 8) {
  Write-Host "ROBOCOPY_INSTALLER_BACK_FAILED exit=$LASTEXITCODE"
  exit 1
}

Set-Content -Path "C:\lux-build\win_pipeline_result.txt" -Value "WIN_PIPELINE_OK" -NoNewline
Write-Host "WIN_PIPELINE_OK"
PSEOF

  local WIN_OUT="" PS_EC=0
  WIN_OUT=$(win_ps_file "$ps_name") || PS_EC=$?
  echo "$WIN_OUT"

  # Ensure no lingering vctip survives on VM
  win "taskkill /F /IM vctip.exe >nul 2>&1 & exit 0" >/dev/null 2>&1 || true

  if [ "$PS_EC" -ne 0 ] || ! echo "$WIN_OUT" | grep -q "WIN_PIPELINE_OK"; then
    local WIN_SENTINEL
    WIN_SENTINEL=$(win "type C:\\lux-build\\win_pipeline_result.txt" 2>/dev/null | tr -d '\r\n' || true)
    if [ "$WIN_SENTINEL" = "WIN_PIPELINE_OK" ]; then
      echo "WARN: prlctl stdout missed WIN_PIPELINE_OK (PS_EC=$PS_EC) but sentinel shows WIN_PIPELINE_OK — trusting sentinel"
    else
      echo "ERROR: Windows build pipeline failed (PS_EC=$PS_EC, sentinel='$WIN_SENTINEL')" >&2
      return 1
    fi
  fi

  [ -f "$REPO/dist/lux-${VERSION}-setup.exe" ] && mv -f "$REPO/dist/lux-${VERSION}-setup.exe" "$WIN_INSTALLER"
  [ -f "$WIN_INSTALLER" ] || { echo "ERROR: Windows installer not found — ISCC output missing or copy failed" >&2; return 1; }
  local WIN_SIZE
  WIN_SIZE=$(stat -f%z "$WIN_INSTALLER" 2>/dev/null || echo 0)
  [ "$WIN_SIZE" -ge 5000000 ] || { echo "ERROR: Windows installer is only ${WIN_SIZE} bytes — too small, aborting" >&2; return 1; }
  local dt=$(( $(date +%s) - t0 ))
  echo "==> [Windows] Installer ready in ${dt}s: $(ls -lh "$WIN_INSTALLER" | awk '{print $5, $9}')"
}

MACOS_LOG="/tmp/lux_build_macos.log"
WIN_LOG="/tmp/lux_build_windows.log"
: > "$MACOS_LOG"
: > "$WIN_LOG"

# Stage cached lux_core.exe in dist/ (gitignored, excluded from robocopy & macOS bundle)
cp -f "$WIN_CORE_CACHED_EXE" "$REPO/dist/win_lux_core.exe"

echo "==> Starting parallel builds: macOS ($MACOS_LOG) + Windows ($WIN_LOG)..."
BUILD_T0=$(date +%s)

( build_macos ) > "$MACOS_LOG" 2>&1 &
MAC_PID=$!

( build_windows ) > "$WIN_LOG" 2>&1 &
WIN_PID=$!

MAC_EC=0
WIN_EC=0
wait "$MAC_PID" || MAC_EC=$?
wait "$WIN_PID" || WIN_EC=$?
MAC_PID=""
WIN_PID=""

rm -f "$REPO/dist/win_lux_core.exe"
BUILD_DT=$(( $(date +%s) - BUILD_T0 ))
echo "==> Parallel builds finished in ${BUILD_DT}s (macOS=$MAC_EC, Windows=$WIN_EC)"

echo "── macOS build summary ──"
tail -n 15 "$MACOS_LOG" || true
echo "── Windows build summary ──"
tail -n 25 "$WIN_LOG" || true

if [ "$MAC_EC" -ne 0 ] || [ "$WIN_EC" -ne 0 ]; then
  echo "" >&2
  [ "$MAC_EC" -ne 0 ] && echo "ERROR: macOS build failed (exit $MAC_EC). Full log: $MACOS_LOG" >&2
  [ "$WIN_EC" -ne 0 ] && echo "ERROR: Windows build failed (exit $WIN_EC). Full log: $WIN_LOG" >&2
  false
fi

[ -f "dist/$DMG_NAME" ] || { echo "ERROR: macOS DMG missing: dist/$DMG_NAME" >&2; exit 1; }
[ -f "$WIN_INSTALLER" ] || { echo "ERROR: Windows installer missing: $WIN_INSTALLER" >&2; exit 1; }

# ── Step 5: Upload BOTH platforms, then update appcast atomically ──────────
# Sequential by design: both publish_appcast.py and publish_appcast_windows.py
# read-modify-write the same appcast file (appcast.json / appcast-beta.json).
# Parallelizing them would race and clobber one platform's entry.
echo "==> Uploading both platforms (sequentially for atomic appcast updates)..."

# Upload macOS DMG
$UPLOAD_PY "$REPO/scripts/publish_appcast.py" "$VERSION" "dist/$DMG_NAME" --channel "$CHANNEL"

# Upload Windows installer
$UPLOAD_PY "$REPO/scripts/publish_appcast_windows.py" "$VERSION" "$WIN_INSTALLER" --channel "$CHANNEL"

# When publishing stable, also advance the beta channel so older beta clients
# (that only poll appcast-beta.json) receive the newer stable release too.
if [ "$CHANNEL" == "stable" ]; then
  echo "==> Advancing beta appcast to match stable $VERSION..."
  $UPLOAD_PY "$REPO/scripts/publish_appcast.py" "$VERSION" "dist/$DMG_NAME" --channel beta
  $UPLOAD_PY "$REPO/scripts/publish_appcast_windows.py" "$VERSION" "$WIN_INSTALLER" --channel beta
fi

# ── Step 6: Commit and push ────────────────────────────────────────────────
# Remove temporary OAuth token symlink before staging git files
if [ -n "$OAUTH_TEMP_LINK" ] && [ -e "$OAUTH_TEMP_LINK" ]; then
  rm -f "$OAUTH_TEMP_LINK"
  OAUTH_TEMP_LINK=""
fi

git add pubspec.yaml lib/core/checksum.dart lib/core/core_config.dart lib/core/core_manager.dart lib/home.dart lib/const/const.dart lib/pages/proxies_page.dart lib/pages/settings_page.dart lib/widget/proxy_list_item.dart lib/widget/proxy_item_action_menu.dart lib/widget/proxy_edit_dialog.dart lib/widget/pac_rules_dialog.dart lib/util/cert_trust.dart test/cert_trust_test.dart test/pac_rules_gui_test.dart test/updater_ui_test.dart test/settings_page_reconnect_test.dart assets/translations.json scripts/release-page/index.html scripts/release_all.sh dist-setup.iss windows/packaging/exe/setup.iss lib/util/updater.dart lib/util/utils.dart render_iss.py
if [ "$CHANNEL" == "beta" ]; then
  git add appcast-beta.json 2>/dev/null || true
  git commit -m "release (beta): $VERSION"
else
  git add appcast.json appcast-beta.json 2>/dev/null || true
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
