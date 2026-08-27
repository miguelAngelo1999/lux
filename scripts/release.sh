#!/bin/bash
# Release the rebuild lineage.
#
# Usage: bash scripts/release.sh [patch|minor|major]
#
# Differs from the old scripts/bump_and_release.sh in three ways that matter:
#   * operates on /Users/virgoh/lux-clean, not /Users/virgoh/lux
#   * does NOT copy into /Applications; the in-app updater is the only install
#     path, so a later "Check for Updates" can never revert what was just built
#   * never pushes; the caller decides when the branch goes to a remote
#
# Steps: bump pubspec, build, make the DMG, upload to Drive, rewrite appcast.json,
# commit. Prints the DMG url at the end.
set -euo pipefail

REPO=/Users/virgoh/lux-clean
BUMP="${1:-patch}"

export PATH="/opt/homebrew/bin:/Users/virgoh/flutter/bin:$PATH"
# 1090 is Lux's own mixed port and 8079 the always-on preproxy. Prefer 1090 when
# it is up so the release goes out over the same path the app uses; fall back to
# 8079 so a release is still possible while the core is stopped.
if curl -s -o /dev/null --max-time 4 -x http://127.0.0.1:1090 https://example.com; then
  PROXY=http://127.0.0.1:1090
else
  PROXY=http://127.0.0.1:8079
fi
export http_proxy="$PROXY" https_proxy="$PROXY"
export LUX_RELEASE_PROXY="$PROXY"
export DART_IO_ALLOW_BAD_CERTIFICATES=true GIT_SSL_NO_VERIFY=1
echo "# proxy: $PROXY"

cd "$REPO"

# pubspec declares assets/bin/ as a directory, so everything in it is bundled.
# A Windows core left there from scripts/build_core_windows.sh would ship an 18MB
# executable inside the macOS app that it can never run.
# IMPORTANT: only remove the .exe — lux_core (the macOS binary) MUST remain.
if [ -f assets/bin/lux_core.exe ]; then
  echo "# removing assets/bin/lux_core.exe so it is not bundled into the mac app"
  rm -f assets/bin/lux_core.exe
fi

# Safety check: the macOS core MUST exist or the build ships an empty bundle
if [ ! -f assets/bin/lux_core ]; then
  echo "FATAL: assets/bin/lux_core is missing! Cannot build without it."
  echo "Run: cd /path/to/itun2socks-clean && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build ... && lipo ..."
  exit 1
fi

CURRENT=$(grep "^version:" pubspec.yaml | sed 's/version: //' | cut -d'+' -f1)
echo "# current: $CURRENT"

python3 - "$CURRENT" "$BUMP" <<'PYEOF'
import re, sys
cur, bump = sys.argv[1], sys.argv[2]
v = cur.split(".")
if bump == "major":
    v = [str(int(v[0]) + 1), "0", "0"]
elif bump == "minor":
    v = [v[0], str(int(v[1]) + 1), "0"]
else:
    v = [v[0], v[1], str(int(v[2]) + 1)]
new = ".".join(v)
p = "pubspec.yaml"
c = open(p).read()
open(p, "w").write(re.sub(r"^version: .+", f"version: {new}+1", c, flags=re.MULTILINE))
print(f"# bumped: {new}")
PYEOF

VERSION=$(grep "^version:" pubspec.yaml | sed 's/version: //' | cut -d'+' -f1)

echo "# building"
flutter build macos --release --no-pub

APP=build/macos/Build/Products/Release/Lux.app
# Gatekeeper flags a quarantined bundle inside a DMG as damaged.
xattr -cr "$APP"

# Codesign the app if a Developer ID is configured (no-op otherwise).
bash "$REPO/scripts/sign_and_notarize.sh" app "$APP"

DMG_NAME="Lux-${VERSION}-macOS-universal.dmg"
rm -f dist/*.dmg
mkdir -p dist

# Stage DMG contents: Lux.app + install.sh
DMG_STAGE="/tmp/lux-dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
cp "$REPO/macos/install.sh" "$DMG_STAGE/"

# create-dmg only accepts .app bundles; use hdiutil for mixed content
SIZE_KB=$(du -sk "$DMG_STAGE" | awk '{print $1}')
SIZE_KB=$((SIZE_KB + 5000))
hdiutil create -size ${SIZE_KB}k -fs HFS+ -volname "Lux $VERSION" -ov /tmp/lux_tmp.dmg >/dev/null
MOUNT_DIR=$(hdiutil attach /tmp/lux_tmp.dmg | grep "/Volumes" | awk -F'\t' '{print $NF}')
cp -R "$DMG_STAGE/Lux.app" "$MOUNT_DIR/"
cp "$DMG_STAGE/install.sh" "$MOUNT_DIR/"
hdiutil detach "$MOUNT_DIR" >/dev/null
hdiutil convert /tmp/lux_tmp.dmg -format UDZO -o "dist/$DMG_NAME" >/dev/null
rm -f /tmp/lux_tmp.dmg
rm -rf "$DMG_STAGE"
hdiutil verify "dist/$DMG_NAME" >/dev/null
echo "# dmg: $(ls -lh "dist/$DMG_NAME" | awk '{print $5}')"

# Notarize + staple the DMG if a Developer ID is configured (no-op otherwise).
bash "$REPO/scripts/sign_and_notarize.sh" dmg "dist/$DMG_NAME"

echo "# uploading"
python3 "$REPO/scripts/publish_appcast.py" "$VERSION" "dist/$DMG_NAME"

git add pubspec.yaml appcast.json
git commit -m "release: $VERSION"
echo "# committed. push when ready: git push origin rebuild/clean-base"
