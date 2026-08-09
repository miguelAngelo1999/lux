#!/usr/bin/env python3
"""Snapshot Lux's live connection tracker.

Usage: peek_connections.py <core-port> <secret> [filter-substring]

Reads one frame from the /connection websocket and prints host, matched rule and
chosen outbound per connection. Useful for answering "what did Lux actually
decide for this traffic", which the UI only shows while you are looking at it.
"""

import json
import sys
from urllib.parse import quote

try:
    from websockets.sync.client import connect
except Exception:
    print("needs: pip3 install websockets")
    sys.exit(2)


def main():
    if len(sys.argv) < 3:
        print(__doc__.strip())
        return 2
    port, secret = sys.argv[1], sys.argv[2]
    needle = sys.argv[3].lower() if len(sys.argv) > 3 else ""

    url = f"ws://127.0.0.1:{port}/connection?token={quote(secret)}"
    with connect(url, open_timeout=10) as ws:
        raw = ws.recv(timeout=10)

    data = json.loads(raw)
    conns = data if isinstance(data, list) else data.get("connections", [])

    rows = []
    for c in conns:
        meta = c.get("metadata", {}) or {}
        host = meta.get("host") or meta.get("destinationIP") or ""
        dport = meta.get("destinationPort", "")
        proc = (meta.get("process") or "").split("/")[-1]
        target = f"{host}:{dport}"
        line = (target, c.get("rule", ""), c.get("proxy") or c.get("outbound") or "",
                proc, meta.get("network", ""))
        if not needle or needle in " ".join(str(x).lower() for x in line):
            rows.append(line)

    print(f"{len(conns)} connections, {len(rows)} shown")
    print(f"{'TARGET':<42} {'RULE':<22} {'OUTBOUND':<24} {'PROCESS':<18} NET")
    for target, rule, out, proc, net in sorted(rows):
        print(f"{target:<42} {rule:<22} {out:<24} {proc:<18} {net}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
