#!/bin/bash
# Run all Lux tests: Go unit tests + Flutter unit tests + connectivity simulation
# Usage: bash scripts/test_all.sh [--skip-connectivity] [--skip-update]

set -uo pipefail

SKIP_CONNECTIVITY=0
SKIP_UPDATE=0
for arg in "$@"; do
  case "$arg" in
    --skip-connectivity) SKIP_CONNECTIVITY=1 ;;
    --skip-update) SKIP_UPDATE=1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ITUN="/Users/virgoh/itun2socks"
[ -f "$ITUN/go.mod" ] || ITUN="$(dirname "$ROOT")/itun2socks"
[ -f "$ITUN/go.mod" ] || ITUN=""
PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

echo "═══════════════════════════════════════════"
echo "  Lux Test Suite"
echo "  $(date)"
echo "═══════════════════════════════════════════"
echo ""

# ── Go unit tests ──────────────────────────────────────────────────────────
if [ -n "$ITUN" ]; then
  echo "── Go unit tests ──────────────────────────"
  cd "$ITUN"
  if GOPROXY="off" GONOSUMCHECK="*" GONOSUMDB="*" GOINSECURE="*" \
    go test ./internal/pac/... ./internal/conn/... ./internal/configuration/... \
    -timeout 30s 2>&1; then
    pass "Go unit tests passed"
  else
    fail "Go unit tests failed"
  fi
  cd "$ROOT"
else
  echo "  (itun2socks not found — skipping Go tests)"
fi
echo ""

# ── Flutter unit tests ─────────────────────────────────────────────────────
echo "── Flutter unit tests ─────────────────────"
cd "$ROOT"
export PATH="/opt/homebrew/bin:/Users/virgoh/flutter/bin:$PATH"
FLUTTER_OUT=$(flutter test test/widget/network_detector_test.dart --no-pub 2>&1)
if echo "$FLUTTER_OUT" | grep -qE "\+3|All tests passed|0 failed"; then
  pass "Flutter unit tests passed (3/3)"
else
  fail "Flutter unit tests failed"
  echo "$FLUTTER_OUT" | tail -5
fi
echo ""

# ── Connectivity simulation ────────────────────────────────────────────────
if [ "$SKIP_CONNECTIVITY" -eq 0 ]; then
  echo "── Connectivity simulation ────────────────"
  if bash "$ROOT/scripts/test_network_switch.sh" 2>&1 | tail -3 | grep -qE "0 failed|Results: [0-9]+ passed, 0 failed"; then
    pass "Connectivity simulation passed"
  else
    fail "Connectivity simulation had failures (check output above)"
  fi
  echo ""
fi

# ── Update cycle test ──────────────────────────────────────────────────────
if [ "$SKIP_UPDATE" -eq 0 ]; then
  echo "── Update cycle test ──────────────────────"
  if bash "$ROOT/scripts/test_update_cycle.sh" 2>&1 | tail -3 | grep -qE "0 failed|Results: [0-9]+ passed, 0 failed"; then
    pass "Update cycle test passed"
  else
    fail "Update cycle test had failures"
  fi
  echo ""
fi

# ── Results ───────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════"
echo "  TOTAL: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════"

exit $FAIL
