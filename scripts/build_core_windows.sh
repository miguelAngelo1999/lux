#!/bin/bash
# Build the Windows core and update the checksum the app enforces at launch.
#
# Usage: bash scripts/build_core_windows.sh
#
# Windows calls verifyCoreBinary() on every launch and throws when the constant in
# lib/core/checksum.dart does not match the shipped exe, so the core never starts.
# macOS skips that check above macOS 15, which means a stale constant is invisible
# while developing here and fatal there. Rebuilding the core without rerunning this
# is the whole failure mode.
#
# Cross-compiling from macOS is legitimate: the core is pure Go with
# CGO_ENABLED=0, so windows/amd64 output does not depend on the build host.
# with_gvisor is deliberately omitted; Windows uses wintun.
set -euo pipefail

GO_REPO=/Users/virgoh/itun2socks-clean
FL_REPO=/Users/virgoh/lux-clean
OUT="$FL_REPO/assets/bin/lux_core.exe"

export PATH="/opt/homebrew/bin:$PATH"
export GOPROXY=off GONOSUMCHECK="*" GOINSECURE="*"

cd "$GO_REPO"
echo "# building windows/amd64 core"
CGO_ENABLED=0 GOOS=windows GOARCH=amd64 \
  go build -ldflags="-s -w" -trimpath -o "$OUT" .

SUM=$(shasum -a 256 "$OUT" | awk '{print $1}')
echo "# exe    $OUT"
echo "# size   $(du -h "$OUT" | cut -f1)"
echo "# sha256 $SUM"

python3 - "$FL_REPO/lib/core/checksum.dart" "$SUM" <<'PY'
import re
import sys

path, digest = sys.argv[1], sys.argv[2]
src = open(path).read()
pattern = r'(const\s+windowsAmd64Checksum\s*=\s*")[0-9a-fA-F]*(")'
new, n = re.subn(pattern, rf'\g<1>{digest}\g<2>', src)
if n != 1:
    sys.exit(f"expected one windowsAmd64Checksum assignment, replaced {n}")
if new == src:
    print("# checksum already current")
else:
    open(path, "w").write(new)
    print("# checksum.dart updated")
PY

echo "# done. flutter build windows --release will now pass verifyCoreBinary"
