#!/bin/bash
# Windows readiness check, runnable from macOS.
#
# Usage: bash scripts/check_windows.sh
#
# Cross-compiles the core for windows/amd64, vets it, compiles the test binaries,
# and checks the Flutter side for the things that only break on Windows:
#
#   * the startup checksum gate, which is enforced unconditionally on Windows but
#     skipped on macOS above 15, so a stale constant is invisible here and fatal
#     there
#   * the presence of a Windows core binary in assets
#   * the appcast's windows entry, without which Windows clients are never
#     offered an update
#
# Exits non-zero if anything would break a Windows build or launch.
set -uo pipefail

GO_REPO=/Users/virgoh/itun2socks-clean
FL_REPO=/Users/virgoh/lux-clean
export PATH="/opt/homebrew/bin:/Users/virgoh/flutter/bin:$PATH"
export GOPROXY=off

fails=0
note() { printf '%-52s %s\n' "$1" "$2"; }
fail() { note "$1" "FAIL  $2"; fails=$((fails + 1)); }
ok()   { note "$1" "ok    ${2:-}"; }

echo "== go, windows/amd64 (no with_gvisor, per the build guide) =="
cd "$GO_REPO" || exit 1

if CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" -trimpath \
     -o /tmp/lux_core_wincheck.exe . 2>/tmp/win_build.err; then
  ok "core builds" "$(du -h /tmp/lux_core_wincheck.exe | cut -f1)"
else
  fail "core builds" "see /tmp/win_build.err"
  head -5 /tmp/win_build.err | sed 's/^/      /'
fi

if GOOS=windows GOARCH=amd64 go vet ./internal/... ./pkg/sysproxy/... 2>/tmp/win_vet.err; then
  ok "go vet clean"
else
  fail "go vet clean" "see /tmp/win_vet.err"
  head -8 /tmp/win_vet.err | sed 's/^/      /'
fi

# go test -c compiles a test binary without running it. Plain `go test` would try
# to execute a Windows exe on macOS and fail with "exec format error", which says
# nothing about whether the code is correct.
test_compile_failed=0
for pkg in ./internal/configuration ./internal/conn ./internal/tunnel/statistic \
           ./internal/cfg/distribution/rule_engine; do
  if ! GOOS=windows GOARCH=amd64 go test -c -o /dev/null "$pkg" 2>>/tmp/win_test.err; then
    test_compile_failed=1
  fi
done
if [ "$test_compile_failed" -eq 0 ]; then
  ok "test binaries compile"
else
  fail "test binaries compile" "see /tmp/win_test.err"
  grep -E "\.go:[0-9]+" /tmp/win_test.err | head -8 | sed 's/^/      /'
fi

echo
echo "== flutter / packaging =="
cd "$FL_REPO" || exit 1

if [ -f assets/bin/lux_core.exe ]; then
  ok "assets/bin/lux_core.exe present"
else
  fail "assets/bin/lux_core.exe present" "build it on Windows before flutter build"
fi

# The gate that bites: Windows calls verifyCoreBinary unconditionally.
WIN_SUM=$(grep -oE 'windowsAmd64Checksum = "[0-9a-f]+"' lib/core/checksum.dart \
  | grep -oE '[0-9a-f]{64}')
if [ -z "$WIN_SUM" ]; then
  fail "windowsAmd64Checksum readable" "not found in lib/core/checksum.dart"
else
  if [ -f assets/bin/lux_core.exe ]; then
    ACTUAL=$(shasum -a 256 assets/bin/lux_core.exe | awk '{print $1}')
    if [ "$ACTUAL" = "$WIN_SUM" ]; then
      ok "windowsAmd64Checksum matches asset"
    else
      fail "windowsAmd64Checksum matches asset" \
        "constant ${WIN_SUM:0:12}... asset ${ACTUAL:0:12}..."
    fi
  else
    # Compare against the binary we just cross-compiled. Not authoritative,
    # because a build on Windows may differ, but a match is strong evidence the
    # constant tracks current source and a mismatch is worth knowing.
    ACTUAL=$(shasum -a 256 /tmp/lux_core_wincheck.exe 2>/dev/null | awk '{print $1}')
    if [ "$ACTUAL" = "$WIN_SUM" ]; then
      ok "windowsAmd64Checksum matches a fresh cross-compile"
    else
      fail "windowsAmd64Checksum is stale" \
        "constant ${WIN_SUM:0:12}... fresh build ${ACTUAL:0:12}..."
    fi
  fi
fi

# Windows clients read the same appcast. An empty url means no update is ever
# offered, which is fine deliberately but should not be a surprise.
WIN_URL=$(python3 -c "
import json
try:
    print(json.load(open('appcast.json'))['windows']['url'])
except Exception:
    print('')
" 2>/dev/null)
if [ -n "$WIN_URL" ]; then
  ok "appcast windows url set"
else
  note "appcast windows url set" "warn  empty: Windows is never offered an update"
fi

if [ -d windows/runner ]; then
  ok "windows runner project present"
else
  fail "windows runner project present" "flutter create --platforms=windows"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS: nothing found that would break Windows"
else
  echo "FAIL: $fails issue(s) would break a Windows build or launch"
fi
exit "$fails"
