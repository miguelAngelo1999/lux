#!/bin/bash
# ============================================================
# Lux — One-line installer
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/miguelAngelo1999/lux/feat/native-ui/install.sh | bash
# ============================================================
set -euo pipefail

APPCAST_URL="https://raw.githubusercontent.com/miguelAngelo1999/lux/feat/native-ui/appcast.json"
APP_DEST="/Applications/Lux.app"
BIN_PATH="$APP_DEST/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/lux_core"
REAL_PATH="${BIN_PATH}_real"
HELPER_DIR="/Library/PrivilegedHelperTools/com.github.igoogolx.lux"
SUDOERS_FILE="/etc/sudoers.d/lux_core"
SCRIPTS_SRC="$APP_DEST/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/scripts"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "  ${GREEN}✔${NC}  $*"; }
warn()    { echo -e "  ${YELLOW}!${NC}  $*"; }
heading() { echo -e "\n${BOLD}$*${NC}"; }
die()     { echo -e "  ${RED}✘${NC}  $*" >&2; exit 1; }

echo ""
echo -e "${BOLD}=====================================${NC}"
echo -e "${BOLD}  Lux Installer${NC}"
echo -e "${BOLD}=====================================${NC}"
echo ""

# ── Require macOS ──────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || die "This installer is for macOS only."

# ── Require curl and python3 ───────────────────────────────
command -v curl   >/dev/null 2>&1 || die "curl not found."
command -v python3 >/dev/null 2>&1 || die "python3 not found."

# ── Fetch latest version from appcast ─────────────────────
heading "Step 1/6  Fetching latest version..."
APPCAST_JSON=$(curl -fsSL "$APPCAST_URL") || die "Failed to fetch appcast from GitHub."
VERSION=$(echo "$APPCAST_JSON"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['version'])")
DMG_URL=$(echo "$APPCAST_JSON"    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['macOS']['url'])")
EXPECTED_SHA=$(echo "$APPCAST_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['macOS']['sha256'])")

info "Latest version: $VERSION"

# Check if already installed and up to date
if [ -d "$APP_DEST" ]; then
    INSTALLED=$(defaults read "$APP_DEST/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0")
    if [ "$INSTALLED" = "$VERSION" ]; then
        info "Lux $VERSION is already installed."
        echo ""
        echo "Re-running setup (elevation + sudoers) to make sure everything is correct..."
    fi
fi

# ── Download DMG ───────────────────────────────────────────
heading "Step 2/6  Downloading Lux $VERSION..."
DMG_FILE="/tmp/Lux-${VERSION}-macOS-universal.dmg"
rm -f "$DMG_FILE"

# GDrive links redirect — follow with -L
curl -fsSL -L --progress-bar "$DMG_URL" -o "$DMG_FILE" || die "Download failed."
info "Downloaded to $DMG_FILE"

