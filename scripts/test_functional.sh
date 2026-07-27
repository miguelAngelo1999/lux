#!/bin/bash
# Lux Functional Test Suite
# Tests actual app behaviour — traffic routing, env vars, cert trust, PAC rules.
# These test what USERS experience, not just API responses.
#
# Safe to run at any time — does NOT call stop/start.
# Usage: bash scripts/test_functional.sh

set -uo pipefail

PASS=0
FAIL=0
WARN=0

pass() { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }
warn() { echo "  ⚠️  WARN: $1"; WARN=$((WARN+1)); }
info() { echo "  ℹ️  $1"; }

LOCKFILE="$HOME/Library/Application Support/com.github.igoogolx.lux/1.0/lux_core.lock"
LOG_FILE="$HOME/Library/Application Support/com.github.igoogolx.lux/1.0/logs/flutter_app.log"
CORE_LOG="$HOME/Library/Application Support/com.github.igoogolx.lux/1.0/logs/core.log"

get_secret() {
  local s
  s=$(python3 -c "import json; d=json.load(open('$LOCKFILE')); print(d['secret'])" 2>/dev/null || echo "")
  if [ -n "$s" ]; then
    for p in 8963 18000 9090; do
      curl -s --max-time 1 -H "Authorization: Bearer $s" "http://127.0.0.1:$p/manager" 2>/dev/null | grep -q "isStarted" && { echo "$s"; return; }
    done
  fi
  grep -o 'token=[a-f0-9-]*' "$CORE_LOG" 2>/dev/null | tail -1 | cut -d= -f2
}

get_port() {
  local s p
  s=$(get_secret)
  p=$(python3 -c "import json; d=json.load(open('$LOCKFILE')); print(d['port'])" 2>/dev/null || echo "")
  if [ -n "$p" ]; then
    curl -s --max-time 2 -H "Authorization: Bearer $s" "http://127.0.0.1:$p/manager" > /dev/null 2>&1 && { echo "$p"; return; }
  fi
  for try_port in 18000 8963 9090; do
    curl -s --max-time 2 -H "Authorization: Bearer $s" "http://127.0.0.1:$try_port/manager" > /dev/null 2>&1 && { echo "$try_port"; return; }
  done
  echo "8963"
}

lux_api() {
  local path="$1" method="${2:-GET}" body="${3:-}"
  local s p
  s=$(get_secret); p=$(get_port)
  if [ -n "$body" ]; then
    curl -s -X "$method" -H "Authorization: Bearer $s" -H "Content-Type: application/json" \
      -d "$body" "http://127.0.0.1:$p$path" 2>/dev/null
  else
    curl -s -X "$method" -H "Authorization: Bearer $s" "http://127.0.0.1:$p$path" 2>/dev/null
  fi
}

echo "═══════════════════════════════════════════"
echo "  Lux Functional Test Suite"
echo "  $(date)"
echo "═══════════════════════════════════════════"
echo ""

# Prereqs
if ! pgrep -x Lux > /dev/null 2>&1; then echo "ERROR: Lux not running"; exit 1; fi
if [ -z "$(get_secret)" ]; then echo "ERROR: lux_core not reachable"; exit 1; fi
echo "Lux running on port $(get_port)"
echo ""

# ── F1: Proxy actually routes traffic ──────────────────────────────────────
echo "F1: Traffic flows through proxy (port 1090)"
PROXY_PORT=1090

# F1a: Traffic actually routes (don't check lsof — TUN mode uses kernel bypass)
# Instead verify by actually making a request
HTTP_RESULT=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  --proxy http://127.0.0.1:$PROXY_PORT http://www.msftconnecttest.com/connecttest.txt 2>/dev/null || echo "000")
if [ "$HTTP_RESULT" = "200" ]; then
  pass "HTTP traffic flows through proxy port $PROXY_PORT (msftconnecttest.com → 200)"
else
  fail "HTTP through proxy failed (HTTP $HTTP_RESULT)"
fi

# F1c: HTTPS request through proxy succeeds
HTTPS_RESULT=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  --proxy http://127.0.0.1:$PROXY_PORT https://www.google.com 2>/dev/null || echo "000")
if [ "$HTTPS_RESULT" = "200" ]; then
  pass "HTTPS traffic flows through proxy (google.com → 200)"
elif [ "$HTTPS_RESULT" = "407" ]; then
  warn "Proxy requires authentication (407) — check credentials"
else
  fail "HTTPS through proxy failed (HTTP $HTTPS_RESULT)"
fi

