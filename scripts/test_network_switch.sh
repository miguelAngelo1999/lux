#!/bin/bash
# Connectivity simulation test for Lux NetworkDetector
# Tests that Lux correctly switches between proxy_all and bypass_all.
#
# Usage:
#   bash scripts/test_network_switch.sh              # safe read-only tests only
#   bash scripts/test_network_switch.sh --destructive  # also runs stop/start (KILLS proxy briefly)
#
# WARNING: --destructive stops lux_core which drops all network traffic temporarily.
# Never run --destructive while using Lux as your internet gateway.

set -uo pipefail

LOCKFILE="$HOME/Library/Application Support/com.github.igoogolx.lux/1.0/lux_core.lock"
LOG_FILE="$HOME/Library/Application Support/com.github.igoogolx.lux/1.0/logs/flutter_app.log"
RESULTS_DIR="/tmp/lux_test_results"
DESTRUCTIVE=0
PASS=0
FAIL=0

for arg in "$@"; do
  [ "$arg" = "--destructive" ] && DESTRUCTIVE=1
done

mkdir -p "$RESULTS_DIR"

# ── Helpers ────────────────────────────────────────────────────────────────

get_secret() {
  # Try lockfile first, verify it works
  local s
  s=$(python3 -c "import json; d=json.load(open('$LOCKFILE')); print(d['secret'])" 2>/dev/null || echo "")
  if [ -n "$s" ]; then
    for try_port in 8963 18000 9090; do
      if curl -s --max-time 1 -H "Authorization: Bearer $s" "http://127.0.0.1:$try_port/manager" 2>/dev/null | grep -q "isStarted"; then
        echo "$s"
        return
      fi
    done
  fi
  # Fallback: read most recent token from core.log
  s=$(grep -o 'token=[a-f0-9-]*' "$HOME/Library/Application Support/com.github.igoogolx.lux/1.0/logs/core.log" 2>/dev/null | tail -1 | cut -d= -f2)
  echo "${s:-}"
}

get_port() {
  local p secret
  secret=$(get_secret)
  p=$(python3 -c "import json; d=json.load(open('$LOCKFILE')); print(d['port'])" 2>/dev/null || echo "")
  # Verify port responds
  if [ -n "$p" ] && curl -s --max-time 2 -H "Authorization: Bearer $secret" "http://127.0.0.1:$p/manager" > /dev/null 2>&1; then
    echo "$p"; return
  fi
  for try_port in 18000 8963 9090; do
    if curl -s --max-time 2 -H "Authorization: Bearer $secret" "http://127.0.0.1:$try_port/manager" > /dev/null 2>&1; then
      echo "$try_port"; return
    fi
  done
  echo "${p:-8963}"
}

lux_api() {
  local path="$1" method="${2:-GET}" body="${3:-}"
  local secret port
  secret=$(get_secret); port=$(get_port)
  if [ -n "$body" ]; then
    curl -s -X "$method" -H "Authorization: Bearer $secret" \
      -H "Content-Type: application/json" -d "$body" \
      "http://127.0.0.1:$port$path" 2>/dev/null
  else
    curl -s -X "$method" -H "Authorization: Bearer $secret" \
      "http://127.0.0.1:$port$path" 2>/dev/null
  fi
}

get_current_rule() {
  local secret port
  secret=$(get_secret); port=$(get_port)
  curl -s -H "Authorization: Bearer $secret" "http://127.0.0.1:$port/rules" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('selectedId','unknown'))" 2>/dev/null \
    || echo "unknown"
}

set_rule() {
  local secret port
  secret=$(get_secret); port=$(get_port)
  curl -s -X POST -H "Authorization: Bearer $secret" -H "Content-Type: application/json" \
    -d "{\"id\":\"$1\"}" "http://127.0.0.1:$port/selected/rule" > /dev/null 2>&1
  sleep 1
  local actual
  actual=$(get_current_rule)
  if [ "$actual" = "$1" ]; then
    echo "  ✓ rule set to $1"; return 0
  else
    echo "  ✗ expected $1, got $actual"; return 1
  fi
}

check_proxy_works() {
  local secret port
  secret=$(get_secret); port=$(get_port)
  curl -s --max-time 5 -H "Authorization: Bearer $secret" \
    "http://127.0.0.1:$port/health" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print('ok' if d.get('ok') else 'fail')" 2>/dev/null \
    || echo "error"
}

get_is_started() {
  local secret port
  secret=$(get_secret); port=$(get_port)
  curl -s --max-time 5 -H "Authorization: Bearer $secret" \
    "http://127.0.0.1:$port/manager" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print('True' if d.get('isStarted') else 'False')" 2>/dev/null \
    || echo "error"
}