# ── Verify checksum ────────────────────────────────────────
heading "Step 3/6  Verifying integrity..."
ACTUAL_SHA=$(shasum -a 256 "$DMG_FILE" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    rm -f "$DMG_FILE"
    die "Checksum mismatch!\n  expected: $EXPECTED_SHA\n  got:      $ACTUAL_SHA"
fi
info "Checksum verified"

# ── Install app ────────────────────────────────────────────
heading "Step 4/6  Installing Lux.app..."

# Kill running instances
launchctl unload "$HOME/Library/LaunchAgents/com.github.igoogolx.lux.core.plist" 2>/dev/null || true
sudo pkill -9 -x lux_core_real 2>/dev/null || true
pkill -9 -x Lux 2>/dev/null || true
sleep 1

# Remove quarantine from DMG itself before mounting
xattr -d com.apple.quarantine "$DMG_FILE" 2>/dev/null || true

# Mount DMG
MOUNT_POINT=$(hdiutil attach "$DMG_FILE" -nobrowse -quiet | awk 'END {print $NF}')
[ -d "$MOUNT_POINT" ] || die "Failed to mount DMG."

# Find Lux.app in the volume
SOURCE_APP=$(find "$MOUNT_POINT" -maxdepth 1 -name "Lux.app" | head -1)
[ -d "$SOURCE_APP" ] || { hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null; die "Lux.app not found in DMG."; }

# Copy to /Applications
sudo rm -rf "$APP_DEST"
sudo cp -R "$SOURCE_APP" "$APP_DEST"
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
rm -f "$DMG_FILE"

# Remove quarantine from installed app
sudo xattr -cr "$APP_DEST"
info "Lux.app installed to /Applications"

# ── Elevation setup ────────────────────────────────────────
heading "Step 5/6  Setting up elevation (TUN mode needs root)..."

if [ -f "$REAL_PATH" ]; then
    sudo chown root:wheel "$REAL_PATH"
    sudo chmod 770 "$REAL_PATH"
    sudo chmod u+s "$REAL_PATH"
    info "lux_core_real permissions set"
elif [ -f "$BIN_PATH" ]; then
    sudo mv "$BIN_PATH" "$REAL_PATH"
    printf '#!/bin/bash\nexec sudo "%s" "$@"\n' "$REAL_PATH" | sudo tee "$BIN_PATH" > /dev/null
    sudo chmod 755 "$BIN_PATH"
    sudo chown root:wheel "$REAL_PATH"
    sudo chmod 770 "$REAL_PATH"
    sudo chmod u+s "$REAL_PATH"
    info "lux_core wrapper created"
else
    warn "lux_core binary not found — TUN mode may not work"
fi

# ── Sudoers ────────────────────────────────────────────────
heading "Step 6/6  Configuring passwordless sudo..."
CURRENT_USER=$(whoami)
sudo mkdir -p "$HELPER_DIR"
sudo chown "$CURRENT_USER":staff "$HELPER_DIR"
sudo chmod 755 "$HELPER_DIR"

# Install helper scripts from app bundle
for SCRIPT in lux_proxy_apply.sh lux_proxy_clear.sh; do
    if [ -f "$SCRIPTS_SRC/$SCRIPT" ]; then
        sudo cp "$SCRIPTS_SRC/$SCRIPT" "$HELPER_DIR/$SCRIPT"
        sudo chown root:wheel "$HELPER_DIR/$SCRIPT"
        sudo chmod 755 "$HELPER_DIR/$SCRIPT"
        info "$SCRIPT installed"
    fi
done

{
    echo "$CURRENT_USER ALL=(root) NOPASSWD: $REAL_PATH *"
    echo "$CURRENT_USER ALL=(root) NOPASSWD: /bin/bash $HELPER_DIR/lux_proxy_apply.sh *"
    echo "$CURRENT_USER ALL=(root) NOPASSWD: /bin/bash $HELPER_DIR/lux_proxy_clear.sh"
    echo "$CURRENT_USER ALL=(root) NOPASSWD: /bin/bash $HELPER_DIR/lux_cert_install.sh"
    echo "$CURRENT_USER ALL=(root) NOPASSWD: /bin/bash $HELPER_DIR/lux_network_reset.sh"
    echo "$CURRENT_USER ALL=(root) NOPASSWD: /bin/bash $HELPER_DIR/lux_updater.sh"
} | sudo tee "$SUDOERS_FILE" > /dev/null
sudo chmod 0440 "$SUDOERS_FILE"
sudo visudo -c -f "$SUDOERS_FILE" 2>/dev/null && info "Passwordless sudo configured" || warn "sudoers validation failed — TUN may require password"

# ── Launch ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=====================================${NC}"
echo -e "${GREEN}${BOLD}  ✔  Lux $VERSION installed!${NC}"
echo -e "${BOLD}=====================================${NC}"
echo ""
echo "  Opening Lux..."
echo ""

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DEST" 2>/dev/null || true
sleep 1
open -a /Applications/Lux.app
