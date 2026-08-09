#!/bin/bash
# Capture the state of Kiro's connections through Lux, for diagnosing a stall.
#
# Usage: bash scripts/watch_kiro_stall.sh [seconds]
#
# Run it, then reproduce the stall in Kiro. It samples once a second and reports:
#
#   socket states      CLOSE_WAIT means the peer sent FIN and Kiro has not closed;
#                      ESTABLISHED with a non-empty recv queue means bytes are
#                      sitting unread
#   queue depths       Recv-Q on Kiro's side growing while the UI waits points at
#                      the application; Send-Q stuck on Lux's side points at the
#                      relay
#   core log lines     anything Lux says about those connections in the window
#
# Everything is written to /tmp/kiro_stall/ for reading afterwards.
set -uo pipefail

SECONDS_TO_RUN="${1:-90}"
OUT=/tmp/kiro_stall
LOG="$HOME/Library/Application Support/com.github.igoogolx.lux/1.0/logs/core.log"

rm -rf "$OUT"; mkdir -p "$OUT"

# Mark where the core log is now so only new lines are examined.
START_LINES=$(wc -l < "$LOG" 2>/dev/null || echo 0)
echo "# sampling ${SECONDS_TO_RUN}s -- reproduce the stall in Kiro now"
echo "# core log starts at line $START_LINES"
echo

for i in $(seq 1 "$SECONDS_TO_RUN"); do
  {
    echo "=== t=${i}s $(date +%H:%M:%S) ==="
    # -n numeric, no name lookups; keep only Kiro's remote sockets.
    netstat -anv -p tcp 2>/dev/null | awk '
      NR==1 || /10\.8\.0\.1\.8082|10\.255\.0\.1/ {print}
    ' | head -40
  } >> "$OUT/sockets.txt"

  {
    echo "=== t=${i}s ==="
    lsof -nP -iTCP 2>/dev/null | grep -iE "kiro|lux_core" \
      | awk '{print $1, $9, $10}' | sort | uniq -c | sort -rn | head -20
  } >> "$OUT/lsof.txt"

  sleep 1
done

END_LINES=$(wc -l < "$LOG" 2>/dev/null || echo 0)
tail -n "$((END_LINES - START_LINES))" "$LOG" 2>/dev/null > "$OUT/core_window.log"

echo "# state summary over the window"
grep -oE "(ESTABLISHED|CLOSE_WAIT|FIN_WAIT_1|FIN_WAIT_2|LAST_ACK|TIME_WAIT|SYN_SENT)" \
  "$OUT/sockets.txt" 2>/dev/null | sort | uniq -c | sort -rn

echo
echo "# non-zero queue depths seen (proto recvq sendq local remote state)"
awk '$1 ~ /^tcp/ && ($2 != 0 || $3 != 0) {print $1, $2, $3, $4, $5, $6}' \
  "$OUT/sockets.txt" 2>/dev/null | sort -u | head -20

echo
echo "# what the core said in the window"
python3 - "$OUT/core_window.log" <<'PY'
import json, re, sys
from collections import Counter
c = Counter()
try:
    lines = open(sys.argv[1], errors="ignore").read().splitlines()
except OSError:
    lines = []
for line in lines:
    try:
        d = json.loads(line)
    except Exception:
        continue
    m = re.sub(r"\d+", "N", d.get("msg", ""))[:105]
    c[(d.get("level", "?"), m)] += 1
if not c:
    print("  (nothing logged)")
for (lvl, m), n in c.most_common(15):
    print(f"  {n:5d}  [{lvl}] {m}")
PY

echo
echo "# raw captures in $OUT/"
