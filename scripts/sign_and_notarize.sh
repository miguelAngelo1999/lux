#!/bin/bash
# sign_and_notarize.sh — codesign + notarize a Lux.app and/or DMG.
#
# This is a NO-OP unless signing credentials are set in the environment, so the
# release pipeline works both with and without a paid Apple Developer account:
#
#   * WITHOUT credentials  → prints a note and exits 0 (unsigned build ships,
#                            users install via install.sh as before)
#   * WITH credentials     → signs the app with a Developer ID, notarizes the
#                            DMG through Apple, and staples the ticket
#
# Required env vars to enable signing (all must be set):
#   LUX_SIGN_IDENTITY   e.g. "Developer ID Application: Your Org (TEAMID)"
#   LUX_NOTARY_PROFILE  name of a stored notarytool keychain profile
#                       (created once via: xcrun notarytool store-credentials)
#
# Usage:
#   scripts/sign_and_notarize.sh app  /path/to/Lux.app
#   scripts/sign_and_notarize.sh dmg  /path/to/Lux.dmg
#
# Returns 0 on success OR when signing is disabled; non-zero only on a real
# signing/notarization failure when credentials ARE present.

set -euo pipefail

MODE="${1:-}"
TARGET="${2:-}"

if [ -z "$MODE" ] || [ -z "$TARGET" ]; then
  echo "usage: sign_and_notarize.sh <app|dmg> <path>" >&2
  exit 2
fi

# ── Disabled path: no credentials → skip cleanly ──────────────────────────────
if [ -z "${LUX_SIGN_IDENTITY:-}" ] || [ -z "${LUX_NOTARY_PROFILE:-}" ]; then
  echo "# signing disabled (LUX_SIGN_IDENTITY / LUX_NOTARY_PROFILE not set) — shipping unsigned"
  exit 0
fi

case "$MODE" in
  app)
    echo "# signing app with: $LUX_SIGN_IDENTITY"
    # Sign nested binaries first (the Go core), then the whole bundle.
    # --options runtime enables the hardened runtime, required for notarization.
    ENTITLEMENTS_ARG=()
    if [ -f "$(dirname "$0")/../macos/Runner/Release.entitlements" ]; then
      ENTITLEMENTS_ARG=(--entitlements "$(dirname "$0")/../macos/Runner/Release.entitlements")
    fi

    # Sign the embedded lux_core binary (and _real if the wrapper is present)
    CORE_DIR="$TARGET/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin"
    if [ -f "$CORE_DIR/lux_core" ]; then
      codesign --force --timestamp --options runtime \
        --sign "$LUX_SIGN_IDENTITY" "$CORE_DIR/lux_core" || true
    fi

    # Sign the full app bundle (deep signs frameworks/helpers)
    codesign --force --deep --timestamp --options runtime \
      "${ENTITLEMENTS_ARG[@]}" \
      --sign "$LUX_SIGN_IDENTITY" "$TARGET"

    # Verify
    codesign --verify --deep --strict --verbose=2 "$TARGET"
    echo "# app signed and verified"
    ;;

  dmg)
    echo "# notarizing DMG: $TARGET"
    # Sign the DMG itself
    codesign --force --timestamp --sign "$LUX_SIGN_IDENTITY" "$TARGET"

    # Submit for notarization and wait
    xcrun notarytool submit "$TARGET" \
      --keychain-profile "$LUX_NOTARY_PROFILE" \
      --wait

    # Staple the notarization ticket so it works offline / behind proxies
    xcrun stapler staple "$TARGET"
    xcrun stapler validate "$TARGET"
    echo "# DMG notarized and stapled"
    ;;

  *)
    echo "unknown mode: $MODE (expected app|dmg)" >&2
    exit 2
    ;;
esac
