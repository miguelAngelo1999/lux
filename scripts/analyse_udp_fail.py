#!/usr/bin/env python3
"""Group lux_core's UDP relay failures by destination port.

Usage: analyse_udp_fail.py [path-to-core.log]

Port 443 failures are QUIC attempts. A relay that fails without answering is a
black hole: the client waits out its own timeout before falling back to TCP,
which looks like a stalled request. Rejecting cleanly, or blocking QUIC outright,
makes the fallback immediate.
"""

import json
import os
import re
import sys
from collections import Counter

DEFAULT = os.path.expanduser(
    "~/Library/Application Support/com.github.igoogolx.lux/1.0/logs/core.log"
)

ADDR = re.compile(r"remote address:\s*([0-9a-fA-F:.\[\]]+):(\d+)")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    if not os.path.exists(path):
        print(f"no log at {path}")
        return 1

    ports = Counter()
    hosts = Counter()
    total = 0
    for line in open(path, errors="ignore"):
        try:
            d = json.loads(line)
        except Exception:
            continue
        msg = d.get("msg", "")
        if "fail to get udp conn" not in msg:
            continue
        total += 1
        m = ADDR.search(msg)
        if m:
            hosts[m.group(1)] += 1
            ports[m.group(2)] += 1

    print(f"udp relay failures: {total}")
    print("\nby destination port:")
    for p, n in ports.most_common(10):
        tag = "  <-- QUIC / HTTP3" if p == "443" else ""
        tag = "  <-- DNS" if p == "53" else tag
        print(f"  {p:>6}  {n}{tag}")
    print("\ntop destinations:")
    for h, n in hosts.most_common(8):
        print(f"  {n:6d}  {h}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
