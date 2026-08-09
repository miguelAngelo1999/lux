#!/usr/bin/env python3
"""Summarise lux_core's log around connection lifecycle.

Usage: analyse_core_log.py [path-to-core.log]

Separates the two reasons the statistic cache fires its eviction callback:

  * a normal teardown, where TcpTracker.Close calls manager.Leave, which calls
    Remove, which fires the callback, which calls Close again -- the recursion
    shows up as a following "use of closed network connection"
  * a capacity eviction, where the 256-entry LRU drops a connection that is
    still live; there is no preceding Close, so the socket really is terminated
    underneath whoever was using it

The second kind is what silently kills an idle streaming response.
"""

import json
import os
import re
import sys
from collections import Counter

DEFAULT = os.path.expanduser(
    "~/Library/Application Support/com.github.igoogolx.lux/1.0/logs/core.log"
)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    if not os.path.exists(path):
        print(f"no log at {path}")
        return 1

    evict = 0
    double_close = 0
    opens = 0
    closes_ok = 0
    policies = Counter()
    procs = Counter()
    # An eviction whose very next lifecycle line is not a double-close error is
    # a capacity eviction of a live connection.
    pending_evict = False
    capacity_evictions = 0

    open_re = re.compile(r"^\[TCP\],\s+(\S+) to (\S+) using (\S+)")

    for line in open(path, errors="ignore"):
        try:
            d = json.loads(line)
        except Exception:
            continue
        msg = d.get("msg", "")

        m = open_re.match(msg)
        if m:
            opens += 1
            policies[m.group(3)] += 1
            if pending_evict:
                capacity_evictions += 1
                pending_evict = False
            continue

        if "close connection on evicted" in msg:
            if pending_evict:
                capacity_evictions += 1
            evict += 1
            pending_evict = True
            continue

        if "fail to close remote tcp conn" in msg and "use of closed" in msg:
            double_close += 1
            pending_evict = False
            continue

        if "find process" in msg:
            proc = msg.rsplit(":", 1)[-1].strip()
            procs[proc.split("/")[-1]] += 1

    if pending_evict:
        capacity_evictions += 1

    print(f"log: {path}")
    print(f"tcp opens                     : {opens}")
    print(f"eviction callbacks fired      : {evict}")
    print(f"  of which double-close (safe): {double_close}")
    print(f"  of which no preceding close : {capacity_evictions}  <-- killed live conns")
    print(f"successful closes logged      : {closes_ok}")
    print()
    print("policy split:")
    for p, n in policies.most_common():
        print(f"  {p:<10} {n}")
    print()
    print("top processes by rule lookups:")
    for p, n in procs.most_common(8):
        print(f"  {n:6d}  {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
