#!/bin/bash
set -e
export PATH="/opt/homebrew/bin:/Users/virgoh/flutter/bin:$PATH"
export http_proxy=http://127.0.0.1:1090
export https_proxy=http://127.0.0.1:1090
export DART_IO_ALLOW_BAD_CERTIFICATES=true

echo "=== Step 1: Build lux_core (universal) ==="
cd /Users/virgoh/itun2socks
export GONOSUMCHECK="*"
export GONOSUMDB="*"
export GOINSECURE="*"
export GOPROXY="off"

CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
  go build -ldflags="-s -w" -trimpath -tags="with_gvisor" \
  -o /tmp/lux_core_arm64 .

CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 \
  go build -ldflags="-s -w" -trimpath -tags="with_gvisor" \
  -o /tmp/lux_core_amd64 .

lipo -create \
  -output /Users/virgoh/lux/assets/bin/lux_core \
  /tmp/lux_core_arm64 \
  /tmp/lux_core_amd64

file /Users/virgoh/lux/assets/bin/lux_core
echo "✅ lux_core built"

echo ""
echo "=== Step 2: Build Flutter app ==="
sudo chown -R virgoh:staff /Users/virgoh/lux/build/ 2>/dev/null || true
cd /Users/virgoh/lux
flutter build macos --release
echo "✅ Flutter build done"

echo ""
echo "=== Step 3: Package DMG ==="
xattr -cr build/macos/Build/Products/Release/Lux.app
rm -f dist/*.dmg
mkdir -p dist

create-dmg \
  --overwrite \
  --no-code-sign \
  --dmg-title "Lux 1.41.0" \
  build/macos/Build/Products/Release/Lux.app \
  dist/

for f in dist/*.dmg; do
  mv "$f" "dist/Lux-1.41.0-macOS-universal.dmg"
done

hdiutil verify dist/Lux-1.41.0-macOS-universal.dmg
ls -lh dist/Lux-1.41.0-macOS-universal.dmg
echo "✅ DMG ready at lux/dist/Lux-1.41.0-macOS-universal.dmg"
