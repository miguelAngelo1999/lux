#!/bin/bash
# One-shot: copy every hosted pub package the lockfile needs from the Mac's
# pub cache into the Windows VM's pub cache, when the VM is missing it or has
# an empty stub. Fixes the recurring "no versions of X match" / empty-stub
# failures that break `flutter pub get --offline` on the VM.
set -u
VM="Windows 11 (1)"
MAC_CACHE="$HOME/.pub-cache/hosted/pub.dev"
VM_CACHE='C:\Users\virgoh\AppData\Local\Pub\Cache\hosted\pub.dev'
LOCK="/Users/virgoh/lux-clean/pubspec.lock"

# Extract "name-version" for every hosted package in the lockfile.
pkgs=$(python3 - "$LOCK" <<'PY'
import sys, re
txt = open(sys.argv[1]).read()
# crude but effective: find blocks with name:, source: hosted, version:
cur = {}
out = []
name = None
for line in txt.splitlines():
    m = re.match(r'^  (\S+):\s*$', line)
    if m:
        if name and cur.get('hosted') and cur.get('version'):
            out.append(f"{name}-{cur['version']}")
        name = m.group(1); cur = {}
        continue
    if 'source: hosted' in line: cur['hosted'] = True
    mv = re.match(r'\s*version:\s*"([^"]+)"', line)
    if mv: cur['version'] = mv.group(1)
if name and cur.get('hosted') and cur.get('version'):
    out.append(f"{name}-{cur['version']}")
print("\n".join(out))
PY
)

copied=0; missing_on_mac=0; already=0
for p in $pkgs; do
  if [ ! -f "$MAC_CACHE/$p/pubspec.yaml" ]; then
    echo "SKIP (not in Mac cache): $p"; missing_on_mac=$((missing_on_mac+1)); continue
  fi
  have=$(prlctl exec "$VM" cmd /c "if exist \"$VM_CACHE\\$p\\pubspec.yaml\" (echo YES) else (echo NO)" </dev/null 2>&1 | tr -d '\r' | grep -o -m1 -E 'YES|NO')
  if [ "$have" = "YES" ]; then already=$((already+1)); continue
  fi
  echo "COPY -> $p"
  prlctl exec "$VM" cmd /c "rmdir /S /Q \"$VM_CACHE\\$p\" 2>nul & robocopy \\\\Mac\\Home\\.pub-cache\\hosted\\pub.dev\\$p \"$VM_CACHE\\$p\" /E /NP /NFL /NDL /R:1 /W:1 >nul & echo done" </dev/null >/dev/null 2>&1
  copied=$((copied+1))
done
echo "=== synced: copied=$copied already=$already not_on_mac=$missing_on_mac ==="
