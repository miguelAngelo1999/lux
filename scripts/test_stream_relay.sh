#!/bin/bash
# Exercise the failure mode behind stalled streaming responses.
#
# Usage: bash scripts/test_stream_relay.sh [proxy]
#
# Requests a response that trickles bytes with long idle gaps and is terminated by
# the server closing the connection -- the shape of a chat completion stream. The
# relay bug being checked is a missing half-close: the server's FIN never reaches
# the client, so the client waits forever for the end of a body it already has.
#
# A pass prints the elapsed time close to the drip duration. A hang means curl
# sits past it until the max-time cap.
set -uo pipefail

PROXY="${1:-http://127.0.0.1:1090}"
DURATION=20
BYTES=5
CAP=$((DURATION + 25))

echo "# proxy   : $PROXY"
echo "# request : $BYTES bytes over ${DURATION}s, server closes at the end"
echo "# cap     : ${CAP}s (anything at or above this is a hang)"
echo

run() {
  local label="$1" url="$2"
  local start end elapsed code
  start=$(date +%s)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CAP" \
    -x "$PROXY" -H 'Cache-Control: no-cache' "$url" 2>/dev/null)
  end=$(date +%s)
  elapsed=$((end - start))

  if [ "$elapsed" -ge "$CAP" ]; then
    echo "FAIL  $label  http=$code elapsed=${elapsed}s  <-- hung waiting for close"
    return 1
  fi
  echo "ok    $label  http=$code elapsed=${elapsed}s"
  return 0
}

fails=0

# httpbingo's drip closes the connection when the stream ends, so completion
# depends on that close reaching the client.
run "drip via httpbingo" \
  "https://httpbingo.org/drip?duration=$DURATION&numbytes=$BYTES&delay=0" || fails=$((fails + 1))

# A chunked response with no length, also terminated by close.
run "stream-bytes" \
  "https://httpbingo.org/stream-bytes/2048?chunk_size=64" || fails=$((fails + 1))

echo
if [ "$fails" -eq 0 ]; then
  echo "PASS: streams completed without waiting on the cap"
else
  echo "FAIL: $fails stream(s) hung"
fi
exit "$fails"
