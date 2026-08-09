#!/usr/bin/env python3
"""Tell whether the running core has the connection-cache fix.

Usage: check_cache_fix_live.py [path-to-core.log]

core.log is appended across restarts, so counting the old log message over the
whole file mixes the previous core's output with the current one. This splits on
the first appearance of the new message and reports each side separately.

  old marker: "close connection on evicted"      -- eviction closed the socket
  new marker: "stopped tracking connection"      -- eviction only forgets
"""

import json
import os
import sys

DEFAULT = os.path.expanduser(
    "~/Library/Application Support/com.github.igoogolx.lux/1.0/logs/core.log"
)

OLD = "close connection on evicted"
NEW = "stopped tracking connection"
DBL = "fail to close remote tcp conn"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    if not os.path.exists(path):
        print(f"no log at {path}")
        return 1

    first_new = None
    last_old = None
    counts = {"old": 0, "new": 0, "dbl_before": 0, "dbl_after": 0}

    for line in open(path, errors="ignore"):
        try:
            d = json.loads(line)
        except Exception:
            continue
        msg = d.get("msg", "")
        ts = d.get("time", "")

        if NEW in msg:
            counts["new"] += 1
            if first_new is None:
                first_new = ts
        elif OLD in msg:
            counts["old"] += 1
            last_old = ts
        elif DBL in msg and "use of closed" in msg:
            if first_new is None:
                counts["dbl_before"] += 1
            else:
                counts["dbl_after"] += 1

    print(f"log: {path}\n")
    print(f"old marker '{OLD}'")
    print(f"  count     : {counts['old']}")
    print(f"  last seen : {last_old or '-'}")
    print()
    print(f"new marker '{NEW}'")
    print(f"  count     : {counts['new']}")
    print(f"  first seen: {first_new or '-'}")
    print()
    print("double-close errors before first new marker:", counts["dbl_before"])
    print("double-close errors after  first new marker:", counts["dbl_after"],
          "  <-- must be 0 if the fix is live")
    print()

    if counts["new"] == 0:
        print("VERDICT: running core does NOT have the fix")
        return 2
    if counts["dbl_after"] > 0:
        print("VERDICT: new core is running but still double-closing -- investigate")
        return 3
    print("VERDICT: fix is live; the old counts above are the previous core's history")
    return 0


if __name__ == "__main__":
    sys.exit(main())
