#!/bin/bash
# Compare the PAC / TUN-routing feature set across the two itun2socks lineages.
#
# Usage: bash scripts/check_pac_features.sh
#
# The handoff notes describe work done on feat/stable. The rebuild ships from
# rebuild/clean-base. If a feature exists only in the former, the rebuild is a
# regression for anyone relying on it, so this reports both side by side rather
# than assuming either one is authoritative.
set -uo pipefail

STABLE=/Users/virgoh/itun2socks
CLEAN=/Users/virgoh/itun2socks-clean

row() { printf '  %-46s %s\n' "$1" "$2"; }

probe() {
  local repo="$1" label="$2" pattern="$3" scope="$4"
  local n
  n=$(grep -rIl --include="*.go" -E "$pattern" "$repo/$scope" 2>/dev/null \
      | grep -v dist-ui | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then row "$label" "present ($n file(s))"; else row "$label" "ABSENT"; fi
}

for repo in "$STABLE" "$CLEAN"; do
  [ -d "$repo" ] || { echo "== $repo (missing) =="; continue; }
  branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
  head=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null)
  echo "== $(basename "$repo")  [$branch @ $head] =="

  if [ -d "$repo/internal/pac" ]; then
    row "internal/pac package" "present ($(ls "$repo/internal/pac" 2>/dev/null | wc -l | tr -d ' ') files)"
  else
    row "internal/pac package" "ABSENT"
  fi

  probe "$repo" "pac.IsJSEvalActive / EvalForURL"  "IsJSEvalActive|EvalForURL"        "."
  probe "$repo" "FindProxyForURL evaluation"        "FindProxyForURL"                  "."
  probe "$repo" "JS engine dependency in source"    "goja|otto|quickjs|duktape"        "."
  probe "$repo" "myIpAddress implementation"        "myIpAddress|MyIpAddress"          "."
  probe "$repo" "TCP result logging (duration+bytes)" "durationMs|duration_ms|bytesIn|bytes_in|upload=.*download=" "internal"
  probe "$repo" "GetProxy fallback in tunnel match"  "conn\.GetProxy\(constants\.PolicyProxy\)" "."

  echo -n "  go.mod JS engine: "
  grep -oE "(goja|otto|quickjs|duktape)[^ ]*" "$repo/go.mod" 2>/dev/null | head -1 || echo "none"
  echo
done

echo "== where match() falls back, per lineage =="
for repo in "$STABLE" "$CLEAN"; do
  [ -d "$repo" ] || continue
  f=$(grep -rIl --include="*.go" "func match(" "$repo" 2>/dev/null | grep -v dist-ui | head -1)
  echo "  $(basename "$repo"): ${f:-no match() found}"
  [ -n "$f" ] && grep -n "proxies\[\"DIRECT\"\]\|GetProxy\|IsJSEvalActive" "$f" 2>/dev/null \
    | sed 's/^/      /' | head -8
done
