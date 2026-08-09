#!/usr/bin/env python3
"""Split sockets facing the upstream proxy by which side of Lux they belong to.

Usage: split_proxy_sockets.py [remote-host] [samples] [interval-seconds]

A connection through Lux exists twice:

  local 10.255.0.1.x  -> the application's side, inside the tunnel
  local <lan ip>.x    -> lux_core's own outbound leg

Comparing the two tells you where a teardown stopped. A pile-up of FIN_WAIT_2 on
one side means that side sent FIN and never received the peer's, which is what
happens when a relay does not forward a half-close. Sampling over time also shows
whether ESTABLISHED is accumulating, which is the leak that goes with it.
"""

import re
import subprocess
import sys
import time
from collections import Counter

STATES = (
    "ESTABLISHED", "FIN_WAIT_1", "FIN_WAIT_2", "CLOSE_WAIT",
    "LAST_ACK", "TIME_WAIT", "SYN_SENT", "CLOSING",
)


def sample(remote):
    out = subprocess.run(
        ["netstat", "-anv", "-p", "tcp"], capture_output=True, text=True
    ).stdout

    tunnel = Counter()
    outbound = Counter()
    for line in out.splitlines():
        if remote not in line:
            continue
        state = next((s for s in STATES if s in line), None)
        if not state:
            continue
        fields = line.split()
        local = next((f for f in fields if re.match(r"^\d+\.\d+\.\d+\.\d+\.\d+$", f)), "")
        if local.startswith("10.255.0."):
            tunnel[state] += 1
        else:
            outbound[state] += 1
    return tunnel, outbound


def main():
    remote = sys.argv[1] if len(sys.argv) > 1 else "10.8.0.1.8082"
    samples = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    interval = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0

    print(f"remote {remote}, {samples} samples every {interval:g}s\n")
    header = f"{'t':>5}  {'side':<10}" + "".join(f"{s[:11]:>12}" for s in STATES)
    print(header)
    print("-" * len(header))

    first = {}
    last = {}
    for i in range(samples):
        tunnel, outbound = sample(remote)
        for label, counts in (("tunnel", tunnel), ("outbound", outbound)):
            row = f"{i * interval:5.0f}  {label:<10}" + "".join(
                f"{counts.get(s, 0):>12}" for s in STATES
            )
            print(row)
            first.setdefault(label, dict(counts))
            last[label] = dict(counts)
        if i < samples - 1:
            print()
            time.sleep(interval)

    print("\ntrend over the window:")
    for label in ("tunnel", "outbound"):
        a, b = first.get(label, {}), last.get(label, {})
        for s in STATES:
            d = b.get(s, 0) - a.get(s, 0)
            if d:
                arrow = "up" if d > 0 else "down"
                print(f"  {label:<10} {s:<12} {d:+d} ({arrow})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
