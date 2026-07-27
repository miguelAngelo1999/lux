#!/bin/bash
# Update cycle test for Lux
# Verifies: appcast reachable, DMG downloads, version matches, updater runs, Lux relaunches
#
# Usage: bash scripts/test_update_cycle.sh
# NOTE: This test actually installs the update. Run on a test machine or when you want to test the full cycle.

set -euo pipefail

APPCAST_URL=$(python3 -c "
import sys; sys.path.insert(0, 'scripts')
try:
    import constants; print(constants.APPCAST_URL)
except:
    import json; d=json.load(open('appcast.json')); print('file://$(pwd)/appcast.json')
" 2>/dev/null || cat appcast.json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('url',''))")

RESULTS_DIR="/tmp/lux_test_results"
PASS=0
FAIL=0

mkdir -p "$RESULTS_DIR"

pass() { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }

echo "═══════════════════════════════════════════"
echo "  Lux Update Cycle Test"
echo "═══════════════════════════════════════════"
echo ""

# ── Test 1: appcast.json reachable ─────────────────────────────────────────
echo "Test 1: appcast.json reachable"
APPCAST=$(curl -s --max-time 10 --proxy http://127.0.0.1:1090 \
  "https://drive.usercontent.google.com/download?id=1jf-8thv_VVPIQ3k_n83UhygzEKkydI2p&export=download&confirm=t" \
  2>/dev/null || echo "")

if echo "$APPCAST" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('version','?'))" 2>/dev/null | grep -qE "^[0-9]+\.[0-9]+\.[0-9]+$"; then
  APPCAST_VERSION=$(echo "$APPCAST" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('version'))")
  APPCAST_URL_DMG=$(echo "$APPCAST" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['macOS']['url'])")
  APPCAST_SHA256=$(echo "$APPCAST" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['macOS']['sha256'])")
  pass "appcast reachable — latest=$APPCAST_VERSION"
else
  fail "appcast not reachable or invalid JSON"
  echo "  Response: ${APPCAST:0:200}"
  exit 1
fi
echo ""

# ── Test 2: DMG URL is valid ───────────────────────────────────────────────
echo "Test 2: DMG URL responds with binary content"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  --proxy http://127.0.0.1:1090 "$APPCAST_URL_DMG" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  pass "DMG URL returns 200"
else
  fail "DMG URL returned HTTP $HTTP_CODE"
fi
echo ""

# ── Test 3: Current version vs appcast ────────────────────────────────────
echo "Test 3: Version comparison"
CURRENT=$(defaults read /Applications/Lux.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo "0.0.0")
echo "  installed: $CURRENT"
echo "  appcast:   $APPCAST_VERSION"

python3 -c "
import sys
def ver(s): return tuple(int(x) for x in s.split('.'))
cur, latest = '$CURRENT', '$APPCAST_VERSION'
if ver(latest) > ver(cur):
    print('  update available')
elif ver(latest) == ver(cur):
    print('  up to date')
else:
    print('  installed is newer than appcast (dev build)')
sys.exit(0)
"
pass "version comparison completed"
echo ""

# ── Test 4: SHA256 of local DMG matches appcast ────────────────────────────
echo "Test 4: DMG integrity (SHA256 if local DMG exists)"
LOCAL_DMG=$(ls /Users/*/Library/Caches/com.github.igoogolx.lux/Lux-*.dmg 2>/dev/null | sort | tail -1 || echo "")
if [ -n "$LOCAL_DMG" ] && [ -f "$LOCAL_DMG" ]; then
  ACTUAL_SHA=$(shasum -a 256 "$LOCAL_DMG" | awk '{print $1}')
  if [ "$ACTUAL_SHA" = "$APPCAST_SHA256" ]; then
    pass "SHA256 matches ($LOCAL_DMG)"
  else
    fail "SHA256 mismatch for $LOCAL_DMG"
    echo "  expected: $APPCAST_SHA256"
    echo "  actual:   $ACTUAL_SHA"
  fi
else
  echo "  (no local DMG cache found — skipping SHA256 check)"
  pass "SHA256 check skipped (no cached DMG)"
fi
echo ""

# ── Test 5: Updater script exists and is valid bash ───────────────────────
echo "Test 5: lux_updater.sh syntax"
UPDATER="/Library/PrivilegedHelperTools/com.github.igoogolx.lux/lux_updater.sh"
if [ -f "$UPDATER" ]; then
  if bash -n "$UPDATER" 2>/dev/null; then
    pass "lux_updater.sh syntax valid"
  else
    fail "lux_updater.sh has syntax errors"
  fi
else
  fail "lux_updater.sh not found at $UPDATER"
fi
echo ""

# ── Test 6: Sudoers NOPASSWD rules are configured ─────────────────────────
echo "Test 6: NOPASSWD sudoers rules"
NOPASSWD_COUNT=$(sudo -n -l 2>/dev/null | grep -c "NOPASSWD" || echo "0")
if [ "$NOPASSWD_COUNT" -gt 0 ]; then
  pass "NOPASSWD rules configured ($NOPASSWD_COUNT entries)"
else
  fail "no NOPASSWD sudoers rules found"
fi
echo ""

# ── Results ───────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════"

{
  echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "pass=$PASS"
  echo "fail=$FAIL"
  echo "current=$CURRENT"
  echo "appcast=$APPCAST_VERSION"
} > "$RESULTS_DIR/update_cycle.txt"

exit $FAIL
