#!/bin/bash
# Find an endpoint that trickles a response with idle gaps and ends by closing.
# Used to build a reproduction for the stalled-stream relay bug.
set -uo pipefail
P="${1:-http://127.0.0.1:1090}"

try() {
  local name="$1" url="$2" cap="$3"
  local s e
  s=$(date +%s)
  local out
  out=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' --max-time "$cap" -x "$P" "$url" 2>&1)
  e=$(date +%s)
  printf '%-34s cap=%-3s elapsed=%-4s %s\n' "$name" "$cap" "$((e - s))s" "$out"
}

try "httpbingo drip d=8"  "https://httpbingo.org/drip?duration=8&numbytes=8&delay=0" 30
try "httpbin drip d=8"    "https://httpbin.org/drip?duration=8&numbytes=8&delay=0"   30
try "httpbin stream/5"    "https://httpbin.org/stream/5"                             30
try "postman delay/5"     "https://postman-echo.com/delay/5"                         30
try "cloudflare trace"    "https://cloudflare.com/cdn-cgi/trace"                      20
