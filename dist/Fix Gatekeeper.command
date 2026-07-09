#!/bin/bash
# Run this AFTER dragging Lux.app to Applications.
# Fixes "Lux is damaged" or "can't be opened" errors on macOS.
echo "====================================="
echo "  Lux — Fix Gatekeeper"
echo "====================================="
echo ""

if [ -d "/Applications/Lux.app" ]; then
    echo "Found Lux.app in /Applications. Removing quarantine..."
    xattr -cr /Applications/Lux.app
    echo ""
    echo "✅ Done! You can now open Lux from your Applications folder."
else
    echo "⚠️  Lux.app not found in /Applications."
    echo ""
    echo "Please drag Lux.app to your Applications folder first,"
    echo "then run this script again."
    echo ""
    echo "Or manually run in Terminal:"
    echo "  xattr -cr /Applications/Lux.app"
fi
echo ""
echo "Press any key to close..."
read -n 1