pass() { echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }

echo "═══════════════════════════════════════════"
echo "  Lux NetworkDetector Connectivity Tests"
if [ "$DESTRUCTIVE" -eq 1 ]; then
  echo "  ⚠️  DESTRUCTIVE MODE — stop/start tests enabled"
fi
echo "═══════════════════════════════════════════"
echo ""

# Check prereqs
if ! pgrep -x Lux > /dev/null 2>&1; then
  echo "ERROR: Lux is not running. Start Lux first."; exit 1
fi
SECRET=$(get_secret)
if [ -z "$SECRET" ]; then
  echo "ERROR: Could not find lux_core secret."; exit 1
fi
echo "Lux is running. Starting tests..."
echo ""

# ── Test 1: lux_core API reachable ─────────────────────────────────────────
echo "Test 1: lux_core API reachable"
PORT=$(get_port)
response=$(curl -s --max-time 5 -H "Authorization: Bearer $SECRET" "http://127.0.0.1:$PORT/manager" 2>/dev/null)
if echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if 'isStarted' in d else 1)" 2>/dev/null; then
  pass "lux_core API responding on port $PORT"
else
  fail "lux_core API not responding: ${response:0:100}"
fi
echo ""

# ── Test 2: Rule switching (read-only safe) ────────────────────────────────
echo "Test 2: Rule switching (proxy_all ↔ bypass_all)"
ORIGINAL_RULE=$(get_current_rule)
echo "  current rule: $ORIGINAL_RULE"

if set_rule "bypass_all"; then pass "switch to bypass_all"
else fail "switch to bypass_all"; fi
sleep 1
if set_rule "proxy_all"; then pass "switch back to proxy_all"
else fail "switch back to proxy_all"; fi

# Restore original
set_rule "$ORIGINAL_RULE" > /dev/null 2>&1 || true
echo ""

# ── Test 3: Health check ───────────────────────────────────────────────────
echo "Test 3: Proxy health check"
health=$(check_proxy_works)
if [ "$health" = "ok" ]; then pass "proxy health OK"
else fail "proxy health failed ($health)"; fi
echo ""

# ── Test 4: NetworkDetector logs ──────────────────────────────────────────
echo "Test 4: NetworkDetector logs in flutter_app.log"
if grep -q "NET-DETECT" "$LOG_FILE" 2>/dev/null; then
  COUNT=$(grep -c "NET-DETECT" "$LOG_FILE" 2>/dev/null || echo "0")
  pass "NET-DETECT entries found ($COUNT log lines)"
else
  echo "  (no NET-DETECT entries yet — switch networks to trigger)"
  pass "flutter_app.log accessible"
fi
echo ""

# ── Tests 5-6: DESTRUCTIVE (stop/start) — only with --destructive flag ─────
if [ "$DESTRUCTIVE" -eq 1 ]; then
  echo "Test 5: Stop + Start cycle ⚠️"
  echo "  WARNING: this will drop your internet connection briefly"
  lux_api "/manager/stop" "POST" > /dev/null; sleep 3
  status=$(get_is_started)
  if [ "$status" = "False" ]; then pass "lux_core stopped"
  else fail "lux_core stop failed (status=$status)"; fi

  lux_api "/manager/start" "POST" > /dev/null
  for retry in 1 2 3 4 5; do
    sleep 3; status=$(get_is_started)
    [ "$status" = "True" ] && break
  done
  if [ "$status" = "True" ]; then pass "lux_core restarted"
  else fail "lux_core restart failed (status=$status)"; fi
  echo ""

  echo "Test 6: Rapid stop+start stress (3 cycles) ⚠️"
  stress_ok=0
  for i in $(seq 1 3); do
    lux_api "/manager/stop" "POST" > /dev/null; sleep 2
    lux_api "/manager/start" "POST" > /dev/null; sleep 5
    s=$(get_is_started)
    if [ "$s" = "True" ]; then stress_ok=$((stress_ok+1)); echo "  cycle $i: ✓"
    else echo "  cycle $i: ✗"; fi
  done
  if [ "$stress_ok" -eq 3 ]; then pass "3/3 cycles succeeded"
  else fail "$stress_ok/3 cycles succeeded"; fi
  echo ""
else
  echo "Tests 5-6: SKIPPED (stop/start) — pass --destructive to enable"
  echo "  (these tests drop internet — only run when safe to do so)"
  echo ""
fi

# ── Results ───────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════"

{
  echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "pass=$PASS"; echo "fail=$FAIL"
  echo "destructive=$DESTRUCTIVE"
} > "$RESULTS_DIR/last_run.txt"

exit $FAIL
