#!/bin/bash
set -e
export PATH="/opt/homebrew/bin:/Users/virgoh/flutter/bin:$PATH"
export http_proxy=http://127.0.0.1:1090
export https_proxy=http://127.0.0.1:1090
export DART_IO_ALLOW_BAD_CERTIFICATES=true
export GIT_SSL_NO_VERIFY=1
export GONOSUMCHECK="*" GONOSUMDB="*" GOINSECURE="*" GOPROXY="off"

VERSION="1.43.0"

echo "=== Building lux_core ==="
cd /Users/virgoh/itun2socks
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -trimpath -tags="with_gvisor" -o /tmp/lux_core_arm64 .
CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w" -trimpath -tags="with_gvisor" -o /tmp/lux_core_amd64 .
lipo -create -output /Users/virgoh/lux/assets/bin/lux_core /tmp/lux_core_arm64 /tmp/lux_core_amd64
HASH=$(shasum -a 256 /Users/virgoh/lux/assets/bin/lux_core | cut -d' ' -f1)
sed -i '' "s/const darwinUniversalChecksum = \"[^\"]*\"/const darwinUniversalChecksum = \"$HASH\"/" /Users/virgoh/lux/lib/core/checksum.dart
echo "lux_core built hash=$HASH"

echo "=== Building Flutter ==="
cd /Users/virgoh/lux
flutter build macos --release --no-pub
echo "Flutter built"

echo "=== Creating DMG ==="
xattr -cr build/macos/Build/Products/Release/Lux.app
rm -f dist/*.dmg 2>/dev/null || true
mkdir -p dist

# Build a staging folder with app + Gatekeeper fix script
STAGING=$(mktemp -d /tmp/lux_dmg_XXXXXX)
cp -R build/macos/Build/Products/Release/Lux.app "$STAGING/Lux.app"
cp dist/"Fix Gatekeeper.command" "$STAGING/Fix Gatekeeper.command"
# Add /Applications symlink so users can drag Lux.app into it
ln -s /Applications "$STAGING/Applications"

# Create a writable DMG from the staging folder
DMG_TMP="/tmp/lux_tmp.dmg"
DMG_OUT="dist/Lux-${VERSION}-macOS-universal.dmg"
STAGING_SIZE=$(du -sm "$STAGING" | cut -f1)
DMG_SIZE_MB=$((STAGING_SIZE + 20))

hdiutil create -srcfolder "$STAGING" -volname "Lux $VERSION" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 \
  -size ${DMG_SIZE_MB}m "$DMG_OUT"

rm -rf "$STAGING"
echo "DMG created: $DMG_OUT"

DMG="dist/Lux-${VERSION}-macOS-universal.dmg"
DMG_SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
DMG_SIZE=$(wc -c < "$DMG" | tr -d ' ')

echo "DMG: $DMG"
echo "SHA256: $DMG_SHA"
echo "Size: $DMG_SIZE bytes"

# Update appcast.json
python3 - <<PYEOF
import json, os
path = '/Users/virgoh/lux/appcast.json'
d = json.load(open(path))
d['version'] = '${VERSION}'
d['notes'] = 'Auto-reconnect watchdog, self-relaunch on crash, 9-language auto-translation, load balancer health fix, stale TUN cleanup'
d['macOS']['sha256'] = '${DMG_SHA}'
d['macOS']['size'] = ${DMG_SIZE}
# URL will be updated manually after upload to Drive
json.dump(d, open(path, 'w'), indent=2)
print('appcast.json updated')
PYEOF

echo "=== DONE — upload dist/Lux-${VERSION}-macOS-universal.dmg to Drive then update appcast.json macOS.url ==="