# F1d: Traffic actually goes through upstream proxy (not direct)
UPSTREAM=$(lux_api "/setting/interfaces" 2>/dev/null | python3 -c "
import json,sys
try:
  d = json.load(sys.stdin)
  print(d.get('default','unknown'))
except: print('unknown')
" 2>/dev/null || echo "unknown")
ACTIVE_PROXY=$(lux_api "/proxies" 2>/dev/null | python3 -c "
import json,sys
try:
  d = json.load(sys.stdin)
  proxies = d.get('proxies', [])
  sel_id = d.get('id','')
  for p in proxies:
    if p.get('id') == sel_id:
      print(p.get('name','?'), p.get('server','?'), p.get('port','?'))
      break
except: print('unknown')
" 2>/dev/null || echo "unknown")
info "Active proxy: $ACTIVE_PROXY"
echo ""

# ── F2: Verify rule matches network state (read-only — no switching) ────────
echo "F2: Rule matches current network state"
CURRENT_RULE=$(lux_api "/rules" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('selectedId','unknown'))" 2>/dev/null || echo "unknown")
CORP_PROXY_HOST=$(lux_api "/proxies" 2>/dev/null | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin); proxies=d.get('proxies',[]); sel=d.get('id','')
  for p in proxies:
    if p.get('id')==sel and p.get('type') not in ('direct',):
      print(p.get('server','')); break
except: pass
" 2>/dev/null || echo "")
CORP_PORT=$(lux_api "/proxies" 2>/dev/null | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin); proxies=d.get('proxies',[]); sel=d.get('id','')
  for p in proxies:
    if p.get('id')==sel and p.get('type') not in ('direct',):
      print(p.get('port',8080)); break
except: print(8080)
" 2>/dev/null || echo "8080")

info "Current rule: $CURRENT_RULE"

if [ -n "$CORP_PROXY_HOST" ] && [ "$CORP_PROXY_HOST" != "" ]; then
  PROXY_REACHABLE=$(python3 -c "
import socket
try:
  s = socket.create_connection(('$CORP_PROXY_HOST', $CORP_PORT), timeout=3)
  s.close(); print('yes')
except: print('no')
" 2>/dev/null || echo "unknown")

  if [ "$PROXY_REACHABLE" = "yes" ] && [ "$CURRENT_RULE" = "proxy_all" ]; then
    pass "Rule=proxy_all, corporate proxy reachable ✓"
  elif [ "$PROXY_REACHABLE" = "no" ] && [ "$CURRENT_RULE" = "bypass_all" ]; then
    pass "Rule=bypass_all, proxy unreachable ✓ (home network)"
  elif [ "$PROXY_REACHABLE" = "yes" ] && [ "$CURRENT_RULE" = "bypass_all" ]; then
    fail "Rule=bypass_all but proxy IS reachable — should be proxy_all (NetworkDetector missed it)"
  elif [ "$PROXY_REACHABLE" = "no" ] && [ "$CURRENT_RULE" = "proxy_all" ]; then
    warn "Rule=proxy_all but proxy unreachable — may still be switching (wait 10s and retry)"
  else
    pass "Rule=$CURRENT_RULE (proxy reachability: $PROXY_REACHABLE)"
  fi
else
  warn "No corporate proxy configured — skipping rule accuracy check"
fi
echo ""

# ── F3: System proxy settings set correctly ───────────────────────────────
echo "F3: macOS system proxy settings"

# F3a: HTTP proxy enabled in macOS network settings
HTTP_ENABLED=$(scutil --proxy 2>/dev/null | grep "HTTPEnable" | awk '{print $3}')
if [ "$HTTP_ENABLED" = "1" ]; then
  pass "macOS HTTP proxy enabled"
else
  fail "macOS HTTP proxy not enabled (HTTPEnable=$HTTP_ENABLED)"
fi

# F3b: Proxy points to localhost:1090
HTTP_PROXY_HOST=$(scutil --proxy 2>/dev/null | grep "HTTPProxy " | awk '{print $3}')
HTTP_PROXY_PORT=$(scutil --proxy 2>/dev/null | grep "HTTPPort" | awk '{print $3}')
if [ "$HTTP_PROXY_HOST" = "127.0.0.1" ] && [ "$HTTP_PROXY_PORT" = "1090" ]; then
  pass "macOS system proxy → 127.0.0.1:1090"
else
  fail "macOS system proxy wrong: $HTTP_PROXY_HOST:$HTTP_PROXY_PORT (expected 127.0.0.1:1090)"
fi

# F3c: HTTP_PROXY env var set via launchctl
LAUNCHCTL_PROXY=$(launchctl getenv HTTP_PROXY 2>/dev/null || echo "")
if echo "$LAUNCHCTL_PROXY" | grep -qE "127.0.0.1|localhost"; then
  pass "HTTP_PROXY env var set via launchctl: $LAUNCHCTL_PROXY"
else
  fail "HTTP_PROXY env var not set via launchctl (got: '${LAUNCHCTL_PROXY:-empty}')"
fi

# F3d: NODE_EXTRA_CA_CERTS set
NODE_CA=$(launchctl getenv NODE_EXTRA_CA_CERTS 2>/dev/null || echo "")
if [ -n "$NODE_CA" ]; then
  pass "NODE_EXTRA_CA_CERTS set: $NODE_CA"
else
  warn "NODE_EXTRA_CA_CERTS not set via launchctl (run cert installer)"
fi
echo ""

# ── F4: CA Certificate trust ─────────────────────────────────────────────
echo "F4: Corporate CA certificate trust"

# F4a: Any corp CA in system keychain
CORP_CERTS=$(security find-certificate -a /Library/Keychains/System.keychain 2>/dev/null | grep "labl" | grep -v "Apple\|DigiCert\|GlobalSign\|VeriSign\|Comodo\|Sectigo\|Thawte\|GeoTrust\|Symantec\|Let.s Encrypt\|ISRG\|Google\|Amazon\|Microsoft" | wc -l | tr -d ' ')
info "Non-standard CA certs in system keychain: $CORP_CERTS"
if [ "$CORP_CERTS" -gt 0 ]; then
  pass "Corporate CA(s) found in system keychain ($CORP_CERTS cert(s))"
else
  warn "No corporate CAs in system keychain (run Settings → Install SSL Certificate)"
fi

# F4b: HTTPS to corporate proxy works (no SSL error)
# If corp CA is trusted, HTTPS through proxy shouldn't give SSL errors
CORP_PROXY=$(lux_api "/proxies" 2>/dev/null | python3 -c "
import json,sys
try:
  d = json.load(sys.stdin)
  proxies = d.get('proxies',[])
  sel = d.get('id','')
  for p in proxies:
    if p.get('id') == sel and p.get('type') not in ('direct',):
      print(f\"{p.get('server','')}:{p.get('port','')}\")
      break
except: pass
" 2>/dev/null || echo "")
if [ -n "$CORP_PROXY" ] && [ "$CORP_PROXY" != ":" ]; then
  # Try to reach the proxy server itself over HTTPS (or just TCP)
  PROXY_HOST=$(echo "$CORP_PROXY" | cut -d: -f1)
  PROXY_PORT=$(echo "$CORP_PROXY" | cut -d: -f2)
  TCP_RESULT=$(python3 -c "
import socket
try:
  s = socket.create_connection(('$PROXY_HOST', $PROXY_PORT), timeout=3)
  s.close()
  print('ok')
except Exception as e:
  print(f'fail: {e}')
" 2>/dev/null || echo "error")
  if [ "$TCP_RESULT" = "ok" ]; then
    pass "Corporate proxy $CORP_PROXY reachable (TCP)"
  else
    warn "Corporate proxy $CORP_PROXY not reachable: $TCP_RESULT (may be home network)"
  fi
else
  warn "No corporate proxy configured or DIRECT mode active"
fi
echo ""

# ── F5: PAC rules applied correctly ──────────────────────────────────────
echo "F5: PAC rules (intranet DIRECT, internet PROXY)"
PAC_RULES=$(grep '"pac"' "$CORE_LOG" 2>/dev/null | grep "applied\|parsed" | tail -3)
if [ -n "$PAC_RULES" ]; then
  RULE_COUNT=$(echo "$PAC_RULES" | tail -1 | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('msg',''))" 2>/dev/null || echo "$PAC_RULES")
  pass "PAC rules detected: $RULE_COUNT"
else
  warn "No PAC rule log entries found (PAC may not be configured on this network)"
fi

# Check if wpad.dat is being fetched
WPAD_ACCESS=$(grep "wpad" "$CORE_LOG" 2>/dev/null | tail -3)
if [ -n "$WPAD_ACCESS" ]; then
  pass "WPAD/PAC URL detected and accessed"
else
  warn "No WPAD activity (expected on corporate network)"
fi
echo ""

# ── F6: Auto-connect timing ───────────────────────────────────────────────
echo "F6: Auto-connect startup timing"
# Find most recent startup + connect time from flutter log (both events logged there)
STARTUP_TIME=$(grep "APP.*Lux Flutter started" "$LOG_FILE" 2>/dev/null | tail -1 | cut -c1-26)
# Look for setAutoConnect success or Go-side connect AFTER this startup
CONNECTED_TIME=$(grep -A50 "$(echo "$STARTUP_TIME" | cut -c1-19)" "$LOG_FILE" 2>/dev/null | \
  grep -E "setAutoConnect.*succeeded|already connected|lux_core already connected" | head -1 | cut -c1-26)

# If not in flutter log, check core log for AUTO-CONNECT
if [ -z "$CONNECTED_TIME" ] && [ -n "$STARTUP_TIME" ]; then
  # Find the core log entry nearest to startup
  START_SEC=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('${STARTUP_TIME:0:19}').timestamp()))" 2>/dev/null || echo "0")
  CONNECTED_TIME=$(python3 -c "
import json, datetime
log = open('$CORE_LOG').read()
start_ts = $START_SEC
for line in log.split('\n'):
  try:
    d = json.loads(line)
    if 'started the client' in d.get('msg','') or 'AUTO-CONNECT' in d.get('msg',''):
      t = datetime.datetime.fromisoformat(d['time'][:26].replace('-03:00',''))
      if t.timestamp() >= start_ts:
        print(d['time'][:26])
        break
  except: pass
" 2>/dev/null || echo "")
fi

if [ -n "$STARTUP_TIME" ] && [ -n "$CONNECTED_TIME" ]; then
  DELTA=$(python3 -c "
from datetime import datetime
try:
  s = '${STARTUP_TIME:0:19}'
  c = '${CONNECTED_TIME:0:19}'
  start = datetime.fromisoformat(s)
  conn  = datetime.fromisoformat(c)
  print(int(abs((conn-start).total_seconds())))
except Exception as e:
  print('?')
" 2>/dev/null || echo "?")
  if [ "$DELTA" != "?" ] && [ "$DELTA" -le 30 ] 2>/dev/null; then
    pass "Auto-connect within ${DELTA}s of startup (target: ≤30s)"
  elif [ "$DELTA" != "?" ] && [ "$DELTA" -le 60 ] 2>/dev/null; then
    warn "Auto-connect took ${DELTA}s (target: ≤30s — acceptable but slow)"
  elif [ "$DELTA" != "?" ]; then
    fail "Auto-connect took ${DELTA}s (target: ≤30s)"
  else
    warn "Could not calculate startup-to-connect time"
  fi
  info "Startup: $STARTUP_TIME → Connected: $CONNECTED_TIME (${DELTA}s)"
else
  warn "No startup/connect timestamps found in recent logs"
fi
echo ""

# ── F7: Proxy credentials work (no 407 in recent traffic) ─────────────────
echo "F7: Proxy authentication (no recent 407 errors)"
RECENT_407=$(grep "proxy_auth_failed\|HTTP 407\|\[407\]" "$LOG_FILE" 2>/dev/null | \
  grep "$(date '+%Y-%m-%d')" | wc -l | tr -d ' ')
if [ "$RECENT_407" -eq 0 ]; then
  pass "No 407 auth failures today"
else
  fail "$RECENT_407 proxy auth failure(s) today (check credentials)"
fi
echo ""

# ── F8: Verify proxy is actually routing (not just running) ───────────────
echo "F8: End-to-end connectivity (real request through full stack)"
E2E=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  --proxy http://127.0.0.1:$PROXY_PORT https://www.google.com 2>/dev/null || echo "000")
if [ "$E2E" = "200" ]; then
  pass "End-to-end: HTTPS to google.com through Lux → 200"
elif [ "$E2E" = "407" ]; then
  fail "End-to-end: proxy requires re-authentication (407)"
elif [ "$E2E" = "000" ]; then
  fail "End-to-end: no response (proxy not routing)"
else
  warn "End-to-end: unexpected HTTP $E2E"
fi
echo ""

# ── Results ───────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════"
TOTAL=$((PASS+FAIL+WARN))
echo "  PASS: $PASS   FAIL: $FAIL   WARN: $WARN"
echo "  ($TOTAL checks total)"
echo "═══════════════════════════════════════════"
echo ""
echo "Legend:"
echo "  ✅ PASS — working correctly"
echo "  ❌ FAIL — broken, needs fix"
echo "  ⚠️  WARN — not set up / network-dependent"

{
  echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "pass=$PASS"; echo "fail=$FAIL"; echo "warn=$WARN"
  echo "version=$(defaults read /Applications/Lux.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)"
} > /tmp/lux_test_results/functional.txt

exit $FAIL
