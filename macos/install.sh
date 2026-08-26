#!/bin/bash
# Lux Installer — run this from the mounted DMG or after copying it locally.
# Usage: paste the one-liner from the download page into Terminal.
#
# What this does:
#   1. Finds the Lux DMG (mounted or in ~/Downloads)
#   2. Removes quarantine attributes
#   3. Ad-hoc signs the app (bypasses Gatekeeper)
#   4. Copies to /Applications
#   5. Sets up elevation (wrapper + sudoers for lux_core)
#   6. Installs corporate proxy CA cert if present on the network
#   7. Opens Lux

set -e

echo "=== Lux Installer ==="

# --- Find Lux.app ---
APP=""
# Check if we're running from a mounted DMG
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$SCRIPT_DIR/Lux.app" ]; then
  APP="$SCRIPT_DIR/Lux.app"
fi

# Check common mounted DMG paths
if [ -z "$APP" ]; then
  for vol in /Volumes/Lux*; do
    if [ -d "$vol/Lux.app" ]; then
      APP="$vol/Lux.app"
      break
    fi
  done
fi

# Check Downloads
if [ -z "$APP" ] && [ -d "$HOME/Downloads/Lux.app" ]; then
  APP="$HOME/Downloads/Lux.app"
fi

if [ -z "$APP" ]; then
  echo "ERROR: Could not find Lux.app. Make sure the DMG is mounted or Lux.app is in ~/Downloads."
  exit 1
fi

echo "Found: $APP"

# --- Remove quarantine ---
echo "Removing quarantine..."
xattr -cr "$APP" 2>/dev/null || true

# --- Ad-hoc code sign (bypasses Gatekeeper without Apple Developer cert) ---
echo "Signing app..."
codesign --force --deep --sign - "$APP" 2>/dev/null || true

# --- Kill existing Lux if running ---
pkill -f "Lux.app" 2>/dev/null || true
sudo pkill -9 -f "lux_core" 2>/dev/null || true
sleep 1

# --- Copy to /Applications ---
echo "Installing to /Applications..."
sudo rm -rf /Applications/Lux.app
sudo cp -R "$APP" /Applications/Lux.app
sudo xattr -cr /Applications/Lux.app

# --- Set up elevation (wrapper + sudoers) ---
echo "Setting up elevation..."
BIN="/Applications/Lux.app/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/bin/lux_core"
REAL="${BIN}_real"
USER_NAME="$(whoami)"

if [ ! -f "$REAL" ]; then
  sudo mv "$BIN" "$REAL"
fi

# Write wrapper script
printf '#!/bin/bash\nexec sudo "%s" "$@"\n' "$REAL" | sudo tee "$BIN" > /dev/null
sudo chmod 755 "$BIN"
sudo chown root:wheel "$REAL"
sudo chmod 770 "$REAL"

# Create helper tools directory
sudo mkdir -p /Library/PrivilegedHelperTools/com.github.igoogolx.lux
sudo chown "$USER_NAME":staff /Library/PrivilegedHelperTools/com.github.igoogolx.lux
sudo chmod 755 /Library/PrivilegedHelperTools/com.github.igoogolx.lux

# Sudoers entry for passwordless sudo
SUDOERS_CONTENT="$USER_NAME ALL=(root) NOPASSWD: $REAL *
$USER_NAME ALL=(root) NOPASSWD: /bin/bash /Library/PrivilegedHelperTools/com.github.igoogolx.lux/lux_proxy_apply.sh *
$USER_NAME ALL=(root) NOPASSWD: /bin/bash /Library/PrivilegedHelperTools/com.github.igoogolx.lux/lux_proxy_clear.sh
$USER_NAME ALL=(root) NOPASSWD: /bin/bash /Library/PrivilegedHelperTools/com.github.igoogolx.lux/lux_cert_install.sh
$USER_NAME ALL=(root) NOPASSWD: /bin/bash /Library/PrivilegedHelperTools/com.github.igoogolx.lux/lux_network_reset.sh
$USER_NAME ALL=(root) NOPASSWD: /bin/bash /Library/PrivilegedHelperTools/com.github.igoogolx.lux/lux_updater.sh"

echo "$SUDOERS_CONTENT" | sudo tee /etc/sudoers.d/lux_core > /dev/null
sudo chmod 0440 /etc/sudoers.d/lux_core

# Validate sudoers
if ! sudo visudo -c -f /etc/sudoers.d/lux_core > /dev/null 2>&1; then
  echo "WARNING: sudoers validation failed, removing invalid file"
  sudo rm -f /etc/sudoers.d/lux_core
fi

# --- Install corporate proxy CA cert (if detectable) ---
# Try to grab the MITM cert from the corporate proxy
PROXY_HOST=""
# Check common corporate proxy addresses
for host in 192.168.68.254:8082 10.8.0.1:8082; do
  if timeout 2 bash -c "echo >/dev/tcp/${host%:*}/${host#*:}" 2>/dev/null; then
    PROXY_HOST="$host"
    break
  fi
done

if [ -n "$PROXY_HOST" ]; then
  echo "Corporate proxy detected at $PROXY_HOST — installing CA cert..."
  CERT_FILE="/tmp/lux_proxy_ca.pem"
  # Connect through the proxy to grab its MITM cert
  echo | openssl s_client -proxy "$PROXY_HOST" -connect www.google.com:443 -showcerts 2>/dev/null | \
    awk '/BEGIN CERT/,/END CERT/{ print }' | \
    awk 'BEGIN{n=0} /BEGIN CERT/{n++} n>1' > "$CERT_FILE" 2>/dev/null || true

  if [ -s "$CERT_FILE" ] && grep -q "BEGIN CERTIFICATE" "$CERT_FILE"; then
    # Install each cert in the chain to System Keychain
    csplit -f /tmp/lux_ca_ -z "$CERT_FILE" '/-----BEGIN CERTIFICATE-----/' '{*}' 2>/dev/null || true
    for f in /tmp/lux_ca_*; do
      if grep -q "BEGIN CERTIFICATE" "$f" 2>/dev/null; then
        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain "$f" 2>/dev/null || true
      fi
    done
    rm -f /tmp/lux_ca_* "$CERT_FILE"
    echo "CA certificate installed."
  else
    rm -f "$CERT_FILE"
    echo "No MITM cert detected (proxy may not intercept TLS). Skipping."
  fi
fi

# --- Open Lux ---
echo "Launching Lux..."
open /Applications/Lux.app

echo ""
echo "=== Done! Lux is installed and running. ==="
echo "If this is your first time, configure your proxy in Settings."
