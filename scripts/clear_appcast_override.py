#!/usr/bin/env python3
"""Remove the customAppcastUrl override from the live prefs file.

The override was pointed at a dead local URL to stop the update prompt while the
published appcast still described the old fork lineage. Now that the appcast
describes the rebuild, the override has to go or the updater can never see it.

Only that one key is touched; the rest of lux_prefs.json is preserved because
lux_core and the Flutter app both keep state there.
"""

import json
import os
import shutil
import sys

PREFS = os.path.expanduser(
    "~/Library/Application Support/com.github.igoogolx.lux/1.0/lux_prefs.json"
)


def main():
    if not os.path.exists(PREFS):
        print(f"no prefs at {PREFS}")
        return 0

    with open(PREFS) as f:
        prefs = json.load(f)

    if "customAppcastUrl" not in prefs:
        print("already cleared")
        return 0

    shutil.copy2(PREFS, PREFS + ".bak")
    old = prefs.pop("customAppcastUrl")

    tmp = PREFS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(prefs, f)
    os.replace(tmp, PREFS)

    print(f"removed customAppcastUrl ({old})")
    print(f"remaining keys: {sorted(prefs)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
